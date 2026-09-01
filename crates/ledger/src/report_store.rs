//! The read path's OUTBOUND port — what the report service asks of storage.
//!
//! Its own port rather than a method on [`Repository`](crate::Repository),
//! for the reason that port's own doc gives: it is *"what the **writer**
//! service asks of storage"*, and the rule that comes with it — **one method
//! per statement** — carries over here unchanged. Eight methods, eight
//! statements, each one a scoped read transaction of its own in the adapter.
//!
//! **The bracket is the adapter's** (ADR-0019, ADR-0004): `BEGIN … READ
//! ONLY`, `SET LOCAL ROLE openledger_read`, `SELECT set_config('app.tenant_id',
//! $1, true)` are PostgreSQL's dialect, and the dialect lives in
//! `crates/ledger/postgres`. What that buys, beyond layering: **every method
//! here brackets exactly ONE data statement**, so ADR-0019's isolation ruling
//! is exact rather than approximate — `READ COMMITTED` on a single-statement
//! report, and the `REPEATABLE READ` a multi-statement read would require is
//! a case this port cannot reach. What it costs is that
//! [`ReportStore::read_bounds`] is its own bracket rather than a statement
//! inside the report's, which is one more round trip per pinned report and is
//! the plainest reading of ADR-0019's *"plus whatever the cursor validation
//! costs"*.
//!
//! **Nothing optional reaches SQL.** The `…Read` structs below carry a
//! resolved [`Cursor`] and a resolved `chart_version` — not `Option`s — so
//! ADR-0019's two standing rules (a cursor never arrives as SQL NULL, and
//! `chart_version` is never left to the SQL default) are held by the SHAPE of
//! this port rather than by a statement remembering them. The service is what
//! resolves them; this is what makes forgetting unrepresentable.

use time::OffsetDateTime;
use uuid::Uuid;

use crate::accounts::Account;
use crate::reports::{
    AccountBalance, AccountBalanceQuery, Cursor, StatementLine, Transaction, TransactionQuery,
    TrialBalanceRow,
};
use crate::repository::StorageError;

/// An answer, beside the tenant the read path scoped the session to — which
/// the adapter reads back from `set_config`'s own return value, so it is what
/// the session actually holds and not what the read path meant to set.
///
/// Every method answers in this shape, including the two that pin nothing, so
/// ADR-0019's `tenant_mismatch` check is one comparison in one place and no
/// read can skip it. Vacuous today by construction: the scope is set FROM the
/// requested tenant. It stops being vacuous the day a gateway supplies the
/// scope instead of the body.
pub struct Scoped<T> {
    pub tenant_id: String,
    pub answer: T,
}

/// What the read path has to know before it may pin a report: the cursor's
/// two bounds, and the chart version the book is on.
///
/// All three are read in ONE statement inside ONE scoped read transaction —
/// which is what makes `oldest_entry` **this tenant's** oldest rather than
/// the cluster's (ADR-0019).
pub struct ReadBounds {
    /// `report_cursor()` — `pg_snapshot_xmin`, the cluster's horizon.
    /// Everything strictly below it has committed or aborted and can never
    /// grow.
    pub horizon: Cursor,
    /// The oldest `xact_id` on this tenant's book, or nothing when the book
    /// is empty. The floor a supplied cursor must sit STRICTLY above: the
    /// reports filter `xact_id < :cursor`, so a cursor equal to the oldest
    /// admits nothing and returns the same all-zero fabrication the rule
    /// exists to refuse.
    pub oldest_entry: Option<Cursor>,
    /// `max(version)` over `chart_versions`, or nothing on a book with no
    /// chart seeded. The value the SQL default WOULD have resolved — read
    /// here so the read path can pass it explicitly and know which version
    /// answered (ADR-0019 B6).
    pub chart_version: Option<i32>,
}

/// A trial balance with every value resolved — the shape a statement can be
/// bound from, with no absence left to interpret.
pub struct TrialBalanceRead<'a> {
    pub tenant_id: &'a str,
    pub effective_from: OffsetDateTime,
    pub effective_to: OffsetDateTime,
    pub cursor: Cursor,
}

/// A balance sheet, likewise resolved: one instant, one cursor, one named
/// chart version.
pub struct BalanceSheetRead<'a> {
    pub tenant_id: &'a str,
    pub as_of: OffsetDateTime,
    pub cursor: Cursor,
    pub chart_version: i32,
}

/// An income statement, likewise resolved: a half-open range, one cursor, one
/// named chart version.
pub struct IncomeStatementRead<'a> {
    pub tenant_id: &'a str,
    pub effective_from: OffsetDateTime,
    pub effective_to: OffsetDateTime,
    pub cursor: Cursor,
    pub chart_version: i32,
}

/// One page of the account register, with every value resolved — the shape a
/// statement can be bound from, with no absence left to interpret. `limit` is
/// a plain number here and an `Option` on the query, because choosing the page
/// size is the read path's judgement (the same place the cursor rule lives)
/// and this port is where forgetting to choose is made unrepresentable.
///
/// `after`, `purpose` and `owner_id` stay `Option`s, and that is not the same
/// thing: each is a FILTER whose absence means "do not filter", which is a
/// question the statement answers rather than a decision the service owes it.
pub struct AccountListingRead<'a> {
    pub tenant_id: &'a str,
    pub limit: i64,
    pub after: Option<Uuid>,
    pub purpose: Option<&'a str>,
    pub owner_id: Option<&'a str>,
}

/// Why storage refused a read — the adapter's classification of what the
/// backend said, in this port's own words.
///
/// It is not [`ReadError`](crate::ReadError) and it is not the opaque
/// [`StorageError`] the writer's port carries, and both absences are the
/// point. The SQLSTATEs (`23514`, `57014`, `22P02`) are PostgreSQL's, so
/// reading them is the adapter's job; the STATUS each one deserves is the
/// port's, so naming them is this crate's. The service translates — the same
/// two-enum shape [`SupersedeRefusal`](crate::SupersedeRefusal) has on the
/// write path — and the arms this enum does not have (a cursor refusal, an
/// unknown account) are the ones storage cannot diagnose.
pub enum ReportRefusal {
    /// `23514`: the named chart version does not exist, or the book has none.
    ChartVersionUnknown(String),
    /// `23514`, the A14 arm: the chart version does not present every account
    /// type with posted entries in scope.
    ChartVersionIncomplete(String),
    /// `22P02` and its neighbours: an argument the backend could not read.
    InvalidRequest(String),
    /// `57014`: the read exceeded the read pool's `statement_timeout`.
    TimedOut,
    /// Anything else, opaque.
    Storage(StorageError),
}

/// One method per statement, each running inside its own scoped read
/// transaction. Implemented once, by `PgReportStore`; the generic is the
/// seam's cost, not a plug-in system.
pub trait ReportStore: Send + Sync {
    /// `report_cursor()` alone — the cluster's horizon, one statement, no
    /// report and no bounds.
    ///
    /// It is a method of its own rather than a reading of
    /// [`read_bounds`](ReportStore::read_bounds) because that statement also
    /// takes `min(xact_id)` over this tenant's entries, and a caller who asked
    /// only for the horizon should not pay for an aggregate they did not ask
    /// about. One method per statement, as everywhere on this port.
    fn report_cursor(
        &self,
        tenant_id: &str,
    ) -> impl Future<Output = Result<Scoped<Cursor>, ReportRefusal>> + Send;

    /// The cursor's two bounds and the book's chart version, read inside a
    /// scoped read transaction so the floor is this tenant's.
    fn read_bounds(
        &self,
        tenant_id: &str,
    ) -> impl Future<Output = Result<Scoped<ReadBounds>, ReportRefusal>> + Send;

    /// The posted balance, summed over the account's stripe rows — and
    /// `None` when `ledger_accounts` has no such row, which is the only way
    /// an unknown account can be told from a dormant one.
    fn account_balance(
        &self,
        query: &AccountBalanceQuery,
    ) -> impl Future<Output = Result<Scoped<Option<AccountBalance>>, ReportRefusal>> + Send;

    /// `trial_balance_at`.
    fn trial_balance(
        &self,
        read: &TrialBalanceRead<'_>,
    ) -> impl Future<Output = Result<Scoped<Vec<TrialBalanceRow>>, ReportRefusal>> + Send;

    /// `balance_sheet_at` — which since ADR-0020 reads the period checkpoint
    /// plus two tails rather than aggregating from inception.
    fn balance_sheet(
        &self,
        read: &BalanceSheetRead<'_>,
    ) -> impl Future<Output = Result<Scoped<Vec<StatementLine>>, ReportRefusal>> + Send;

    /// `income_statement_for` — refused the checkpoint structurally
    /// (ADR-0020): it is a flow, and the accounts it reports are exactly the
    /// ones a close zeroes.
    fn income_statement(
        &self,
        read: &IncomeStatementRead<'_>,
    ) -> impl Future<Output = Result<Scoped<Vec<StatementLine>>, ReportRefusal>> + Send;

    /// One transaction and its entries, by primary key — `None` when this
    /// tenant's book has no such transaction.
    fn transaction(
        &self,
        query: &TransactionQuery,
    ) -> impl Future<Output = Result<Scoped<Option<Transaction>>, ReportRefusal>> + Send;

    /// One page of the account register, ordered by `id` and keyed off the
    /// last one seen (ADR-0021). No report function is involved and no cursor
    /// is pinned: the rows carry no commit position to pin against, which is
    /// the cost ADR-0019 already records for an issued report's ROW SET and
    /// which this endpoint widens the door to.
    fn accounts(
        &self,
        read: &AccountListingRead<'_>,
    ) -> impl Future<Output = Result<Scoped<Vec<Account>>, ReportRefusal>> + Send;
}
