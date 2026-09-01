//! The report store: [`PgReportStore`] and its [`ledger::ReportStore`] impl,
//! one SQL statement per method, each inside a scoped read transaction this
//! file also owns. What order the reads run in — and which cursor and which
//! chart version they run at — is the report service's (`ledger::ReportService`,
//! in the core crate above), not this file's.
//!
//! **The bracket is the subject here, not an implementation detail.**
//! ADR-0019 makes four statements load-bearing before any report runs, and
//! each of them is a refusal of something that was measured to fail:
//!
//! 1. **`BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY`.** The transaction
//!    is mandatory because of the tenant fence rather than isolation:
//!    `set_config(…, is_local => true)` outside a transaction is discarded
//!    before the next statement, so an autocommit read is
//!    unscoped-and-empty forever. `READ COMMITTED` because one statement is
//!    one snapshot at every isolation level, and every bracket below carries
//!    exactly one data statement — `REPEATABLE READ` would buy nothing and
//!    would hold the cluster horizon for the transaction's idle time as well
//!    as the statement's. `READ ONLY` because it binds immediately and turns
//!    a write smuggled into a read path into a refusal by the transaction
//!    rather than by a grant.
//! 2. **`SET LOCAL ROLE openledger_read`.** RLS applies to `current_user`, and
//!    the read pool's `SET ROLE` in `after_connect` is escapable
//!    (`RESET ROLE` climbs back to the login). This is the belt to that
//!    braces, and it is what keeps the fence if a deployment ever wires one
//!    login for both paths — a login that is a member of both
//!    `openledger_app` and `openledger_read` reads **every tenant**, because
//!    RLS policies are permissive and OR'd and the writer's `USING (true)`
//!    unions with the reader's tenant qual.
//! 3. **`SELECT set_config('app.tenant_id', $1, true)`** — with a BIND
//!    parameter. Not `SET`, which takes no bind; not `SET LOCAL`, same;
//!    never interpolation, because `tenant_id` is caller-supplied text from
//!    a request body (ADR-0017) and this is the only form that carries it as
//!    data rather than as SQL. This refines ADR-0013 §5's `SET LOCAL`
//!    instruction. Session-scoped `SET` is refused outright: sqlx issues no
//!    reset on release, and a session `SET app.tenant_id = 't1'` was
//!    inherited by the next checkout, which read t1's rows believing itself
//!    unscoped.
//! 4. The report itself. **Never folded into 3** as
//!    `WITH s AS (SELECT set_config(…)) SELECT …`: PostgreSQL guarantees no
//!    evaluation order between a non-data-modifying CTE and the outer query,
//!    and a tenant fence resting on an unspecified evaluation order is not a
//!    fence. The price is the round trips, negligible against a report and
//!    dominant only against the balance read.
//!
//! `set_config` RETURNS the value it set, and that return is what travels
//! back in [`ledger::Scoped`]: the service's `tenant_mismatch` check then
//! compares the request against what the session actually holds, rather than
//! against what this file meant to set.
//!
//! **Every amount a report answers is selected as `::text`.** The three
//! functions return `numeric` since migration `00004`, and a `numeric` cannot
//! be handed to a JSON consumer as a number — JSON's own numeric type loses
//! precision above 2⁵³, so a total large enough to have needed the widening
//! would be silently rounded by the parser at the other end (ADR-0019). The
//! cast happens here, at the edge, so no Rust type in the read path has to
//! pretend a report total fits in 64 bits.

use ledger::{
    AccountBalance, AccountBalanceQuery, AccountListingRead, BalanceSheetRead, Cursor,
    IncomeStatementRead, ListedAccount, ReadBounds, ReportRefusal, ReportStore, Scoped,
    StatementLine, Transaction, TransactionEntry, TransactionQuery, TrialBalanceRead,
    TrialBalanceRow,
};
use sqlx::{PgPool, Postgres, Row as _};
use time::OffsetDateTime;
use uuid::Uuid;

/// The Postgres report store: the `ledger` crate's outbound read port,
/// implemented. It holds the READ pool — a different pool on a different
/// login from the writer's, which is the structural half of the tenant fence
/// (ADR-0019 A4).
#[derive(Clone)]
pub struct PgReportStore {
    pool: PgPool,
}

impl PgReportStore {
    /// The reader, over the read pool. It takes [`db::ReadDatabase`], not a
    /// bare pool: the composition root hands the adapter what db built, and
    /// never names an sqlx type itself.
    ///
    /// There is no constructor over [`db::Database`], and that is the point —
    /// the writer's pool is the writer's login, and a reader on a login that
    /// can write is fenced by nothing but a `SET LOCAL ROLE` it might forget.
    pub fn over_the_read_pool(database: &db::ReadDatabase) -> Self {
        Self {
            pool: database.pool().clone(),
        }
    }

    /// The bracket's first three statements, in order — every read in this
    /// file starts here and none of them may start anywhere else.
    async fn begin_the_scoped_read(&self, tenant_id: &str) -> Result<ScopedRead, ReportRefusal> {
        let mut tx = self
            .pool
            .begin_with(BEGIN_THE_READ)
            .await
            .map_err(refusal)?;
        sqlx::raw_sql(ASSUME_THE_READ_ROLE)
            .execute(&mut *tx)
            .await
            .map_err(refusal)?;
        let scoped: String = sqlx::query_scalar(SCOPE_TO_ONE_TENANT)
            .bind(tenant_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(refusal)?;
        Ok(ScopedRead { tx, scoped })
    }
}

/// One open, scoped, read-only transaction and the tenant the session
/// actually holds — `set_config`'s own answer, not this file's copy of the
/// argument.
struct ScopedRead {
    tx: sqlx::Transaction<'static, Postgres>,
    scoped: String,
}

impl ScopedRead {
    /// Close the bracket and hand the answer back beside the scope it was
    /// read under. A read-only transaction makes nothing durable, so the
    /// commit is only about releasing the snapshot — and the horizon it holds
    /// for as long as it is open (ADR-0019's cost list).
    async fn end_with<T>(self, answer: T) -> Result<Scoped<T>, ReportRefusal> {
        self.tx.commit().await.map_err(refusal)?;
        Ok(Scoped {
            tenant_id: self.scoped,
            answer,
        })
    }
}

/// ADR-0019's isolation ruling, in one statement: `READ COMMITTED` because
/// each bracket carries one data statement, `READ ONLY` because it costs
/// nothing and refuses a write the grants would otherwise have to.
const BEGIN_THE_READ: &str = "BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY";

/// The role the RLS policies are written for. `SET LOCAL`, so it dies with
/// the transaction rather than riding the pooled connection to the next
/// caller.
const ASSUME_THE_READ_ROLE: &str = "SET LOCAL ROLE openledger_read";

/// The tenant fence, as data. The `true` is `is_local`: the scope dies with
/// the transaction, which is what makes a pooled connection safe to hand on.
const SCOPE_TO_ONE_TENANT: &str = "SELECT set_config('app.tenant_id', $1, true)";

/// The cursor's two bounds and the book's chart version, in ONE statement.
///
/// The horizon is `report_cursor()` — `pg_snapshot_xmin`, everything strictly
/// below which has committed or aborted and can never grow. The floor is this
/// tenant's oldest `xact_id`: the RLS qual already scopes it, and the explicit
/// `tenant_id` predicate is here for the index — `ix_entries__asof_commit` is
/// `(tenant_id, account_id, xact_id)`, which PostgreSQL 18's skip scan can
/// serve for a leading tenant with the account column omitted — and as the
/// same second line of defence the writer's `ORDER BY` is beside its
/// already-sorted arrays. `NULL` back means an empty book, which has no floor
/// to be above.
///
/// The chart version is the value the SQL default WOULD have resolved, read
/// here so the read path can pass it explicitly and report which version
/// answered (ADR-0019 B6). `chart_versions` is deployment-global and carries
/// no `tenant_id`, so it has no policy and is not scoped by the fence.
const READ_BOUNDS: &str = "SELECT report_cursor()::text AS horizon,
            (SELECT min(e.xact_id)::text FROM ledger_entries e
              WHERE e.tenant_id = $1) AS oldest_entry,
            (SELECT max(cv.version) FROM chart_versions cv) AS chart_version";

/// The posted balance of one account, as ADR-0013 §4 requires it be read: a
/// `SUM` over the stripe rows that EXIST, never the range `0..n-1` and never
/// one row. Measured flat at 0.091–0.100 ms across a hundredfold book, which
/// is why shipping this endpoint is how an integrator is stopped from writing
/// the single-row read that under-reports.
///
/// **The `FROM` is `ledger_accounts`, and that is the whole design** (ADR-0019
/// C4). A balance row is created lazily by the first write, so an unknown
/// account, a dormant one and a currency the account does not hold all return
/// zero rows and a NULL sum from `ledger_account_balances` — only the account
/// register can tell them apart. No row back is `404 account_unknown`; a row
/// with `COALESCE(…, 0)` is `200` with a zero balance.
///
/// `input - output` is the debit-positive arithmetic value (ADR-0007 rule
/// 15); `::text` for the reason every report amount is text, one aggregate
/// being exactly what can exceed a `bigint`.
const ACCOUNT_BALANCE: &str = "SELECT COALESCE((
              SELECT SUM(b.input - b.output)
              FROM ledger_account_balances b
              WHERE b.tenant_id = a.tenant_id AND b.account_id = a.id
                AND b.currency = a.currency), 0)::text AS posted_minor
         FROM ledger_accounts a
        WHERE a.tenant_id = $1 AND a.id = $2 AND a.currency = $3";

/// `trial_balance_at`, on both of ADR-0006's axes at once — the cursor is the
/// recorded one, the half-open `[from, to)` range the effective one. It takes
/// no chart version, so this route has no A13/A14 error class at all.
///
/// The `ORDER BY` is this file's: the function groups and does not order, and
/// an answer whose row order is the planner's is an answer that changes shape
/// under a plan change.
const TRIAL_BALANCE: &str = "SELECT t.account_id AS account_id,
            t.purpose AS purpose,
            t.category::text AS category,
            t.currency::text AS currency,
            t.debits::text AS debits,
            t.credits::text AS credits,
            t.balance_debit_positive::text AS balance_debit_positive
         FROM trial_balance_at($1, $2, $3, $4::xid8) t
        ORDER BY t.account_id, t.currency";

/// `balance_sheet_at` — a POSITION, so one instant, and since ADR-0020 it
/// reads the period checkpoint plus two tails rather than aggregating from
/// inception.
///
/// `pinned_cursor` is a column of this function's answer and is deliberately
/// NOT selected: the read path answers with the cursor it passed, on all
/// three report routes, so the three cannot come to disagree about where the
/// value comes from — `trial_balance_at` returns no such column, and one rule
/// for three routes beats two.
const BALANCE_SHEET: &str = "SELECT b.currency::text AS currency,
            b.fs_line AS fs_line,
            b.caption AS caption,
            b.sort_order AS sort_order,
            b.amount_minor::text AS amount_minor,
            b.side AS side
         FROM balance_sheet_at($1, $2, $3::xid8, $4) b
        ORDER BY b.currency, b.sort_order, b.fs_line";

/// `income_statement_for` — a FLOW, so a half-open range, and refused the
/// checkpoint structurally (ADR-0020): the accounts it reports are exactly
/// the ones a close zeroes.
const INCOME_STATEMENT: &str = "SELECT i.currency::text AS currency,
            i.fs_line AS fs_line,
            i.caption AS caption,
            i.sort_order AS sort_order,
            i.amount_minor::text AS amount_minor,
            i.side AS side
         FROM income_statement_for($1, $2, $3, $4::xid8, $5) i
        ORDER BY i.currency, i.sort_order, i.fs_line";

/// One transaction and its entries, by primary key — one statement, and no
/// cursor, because the rows are immutable (`ck_txn__append_only` and
/// `ck_entries__append_only`, both `ENABLE ALWAYS`).
///
/// `LEFT JOIN`, and it is not defensive: a reversal of a PENDING transaction
/// is a zero-posting void marker (ADR-0016), so a transaction with no entries
/// is a real answer and an inner join would report it as a missing
/// transaction.
///
/// No `stripe`, on the transaction or its entries (ADR-0013 §4). `account_seq`
/// IS returned, because gaplessness is the property a caller can audit; that
/// the counter is per `(account, stripe)` is documented, not exposed — which
/// is also why the order below is by account and then by seq rather than by
/// seq alone.
const TRANSACTION: &str = "SELECT x.id AS transaction_id,
            x.kind AS kind,
            x.status::text AS status,
            x.effective_at AS effective_at,
            x.recorded_at AS recorded_at,
            x.resolves_id AS resolves_id,
            x.reverses_id AS reverses_id,
            x.event_id AS event_id,
            e.account_id AS account_id,
            e.direction::text AS direction,
            e.amount_minor AS amount_minor,
            e.currency::text AS currency,
            e.account_seq AS account_seq
         FROM ledger_transactions x
         LEFT JOIN ledger_entries e
                ON e.tenant_id = x.tenant_id AND e.transaction_id = x.id
        WHERE x.tenant_id = $1 AND x.id = $2
        ORDER BY e.account_id, e.account_seq";

/// One page of the account register (ADR-0021) — the first listing on this
/// surface, and the only statement in this file that is not a report.
///
/// **Keyset, never an offset.** The page starts strictly above the last `id`
/// the caller saw, and `id` is `uuidv7()`, so the order is creation order and
/// it is total. An offset would shift under concurrent inserts and a caller
/// paging a growing book would silently skip rows; a keyset on the primary
/// key has neither problem, and `pk_accounts` is `(tenant_id, id)`, so the
/// walk is an index scan of exactly this shape.
///
/// **The two filters are EQUALITY** (ADR-0021): no `LIKE`, no `ILIKE`, no
/// full-text — nothing that would need an index this schema does not have.
/// Each is written as `$n IS NULL OR column = $n` so that one statement
/// serves all four combinations; the alternative is four statements, or a
/// string built at run time from caller-supplied text.
///
/// The explicit `tenant_id` predicate is here for the INDEX, as it is on
/// [`READ_BOUNDS`]: the RLS qual already scopes the read, and the leading
/// key column is what makes this a range scan rather than a filter.
///
/// **No balance column, at any depth** (ADR-0021): balances are per currency
/// and per stripe, a balance per row would be N+1, and the balance route
/// answers that question one account at a time.
const ACCOUNTS: &str = "SELECT a.id AS account_id,
            a.owner_type::text AS owner_type,
            a.owner_id AS owner_id,
            a.purpose AS purpose,
            a.category::text AS category,
            a.normal_balance::text AS normal_balance,
            a.counterparty_scope AS counterparty_scope,
            a.currency::text AS currency,
            a.stripe_count AS stripe_count,
            a.created_at AS created_at
         FROM ledger_accounts a
        WHERE a.tenant_id = $1
          AND ($2::uuid IS NULL OR a.id > $2::uuid)
          AND ($3::text IS NULL OR a.purpose = $3::text)
          AND ($4::text IS NULL OR a.owner_id = $4::text)
        ORDER BY a.id
        LIMIT $5";

/// The SQLSTATE this connection's `statement_timeout` fires as.
const STATEMENT_TIMEOUT: &str = "57014";

/// `check_violation` — the code all three of the report functions' guards
/// `RAISE` under: the chart version that does not exist, the book with no
/// chart at all, and the A14 refusal.
const CHECK_VIOLATION: &str = "23514";

/// `invalid_text_representation` — an argument the backend could not read.
const INVALID_TEXT: &str = "22P02";

/// The marker migration `00004` writes into the A14 message, and the only
/// thing that tells the two `23514` arms apart: both are the same SQLSTATE
/// from the same function, and the difference between *"that version does not
/// exist"* and *"that version does not present a type you have posted to"* is
/// the difference between two instructions to the caller.
const TYPE_UNPRESENTED: &str = "chart_lint.type_unpresented";

/// The backend's answer in the outbound port's grammar. The SQLSTATEs are
/// PostgreSQL's, so reading them belongs here; the STATUS each one deserves
/// belongs to the port, which is why this returns a
/// [`ReportRefusal`] and never an HTTP concern.
fn refusal(error: sqlx::Error) -> ReportRefusal {
    let Some(database) = error.as_database_error() else {
        return ReportRefusal::Storage(Box::new(error));
    };
    let code = database.code().unwrap_or_default().into_owned();
    let message = database.message().to_owned();
    match code.as_str() {
        STATEMENT_TIMEOUT => ReportRefusal::TimedOut,
        CHECK_VIOLATION if message.contains(TYPE_UNPRESENTED) => {
            ReportRefusal::ChartVersionIncomplete(message)
        }
        CHECK_VIOLATION => ReportRefusal::ChartVersionUnknown(message),
        INVALID_TEXT => ReportRefusal::InvalidRequest(message),
        _ => ReportRefusal::Storage(Box::new(error)),
    }
}

/// The `xid8` a cursor is bound as: decimal text, cast in the statement.
/// There is no sqlx mapping for `xid8` and the core crate could not name one
/// anyway (it names no sqlx type at all), so text is the seam — the same form
/// `report_cursor()::text` comes back as.
fn as_bound_xid8(cursor: Cursor) -> String {
    cursor.to_string()
}

/// A cursor the DATABASE produced, read back from text. A failure here is not
/// a caller's: it means `report_cursor()` or `min(xact_id)` answered something
/// that is not an `xid8`, which is a can't-happen state answered as storage
/// rather than dressed up as a refusal the caller could act on.
fn cursor_from(column: &str, text: &str) -> Result<Cursor, ReportRefusal> {
    Cursor::parse(text).map_err(|_| {
        ReportRefusal::Storage(
            format!("the database answered {column} = {text:?}, which is not an xid8").into(),
        )
    })
}

/// One row of [`TRIAL_BALANCE`]'s answer.
#[derive(sqlx::FromRow)]
struct TrialBalanceSqlRow {
    account_id: Uuid,
    purpose: String,
    category: String,
    currency: String,
    debits: String,
    credits: String,
    balance_debit_positive: String,
}

/// One row of a statement face — the same shape from both statement
/// functions, which return the same columns.
#[derive(sqlx::FromRow)]
struct StatementSqlRow {
    currency: String,
    fs_line: String,
    caption: String,
    sort_order: i32,
    amount_minor: String,
    side: String,
}

/// One row of [`TRANSACTION`]'s answer: the transaction's columns repeated
/// per entry, with the entry's half NULL when there are no entries — the
/// void's shape, and the reason the join is a `LEFT JOIN`.
#[derive(sqlx::FromRow)]
struct TransactionSqlRow {
    transaction_id: Uuid,
    kind: String,
    status: String,
    effective_at: OffsetDateTime,
    recorded_at: OffsetDateTime,
    resolves_id: Option<Uuid>,
    reverses_id: Option<Uuid>,
    event_id: Uuid,
    account_id: Option<Uuid>,
    direction: Option<String>,
    amount_minor: Option<i64>,
    currency: Option<String>,
    account_seq: Option<i64>,
}

/// The flattened rows, assembled into the one transaction they describe. The
/// transaction's own columns are identical on every row, so the first row
/// carries them; the entries are whichever rows have an entry half at all.
fn transaction_from(rows: Vec<TransactionSqlRow>) -> Option<Transaction> {
    let first = rows.first()?;
    let entries = rows
        .iter()
        .filter_map(|row| {
            Some(TransactionEntry {
                account_id: row.account_id?,
                direction: row.direction.clone()?,
                amount_minor: row.amount_minor?,
                currency: row.currency.clone()?,
                account_seq: row.account_seq?,
            })
        })
        .collect();
    Some(Transaction {
        transaction_id: first.transaction_id,
        kind: first.kind.clone(),
        status: first.status.clone(),
        effective_at: first.effective_at,
        recorded_at: first.recorded_at,
        resolves_id: first.resolves_id,
        reverses_id: first.reverses_id,
        event_id: first.event_id,
        entries,
    })
}

/// One row of [`ACCOUNTS`]'s answer.
#[derive(sqlx::FromRow)]
struct AccountSqlRow {
    account_id: Uuid,
    owner_type: String,
    owner_id: Option<String>,
    purpose: String,
    category: String,
    normal_balance: String,
    counterparty_scope: String,
    currency: String,
    stripe_count: i16,
    created_at: OffsetDateTime,
}

/// The page, in the port's own shape.
fn register_page_from(rows: Vec<AccountSqlRow>) -> Vec<ListedAccount> {
    rows.into_iter()
        .map(|row| ListedAccount {
            account_id: row.account_id,
            owner_type: row.owner_type,
            owner_id: row.owner_id,
            purpose: row.purpose,
            category: row.category,
            normal_balance: row.normal_balance,
            counterparty_scope: row.counterparty_scope,
            currency: row.currency,
            stripe_count: row.stripe_count,
            created_at: row.created_at,
        })
        .collect()
}

/// One statement face, from whichever of the two functions was asked.
fn face_from(rows: Vec<StatementSqlRow>) -> Vec<StatementLine> {
    rows.into_iter()
        .map(|row| StatementLine {
            currency: row.currency,
            fs_line: row.fs_line,
            caption: row.caption,
            sort_order: row.sort_order,
            amount_minor: row.amount_minor,
            side: row.side,
        })
        .collect()
}

impl ReportStore for PgReportStore {
    async fn read_bounds(&self, tenant_id: &str) -> Result<Scoped<ReadBounds>, ReportRefusal> {
        let mut scope = self.begin_the_scoped_read(tenant_id).await?;
        let row = sqlx::query(READ_BOUNDS)
            .bind(tenant_id)
            .fetch_one(&mut *scope.tx)
            .await
            .map_err(refusal)?;
        let horizon: String = row.try_get("horizon").map_err(refusal)?;
        let oldest_entry: Option<String> = row.try_get("oldest_entry").map_err(refusal)?;
        let chart_version: Option<i32> = row.try_get("chart_version").map_err(refusal)?;
        let bounds = ReadBounds {
            horizon: cursor_from("report_cursor()", &horizon)?,
            oldest_entry: oldest_entry
                .map(|oldest| cursor_from("min(xact_id)", &oldest))
                .transpose()?,
            chart_version,
        };
        scope.end_with(bounds).await
    }

    async fn account_balance(
        &self,
        query: &AccountBalanceQuery,
    ) -> Result<Scoped<Option<AccountBalance>>, ReportRefusal> {
        let mut scope = self.begin_the_scoped_read(&query.tenant_id).await?;
        let posted_minor: Option<String> = sqlx::query_scalar(ACCOUNT_BALANCE)
            .bind(&query.tenant_id)
            .bind(query.account_id)
            .bind(&query.currency)
            .fetch_optional(&mut *scope.tx)
            .await
            .map_err(refusal)?;
        let found = posted_minor.map(|posted_minor| AccountBalance {
            account_id: query.account_id,
            currency: query.currency.clone(),
            posted_minor,
        });
        scope.end_with(found).await
    }

    async fn trial_balance(
        &self,
        read: &TrialBalanceRead<'_>,
    ) -> Result<Scoped<Vec<TrialBalanceRow>>, ReportRefusal> {
        let mut scope = self.begin_the_scoped_read(read.tenant_id).await?;
        let rows: Vec<TrialBalanceSqlRow> = sqlx::query_as(TRIAL_BALANCE)
            .bind(read.tenant_id)
            .bind(read.effective_from)
            .bind(read.effective_to)
            .bind(as_bound_xid8(read.cursor))
            .fetch_all(&mut *scope.tx)
            .await
            .map_err(refusal)?;
        let rows = rows
            .into_iter()
            .map(|row| TrialBalanceRow {
                account_id: row.account_id,
                purpose: row.purpose,
                category: row.category,
                currency: row.currency,
                debits: row.debits,
                credits: row.credits,
                balance_debit_positive: row.balance_debit_positive,
            })
            .collect();
        scope.end_with(rows).await
    }

    async fn balance_sheet(
        &self,
        read: &BalanceSheetRead<'_>,
    ) -> Result<Scoped<Vec<StatementLine>>, ReportRefusal> {
        let mut scope = self.begin_the_scoped_read(read.tenant_id).await?;
        let rows: Vec<StatementSqlRow> = sqlx::query_as(BALANCE_SHEET)
            .bind(read.tenant_id)
            .bind(read.as_of)
            .bind(as_bound_xid8(read.cursor))
            .bind(read.chart_version)
            .fetch_all(&mut *scope.tx)
            .await
            .map_err(refusal)?;
        scope.end_with(face_from(rows)).await
    }

    async fn income_statement(
        &self,
        read: &IncomeStatementRead<'_>,
    ) -> Result<Scoped<Vec<StatementLine>>, ReportRefusal> {
        let mut scope = self.begin_the_scoped_read(read.tenant_id).await?;
        let rows: Vec<StatementSqlRow> = sqlx::query_as(INCOME_STATEMENT)
            .bind(read.tenant_id)
            .bind(read.effective_from)
            .bind(read.effective_to)
            .bind(as_bound_xid8(read.cursor))
            .bind(read.chart_version)
            .fetch_all(&mut *scope.tx)
            .await
            .map_err(refusal)?;
        scope.end_with(face_from(rows)).await
    }

    async fn transaction(
        &self,
        query: &TransactionQuery,
    ) -> Result<Scoped<Option<Transaction>>, ReportRefusal> {
        let mut scope = self.begin_the_scoped_read(&query.tenant_id).await?;
        let rows: Vec<TransactionSqlRow> = sqlx::query_as(TRANSACTION)
            .bind(&query.tenant_id)
            .bind(query.transaction_id)
            .fetch_all(&mut *scope.tx)
            .await
            .map_err(refusal)?;
        scope.end_with(transaction_from(rows)).await
    }

    async fn accounts(
        &self,
        read: &AccountListingRead<'_>,
    ) -> Result<Scoped<Vec<ListedAccount>>, ReportRefusal> {
        let mut scope = self.begin_the_scoped_read(read.tenant_id).await?;
        let rows: Vec<AccountSqlRow> = sqlx::query_as(ACCOUNTS)
            .bind(read.tenant_id)
            .bind(read.after)
            .bind(read.purpose)
            .bind(read.owner_id)
            .bind(read.limit)
            .fetch_all(&mut *scope.tx)
            .await
            .map_err(refusal)?;
        scope.end_with(register_page_from(rows)).await
    }
}

#[cfg(test)]
mod tests {
    //! The adapter's Rust halves, held without a database in the room: the
    //! classification of what the backend said, and the assembly of a
    //! transaction from the flattened rows its statement answers.
    //!
    //! What the STATEMENTS do — the RLS fence the bracket arms, the `xact_id
    //! < :cursor` filter, the `SUM` over stripes — is proven against real
    //! PostgreSQL by the e2e suite; nothing here re-proves it, and nothing
    //! here could.

    use super::*;

    fn a_row_of(account: Option<Uuid>) -> TransactionSqlRow {
        TransactionSqlRow {
            transaction_id: Uuid::from_u128(0xF0),
            kind: "posting".to_owned(),
            status: "posted".to_owned(),
            effective_at: OffsetDateTime::UNIX_EPOCH,
            recorded_at: OffsetDateTime::UNIX_EPOCH,
            resolves_id: None,
            reverses_id: None,
            event_id: Uuid::from_u128(0xE0),
            account_id: account,
            direction: account.map(|_| "debit".to_owned()),
            amount_minor: account.map(|_| 100),
            currency: account.map(|_| "USD".to_owned()),
            account_seq: account.map(|_| 1),
        }
    }

    #[test]
    fn no_rows_is_no_such_transaction() {
        let rows = Vec::new();

        let found = transaction_from(rows);

        assert!(found.is_none());
    }

    /// The void's shape (ADR-0016): a reversal of a pending transaction
    /// writes a transaction with ZERO postings, so one row whose entry half
    /// is NULL is a real transaction with no entries — never a missing one.
    #[test]
    fn one_row_with_no_entry_half_is_a_transaction_with_no_entries() {
        let rows = vec![a_row_of(None)];

        let found = transaction_from(rows);

        assert_eq!(found.map(|txn| txn.entries.len()), Some(0));
    }

    #[test]
    fn the_transactions_columns_are_read_once_and_its_entries_per_row() {
        let rows = vec![
            a_row_of(Some(Uuid::from_u128(1))),
            a_row_of(Some(Uuid::from_u128(2))),
        ];

        let found = transaction_from(rows);

        assert_eq!(found.map(|txn| txn.entries.len()), Some(2));
    }
}
