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
//!   single ENTRY amount is an `i64` here ([`TransactionEntry`]) and a string
//!   on the wire, and the difference is not a disagreement: `bigint` is exact
//!   in 64 bits and reaches far past what a JSON number carries, so the type
//!   that holds it is exact and the encoding that ships it must be too —
//!   ADR-0019's asymmetry, corrected by building a client against it;
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
//!   question `AccountBalance` already answers exactly. What it does carry is
//!   the whole register row ([`Account`](crate::Account)) — the derived chart
//!   triple, the stripe count and the caller's own `metadata` — which is the
//!   same value an accepted opening answers with, so the two verbs of that
//!   resource cannot come to describe an account differently.
//!
//! Nothing here names an sqlx type, a runtime or a clock: as-of instants come
//! from the caller and cursors come from the database, so `deny.toml`'s
//! capability map and `clippy.toml`'s ambient-clock ban are both untouched
//! (ADR-0019).

use time::OffsetDateTime;
use uuid::Uuid;

use crate::accounts::Account;

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

/// Which of ADR-0006's two time axes orders an account statement — a
/// PARAMETER with two named values, never a default and never a mode flag
/// (ADR-0023).
///
/// **ADR-0019 refused a listing of entries** because one *"must choose
/// between the recorded axis and the effective axis"*. This one does not
/// choose: the caller names the axis, which is exactly what ADR-0019 itself
/// ruled for the trial balance — *"one endpoint serves both time axes, by
/// parameter and never by a mode flag"*. **Defaulting it would pick the axis
/// a caller failed to think about**, and a statement that picks silently is
/// the one place a listing can be confidently wrong.
///
/// Each variant is the ordering one of the schema's two entry indexes already
/// carries, and the entry `id` breaks ties so that each is a TOTAL order —
/// without which a keyset page is not exact:
///
/// | axis | ordered by | index |
/// | --- | --- | --- |
/// | `recorded` | `(xact_id, id)` | `ix_entries__asof_commit` |
/// | `effective` | `(effective_at, xact_id, id)` | `ix_entries__effective` |
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum StatementAxis {
    /// Commit order — when the ledger LEARNT of the entry. It is the axis a
    /// cursor pins, so a page of it is stable under later writes.
    Recorded,
    /// Business order — when the entry is DATED. A backdated arrival sits in
    /// its own past here and at the end of the recorded axis, and that
    /// disagreement is what two axes MEAN (ADR-0006).
    Effective,
}

impl StatementAxis {
    /// The two names the wire spells, and nothing else. Unknown text is
    /// `None` and never a default: coercing it is the decision ADR-0023
    /// refuses.
    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "recorded" => Some(Self::Recorded),
            "effective" => Some(Self::Effective),
            _ => None,
        }
    }

    /// The name this axis is spelled by — for an answer that echoes back the
    /// parameter every row of it was ordered by.
    pub fn named(self) -> &'static str {
        match self {
            Self::Recorded => "recorded",
            Self::Effective => "effective",
        }
    }
}

/// The ordering key of the last entry on a page: an account statement's
/// keyset `after`, which is the AXIS's key and therefore has a shape per axis.
///
/// **It is deliberately not `account_seq`, and that is the trap ADR-0023
/// records.** The counter reads like the obvious page key — per account,
/// gapless, already unique — but `uq_entries__account_seq` is
/// `(tenant_id, account_id, stripe, account_seq)`: the counter is per
/// *stripe*, because a single per-account counter would serialise every
/// writer through one unique index, *"the bottleneck striping exists to
/// remove, moved one table over"* (ADR-0013). So on a striped account it is
/// not a total order, and paging by it would interleave two counters and
/// silently drop or repeat rows. It is RETURNED on every entry — it is what a
/// drift check walks — and it does not order the page.
///
/// A key is rendered by [`rendered`](Self::rendered) and returned verbatim by
/// the caller; nothing else constructs one. The instant is carried as
/// nanoseconds since the epoch rather than as RFC 3339 because a page key
/// must render INFALLIBLY and compare exactly — an RFC 3339 rendering can
/// fail on a year the format cannot hold, and a key that fails to render is a
/// page a caller cannot follow.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum StatementKey {
    /// `(xact_id, id)` — the recorded axis's key.
    Recorded { xact_id: Cursor, entry_id: Uuid },
    /// `(effective_at, xact_id, id)` — the effective axis's key.
    Effective {
        effective_at: OffsetDateTime,
        xact_id: Cursor,
        entry_id: Uuid,
    },
}

impl StatementKey {
    /// The key as text, for the `next_after` a page hands back.
    pub fn rendered(&self) -> String {
        match self {
            Self::Recorded { xact_id, entry_id } => format!("{xact_id},{entry_id}"),
            Self::Effective {
                effective_at,
                xact_id,
                entry_id,
            } => format!(
                "{},{xact_id},{entry_id}",
                effective_at.unix_timestamp_nanos()
            ),
        }
    }

    /// A key a caller sent back, read against the axis they are paging.
    ///
    /// The axis is an argument rather than something read out of the text: a
    /// key belongs to the order it was issued under, and a recorded key
    /// replayed against the effective axis would page by a bound that is not
    /// that order's — so the arity is the axis's, and text that does not fit
    /// it is `None`.
    pub fn parse(text: &str, axis: StatementAxis) -> Option<Self> {
        let mut parts = text.split(',');
        let key = match axis {
            StatementAxis::Recorded => Self::Recorded {
                xact_id: Cursor::parse(parts.next()?).ok()?,
                entry_id: parts.next()?.parse().ok()?,
            },
            StatementAxis::Effective => Self::Effective {
                effective_at: OffsetDateTime::from_unix_timestamp_nanos(
                    parts.next()?.parse().ok()?,
                )
                .ok()?,
                xact_id: Cursor::parse(parts.next()?).ok()?,
                entry_id: parts.next()?.parse().ok()?,
            },
        };
        // Nothing may follow the key: a longer text is a key of the OTHER
        // axis, or a caller's own construction, and either is refused rather
        // than read as far as it parses.
        parts.next().is_none().then_some(key)
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
    pub accounts: Vec<Account>,
    /// The `after` a caller should send for the next page, or `None` when this
    /// page is the last one this listing can promise. `Some` exactly when the
    /// page came back FULL — which is a "there may be more", never a "there
    /// is": the alternative is reading one row past the page to be sure, and
    /// a caller that follows a cursor to an empty page has learnt the same
    /// thing one request later.
    pub next_after: Option<Uuid>,
}

/// `GET /v1/accounts/{account_id}/entries` — one account's entries, in order,
/// at a cursor (ADR-0023).
///
/// **The axis is required.** Every other value here is optional and each
/// absence has a meaning; the axis has none, because whichever one this read
/// picked for a caller who did not name one would be the axis they failed to
/// think about.
///
/// The commit cursor applies as on every other pinned read; the half-open
/// `[effective_from, effective_to)` range is the EFFECTIVE axis's filter and
/// is refused on the recorded axis rather than ignored there.
pub struct AccountStatementQuery {
    pub tenant_id: String,
    pub account_id: Uuid,
    /// `recorded` or `effective`, as text — and an `Option` so that the
    /// refusal of an unnamed axis lives in the core, where ADR-0023's rule
    /// is, rather than in a deserializer. The HTTP surface declares the
    /// parameter required, so absence does not reach here over the wire; the
    /// port is what makes defaulting it unavailable to any other caller.
    pub axis: Option<String>,
    /// Absent means *pin one server-side and tell me which* (ADR-0019), the
    /// same as on every report route.
    pub cursor: Option<String>,
    /// Inclusive lower bound on `effective_at`. `axis=effective` only.
    pub effective_from: Option<OffsetDateTime>,
    /// EXCLUSIVE upper bound on `effective_at` — half-open, as every range on
    /// this surface is (ADR-0011 §A3). `axis=effective` only.
    pub effective_to: Option<OffsetDateTime>,
    /// How many entries at most; `None` takes the read path's default, and a
    /// value outside its window is refused rather than clamped — the same
    /// shape the account listing has, deliberately, rather than a second
    /// convention for the same question.
    pub limit: Option<i64>,
    /// The `next_after` of the previous page, verbatim: the last row's
    /// ORDERING KEY, whose shape is the axis's ([`StatementKey`]). Text here
    /// for the reason `cursor` is text — whether it is a key of the axis
    /// being paged is judgement, and judgement is the service's.
    pub after: Option<String>,
}

/// One page of an account's entries, the axis they were ordered by, and the
/// cursor the page was pinned at.
pub struct AccountStatement {
    pub pinned_cursor: Cursor,
    /// Echoed because it is the parameter that decided every row's position —
    /// the same reason a statement echoes the `chart_version` it was
    /// presented at.
    pub axis: StatementAxis,
    pub entries: Vec<AccountStatementEntry>,
    /// The key to send as `after` for the next page, or `None` when this page
    /// did not fill — a full page means "there may be more", never "there
    /// is", exactly as the account listing's does.
    pub next_after: Option<StatementKey>,
}

/// One entry of an account's statement — the leg that touched THIS account,
/// never the transaction's other legs, which belong to other accounts
/// (ADR-0023). `transaction_id` is on every row and the transaction read
/// answers the rest.
pub struct AccountStatementEntry {
    pub entry_id: Uuid,
    pub transaction_id: Uuid,
    pub direction: String,
    /// An `i64` here and an exact-integer decimal STRING on the wire, for the
    /// reason every amount on this surface is one (ADR-0022).
    pub amount_minor: i64,
    pub currency: String,
    pub effective_at: OffsetDateTime,
    pub recorded_at: OffsetDateTime,
    /// The account's own gapless counter for this leg — per `(account,
    /// stripe)`, which is why it is returned and never ordered by.
    pub account_seq: i64,
    /// The entry's own commit position: the recorded axis's ordering key, and
    /// half of the effective axis's. It is carried so the page key can be
    /// built from the last row of a page and is not rendered on the wire —
    /// `next_after` is where a caller meets it, as a key to return rather
    /// than as a number to do arithmetic on.
    pub xact_id: Cursor,
}

/// `GET /v1/cursor` — the commit horizon on its own, and nothing else.
///
/// **ADR-0019 refused a cursor-minting endpoint** on the ground that *"every
/// report already returns the cursor it used"*. True, and it makes asking for
/// the horizon ALONE cost a whole report: a dashboard refreshing it issues a
/// trial balance over `0001-01-01`…`9999-12-31` for one scalar, which on a
/// large book is the ~28-second query ADR-0019's own cost list records. One
/// statement answers the same value.
///
/// **`tenant_id` is here for the scoping every other read has and not because
/// the horizon is one book's**: `report_cursor()` is `pg_snapshot_xmin`, which
/// is the CLUSTER's, so two tenants are answered the same number. It is taken
/// anyway so that this route runs the identical `BEGIN … READ ONLY` /
/// `SET LOCAL ROLE` / `set_config` bracket every other read runs, rather than
/// being the one read that reaches the database unscoped.
pub struct CursorQuery {
    pub tenant_id: String,
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

/// One leg. `amount_minor` is an `i64` here — `ledger_entries.amount_minor`
/// is a `bigint` and 64 bits hold it exactly — and an exact-integer decimal
/// STRING on the wire, for the reason every report amount is one: JSON has no
/// integer type, and a `bigint` reaches far past what an IEEE-754 double
/// carries. Demonstrated rather than reasoned: a posting of 2⁵³+1 was accepted
/// and read back one lower by `JSON.parse`.
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
    ///
    /// The currency is `None` on a read that names none: an account holds one
    /// currency, so only the balance read — whose row key includes it — can
    /// fail for that second reason, and a statement's refusal must not claim
    /// a currency the caller never asked about.
    AccountUnknown {
        account_id: Uuid,
        currency: Option<String>,
    },
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
/// Eight methods for eight routes, and none of `transaction`, `accounts` or
/// `cursor` got a port of its own — a manifest's worth of ceremony for one
/// method buys a boundary nothing crosses (ADR-0015's own reason for refusing
/// a `ports` crate), and from the caller's side reading a transaction back,
/// listing the register, asking for the horizon and reading a report are the
/// same capability: *tell me what the book says* (ADR-0019, ADR-0021).
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

    /// The commit horizon on its own — `report_cursor()`, one statement, no
    /// report (ADR-0019's refusal of a cursor-minting endpoint, qualified by
    /// what building a client against it cost).
    fn cursor(&self, query: &CursorQuery)
    -> impl Future<Output = Result<Cursor, ReadError>> + Send;

    /// One transaction and its entries.
    fn transaction(
        &self,
        query: &TransactionQuery,
    ) -> impl Future<Output = Result<Transaction, ReadError>> + Send;

    /// One page of one account's entries, on the axis the caller named
    /// (ADR-0023) — the read that makes a ledger inspectable, because until
    /// it shipped the only way to see a transaction was to already know its
    /// id.
    fn account_statement(
        &self,
        query: &AccountStatementQuery,
    ) -> impl Future<Output = Result<AccountStatement, ReadError>> + Send;

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
