//! The account resource's two new verbs (ADR-0021): open one, and list them.
//! Their wire types, their handlers, and the `#[utoipa::path]` annotations the
//! committed spec is generated from.
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
//! size is its report service — and the SQL another ring out.

use axum::extract::State;
use axum::http::{HeaderName, StatusCode};
use axum::response::{IntoResponse, Response};
use ledger::{Ledger, Reports};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use utoipa::{IntoParams, ToSchema};
use uuid::Uuid;

use crate::reports::refusal_for_read;
use crate::wire::{Body, ErrorBody, Params, refuse};

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
/// caused.
#[derive(Serialize, ToSchema)]
pub(crate) struct AccountCreated {
    /// The event row this call claimed — or, on a replay, the one it found.
    /// Opening an account writes an EVENT and no ledger transaction, which is
    /// the case ADR-0005 justified the event log by.
    event_id: Uuid,
    /// The account. Never null, unlike a posting's `transaction_id`: an
    /// accepted opening always wrote one, and a replay finds it by the
    /// natural key its own body names.
    account_id: Uuid,
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
                           and its event atomically.",
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
                           nothing was written (ADR-0013 §2).",
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
            account_id: opened.account_id,
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

/// One account, as the register holds it.
///
/// **No balance, and that is contract** (ADR-0021): balances are per currency
/// and per stripe, so a balance per row would be N+1, and
/// `GET /v1/accounts/{account_id}/balance` answers that question one account
/// at a time and exactly.
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
    /// When the account was opened — the database's clock.
    #[serde(with = "time::serde::rfc3339")]
    created_at: OffsetDateTime,
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
            description = "One page of the account register, in creation order. An unknown \
                           tenant answers 200 with an empty list, never 404: there is no \
                           tenant registry to consult, so inventing the status would mean \
                           inventing the registry (ADR-0019).",
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
            .map(|account| AccountRead {
                account_id: account.account_id,
                owner_type: account.owner_type,
                owner_id: account.owner_id,
                purpose: account.purpose,
                category: account.category,
                normal_balance: account.normal_balance,
                counterparty_scope: account.counterparty_scope,
                currency: account.currency,
                stripe_count: account.stripe_count,
                created_at: account.created_at,
            })
            .collect(),
    })
    .into_response()
}
