//! The read path's INBOUND port — `Reports` — and the types it speaks in.
//!
//! A second port rather than a second method on [`Ledger`](crate::Ledger),
//! and the reason is the error enum: every variant of
//! [`WriteError`](crate::WriteError) except `Storage` promises *"nothing was
//! written"*, which is not a sentence a read can say (ADR-0019). `port.rs`'s
//! own doc sets the test — *"anything else the API grows must earn its place
//! here first"* — and a read fails it, so reads arrive here with their own
//! trait, their own answers and their own [`ReadError`].
//!
//! What is deliberately in the shapes below, because ADR-0019 makes each one
//! contract rather than presentation:
//! - **a report's amounts are exact-integer STRINGS**, never numbers. The
//!   three report functions return `numeric` since migration `00004`, and
//!   JSON's own numeric type loses precision above 2⁵³ — so a total large
//!   enough to have needed the widening would be silently rounded by the
//!   consumer's parser, trading a loud refusal for a quiet wrong answer. A
//!   single POSTING amount stays an `i64` ([`TransactionEntry`]): it is
//!   bounded by `ledger_entries.amount_minor`, and only an aggregate can
//!   exceed it;
//! - **every report answer carries the cursor the read path pinned**, always,
//!   including when the caller supplied none — it is the only way a caller
//!   can notice that the cluster horizon is lagging, which it does for
//!   reasons outside this database;
//! - **no stripe appears anywhere** (ADR-0013 §4). The balance answer is a
//!   `SUM` over an account's stripe rows and says so nowhere; `account_seq`
//!   IS returned, because gaplessness is the property a caller can audit,
//!   and that the counter is per `(account, stripe)` is documented rather
//!   than exposed;
//! - **an as-of instant and a half-open range are different questions and are
//!   not smoothed into one** (ADR-0011 §4): a position takes one instant, a
//!   flow takes a range, and the trial balance takes BOTH axes by parameter —
//!   never by a mode flag (ADR-0019: two resources for two parameters of one
//!   function is Formance's `pit`-resolves-to-six-columns mistake);
//! - **the one listing here pages by KEYSET and carries no balance**
//!   (ADR-0021). An offset shifts under concurrent inserts, so a caller
//!   paging a growing book silently skips rows; and a balance is per currency
//!   and per stripe, so one per row would be N+1 and a second definition of a
//!   question `AccountBalance` already answers exactly.
//!
//! Nothing here names an sqlx type, a runtime or a clock: as-of instants come
//! from the caller and cursors come from the database, so `deny.toml`'s
//! capability map and `clippy.toml`'s ambient-clock ban are both untouched
//! (ADR-0019).

use time::OffsetDateTime;
use uuid::Uuid;

/// A commit-order cursor — PostgreSQL's `xid8`, which is what
/// `report_cursor()` returns and what every report filters `xact_id <` by
/// (ADR-0011). Held as the unsigned 64-bit value the type is, and rendered
/// back to the adapter as decimal text, because the wire form and the bind
/// form are both text: there is no sqlx mapping for `xid8` and this crate
/// could not name one anyway.
///
/// **A caller's cursor is a value in a plausible RANGE, not merely a
/// syntactically valid `xid8`** — which is why [`Cursor`] is a parse and
/// [`ReportService`](crate::ReportService) is the judgement.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub struct Cursor(u64);

/// The text was not an `xid8` at all — `22P02`'s class, and the one cursor
/// failure that is `invalid_request` rather than `cursor_invalid`
/// (ADR-0019's error table: the malformed value is a body refusal, the
/// *implausible* one is the read path's own).
#[derive(Clone, Copy, Debug)]
pub struct CursorUnparseable;

impl Cursor {
    /// The value PostgreSQL would read from this text, or nothing.
    ///
    /// **The negative arm is not a courtesy — it reproduces what the database
    /// does**, and ADR-0019 depends on the reproduction: `'-1'::xid8` is
    /// accepted by PostgreSQL and *wraps* to `18446744073709551615`, which
    /// then returns the entire unpinned book with today's correct numbers —
    /// an unreproducible report that looks right, the worse of the two
    /// measured failures. Parsing `-1` as unparseable would answer it
    /// `invalid_request`; wrapping it the way the backend does puts it above
    /// every horizon, where the plausibility rule refuses it as
    /// `cursor_invalid` — the answer ADR-0019's table names for exactly this
    /// input.
    pub fn parse(text: &str) -> Result<Self, CursorUnparseable> {
        let text = text.trim();
        if let Ok(value) = text.parse::<u64>() {
            return Ok(Self(value));
        }
        text.parse::<i64>()
            .map(|wrapping| Self(wrapping as u64))
            .map_err(|_| CursorUnparseable)
    }

    /// The `xid8` this cursor is, for an adapter that has to render it.
    pub fn as_xid8(self) -> u64 {
        self.0
    }
}

impl std::fmt::Display for Cursor {
    /// The decimal text `xid8` reads and writes — the wire form and the bind
    /// form, which are the same form.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// `GET /v1/accounts/{account_id}/balance` — *posted, now*, and pinned by
/// nothing. This is the balance CACHE, not the journal (ADR-0010: the cache
/// means POSTED), and pinning it to a cursor would be a second definition of
/// a balance. `currency` is required because the balance row's key includes
/// it.
pub struct AccountBalanceQuery {
    pub tenant_id: String,
    pub account_id: Uuid,
    pub currency: String,
}

/// `GET /v1/reports/trial-balance` — BOTH of ADR-0006's axes, by parameter:
/// widen the range and vary the cursor for the recorded axis, fix the cursor
/// and vary the range for the effective axis. `[effective_from,
/// effective_to)` is half-open, as it is on all three report functions
/// (ADR-0011 §A3).
pub struct TrialBalanceQuery {
    pub tenant_id: String,
    pub effective_from: OffsetDateTime,
    pub effective_to: OffsetDateTime,
    /// Absent means *pin one server-side and tell me which* (ADR-0019 B3);
    /// text, because deciding whether it is an `xid8` — and whether it is a
    /// PLAUSIBLE one — is the service's judgement and not the handler's
    /// deserialization.
    pub cursor: Option<String>,
}

/// `GET /v1/reports/balance-sheet` — a POSITION, so one instant.
///
/// `as_of` is an `ends_at`, never a business date: `effective_at < p_asof` is
/// half-open, so a business date returns the position at the START of that
/// day and silently loses a day at every period boundary (ADR-0019; the
/// endpoint's own description says so, because nothing raises and the number
/// is plausible).
pub struct BalanceSheetQuery {
    pub tenant_id: String,
    pub as_of: OffsetDateTime,
    pub cursor: Option<String>,
    /// Absent means *the version the book is on now* — resolved by the read
    /// path and passed to the function EXPLICITLY, never left to the SQL
    /// default, which resolves `max(version)` at run time (ADR-0019 B6:
    /// explicit v1 and the default returned 1 and 3 on the same database).
    pub chart_version: Option<i32>,
}

/// `GET /v1/reports/income-statement` — a FLOW, so a half-open range. *"A
/// statement without a period is not a statement"* (ADR-0011 §4).
pub struct IncomeStatementQuery {
    pub tenant_id: String,
    pub effective_from: OffsetDateTime,
    pub effective_to: OffsetDateTime,
    pub cursor: Option<String>,
    pub chart_version: Option<i32>,
}

/// `GET /v1/accounts` — the account register of one book, keyset-paginated.
///
/// **A listing, and ADR-0019 refused those.** ADR-0021 withdraws that refusal
/// for accounts and keeps it for transactions, and the distinction is the
/// whole reason it can: ADR-0019's stated ground was that a listing *"needs an
/// ordering and a page key this spike did not design"*, and for accounts the
/// ordering already exists — `pk_accounts` is `(tenant_id, id)` and `id` is
/// `uuidv7()`, which is time-ordered and total. A TRANSACTION listing would
/// still have to choose between the recorded and effective axes, which is the
/// bitemporal trap ADR-0006 exists to document; accounts have one axis.
///
/// **The filters are EQUALITY and nothing else** (ADR-0021): no pattern
/// matching, no free text, nothing that needs an index this schema does not
/// have.
pub struct AccountListingQuery {
    pub tenant_id: String,
    /// How many accounts at most. `None` takes the read path's default; a
    /// value outside its window is refused rather than clamped, because a
    /// clamped page is an answer to a question the caller did not ask and
    /// nothing on the wire says so. The number arrives as a signed integer so
    /// that zero and negatives are refused HERE, by name, rather than by a
    /// deserializer naming a serde path.
    pub limit: Option<i64>,
    /// The last `id` of the previous page — the page key. Keyset, never an
    /// offset: an offset shifts under concurrent inserts, so a caller paging
    /// through a growing book silently skips rows (ADR-0021).
    pub after: Option<Uuid>,
    /// Equality on the chart code, or nothing.
    pub purpose: Option<String>,
    /// Equality on the owner, or nothing. It does not select house accounts:
    /// a house account has no owner at all.
    pub owner_id: Option<String>,
}

/// One page of the account register.
pub struct AccountListing {
    pub accounts: Vec<ListedAccount>,
    /// The `after` a caller should send for the next page, or `None` when this
    /// page is the last one this listing can promise. `Some` exactly when the
    /// page came back FULL — which is a "there may be more", never a "there
    /// is": the alternative is reading one row past the page to be sure, and
    /// a caller that follows a cursor to an empty page has learnt the same
    /// thing one request later.
    pub next_after: Option<Uuid>,
}

/// One account as the register holds it: its identity, and its stripe count.
///
/// **No balance**, and that is contract rather than omission (ADR-0021):
/// balances are per currency and per stripe, a balance per row would be N+1,
/// and `GET /v1/accounts/{id}/balance` already answers that question one
/// account at a time.
pub struct ListedAccount {
    pub account_id: Uuid,
    pub owner_type: String,
    /// `None` on a house account, which is the ledger's own side and has no
    /// owner (`ck_accounts__house_has_no_owner`).
    pub owner_id: Option<String>,
    pub purpose: String,
    pub category: String,
    pub normal_balance: String,
    pub counterparty_scope: String,
    pub currency: String,
    /// How many stripes the writer spreads this account's balance row across
    /// — a HINT and not an invariant (ADR-0013 §4). It is the one operational
    /// number on this answer, and it is here because it is the one a caller
    /// can act on: a hot account is re-opened with more stripes, never
    /// re-striped by an update.
    pub stripe_count: i16,
    pub created_at: OffsetDateTime,
}

/// `GET /v1/transactions/{transaction_id}` — pinned by nothing, because the
/// rows are immutable (`ck_txn__append_only` and `ck_entries__append_only`,
/// both `ENABLE ALWAYS`). In scope for M5 because a write-only API is not an
/// adoption surface: the write endpoint answers two UUIDs and nothing over
/// HTTP could say what they point at (ADR-0019).
pub struct TransactionQuery {
    pub tenant_id: String,
    pub transaction_id: Uuid,
}

/// One account's posted balance — the `SUM` over its stripe rows, as an
/// exact-integer string, debit-positive (`input - output`; ADR-0007 rule 15).
///
/// A dormant account answers `"0"` and an unknown one is refused
/// ([`ReadError::AccountUnknown`]): a balance row is created lazily by the
/// first write, so `ledger_account_balances` alone cannot tell the two apart
/// — all three of unknown, dormant and wrong-currency return zero rows and a
/// NULL sum, and only `ledger_accounts` can draw the distinction (ADR-0019).
pub struct AccountBalance {
    pub account_id: Uuid,
    pub currency: String,
    pub posted_minor: String,
}

/// The trial balance, and the cursor it was pinned at.
pub struct TrialBalance {
    pub pinned_cursor: Cursor,
    pub rows: Vec<TrialBalanceRow>,
}

/// One `(account, currency)` of the trial balance. `balance_debit_positive`
/// is the ARITHMETIC value — roll up with that one; `normal_balance` never
/// enters it, so a contra account carries its own sign instead of being
/// flipped twice.
pub struct TrialBalanceRow {
    pub account_id: Uuid,
    pub purpose: String,
    pub category: String,
    pub currency: String,
    pub debits: String,
    pub credits: String,
    pub balance_debit_positive: String,
}

/// A balance sheet or an income statement: the face, the chart version it was
/// presented at, and the cursor it was pinned at.
///
/// **What this promises and what it does not** (ADR-0019 B7): the AMOUNTS are
/// reproducible at a stored cursor; the ROW SET is not. The lines are
/// enumerated from `ledger_accounts`, `chart_versions`, `chart_presentation`,
/// `fs_lines` and `account_types`, none of which carries an `xact_id` column
/// — one new EUR account with nothing posted to it added ten balance-sheet
/// rows at a fixed cursor with every pre-existing amount byte-identical. And
/// the income statement's amounts carry a carve-out of their own: it excludes
/// closing entries through `ledger_period_closes`, which has no commit
/// position, so a close inserted AFTER a statement is issued retroactively
/// removes that transaction's entries from it.
pub struct Statement {
    pub pinned_cursor: Cursor,
    pub chart_version: i32,
    pub lines: Vec<StatementLine>,
}

/// One line of a statement face. `sort_order` is the CHART's ordering, not a
/// row number.
pub struct StatementLine {
    pub currency: String,
    pub fs_line: String,
    pub caption: String,
    pub sort_order: i32,
    pub amount_minor: String,
    pub side: String,
}

/// A transaction read back, with its entries — and with the three things
/// ADR-0016 made wire concepts a caller could not previously read back:
/// `status`, `resolves_id` and `reverses_id`.
pub struct Transaction {
    pub transaction_id: Uuid,
    pub kind: String,
    pub status: String,
    pub effective_at: OffsetDateTime,
    pub recorded_at: OffsetDateTime,
    pub resolves_id: Option<Uuid>,
    pub reverses_id: Option<Uuid>,
    pub event_id: Uuid,
    /// Empty is a REAL answer, not an absence: a reversal of a pending
    /// transaction is a zero-posting void marker (ADR-0016).
    pub entries: Vec<TransactionEntry>,
}

/// One leg. `amount_minor` is a JSON number here and a string on every
/// report, and the asymmetry is deliberate (ADR-0019): a single posting is
/// bounded by its column, and only an aggregate can exceed 2⁵³.
pub struct TransactionEntry {
    pub account_id: Uuid,
    pub direction: String,
    pub amount_minor: i64,
    pub currency: String,
    pub account_seq: i64,
}

/// What a read can answer instead of the book. **No variant promises anything
/// about writes** — that is the whole reason this is not `WriteError` — and
/// each one maps to exactly one status under ADR-0019's error table.
///
/// Two `type` names are shared with the write path deliberately:
/// `invalid_request`, the generic body refusal ADR-0014 grandfathers, and
/// `account_unknown`, which carries **404 here against its 422 there** — a
/// status collision on one name, legal only because ADR-0014 declares
/// responses per endpoint rather than per enum, and called out so the next
/// reader does not take it for a slip.
pub enum ReadError {
    /// A malformed instant, or a cursor that is not an `xid8` at all — the
    /// `22P02` class. `422 invalid_request`.
    InvalidRequest(String),
    /// The cursor is a legal `xid8` and an implausible one: above the
    /// horizon, or at or below the book's oldest `xact_id`. The database
    /// cannot refuse these — `-1` and `0` are legal values — so the refusal
    /// is the read path's. `422 cursor_invalid`.
    CursorInvalid(String),
    /// The named chart version does not exist, or the book has none at all.
    /// `422 chart_version_unknown`.
    ChartVersionUnknown(String),
    /// The chart version exists and does not present every account type that
    /// has posted entries in scope — the A14 refusal, which would otherwise
    /// drop a whole sub-book from the face with the statement still
    /// balanced. `422 chart_version_incomplete`.
    ChartVersionIncomplete(String),
    /// No such account on this tenant's book, or one that does not hold this
    /// currency. `404 account_unknown` — see the note above about the status.
    AccountUnknown { account_id: Uuid, currency: String },
    /// No such transaction on this tenant's book. `404 transaction_unknown`.
    TransactionUnknown { transaction_id: Uuid },
    /// The `tenant_id` asked about is not the scope the read path set on the
    /// session. **Vacuous today by construction** — the read path scopes the
    /// session to the tenant the request named — and implemented anyway: it
    /// is the only mitigation available INSIDE the fence, and it stops being
    /// vacuous the day a gateway supplies the scope instead of the body
    /// (ADR-0019). `422 tenant_mismatch`.
    TenantMismatch { requested: String, scoped: String },
    /// `57014`. **503, not 500 and not 504**: the service is healthy, the
    /// request was too expensive, and retrying it unchanged fails
    /// identically — which is what a caller needs told. `503
    /// report_timed_out`.
    ReportTimedOut,
    /// The read path reached a state its own construction promises cannot
    /// happen. The caller gets a 500 with no internals; the string is for the
    /// operator's log.
    Internal(String),
    /// The storage failed. Opaque for the same reason
    /// [`WriteError::Storage`](crate::WriteError::Storage) is: this crate
    /// names no sqlx type, and `deny.toml`'s capability map only holds
    /// because it does not.
    Storage(Box<dyn std::error::Error + Send + Sync>),
}

/// The read path's inbound port: *tell me what the book says*.
///
/// Six methods for six routes, and neither `transaction` nor `accounts` got a
/// port of its own — a manifest's worth of ceremony for one method buys a
/// boundary nothing crosses (ADR-0015's own reason for refusing a `ports`
/// crate), and from the caller's side reading a transaction back, listing the
/// register and reading a report are the same capability: *tell me what the
/// book says* (ADR-0019, ADR-0021).
///
/// Stated as RPITIT with an explicit `+ Send`, exactly as [`Ledger`] is and
/// for the same reason: an axum handler's future must be `Send`, and a bare
/// `async fn` in a trait cannot promise that to a generic caller. The cost is
/// the same too — `dyn Reports` does not exist, so consumers take the port as
/// a generic parameter.
///
/// [`Ledger`]: crate::Ledger
pub trait Reports: Send + Sync {
    /// One account's posted balance, now.
    fn account_balance(
        &self,
        query: &AccountBalanceQuery,
    ) -> impl Future<Output = Result<AccountBalance, ReadError>> + Send;

    /// The trial balance over a half-open effective range, at a cursor.
    fn trial_balance(
        &self,
        query: &TrialBalanceQuery,
    ) -> impl Future<Output = Result<TrialBalance, ReadError>> + Send;

    /// The balance-sheet face as at one instant, at a cursor and a chart
    /// version.
    fn balance_sheet(
        &self,
        query: &BalanceSheetQuery,
    ) -> impl Future<Output = Result<Statement, ReadError>> + Send;

    /// The income statement over a half-open effective range, at a cursor and
    /// a chart version.
    fn income_statement(
        &self,
        query: &IncomeStatementQuery,
    ) -> impl Future<Output = Result<Statement, ReadError>> + Send;

    /// One transaction and its entries.
    fn transaction(
        &self,
        query: &TransactionQuery,
    ) -> impl Future<Output = Result<Transaction, ReadError>> + Send;

    /// One page of the account register (ADR-0021). A listing is a READ, so
    /// it is here and not on [`Ledger`]: from the caller's side it is the
    /// same capability every other method on this port is — *tell me what the
    /// book says* — and it runs on the same read pool, the same read login
    /// and the same scoped bracket.
    fn accounts(
        &self,
        query: &AccountListingQuery,
    ) -> impl Future<Output = Result<AccountListing, ReadError>> + Send;
}
