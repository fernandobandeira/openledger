//! The report service: ADR-0019's read-path contract, orchestrated in the
//! core over the outbound [`ReportStore`] port, with no SQL in the room.
//!
//! It is deliberately thin, and it owns exactly one thing — **the cursor
//! rule** — because that rule is judgement rather than SQL, and judgement is
//! what keeps an inbound port's implementor from simply being the adapter
//! (ADR-0019 E2). Three sentences are the whole of it:
//!
//! - **an absent cursor is pinned server-side**, and never reaches a report
//!   as SQL NULL — a NULL cursor returns the complete balance-sheet face at
//!   0.00, perfectly balanced, and `recon_equation_breaks(NULL, …)` then
//!   reports zero breaks over the fabrication;
//! - **a supplied cursor is validated before it reaches a report**: it must
//!   parse as `xid8`, sit at or below the current horizon, and sit STRICTLY
//!   above the book's oldest `xact_id`. The database cannot refuse the bad
//!   ones — `-1` wraps to the `xid8` maximum and returns the entire unpinned
//!   book with today's correct numbers, `0` returns the all-zero fabrication,
//!   and both are legal values no `CHECK` and no `STRICT` reaches;
//! - **the cursor used is returned, always**, including when the caller
//!   supplied none: it is the only way a caller can notice that the cluster
//!   horizon is lagging, which it does for reasons outside this database.
//!
//! And one more, of the same kind: **`chart_version` is passed explicitly on
//! every statement call**, never left to the SQL default, which resolves
//! `max(version)` at run time — explicit v1 and the default returned 1 and 3
//! on the same database (ADR-0019 B6).
//!
//! Both bounds are themselves database reads, so *"before it reaches SQL"*
//! means before it reaches a REPORT, not without a round trip — and the floor
//! is read inside a scoped read transaction, which is what makes it that
//! tenant's oldest rather than the cluster's. The race is benign in the one
//! direction that matters: `pg_snapshot_xmin` is non-decreasing, so a cursor
//! valid when it was stored never rises above a later horizon.

use crate::report_store::{
    BalanceSheetRead, IncomeStatementRead, ReadBounds, ReportRefusal, ReportStore, Scoped,
    TrialBalanceRead,
};
use crate::reports::{
    AccountBalance, AccountBalanceQuery, BalanceSheetQuery, Cursor, IncomeStatementQuery,
    ReadError, Reports, Statement, Transaction, TransactionQuery, TrialBalance, TrialBalanceQuery,
};

/// The reader behind the [`Reports`] port, generic over the store. One
/// adapter exists and no second is promised — the generic is the seam's cost,
/// not a plug-in system.
#[derive(Clone)]
pub struct ReportService<S> {
    store: S,
}

impl<S> ReportService<S> {
    pub fn new(store: S) -> Self {
        Self { store }
    }
}

impl<S: ReportStore> Reports for ReportService<S> {
    async fn account_balance(
        &self,
        query: &AccountBalanceQuery,
    ) -> Result<AccountBalance, ReadError> {
        account_balance(&self.store, query).await
    }

    async fn trial_balance(&self, query: &TrialBalanceQuery) -> Result<TrialBalance, ReadError> {
        trial_balance(&self.store, query).await
    }

    async fn balance_sheet(&self, query: &BalanceSheetQuery) -> Result<Statement, ReadError> {
        balance_sheet(&self.store, query).await
    }

    async fn income_statement(&self, query: &IncomeStatementQuery) -> Result<Statement, ReadError> {
        income_statement(&self.store, query).await
    }

    async fn transaction(&self, query: &TransactionQuery) -> Result<Transaction, ReadError> {
        transaction(&self.store, query).await
    }
}

/// One account's posted balance, now — pinned by nothing, so this read never
/// touches the cursor rule. The `SUM` over the account's stripe rows is the
/// statement's; what is decided here is the one thing the balance table
/// cannot decide, and the reason the statement reads `ledger_accounts` too: a
/// balance row is created lazily by the first write, so an unknown account, a
/// dormant one and a currency the account does not hold are all zero rows and
/// a NULL sum. No row back means no such account (ADR-0019 C4).
async fn account_balance<S: ReportStore>(
    store: &S,
    query: &AccountBalanceQuery,
) -> Result<AccountBalance, ReadError> {
    let scoped = store.account_balance(query).await.map_err(refused)?;
    let found = answered_for_the_tenant_that_asked(&query.tenant_id, scoped)?;
    found.ok_or_else(|| ReadError::AccountUnknown {
        account_id: query.account_id,
        currency: query.currency.clone(),
    })
}

/// The trial balance, on both of ADR-0006's axes at once: the cursor is the
/// recorded axis and the half-open range is the effective one, and this
/// service's whole contribution is the first of the two — pin it, or refuse
/// an implausible one, before the report runs.
async fn trial_balance<S: ReportStore>(
    store: &S,
    query: &TrialBalanceQuery,
) -> Result<TrialBalance, ReadError> {
    let bounds = bounds_for_the_book(store, &query.tenant_id).await?;
    let cursor = pin_the_cursor_or_refuse_an_implausible_one(query.cursor.as_deref(), &bounds)?;
    let scoped = store
        .trial_balance(&TrialBalanceRead {
            tenant_id: &query.tenant_id,
            effective_from: query.effective_from,
            effective_to: query.effective_to,
            cursor,
        })
        .await
        .map_err(refused)?;
    let rows = answered_for_the_tenant_that_asked(&query.tenant_id, scoped)?;
    Ok(TrialBalance {
        pinned_cursor: cursor,
        rows,
    })
}

/// The balance-sheet face as at one instant. Two resolutions before the
/// statement runs and neither may be skipped: the cursor, and the chart
/// version — which is named rather than defaulted so the presentation the
/// caller is answered with is the one the read path chose.
async fn balance_sheet<S: ReportStore>(
    store: &S,
    query: &BalanceSheetQuery,
) -> Result<Statement, ReadError> {
    let bounds = bounds_for_the_book(store, &query.tenant_id).await?;
    let cursor = pin_the_cursor_or_refuse_an_implausible_one(query.cursor.as_deref(), &bounds)?;
    let chart_version =
        name_the_chart_version_or_refuse_an_unseeded_book(query.chart_version, &bounds)?;
    let scoped = store
        .balance_sheet(&BalanceSheetRead {
            tenant_id: &query.tenant_id,
            as_of: query.as_of,
            cursor,
            chart_version,
        })
        .await
        .map_err(refused)?;
    let lines = answered_for_the_tenant_that_asked(&query.tenant_id, scoped)?;
    Ok(Statement {
        pinned_cursor: cursor,
        chart_version,
        lines,
    })
}

/// The income statement over a half-open effective range — the same two
/// resolutions as the balance sheet, over the flow rather than the position.
async fn income_statement<S: ReportStore>(
    store: &S,
    query: &IncomeStatementQuery,
) -> Result<Statement, ReadError> {
    let bounds = bounds_for_the_book(store, &query.tenant_id).await?;
    let cursor = pin_the_cursor_or_refuse_an_implausible_one(query.cursor.as_deref(), &bounds)?;
    let chart_version =
        name_the_chart_version_or_refuse_an_unseeded_book(query.chart_version, &bounds)?;
    let scoped = store
        .income_statement(&IncomeStatementRead {
            tenant_id: &query.tenant_id,
            effective_from: query.effective_from,
            effective_to: query.effective_to,
            cursor,
            chart_version,
        })
        .await
        .map_err(refused)?;
    let lines = answered_for_the_tenant_that_asked(&query.tenant_id, scoped)?;
    Ok(Statement {
        pinned_cursor: cursor,
        chart_version,
        lines,
    })
}

/// One transaction and its entries — pinned by nothing, because the rows are
/// immutable (ADR-0019 C3), so this read has no cursor rule to apply either.
async fn transaction<S: ReportStore>(
    store: &S,
    query: &TransactionQuery,
) -> Result<Transaction, ReadError> {
    let scoped = store.transaction(query).await.map_err(refused)?;
    let found = answered_for_the_tenant_that_asked(&query.tenant_id, scoped)?;
    found.ok_or(ReadError::TransactionUnknown {
        transaction_id: query.transaction_id,
    })
}

/// The horizon, the floor and the book's chart version — one statement in one
/// scoped read transaction, and the round trip ADR-0019 accepts as the price
/// of refusing a plausible-looking cursor.
async fn bounds_for_the_book<S: ReportStore>(
    store: &S,
    tenant_id: &str,
) -> Result<ReadBounds, ReadError> {
    let scoped = store.read_bounds(tenant_id).await.map_err(refused)?;
    answered_for_the_tenant_that_asked(tenant_id, scoped)
}

/// ADR-0019's cursor rule, whole.
///
/// An absent cursor is the horizon, pinned here so the caller can store what
/// they were answered at; a supplied one is refused unless it is an `xid8`
/// inside the plausible range. **Strictly** above the floor, because the
/// reports filter `xact_id < :cursor` and a cursor equal to the oldest
/// `xact_id` admits nothing — returning the same all-zero, perfectly balanced
/// fabrication the rule exists to refuse. On a book with no entries at all
/// there is no floor to be above, and any cursor at or below the horizon
/// truthfully answers "nothing".
///
/// The refusal names which bound was missed, because a caller replaying a
/// stored cursor against a restored database needs to know which end they
/// fell off: `xid8` does not survive a logical restore.
fn pin_the_cursor_or_refuse_an_implausible_one(
    supplied: Option<&str>,
    bounds: &ReadBounds,
) -> Result<Cursor, ReadError> {
    let Some(supplied) = supplied else {
        return Ok(bounds.horizon);
    };
    let cursor = Cursor::parse(supplied).map_err(|_| {
        ReadError::InvalidRequest(format!(
            "cursor {supplied:?} is not an xid8; a cursor is the decimal commit position a \
             report was pinned at, as returned in pinned_cursor"
        ))
    })?;
    if cursor > bounds.horizon {
        return Err(ReadError::CursorInvalid(format!(
            "cursor {cursor} is above this cluster's report horizon ({}); nothing at or above \
             the horizon has finished committing, so a report pinned there is not reproducible",
            bounds.horizon
        )));
    }
    if let Some(oldest) = bounds.oldest_entry
        && cursor <= oldest
    {
        return Err(ReadError::CursorInvalid(format!(
            "cursor {cursor} is at or below the oldest entry on this book ({oldest}); a report \
             is filtered xact_id < cursor, so this admits nothing and would answer an all-zero, \
             perfectly balanced book"
        )));
    }
    Ok(cursor)
}

/// ADR-0019 B6: the chart version the statement is presented at is NAMED, on
/// every call. A caller who named one is taken at their word — the function
/// refuses a version that does not exist, and re-asking here would be a
/// second opinion on the same question. A caller who named none gets the
/// version the book is on, resolved by the read path so that the value passed
/// to the function is a value this service knows and can report back.
///
/// A book with no chart at all is refused HERE rather than by letting the
/// absence travel: passing NULL is what makes the SQL default resolve, and
/// the read path never lets it.
fn name_the_chart_version_or_refuse_an_unseeded_book(
    asked_for: Option<i32>,
    bounds: &ReadBounds,
) -> Result<i32, ReadError> {
    asked_for.or(bounds.chart_version).ok_or_else(|| {
        ReadError::ChartVersionUnknown(
            "this database has no chart version: seed a chart before running a statement"
                .to_owned(),
        )
    })
}

/// ADR-0019's `tenant_mismatch`, on every read including the two that pin
/// nothing: the scope the session actually holds — read back from
/// `set_config`'s own return value — against the tenant the request named.
///
/// **Vacuous today by construction**, since the read path scopes the session
/// FROM the requested tenant, and implemented anyway: it is the only
/// mitigation available inside the fence, where a wrong `tenant_id` is
/// otherwise answered with the same silence as an empty book, and it stops
/// being vacuous the day a gateway supplies the scope instead of the body.
fn answered_for_the_tenant_that_asked<T>(
    requested: &str,
    scoped: Scoped<T>,
) -> Result<T, ReadError> {
    if scoped.tenant_id == requested {
        return Ok(scoped.answer);
    }
    Err(ReadError::TenantMismatch {
        requested: requested.to_owned(),
        scoped: scoped.tenant_id,
    })
}

/// Storage's refusal in the inbound port's grammar — the one place the two
/// enums meet. Exhaustive by construction: a new [`ReportRefusal`] variant
/// does not compile until it is given a [`ReadError`] to arrive as, and so a
/// status.
fn refused(refusal: ReportRefusal) -> ReadError {
    match refusal {
        ReportRefusal::ChartVersionUnknown(detail) => ReadError::ChartVersionUnknown(detail),
        ReportRefusal::ChartVersionIncomplete(detail) => ReadError::ChartVersionIncomplete(detail),
        ReportRefusal::InvalidRequest(detail) => ReadError::InvalidRequest(detail),
        ReportRefusal::TimedOut => ReadError::ReportTimedOut,
        ReportRefusal::Storage(failure) => ReadError::Storage(failure),
    }
}

#[cfg(test)]
mod tests {
    //! The cursor rule over a fake store — read top to bottom, the test names
    //! are the rule. What they hold is the JUDGEMENT and the ROUND-TRIP
    //! SHAPE: which cursor reaches the report, which chart version reaches
    //! it, which supplied values are refused and by which name, and that a
    //! refused cursor never lets a report run at all. What the SQL does — the
    //! `xact_id < :cursor` filter, the RLS fence, the `set_config` bracket —
    //! stays proven by the e2e suite against real PostgreSQL; nothing here
    //! re-proves it, and nothing here could.
    //!
    //! Every store call is one scoped read transaction in the adapter, so the
    //! call log below IS the bracket count: a pinned report costs two — the
    //! bounds, then the report — and a refused cursor costs one.

    use std::sync::{Arc, Mutex, PoisonError};

    use time::OffsetDateTime;
    use uuid::Uuid;

    use super::*;
    use crate::reports::{CursorUnparseable, StatementLine, TransactionEntry, TrialBalanceRow};

    /// The book every test below reads against: its oldest entry sits at 100,
    /// the cluster horizon is 900, and the chart is on version 3. Every
    /// cursor case is a value held against those two bounds.
    const OLDEST: &str = "100";
    const HORIZON: &str = "900";
    const CURRENT_CHART: i32 = 3;

    const ACCOUNT: Uuid = Uuid::from_u128(1);
    const TRANSACTION: Uuid = Uuid::from_u128(0xF0);
    const EVENT: Uuid = Uuid::from_u128(0xE0);

    /// The value is irrelevant to every test below; only the shape matters.
    fn an_instant() -> OffsetDateTime {
        OffsetDateTime::UNIX_EPOCH
    }

    fn a_trial_balance_query(cursor: Option<&str>) -> TrialBalanceQuery {
        TrialBalanceQuery {
            tenant_id: "acme".to_owned(),
            effective_from: an_instant(),
            effective_to: an_instant(),
            cursor: cursor.map(str::to_owned),
        }
    }

    fn a_balance_sheet_query(
        cursor: Option<&str>,
        chart_version: Option<i32>,
    ) -> BalanceSheetQuery {
        BalanceSheetQuery {
            tenant_id: "acme".to_owned(),
            as_of: an_instant(),
            cursor: cursor.map(str::to_owned),
            chart_version,
        }
    }

    fn an_income_statement_query(
        cursor: Option<&str>,
        chart_version: Option<i32>,
    ) -> IncomeStatementQuery {
        IncomeStatementQuery {
            tenant_id: "acme".to_owned(),
            effective_from: an_instant(),
            effective_to: an_instant(),
            cursor: cursor.map(str::to_owned),
            chart_version,
        }
    }

    fn an_account_balance_query() -> AccountBalanceQuery {
        AccountBalanceQuery {
            tenant_id: "acme".to_owned(),
            account_id: ACCOUNT,
            currency: "USD".to_owned(),
        }
    }

    fn a_transaction_query() -> TransactionQuery {
        TransactionQuery {
            tenant_id: "acme".to_owned(),
            transaction_id: TRANSACTION,
        }
    }

    /// The fake's futures are always immediately ready, so one poll with a
    /// no-op waker is a complete executor; the loop never observes `Pending`.
    fn run<F: Future>(future: F) -> F::Output {
        let mut future = std::pin::pin!(future);
        let mut cx = std::task::Context::from_waker(std::task::Waker::noop());
        loop {
            if let std::task::Poll::Ready(out) = future.as_mut().poll(&mut cx) {
                return out;
            }
        }
    }

    /// The call log, shared out of the fake before the service consumes it.
    /// One entry per store call, and each entry SPELLS what reached the
    /// statement — the cursor, and the chart version — so a test can hold
    /// the values that went to SQL and not only the ones that came back.
    type Calls = Arc<Mutex<Vec<String>>>;

    /// What the backend said, as the adapter would have classified it —
    /// built on demand, because each case below needs its own.
    type Diagnosis = fn() -> ReportRefusal;

    fn taken(calls: &Calls) -> Vec<String> {
        calls.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// A store of answers, no database: each builder names the situation the
    /// real SQL would produce.
    struct FakeStore {
        oldest_entry: Option<Cursor>,
        horizon: Cursor,
        chart_version: Option<i32>,
        /// The tenant `set_config` reports back. Equal to the requested one
        /// on every honest read; a different value is the mismatch the fence
        /// cannot produce today and the check exists for.
        scopes_to: Option<&'static str>,
        /// What a report statement answers instead of rows.
        refuses_reports_with: Option<Diagnosis>,
        /// Whether the account and the transaction asked about exist.
        holds_the_row: bool,
        calls: Calls,
    }

    impl FakeStore {
        /// A book with entries, a chart, and everything asked for present.
        fn a_book() -> Result<Self, CursorUnparseable> {
            Ok(Self {
                oldest_entry: Some(Cursor::parse(OLDEST)?),
                horizon: Cursor::parse(HORIZON)?,
                chart_version: Some(CURRENT_CHART),
                scopes_to: None,
                refuses_reports_with: None,
                holds_the_row: true,
                calls: Calls::default(),
            })
        }

        /// A book with no entries at all: there is no floor to be above.
        fn a_book_with_no_entries() -> Result<Self, CursorUnparseable> {
            let mut fake = Self::a_book()?;
            fake.oldest_entry = None;
            Ok(fake)
        }

        /// A database on which nobody has seeded a chart — the one case the
        /// read path must refuse rather than let travel as an absence.
        fn a_book_with_no_chart() -> Result<Self, CursorUnparseable> {
            let mut fake = Self::a_book()?;
            fake.chart_version = None;
            Ok(fake)
        }

        /// The session is scoped to a DIFFERENT tenant than the one asked
        /// about — vacuous through the shipped bracket, which is why it takes
        /// a fake to reach at all.
        fn a_book_scoped_to(tenant_id: &'static str) -> Result<Self, CursorUnparseable> {
            let mut fake = Self::a_book()?;
            fake.scopes_to = Some(tenant_id);
            Ok(fake)
        }

        /// The report statement refuses: the backend's own diagnosis, as the
        /// adapter classifies it.
        fn a_book_whose_report_refuses(refusal: Diagnosis) -> Result<Self, CursorUnparseable> {
            let mut fake = Self::a_book()?;
            fake.refuses_reports_with = Some(refusal);
            Ok(fake)
        }

        /// The account (or the transaction) named does not exist on this
        /// book: `ledger_accounts` answers no row.
        fn a_book_without_the_row() -> Result<Self, CursorUnparseable> {
            let mut fake = Self::a_book()?;
            fake.holds_the_row = false;
            Ok(fake)
        }

        fn calls(&self) -> Calls {
            Arc::clone(&self.calls)
        }

        fn record(&self, call: String) {
            self.calls
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(call);
        }

        fn scoped<T>(&self, requested: &str, answer: T) -> Scoped<T> {
            Scoped {
                tenant_id: self.scopes_to.unwrap_or(requested).to_owned(),
                answer,
            }
        }

        /// One statement's answer: the rows, or the refusal this fake was
        /// built to produce.
        fn statement_lines(&self) -> Result<Vec<StatementLine>, ReportRefusal> {
            if let Some(refusal) = self.refuses_reports_with {
                return Err(refusal());
            }
            Ok(vec![StatementLine {
                currency: "USD".to_owned(),
                fs_line: "cash".to_owned(),
                caption: "Cash".to_owned(),
                sort_order: 100,
                amount_minor: "18446744073709551616".to_owned(),
                side: "asset".to_owned(),
            }])
        }
    }

    impl ReportStore for FakeStore {
        async fn read_bounds(&self, tenant_id: &str) -> Result<Scoped<ReadBounds>, ReportRefusal> {
            self.record("read_bounds".to_owned());
            Ok(self.scoped(
                tenant_id,
                ReadBounds {
                    horizon: self.horizon,
                    oldest_entry: self.oldest_entry,
                    chart_version: self.chart_version,
                },
            ))
        }

        async fn account_balance(
            &self,
            query: &AccountBalanceQuery,
        ) -> Result<Scoped<Option<AccountBalance>>, ReportRefusal> {
            self.record("account_balance".to_owned());
            // A dormant account is a row with a zero sum, never an absence:
            // that distinction is the reason the statement reads
            // `ledger_accounts` at all.
            let found = self.holds_the_row.then(|| AccountBalance {
                account_id: query.account_id,
                currency: query.currency.clone(),
                posted_minor: "0".to_owned(),
            });
            Ok(self.scoped(&query.tenant_id, found))
        }

        async fn trial_balance(
            &self,
            read: &TrialBalanceRead<'_>,
        ) -> Result<Scoped<Vec<TrialBalanceRow>>, ReportRefusal> {
            self.record(format!("trial_balance at {}", read.cursor));
            if let Some(refusal) = self.refuses_reports_with {
                return Err(refusal());
            }
            Ok(self.scoped(
                read.tenant_id,
                vec![TrialBalanceRow {
                    account_id: ACCOUNT,
                    purpose: "operating_cash".to_owned(),
                    category: "asset".to_owned(),
                    currency: "USD".to_owned(),
                    debits: "100".to_owned(),
                    credits: "0".to_owned(),
                    balance_debit_positive: "100".to_owned(),
                }],
            ))
        }

        async fn balance_sheet(
            &self,
            read: &BalanceSheetRead<'_>,
        ) -> Result<Scoped<Vec<StatementLine>>, ReportRefusal> {
            self.record(format!(
                "balance_sheet at {} v{}",
                read.cursor, read.chart_version
            ));
            Ok(self.scoped(read.tenant_id, self.statement_lines()?))
        }

        async fn income_statement(
            &self,
            read: &IncomeStatementRead<'_>,
        ) -> Result<Scoped<Vec<StatementLine>>, ReportRefusal> {
            self.record(format!(
                "income_statement at {} v{}",
                read.cursor, read.chart_version
            ));
            Ok(self.scoped(read.tenant_id, self.statement_lines()?))
        }

        async fn transaction(
            &self,
            query: &TransactionQuery,
        ) -> Result<Scoped<Option<Transaction>>, ReportRefusal> {
            self.record("transaction".to_owned());
            let found = self.holds_the_row.then(|| Transaction {
                transaction_id: query.transaction_id,
                kind: "posting".to_owned(),
                status: "pending".to_owned(),
                effective_at: an_instant(),
                recorded_at: an_instant(),
                resolves_id: None,
                reverses_id: None,
                event_id: EVENT,
                entries: vec![TransactionEntry {
                    account_id: ACCOUNT,
                    direction: "debit".to_owned(),
                    amount_minor: 100,
                    currency: "USD".to_owned(),
                    account_seq: 1,
                }],
            });
            Ok(self.scoped(&query.tenant_id, found))
        }
    }

    /// One refusal, rendered as the sentence it makes, so a table of cursor
    /// cases reads as a table of meanings rather than a nest of matches.
    fn spoken<T>(answer: &Result<T, ReadError>) -> &'static str {
        match answer {
            Ok(_) => "answered",
            Err(ReadError::InvalidRequest(_)) => "invalid_request",
            Err(ReadError::CursorInvalid(_)) => "cursor_invalid",
            Err(ReadError::ChartVersionUnknown(_)) => "chart_version_unknown",
            Err(ReadError::ChartVersionIncomplete(_)) => "chart_version_incomplete",
            Err(ReadError::AccountUnknown { .. }) => "account_unknown",
            Err(ReadError::TransactionUnknown { .. }) => "transaction_unknown",
            Err(ReadError::TenantMismatch { .. }) => "tenant_mismatch",
            Err(ReadError::ReportTimedOut) => "report_timed_out",
            Err(ReadError::Internal(_)) => "internal",
            Err(ReadError::Storage(_)) => "storage",
        }
    }

    #[test]
    fn an_absent_cursor_is_pinned_to_the_horizon_and_the_horizon_is_what_reaches_the_report()
    -> Result<(), CursorUnparseable> {
        let store = FakeStore::a_book()?;
        let calls = store.calls();
        let service = ReportService::new(store);
        let query = a_trial_balance_query(None);

        let answered = run(service.trial_balance(&query));

        // The pinned value is the caller's to store, so it must be the value
        // the report ran at — and it is asserted on BOTH sides: what came
        // back, and what the statement was handed.
        assert_eq!(
            answered.map(|report| report.pinned_cursor.to_string()).ok(),
            Some(HORIZON.to_owned())
        );
        assert_eq!(
            taken(&calls),
            [
                "read_bounds".to_owned(),
                format!("trial_balance at {HORIZON}")
            ]
        );
        Ok(())
    }

    #[test]
    fn a_supplied_cursor_inside_the_plausible_range_reaches_the_report_unchanged()
    -> Result<(), CursorUnparseable> {
        let store = FakeStore::a_book()?;
        let calls = store.calls();
        let service = ReportService::new(store);
        let query = a_trial_balance_query(Some("450"));

        let answered = run(service.trial_balance(&query));

        assert_eq!(
            answered.map(|report| report.pinned_cursor.to_string()).ok(),
            Some("450".to_owned())
        );
        assert_eq!(
            taken(&calls),
            ["read_bounds".to_owned(), "trial_balance at 450".to_owned()]
        );
        Ok(())
    }

    /// The horizon itself is a legal cursor: everything strictly below it has
    /// finished committing, which is exactly what a report filtered
    /// `xact_id < :cursor` needs.
    #[test]
    fn a_cursor_exactly_at_the_horizon_is_accepted() -> Result<(), CursorUnparseable> {
        let store = FakeStore::a_book()?;
        let service = ReportService::new(store);
        let query = a_trial_balance_query(Some(HORIZON));

        let answered = run(service.trial_balance(&query));

        assert_eq!(spoken(&answered), "answered");
        Ok(())
    }

    /// ADR-0019's floor, and the reason it is STRICT: a report is filtered
    /// `xact_id < :cursor`, so a cursor at the oldest entry admits nothing
    /// and answers an all-zero, perfectly balanced book — the fabrication the
    /// rule exists to refuse, not a report of an empty period.
    #[test]
    fn a_cursor_at_or_below_the_books_oldest_entry_is_refused_as_an_implausible_cursor()
    -> Result<(), CursorUnparseable> {
        for supplied in ["0", "1", "99", OLDEST] {
            let store = FakeStore::a_book()?;
            let calls = store.calls();
            let service = ReportService::new(store);
            let query = a_trial_balance_query(Some(supplied));

            let answered = run(service.trial_balance(&query));

            assert_eq!(spoken(&answered), "cursor_invalid", "for cursor {supplied}");
            // Refused BEFORE the report: the bounds were read, and nothing
            // else ran. A cursor the database cannot refuse must not reach
            // it.
            assert_eq!(
                taken(&calls),
                ["read_bounds".to_owned()],
                "for cursor {supplied}"
            );
        }
        Ok(())
    }

    /// The other end, and the one that looks right: `'-1'::xid8` is accepted
    /// by PostgreSQL and wraps to the `xid8` maximum, which returns the
    /// ENTIRE unpinned book with today's correct numbers. Above the horizon
    /// is where the wrap lands, and above the horizon is refused.
    #[test]
    fn a_cursor_above_the_horizon_is_refused_including_the_one_that_wraps()
    -> Result<(), CursorUnparseable> {
        for supplied in ["901", "18446744073709551615", "-1"] {
            let store = FakeStore::a_book()?;
            let calls = store.calls();
            let service = ReportService::new(store);
            let query = a_trial_balance_query(Some(supplied));

            let answered = run(service.trial_balance(&query));

            assert_eq!(spoken(&answered), "cursor_invalid", "for cursor {supplied}");
            assert_eq!(
                taken(&calls),
                ["read_bounds".to_owned()],
                "for cursor {supplied}"
            );
        }
        Ok(())
    }

    /// A cursor that is not an `xid8` at all is the `22P02` class, and it
    /// answers under the name ADR-0014 grandfathers for a malformed value —
    /// not `cursor_invalid`, which is reserved for a LEGAL value the database
    /// would have accepted.
    #[test]
    fn a_cursor_that_is_not_an_xid8_is_refused_as_a_malformed_request()
    -> Result<(), CursorUnparseable> {
        for supplied in ["not-a-cursor", "", "1.5", "12x", "18446744073709551616"] {
            let store = FakeStore::a_book()?;
            let calls = store.calls();
            let service = ReportService::new(store);
            let query = a_trial_balance_query(Some(supplied));

            let answered = run(service.trial_balance(&query));

            assert_eq!(
                spoken(&answered),
                "invalid_request",
                "for cursor {supplied:?}"
            );
            assert_eq!(
                taken(&calls),
                ["read_bounds".to_owned()],
                "for cursor {supplied:?}"
            );
        }
        Ok(())
    }

    /// A book with no entries has no floor, so the strictness has nothing to
    /// be strict about: any cursor at or below the horizon truthfully answers
    /// "nothing", including zero.
    #[test]
    fn on_a_book_with_no_entries_there_is_no_floor_to_be_above() -> Result<(), CursorUnparseable> {
        let store = FakeStore::a_book_with_no_entries()?;
        let service = ReportService::new(store);
        let query = a_trial_balance_query(Some("0"));

        let answered = run(service.trial_balance(&query));

        assert_eq!(spoken(&answered), "answered");
        Ok(())
    }

    /// ADR-0019 B6, on both statement routes: the version reaching the
    /// function is never absent — a caller's is taken as given, and a caller
    /// who named none gets the version the book is on, resolved here so the
    /// read path knows what answered.
    #[test]
    fn a_statement_always_passes_a_named_chart_version_and_reports_the_one_it_used()
    -> Result<(), CursorUnparseable> {
        let cases = [(None, CURRENT_CHART), (Some(1), 1)];
        for (asked_for, expected) in cases {
            let store = FakeStore::a_book()?;
            let calls = store.calls();
            let service = ReportService::new(store);
            let query = a_balance_sheet_query(Some("450"), asked_for);

            let answered = run(service.balance_sheet(&query));

            assert_eq!(
                answered.map(|face| face.chart_version).ok(),
                Some(expected),
                "for a request naming {asked_for:?}"
            );
            assert_eq!(
                taken(&calls),
                [
                    "read_bounds".to_owned(),
                    format!("balance_sheet at 450 v{expected}")
                ],
                "for a request naming {asked_for:?}"
            );
        }
        Ok(())
    }

    #[test]
    fn an_income_statement_pins_the_same_two_values_the_balance_sheet_does()
    -> Result<(), CursorUnparseable> {
        let store = FakeStore::a_book()?;
        let calls = store.calls();
        let service = ReportService::new(store);
        let query = an_income_statement_query(None, None);

        let answered = run(service.income_statement(&query));

        assert_eq!(spoken(&answered), "answered");
        assert_eq!(
            taken(&calls),
            [
                "read_bounds".to_owned(),
                format!("income_statement at {HORIZON} v{CURRENT_CHART}")
            ]
        );
        Ok(())
    }

    /// The absence the read path must not forward: passing NULL is what makes
    /// the SQL default resolve, so an unseeded book is refused here by name
    /// rather than answered by the function's own guard.
    #[test]
    fn a_book_with_no_chart_version_is_refused_before_the_statement_runs()
    -> Result<(), CursorUnparseable> {
        let store = FakeStore::a_book_with_no_chart()?;
        let calls = store.calls();
        let service = ReportService::new(store);
        let query = a_balance_sheet_query(None, None);

        let answered = run(service.balance_sheet(&query));

        assert_eq!(spoken(&answered), "chart_version_unknown");
        assert_eq!(taken(&calls), ["read_bounds".to_owned()]);
        Ok(())
    }

    /// The statement's own refusals, as the adapter classifies them and the
    /// port names them. A `type` crossed here hands the caller the wrong
    /// instruction — which is what an error is for.
    #[test]
    fn a_statements_own_refusal_arrives_under_its_own_name() -> Result<(), CursorUnparseable> {
        let cases: [(Diagnosis, &str); 4] = [
            (
                || ReportRefusal::ChartVersionUnknown("v999".to_owned()),
                "chart_version_unknown",
            ),
            (
                || ReportRefusal::ChartVersionIncomplete("type_unpresented".to_owned()),
                "chart_version_incomplete",
            ),
            (
                || ReportRefusal::InvalidRequest("22P02".to_owned()),
                "invalid_request",
            ),
            (|| ReportRefusal::TimedOut, "report_timed_out"),
        ];
        for (refusal, expected) in cases {
            let store = FakeStore::a_book_whose_report_refuses(refusal)?;
            let service = ReportService::new(store);
            let query = a_balance_sheet_query(Some("450"), Some(1));

            let answered = run(service.balance_sheet(&query));

            assert_eq!(spoken(&answered), expected);
        }
        Ok(())
    }

    /// ADR-0019 C4: only `ledger_accounts` can tell an unknown account from a
    /// dormant one, and the two must not answer alike — a dormant account is
    /// a balance of zero, and a missing one is refused by name.
    #[test]
    fn a_dormant_account_answers_zero_and_an_unknown_one_is_refused()
    -> Result<(), CursorUnparseable> {
        let store = FakeStore::a_book()?;
        let service = ReportService::new(store);
        let query = an_account_balance_query();

        let answered = run(service.account_balance(&query));

        assert_eq!(
            answered.map(|balance| balance.posted_minor).ok(),
            Some("0".to_owned())
        );

        let store = FakeStore::a_book_without_the_row()?;
        let calls = store.calls();
        let service = ReportService::new(store);

        let answered = run(service.account_balance(&query));

        assert_eq!(spoken(&answered), "account_unknown");
        // No bounds read on this route: it means POSTED, NOW, and pinning it
        // to a cursor would be a second definition of a balance.
        assert_eq!(taken(&calls), ["account_balance".to_owned()]);
        Ok(())
    }

    #[test]
    fn an_unknown_transaction_is_refused_by_name_and_reads_no_cursor()
    -> Result<(), CursorUnparseable> {
        let store = FakeStore::a_book_without_the_row()?;
        let calls = store.calls();
        let service = ReportService::new(store);
        let query = a_transaction_query();

        let answered = run(service.transaction(&query));

        assert_eq!(spoken(&answered), "transaction_unknown");
        assert_eq!(taken(&calls), ["transaction".to_owned()]);
        Ok(())
    }

    /// The transaction read carries the three things ADR-0016 made wire
    /// concepts a caller could not read back — and `status` is the one an
    /// integrator posting a pending transaction has no other way to confirm.
    #[test]
    fn a_transaction_read_back_carries_its_status() -> Result<(), CursorUnparseable> {
        let store = FakeStore::a_book()?;
        let service = ReportService::new(store);
        let query = a_transaction_query();

        let answered = run(service.transaction(&query));

        assert_eq!(
            answered.map(|found| found.status).ok(),
            Some("pending".to_owned())
        );
        Ok(())
    }

    /// ADR-0019's `tenant_mismatch`: vacuous through the shipped bracket,
    /// which is why only a fake can reach it — and held anyway, because the
    /// day a gateway supplies the scope instead of the body is the day it
    /// stops being vacuous. It is checked on EVERY read, including the two
    /// that pin nothing.
    #[test]
    fn a_read_scoped_to_another_tenant_is_refused_on_every_route() -> Result<(), CursorUnparseable>
    {
        let store = FakeStore::a_book_scoped_to("someone-else")?;
        let service = ReportService::new(store);

        let refused = [
            spoken(&run(service.trial_balance(&a_trial_balance_query(None)))),
            spoken(&run(
                service.balance_sheet(&a_balance_sheet_query(None, None))
            )),
            spoken(&run(
                service.income_statement(&an_income_statement_query(None, None))
            )),
            spoken(&run(service.account_balance(&an_account_balance_query()))),
            spoken(&run(service.transaction(&a_transaction_query()))),
        ];

        assert_eq!(refused, ["tenant_mismatch"; 5]);
        Ok(())
    }

    /// The amount a report carries is a STRING all the way through the core,
    /// and this is the value that makes it necessary: 2⁶⁴, which no JSON
    /// number can carry and which `numeric` can (ADR-0019).
    #[test]
    fn a_statement_amount_larger_than_a_json_number_survives_the_core()
    -> Result<(), CursorUnparseable> {
        let store = FakeStore::a_book()?;
        let service = ReportService::new(store);
        let query = a_balance_sheet_query(None, None);

        let answered = run(service.balance_sheet(&query));

        assert_eq!(
            answered
                .ok()
                .and_then(|face| face.lines.first().map(|line| line.amount_minor.clone())),
            Some("18446744073709551616".to_owned())
        );
        Ok(())
    }
}
