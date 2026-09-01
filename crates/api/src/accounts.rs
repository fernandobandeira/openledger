//! The account resource's two new verbs (ADR-0021): open one, and list them —
//! and, since ADR-0023, its statement: one account's entries, in order, at a
//! cursor. Their wire types, their handlers, and the `#[utoipa::path]`
//! annotations the committed spec is generated from.
//!
//! **Why this file exists at all.** Until ADR-0021 there was no way to open an
//! account over HTTP — accounts were seeded by SQL, which is what the e2e
//! suite does and what the reference chart does. That is the same hole
//! ADR-0014 named for the writer: *"a writer only Rust code can call is not a
//! deliverable"* is the argument against a ledger you cannot open an account
//! in without a `psql` session.
//!
//! **The two verbs split by DIRECTION, not by resource**, which is why they
//! reach two different ports from one file: opening is a write and goes to
//! [`ledger::Ledger`]'s second method, listing is a read and goes to
//! [`ledger::Reports`] behind the read pool and the read login. The third
//! verb this resource has —
//! `GET /v1/accounts/{account_id}/balance` — stays in `reports.rs` beside the
//! reads it shares its shape with, because it is a report of one number and
//! not a fact about the register.
//!
//! What this layer owns is what every handler here owns: which status, which
//! header, which error `type`. The judgement is one ring in — the chart
//! derivation and every named refusal are `ledger`'s writer service, the page
//! size, the axis and the cursor rule its report service — and the SQL another
//! ring out.
//!
//! **Both listings on this resource page the same way**, deliberately: a
//! `limit` with a stated default and maximum refused rather than clamped, an
//! `after` carrying the last row's ordering key, and a `next_after` that is
//! present exactly when the page came back full. What differs is the key —
//! the register's is an `account_id`, the statement's is the AXIS's ordering
//! key — and the difference is the shape of the key, never a second
//! convention for asking.

use axum::extract::State;
use axum::http::{HeaderName, StatusCode};
use axum::response::{IntoResponse, Response};
use ledger::{Ledger, Reports};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use utoipa::{IntoParams, ToSchema};
use uuid::Uuid;

use crate::reports::{instant, refusal_for_read};
use crate::wire::{Body, ErrorBody, Params, Refusal, Segment, refuse};

const IDEMPOTENCY_REPLAYED: HeaderName = HeaderName::from_static("idempotency-replayed");

/// Who an account belongs to — the schema's `account_owner_type`. `house` is
/// the ledger's own side of a movement and is the one value that carries NO
/// `owner_id`; the other three name one.
#[derive(Clone, Copy, Deserialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum OwnerTypeBody {
    Company,
    Platform,
    BankAccount,
    /// The ledger's own account for this purpose and currency — one per
    /// tenant (`uq_accounts__house`), and it must carry no `owner_id`.
    House,
}

/// The body of `POST /v1/accounts`.
///
/// **What is NOT here is the design** (ADR-0021): there is no `category`, no
/// `normal_balance` and no `counterparty_scope`. `ledger_accounts` carries all
/// three as COPIES of the chart row, held honest by `fk_accounts__type` and
/// `fk_accounts__scope` — so a body that stated them could disagree with the
/// chart, and the caller would be handed a foreign-key error rather than an
/// answer. The caller names a `purpose` and the server reads the rest, which
/// makes a whole class of refusals unreachable rather than merely reported.
#[derive(Deserialize, ToSchema)]
pub(crate) struct AccountBody {
    /// The book this account belongs to. Named in the body by decision
    /// (ADR-0017): data scoping, never an identity claim.
    #[schema(example = "t1")]
    tenant_id: String,
    /// Caller-supplied replay key, unique per tenant — and in the SAME
    /// namespace a posting's key lives in, because it is the same spine
    /// (`ledger_events`, ADR-0005). Sending the same key with the same body
    /// replays the stored result; with a different body it is refused as
    /// `idempotency_key_reused` (ADR-0013 §2), and that includes a key an
    /// earlier POSTING claimed.
    #[schema(min_length = 1, example = "open-co-1-receivable")]
    idempotency_key: String,
    /// The account type, by its chart code — `customer_receivable`,
    /// `fee_revenue`, and whatever else this deployment's chart carries. A
    /// code `account_types` does not hold is `account_type_unknown`.
    #[schema(example = "customer_receivable")]
    purpose: String,
    owner_type: OwnerTypeBody,
    /// Who owns it. Required for every `owner_type` except `house`, and
    /// refused for `house` — `ck_accounts__house_has_no_owner`, answered as
    /// `account_owner_mismatched`.
    #[serde(default)]
    #[schema(example = "co_1")]
    owner_id: Option<String>,
    /// ISO 4217 alphabetic code, three uppercase ASCII letters. One account
    /// holds one currency.
    #[schema(min_length = 3, max_length = 3, example = "USD")]
    currency: String,
    /// How many stripes the writer spreads this account's balance row across,
    /// 1–1024. Omitted means one. **A hint, not an invariant** (ADR-0013 §4):
    /// a reader sums the stripe rows that exist, never the range `0..n-1`, so
    /// nothing is stranded by getting it wrong — but no stripe ever appears
    /// in a response, so this is the only place the number is spoken.
    #[serde(default)]
    #[schema(minimum = 1, maximum = 1024, example = 64)]
    stripe_count: Option<i64>,
    /// Caller's own JSON object, stored as given. It must BE an object:
    /// `jsonb` would store a bare number as happily, and a metadata field
    /// that is sometimes a scalar is a shape every reader has to defend
    /// against.
    #[serde(default)]
    metadata: Option<serde_json::Value>,
}

/// The stored result of an accepted opening: the event, and the account it
/// caused — **the whole account**, not its id.
///
/// **Two UUIDs undercut ADR-0021's own design.** The decision's centre is
/// that the caller names a `purpose` and the server DERIVES `category`,
/// `normal_balance` and `counterparty_scope`; answering with an id meant the
/// derived triple could only be seen by a second call to `GET /v1/accounts`
/// plus a client-side scan, because there is no `GET /v1/accounts/{id}` and
/// the listing filters on `purpose` and `owner_id` but not on the account.
/// "Show me the account I just opened" was a paged search. It is one field
/// now, and it is the SAME [`AccountRead`] a listing row is — one type, so
/// the two cannot come to disagree about what an account looks like.
///
/// `event_id` stays beside it: opening an account writes an EVENT and no
/// ledger transaction, which is the case ADR-0005 justified the event log by,
/// and the spine is a fact a caller should still be able to see.
#[derive(Serialize, ToSchema)]
pub(crate) struct AccountCreated {
    /// The event row this call claimed — or, on a replay, the one it found.
    event_id: Uuid,
    /// The account, as the register holds it. Never null, unlike a posting's
    /// `transaction_id`: an accepted opening always wrote one, and a replay
    /// finds it by the natural key its own body names.
    account: AccountRead,
}

/// Open an account.
///
/// The response set below is this endpoint's real one, not a shared error
/// enum's: the six 422 `type`s named are exactly the ones the writer can
/// produce here. `account_exists` never appears on the posting endpoint and
/// `account_unknown` never appears here, which is precisely why opening
/// carries its own error type in the core (ADR-0021).
#[utoipa::path(
    post,
    path = "/v1/accounts",
    operation_id = "openAccount",
    tag = "accounts",
    request_body = AccountBody,
    responses(
        (
            status = 201,
            description = "Opened: this call claimed the idempotency key and wrote the account \
                           and its event atomically. The answer carries the whole account, \
                           including the `category`, `normal_balance` and `counterparty_scope` \
                           the server DERIVED from `purpose` — the same representation \
                           `GET /v1/accounts` answers per row (ADR-0021).",
            body = AccountCreated,
            headers(
                ("Idempotency-Replayed" = bool,
                 description = "`false`: this response is the first for its idempotency key.")
            )
        ),
        (
            status = 200,
            description = "Replayed: this key was already accepted with this same body. The \
                           stored result is re-rendered — never a cached response body — and \
                           nothing was written (ADR-0013 §2). It carries the same full account \
                           the 201 did, read back from the register.",
            body = AccountCreated,
            headers(
                ("Idempotency-Replayed" = bool,
                 description = "`true`: this response re-renders a previously stored result.")
            )
        ),
        (
            status = 422,
            description = "Refused, and nothing was written. Every `type` below is a constraint \
                           the schema already holds, refused by name rather than surfaced as a \
                           database error (ADR-0021). `type` is one of: `invalid_request` (a \
                           precondition on the body failed — a `stripe_count` outside 1–1024, a \
                           currency that is not three uppercase letters, a blank tenant, \
                           metadata that is not an object — or a field failed to deserialize \
                           into its documented type), `idempotency_key_reused` (same key, \
                           different body — send a new key, or resend the original request \
                           unchanged; the key namespace is shared with `POST /v1/transactions`, \
                           deliberately, because it is the same spine), `account_type_unknown` \
                           (`purpose` names no row in this deployment's chart), \
                           `account_exists` (`uq_accounts__owned` or `uq_accounts__house` \
                           already holds this account; the refusal does not say whose, because \
                           within one tenant a collision is always the caller's own), \
                           `account_owner_mismatched` (`ck_accounts__house_has_no_owner` — a \
                           house account has no owner and an owned account must have one), \
                           `account_type_requires_an_owner` \
                           (`ck_accounts__per_shard_is_owned` — a type whose split key IS the \
                           counterparty cannot be held in a house account, because such an \
                           account nets every counterparty at write time and no report can \
                           recover it).",
            body = ErrorBody
        ),
        (
            status = 400,
            description = "The request body is not syntactically valid JSON. `type` is \
                           `invalid_request`; `detail` carries the parser's message.",
            body = ErrorBody
        ),
        (
            status = 413,
            description = "The request body exceeds the size limit. `type` is \
                           `invalid_request`.",
            body = ErrorBody
        ),
        (
            status = 415,
            description = "The request's `Content-Type` is not `application/json`. `type` is \
                           `invalid_request`.",
            body = ErrorBody
        ),
        (
            status = 500,
            description = "The write failed; nothing was committed. `type` is `internal`, and \
                           the caller gets no internals — the operator's log has the error.",
            body = ErrorBody
        ),
    ),
)]
pub(crate) async fn open_account<L, R>(
    State(state): State<crate::AppState<L, R>>,
    Body(body): Body<AccountBody>,
) -> Response
where
    L: Ledger,
    R: Reports,
{
    let command = match to_command(body) {
        Ok(command) => command,
        Err(invalid) => {
            return refuse(
                StatusCode::UNPROCESSABLE_ENTITY,
                "invalid_request",
                invalid.detail().to_owned(),
            );
        }
    };
    match state.ledger.open_account(&command).await {
        Ok(opened) => answer_the_stored_account(opened),
        Err(refused) => refusal_for_opening(refused),
    }
}

/// The accepted answer, rendered from what the writer stored. The one decision
/// here is 201-vs-200, and the `Idempotency-Replayed` header is read off the
/// same flag, so the two cannot disagree — the same rule
/// `POST /v1/transactions` follows, because it is the same contract.
fn answer_the_stored_account(opened: ledger::AccountOpened) -> Response {
    let status = if opened.replayed {
        StatusCode::OK
    } else {
        StatusCode::CREATED
    };
    let replayed = if opened.replayed { "true" } else { "false" };
    (
        status,
        [(IDEMPOTENCY_REPLAYED, replayed)],
        axum::Json(AccountCreated {
            event_id: opened.event_id,
            account: account_on_the_wire(opened.account),
        }),
    )
        .into_response()
}

/// Every refusal the writer can produce when opening an account, on the wire —
/// the whole table in one place, because the six named `type`s ARE the domain
/// and they are what the `#[utoipa::path]` responses above document.
/// Exhaustive by construction: a new [`ledger::OpenAccountError`] variant does
/// not compile until it is named a `type` and given its prose.
fn refusal_for_opening(error: ledger::OpenAccountError) -> Response {
    match error {
        // 422 and not 409, for the same reason the posting endpoint's
        // refusals are: the caller must CHANGE the request to escape
        // (ADR-0013 §2).
        ledger::OpenAccountError::KeyReused => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "idempotency_key_reused",
            "this idempotency key was already used by a request with a different body; \
             nothing was written — send a new key, or resend the original request unchanged"
                .to_owned(),
        ),
        ledger::OpenAccountError::AccountTypeUnknown { purpose } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "account_type_unknown",
            format!(
                "purpose {purpose:?} names no account type in this deployment's chart; an \
                 account's category, normal balance and counterparty scope are read from \
                 that row, so there is nothing to open it as"
            ),
        ),
        ledger::OpenAccountError::AccountExists { purpose, currency } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "account_exists",
            format!(
                "an account for purpose {purpose:?} in {currency} already exists on this book \
                 for this owner; one account per owner, purpose and currency, and one house \
                 account per purpose and currency"
            ),
        ),
        ledger::OpenAccountError::AccountOwnerMismatched {
            owner_type,
            owner_id_given,
        } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "account_owner_mismatched",
            if owner_id_given {
                format!(
                    "owner_type {owner_type:?} is the ledger's own side and carries no owner; \
                     send no owner_id, or name an owner_type that has one"
                )
            } else {
                format!(
                    "owner_type {owner_type:?} names an owner and none was sent; send an \
                     owner_id, or open a house account instead"
                )
            },
        ),
        ledger::OpenAccountError::AccountTypeRequiresAnOwner { purpose } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "account_type_requires_an_owner",
            format!(
                "account type {purpose:?} is split by counterparty, so it cannot be held in a \
                 house account: one house account per purpose and currency would net every \
                 counterparty's position at write time, and no report can recover it"
            ),
        ),
        // Same wire shape for both 500 classes: the caller gets no internals,
        // the operator's log gets the difference.
        ledger::OpenAccountError::Storage(e) => {
            eprintln!("openledger: opening an account failed: {e}");
            refuse(
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal",
                "the write failed; nothing was committed".to_owned(),
            )
        }
        ledger::OpenAccountError::Internal(detail) => {
            eprintln!("openledger: opening an account failed: {detail}");
            refuse(
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal",
                "the write failed; nothing was committed".to_owned(),
            )
        }
    }
}

/// The wire body as the domain's command — the one place the wire's owner
/// spelling becomes the domain's, so a rename on either side cannot silently
/// move the other.
fn to_command(body: AccountBody) -> Result<ledger::OpenAccount, ledger::Invalid> {
    let owner_type = match body.owner_type {
        OwnerTypeBody::Company => ledger::AccountOwnerType::Company,
        OwnerTypeBody::Platform => ledger::AccountOwnerType::Platform,
        OwnerTypeBody::BankAccount => ledger::AccountOwnerType::BankAccount,
        OwnerTypeBody::House => ledger::AccountOwnerType::House,
    };
    ledger::OpenAccount::new(
        body.tenant_id,
        body.idempotency_key,
        body.purpose,
        ledger::AccountOwner {
            owner_type,
            owner_id: body.owner_id,
        },
        body.currency,
        body.stripe_count,
        body.metadata,
    )
}

/// The query half of `GET /v1/accounts` — the book, the page, and the two
/// equality filters.
#[derive(Deserialize, IntoParams)]
#[into_params(parameter_in = Query)]
pub(crate) struct AccountListParams {
    /// The book to read.
    #[param(example = "t1")]
    tenant_id: String,
    /// How many accounts at most, 1–1000. Omitted means 100. A value outside
    /// the window is REFUSED rather than clamped: a clamped page is an answer
    /// to a question the caller did not ask, and nothing on the wire would
    /// say so.
    #[param(minimum = 1, maximum = 1000, example = 100)]
    limit: Option<i64>,
    /// The last `account_id` of the previous page — send back the
    /// `next_after` an earlier page answered with. Keyset, never an offset
    /// (ADR-0021): an offset shifts under concurrent inserts, so a caller
    /// paging a growing book silently skips rows.
    after: Option<Uuid>,
    /// Equality on the chart code. **Equality, not search**: no pattern
    /// matching and no free text.
    #[param(example = "customer_receivable")]
    purpose: Option<String>,
    /// Equality on the owner. It selects no house accounts, which have no
    /// owner at all.
    #[param(example = "co_1")]
    owner_id: Option<String>,
}

/// One page of the account register.
#[derive(Serialize, ToSchema)]
pub(crate) struct AccountListRead {
    /// The page, in creation order — `id` is `uuidv7()`, so ordering by it
    /// orders by when each account was opened.
    ///
    /// **An empty list is a legitimate answer** and never a 404: it is what
    /// an unknown tenant, a typo'd tenant, a tenant with no accounts and a
    /// reader scoped elsewhere all produce, and two of those are the
    /// fail-closed path working correctly (ADR-0019).
    accounts: Vec<AccountRead>,
    /// The `after` to send for the next page, or `null` when this page did
    /// not fill. **A full page means "there may be more", never "there is"**:
    /// the alternative is reading one row past every page to be certain, and
    /// a caller that follows this key to an empty page has learnt the same
    /// thing one request later.
    #[schema(required)]
    next_after: Option<Uuid>,
}

/// One account, as the register holds it — the representation BOTH of this
/// resource's verbs answer with: a row of the listing, and the whole of an
/// accepted opening's `account`.
///
/// **No balance, and that is contract** (ADR-0021): balances are per currency
/// and per stripe, so a balance per row would be N+1, and
/// `GET /v1/accounts/{account_id}/balance` answers that question one account
/// at a time and exactly. `metadata` is here and a balance is not, and the
/// two are different questions: metadata is the caller's own object, written
/// at the opening and readable on no other route.
#[derive(Serialize, ToSchema)]
pub(crate) struct AccountRead {
    account_id: Uuid,
    /// `company`, `platform`, `bank_account` or `house`.
    owner_type: String,
    /// `null` on a house account, which is the ledger's own side and has no
    /// owner.
    #[schema(required)]
    owner_id: Option<String>,
    /// The account type, by its chart code.
    purpose: String,
    /// `asset`, `liability`, `equity`, `revenue` or `expense` — the chart's,
    /// copied onto the account and held honest by `fk_accounts__type`.
    category: String,
    /// `debit` or `credit`. **Not derivable from `category`**: a loss
    /// allowance is an asset with a credit normal balance, which is why the
    /// schema stores both.
    normal_balance: String,
    /// `none`, `shared` or `per_shard` — whether this type's positions may be
    /// summed for reporting, and the reason a `per_shard` type cannot live in
    /// a house account (ADR-0012).
    counterparty_scope: String,
    currency: String,
    /// How many stripes the writer spreads this account's balance row across.
    /// **The one place a stripe count is spoken** — no stripe VALUE appears
    /// in any response (ADR-0013 §4), and this is the hint, not a position.
    #[schema(example = 64)]
    stripe_count: i16,
    /// The caller's own object, as the opening set it — `{}` when it named
    /// none, because the column is `NOT NULL DEFAULT '{}'`.
    ///
    /// It is here because until now a caller could WRITE metadata and had no
    /// route that read it back, which is a hole rather than a missing
    /// feature. ADR-0021's "identity plus `stripe_count`" is extended by this
    /// one field and by nothing else: the part of that sentence that was
    /// load-bearing is the absence of BALANCES, and they are still absent.
    metadata: serde_json::Value,
    /// When the account was opened — the database's clock.
    #[serde(with = "time::serde::rfc3339")]
    created_at: OffsetDateTime,
}

/// One account as the register holds it, on the wire. One renderer for both
/// verbs — the listing's rows and the opening's answer — because ADR-0021's
/// fix is that the two ARE the same representation, and two renderings could
/// disagree about which fields that is.
fn account_on_the_wire(account: ledger::Account) -> AccountRead {
    AccountRead {
        account_id: account.account_id,
        owner_type: account.owner_type,
        owner_id: account.owner_id,
        purpose: account.purpose,
        category: account.category,
        normal_balance: account.normal_balance,
        counterparty_scope: account.counterparty_scope,
        currency: account.currency,
        stripe_count: account.stripe_count,
        metadata: account.metadata,
        created_at: account.created_at,
    }
}

/// List the accounts on one book.
///
/// **ADR-0019 refused every listing; ADR-0021 withdraws that for accounts and
/// keeps it for transactions.** ADR-0019's ground was that a listing *"needs
/// an ordering and a page key this spike did not design"* — a *not yet*, not a
/// *never* — and for accounts the ordering already exists: `pk_accounts` is
/// `(tenant_id, id)` and `id` is `uuidv7()`, which is time-ordered and total.
/// A TRANSACTION listing would still have to choose between the recorded and
/// the effective axis, which is the one place a listing can be confidently
/// wrong.
#[utoipa::path(
    get,
    path = "/v1/accounts",
    operation_id = "listAccounts",
    tag = "accounts",
    params(AccountListParams),
    responses(
        (
            status = 200,
            description = "One page of the account register, in creation order — identity, \
                           the derived chart triple, the stripe count and the caller's own \
                           `metadata`, and no balances (ADR-0021). An unknown tenant answers \
                           200 with an empty list, never 404: there is no tenant registry to \
                           consult, so inventing the status would mean inventing the registry \
                           (ADR-0019).",
            body = AccountListRead
        ),
        (
            status = 422,
            description = "Refused. `type` is one of: `invalid_request` (a `limit` outside \
                           1–1000, zero or negative included — refused rather than clamped) or \
                           `tenant_mismatch`.",
            body = ErrorBody
        ),
        (
            status = 400,
            description = "A required query parameter is missing, or a value would not \
                           deserialize into its documented type — including an `after` that is \
                           not a UUID. `type` is `invalid_request`.",
            body = ErrorBody
        ),
        (
            status = 503,
            description = "The read exceeded this deployment's `statement_timeout` (`57014`). \
                           `type` is `report_timed_out`.",
            body = ErrorBody
        ),
        (
            status = 500,
            description = "The read failed. `type` is `internal`.",
            body = ErrorBody
        ),
    ),
)]
pub(crate) async fn list_accounts<L, R>(
    State(state): State<crate::AppState<L, R>>,
    Params(params): Params<AccountListParams>,
) -> Response
where
    L: Ledger,
    R: Reports,
{
    let query = ledger::AccountListingQuery {
        tenant_id: params.tenant_id,
        limit: params.limit,
        after: params.after,
        purpose: params.purpose,
        owner_id: params.owner_id,
    };
    match state.reports.accounts(&query).await {
        Ok(listing) => answer_the_register_page(listing),
        Err(refused) => refusal_for_read(refused),
    }
}

/// The page on the wire, rendered from what the register holds.
fn answer_the_register_page(listing: ledger::AccountListing) -> Response {
    axum::Json(AccountListRead {
        next_after: listing.next_after,
        accounts: listing
            .accounts
            .into_iter()
            .map(account_on_the_wire)
            .collect(),
    })
    .into_response()
}

/// The query half of `GET /v1/accounts/{account_id}/entries` — the book, the
/// AXIS, the cursor, the effective range and the page.
#[derive(Deserialize, IntoParams)]
#[into_params(parameter_in = Query)]
pub(crate) struct AccountStatementParams {
    /// The book to read.
    #[param(example = "t1")]
    tenant_id: String,
    /// **Required, and there is no default** (ADR-0023). `recorded` orders by
    /// commit position — what the ledger learnt, and when — and `effective`
    /// orders by business date. The two disagree about where a backdated
    /// entry sits, which is what two axes MEAN (ADR-0006): whichever one were
    /// chosen for a caller who named none would be the axis they did not
    /// think about, so this endpoint refuses rather than picks.
    #[param(example = "recorded")]
    axis: String,
    /// The commit position to pin the page to — a `pinned_cursor` from an
    /// earlier read. Omit it and one is pinned server-side and returned. It
    /// bounds BOTH axes: an entry is on this page only if it had committed by
    /// this cursor, whatever it is dated.
    #[param(example = "231000")]
    cursor: Option<String>,
    /// Inclusive lower bound on `effective_at`, RFC 3339. **`axis=effective`
    /// only** — on `axis=recorded` it is refused rather than ignored, because
    /// the page there is ordered and bounded by commit position and a
    /// business-date window would be a filter over the account's whole
    /// history.
    #[param(example = "2026-01-01T00:00:00Z")]
    effective_from: Option<String>,
    /// EXCLUSIVE upper bound on `effective_at`, RFC 3339 — half-open, as every
    /// range on this surface is (ADR-0011 §A3). `axis=effective` only.
    #[param(example = "2026-02-01T00:00:00Z")]
    effective_to: Option<String>,
    /// How many entries at most, 1–1000. Omitted means 100. A value outside
    /// the window is REFUSED rather than clamped, exactly as on
    /// `GET /v1/accounts`.
    #[param(minimum = 1, maximum = 1000, example = 100)]
    limit: Option<i64>,
    /// The `next_after` an earlier page of **this same axis** answered with,
    /// sent back unchanged. It is the last row's ordering key — `xact_id` and
    /// entry id on the recorded axis, the business date as well on the
    /// effective one — and a key of the other axis is refused rather than
    /// used as a bound of an order it does not name.
    ///
    /// **It is never `account_seq`**, and that is the trap worth naming:
    /// `uq_entries__account_seq` is per `(tenant, account, stripe, seq)`, so
    /// on a striped account the counter is not a total order and paging by it
    /// would interleave two counters and silently drop or repeat rows
    /// (ADR-0023). The number is returned on every entry — it is what a drift
    /// check walks — and it does not order the page.
    after: Option<String>,
}

/// One page of one account's entries: the axis they were ordered by, the
/// cursor they were pinned at, and the key of the next page.
#[derive(Serialize, ToSchema)]
pub(crate) struct AccountStatementRead {
    /// The commit position this page ran at — supplied or server-pinned.
    /// Store it and send it back to walk the rest of this same book: the page
    /// after it is then the page after it *was*, whatever has committed since.
    #[schema(example = "231000")]
    pinned_cursor: String,
    /// The axis this page was ordered by, echoed — `recorded` or `effective`.
    #[schema(example = "recorded")]
    axis: String,
    /// The page, in the axis's order. **An empty list is a legitimate answer**
    /// for an account with no entries at this cursor, in this range; an
    /// account that does not exist is a 404 instead, which is a distinction
    /// only the account register can draw (ADR-0019).
    entries: Vec<StatementEntryRead>,
    /// The `after` to send for the next page, or `null` when this page did not
    /// fill. **A full page means "there may be more", never "there is"** — the
    /// same rule `GET /v1/accounts` follows, and for the same reason: the
    /// alternative is reading one row past every page to be certain.
    #[schema(required, example = "231000,0198f0c9-1f8a-7c31-9e1a-000000000001")]
    next_after: Option<String>,
}

/// One entry of an account's statement — **the leg that touched THIS
/// account**, never the transaction's other legs, which belong to other
/// accounts. `transaction_id` is on every row and
/// `GET /v1/transactions/{transaction_id}` answers the rest (ADR-0023).
#[derive(Serialize, ToSchema)]
pub(crate) struct StatementEntryRead {
    /// The entry's own id — `pk_entries`'s column, and the tie-break that
    /// makes each axis a TOTAL order.
    entry_id: Uuid,
    /// The transaction this leg belongs to.
    transaction_id: Uuid,
    /// `debit` or `credit`. Direction carries the sign; the amount never does.
    direction: String,
    /// Minor units, as an exact-integer decimal string — **not a JSON
    /// number** (ADR-0022). `ledger_entries.amount_minor` is a `bigint` and
    /// JSON has no integer type, so a large amount read as a number comes back
    /// silently wrong.
    #[schema(example = "2500")]
    amount_minor: String,
    currency: String,
    /// When the entry is DATED — the business date, and the effective axis's
    /// position.
    #[serde(with = "time::serde::rfc3339")]
    effective_at: OffsetDateTime,
    /// When the entry was WRITTEN — the database's clock. It is provenance
    /// rather than an ordering: the recorded axis is ordered by commit
    /// position (`xact_id`), which `recorded_at` cannot stand in for, because
    /// a clock reading taken before a commit does not order commits
    /// (ADR-0006).
    #[serde(with = "time::serde::rfc3339")]
    recorded_at: OffsetDateTime,
    /// The account's own gapless sequence number for this leg. The counter is
    /// per `(account, stripe)` — documented, never exposed: no stripe appears
    /// in any response (ADR-0013 §4). It is what a drift check walks, and it
    /// is **not** the page key (see `after`).
    account_seq: i64,
}

/// Read one account's entries, in order, at a cursor.
///
/// **The listing ADR-0019 refused, and the axis is why it can ship.** That
/// decision refused a listing of entries because one *"must choose between the
/// recorded axis and the effective axis"*; this one does not choose — it takes
/// the axis as a parameter, which is exactly what ADR-0019 itself ruled for the
/// trial balance. Each ordering is served by the index the schema already
/// carries for it, and the entry id breaks ties so that each is total:
/// `recorded` is `(xact_id, id)` on `ix_entries__asof_commit`, `effective` is
/// `(effective_at, xact_id, id)` on `ix_entries__effective`.
#[utoipa::path(
    get,
    path = "/v1/accounts/{account_id}/entries",
    operation_id = "getAccountStatement",
    tag = "accounts",
    params(
        ("account_id" = Uuid, Path, description = "The account whose entries to read."),
        AccountStatementParams,
    ),
    responses(
        (
            status = 200,
            description = "One page of the account's entries, in the axis's order, with the \
                           cursor the page was pinned at and the key of the next page. **The \
                           two axes answer the same SET in different ORDERS**, and a backdated \
                           entry is where they disagree: it sits in its own past on the \
                           effective axis and at the end of the recorded one. An account that \
                           exists and has no entries in range answers an empty list, never a \
                           404.",
            body = AccountStatementRead
        ),
        (
            status = 404,
            description = "No such account on this book. `type` is `account_unknown` — note \
                           that the write path returns 422 under this same `type`, \
                           deliberately: there the caller must change the request, here the \
                           resource does not exist. An account that exists with no entries is \
                           a 200 with an empty page, and only the account register can draw \
                           that distinction (ADR-0019).",
            body = ErrorBody
        ),
        (
            status = 422,
            description = "Refused. `type` is one of: `invalid_request` (an `axis` that is not \
                           `recorded` or `effective`; an `effective_from` or `effective_to` \
                           that is not an RFC 3339 instant, or either of them on \
                           `axis=recorded`, where the page is bounded by commit position; a \
                           `limit` outside 1–1000, zero and negative included — refused rather \
                           than clamped; an `after` that is not a page key of the axis being \
                           paged; or a `cursor` that is not an `xid8` at all), `cursor_invalid` \
                           (a legal `xid8` above this cluster's horizon or at or below the \
                           book's oldest entry), or `tenant_mismatch`.",
            body = ErrorBody
        ),
        (
            status = 400,
            description = "A required query parameter is missing — `tenant_id`, or the `axis` \
                           this endpoint will not choose for you — or a value would not \
                           deserialize into its documented type, including an `account_id` \
                           path segment that is not a UUID. `type` is `invalid_request`.",
            body = ErrorBody
        ),
        (
            status = 503,
            description = "The read exceeded this deployment's `statement_timeout` (`57014`). \
                           `type` is `report_timed_out`.",
            body = ErrorBody
        ),
        (
            status = 500,
            description = "The read failed. `type` is `internal`.",
            body = ErrorBody
        ),
    ),
)]
pub(crate) async fn get_account_statement<L, R>(
    State(state): State<crate::AppState<L, R>>,
    Segment(account_id): Segment<Uuid>,
    Params(params): Params<AccountStatementParams>,
) -> Response
where
    L: Ledger,
    R: Reports,
{
    let query = match statement_query(account_id, params) {
        Ok(query) => query,
        Err(refused) => return refused.into_response(),
    };
    match state.reports.account_statement(&query).await {
        Ok(page) => answer_the_statement_page(page),
        Err(refused) => refusal_for_read(refused),
    }
}

/// The query string as the port's query. The two instants are parsed here, as
/// they are on every report route; the axis and the page key are NOT — whether
/// text names an axis of this ledger, and whether a key belongs to the order
/// being paged, are the read path's judgement and not this layer's (ADR-0023).
fn statement_query(
    account_id: Uuid,
    params: AccountStatementParams,
) -> Result<ledger::AccountStatementQuery, Refusal> {
    Ok(ledger::AccountStatementQuery {
        tenant_id: params.tenant_id,
        account_id,
        axis: Some(params.axis),
        cursor: params.cursor,
        effective_from: params
            .effective_from
            .as_deref()
            .map(|from| instant("effective_from", from))
            .transpose()?,
        effective_to: params
            .effective_to
            .as_deref()
            .map(|to| instant("effective_to", to))
            .transpose()?,
        limit: params.limit,
        after: params.after,
    })
}

/// The page on the wire, with the axis it was ordered by and the key of the
/// next page rendered as the text a caller sends back unchanged.
fn answer_the_statement_page(page: ledger::AccountStatement) -> Response {
    axum::Json(AccountStatementRead {
        pinned_cursor: page.pinned_cursor.to_string(),
        axis: page.axis.named().to_owned(),
        next_after: page.next_after.map(|key| key.rendered()),
        entries: page
            .entries
            .into_iter()
            .map(|entry| StatementEntryRead {
                entry_id: entry.entry_id,
                transaction_id: entry.transaction_id,
                direction: entry.direction,
                amount_minor: entry.amount_minor.to_string(),
                currency: entry.currency,
                effective_at: entry.effective_at,
                recorded_at: entry.recorded_at,
                account_seq: entry.account_seq,
            })
            .collect(),
    })
    .into_response()
}
