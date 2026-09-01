//! The transaction resource: post one, and read one back. Their wire types,
//! their handlers, and the `#[utoipa::path]` annotations the committed spec is
//! generated from. The types double as the schema — what the handler
//! deserializes IS what the spec documents, so body drift is structurally
//! impossible; status, header and path drift are not, which is what
//! `tests/spec.rs` and the e2e conformance test hold.
//!
//! The read-back half arrived with ADR-0019, and its argument is that a
//! write-only API is not an adoption surface: the post below answers two
//! UUIDs, and until now nothing over HTTP could say what they point at —
//! while ADR-0016 made `status`, `resolves_id` and `reverses_id` wire concepts
//! a caller could not read back. It is cheap in the way scope creep is not:
//! one statement, by primary key, no cursor (the rows are immutable) and no
//! chart version.

use axum::extract::State;
use axum::http::{HeaderName, StatusCode};
use axum::response::{IntoResponse, Response};
use ledger::{Ledger, Reports};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use utoipa::{IntoParams, ToSchema};
use uuid::Uuid;

use crate::reports::refusal_for_read;
use crate::wire::{Body, ErrorBody, Params, Segment, refuse};

const IDEMPOTENCY_REPLAYED: HeaderName = HeaderName::from_static("idempotency-replayed");

/// One movement of money: `amount_minor` leaves `source` and arrives at
/// `destination`. Direction is carried by the pair, never by a sign.
#[derive(Deserialize, ToSchema)]
pub(crate) struct PostingBody {
    /// Account the amount leaves.
    source: Uuid,
    /// Account the amount arrives at.
    destination: Uuid,
    /// Minor units of `currency`. Strictly positive.
    #[schema(minimum = 1, example = 2500)]
    amount_minor: i64,
    /// ISO 4217 alphabetic code, three uppercase ASCII letters.
    #[schema(min_length = 3, max_length = 3, example = "USD")]
    currency: String,
}

/// Whether the transaction lands on the books or records money that MAY
/// move. Status never mutates: a pending transaction becomes posted by a NEW
/// transaction naming it in `resolves_id`, never by an update (ADR-0016).
#[derive(Clone, Copy, Deserialize, ToSchema)]
#[serde(rename_all = "lowercase")]
pub(crate) enum StatusBody {
    /// A claim about what may happen: entries are written and sequenced, but
    /// no report and no balance counts them until a resolution posts. The
    /// pending population is enumerated by `recon_pending_bridge`.
    Pending,
    /// Money that moved. The default.
    Posted,
}

/// The body of `POST /v1/transactions`.
#[derive(Deserialize, ToSchema)]
pub(crate) struct TransactionBody {
    /// The book this transaction belongs to. Named in the body by decision
    /// (ADR-0017): data scoping, never an identity claim — the trust story is
    /// the deployment perimeter's, and authenticating callers is the
    /// deployer's layer.
    #[schema(example = "t1")]
    tenant_id: String,
    /// Caller-supplied replay key, unique per tenant. Sending the same key
    /// with the same body replays the stored result; with a different body it
    /// is refused as `idempotency_key_reused` (ADR-0013 §2).
    #[schema(min_length = 1, example = "charge-1")]
    idempotency_key: String,
    /// When the movement is deemed to have happened, RFC 3339. Required —
    /// the writer will not invent a date — EXCEPT on a reversal, where
    /// omission means "the target's own effective_at" (ADR-0016's soft
    /// convention). A supplied date is taken as given, including one below
    /// the target's; the cost of that window is recorded in ADR-0016.
    #[serde(default, with = "time::serde::rfc3339::option")]
    effective_at: Option<OffsetDateTime>,
    /// Omitted means `posted`.
    #[serde(default)]
    status: Option<StatusBody>,
    /// The PENDING transaction this one resolves — pending → posted is this
    /// new, posted transaction, never an update to the original (ADR-0016).
    /// The resolution's postings need not mirror the pending amounts (a
    /// partial capture resolves with less); a resolving transaction cannot
    /// itself be pending.
    #[serde(default)]
    resolves_id: Option<Uuid>,
    /// The transaction this one reverses — operational undo, as a NEW
    /// posted transaction (ADR-0016): a posted target is mirrored in full
    /// (same legs, directions flipped, derived by the server — send NO
    /// postings), and a pending target is voided by a zero-posting marker.
    /// The target must be an ordinary posting on this tenant's book,
    /// itself neither a resolution nor a reversal, and not already
    /// superseded.
    #[serde(default)]
    reverses_id: Option<Uuid>,
    /// At least one posting — except on a reversal, which must carry NONE:
    /// the server derives the mirror from the target.
    #[serde(default)]
    postings: Vec<PostingBody>,
}

/// The stored result of an accepted operation: the event, and the transaction
/// it caused.
#[derive(Serialize, ToSchema)]
pub(crate) struct TransactionCreated {
    /// The event row this call claimed — or, on a replay, the one it found.
    event_id: Uuid,
    /// The transaction the event caused. Nullable by contract: most accepted
    /// operations write no transaction at all (ADR-0013 §2). This endpoint
    /// always writes one, but a replay re-renders whatever was stored.
    // `required`: serde renders `None` as an explicit `null`, so the key is
    // always present — nullable and optional are different claims.
    #[schema(required)]
    transaction_id: Option<Uuid>,
}

/// Post a transaction.
///
/// The response set below is this endpoint's real one, not a shared error
/// enum's: the eight 422 `type`s named are exactly the ones the writer can
/// produce here, and nothing else is documented (spike 021 found both
/// candidate libraries fanning shared enums across statuses their endpoints
/// cannot return — the fix is to declare per endpoint, so this project
/// does).
#[utoipa::path(
    post,
    path = "/v1/transactions",
    operation_id = "postTransaction",
    tag = "transactions",
    request_body = TransactionBody,
    responses(
        (
            status = 201,
            description = "Posted: this call claimed the idempotency key and wrote the \
                           transaction atomically.",
            body = TransactionCreated,
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
            body = TransactionCreated,
            headers(
                ("Idempotency-Replayed" = bool,
                 description = "`true`: this response re-renders a previously stored result.")
            )
        ),
        (
            status = 422,
            description = "Refused, and nothing was written. The caller must CHANGE the request \
                           to escape — which is why this is 422, not 400 or 409 (ADR-0013 §2). \
                           `type` is one of: `invalid_request` (a precondition on the body \
                           failed, or a field failed to deserialize into its documented type), \
                           `idempotency_key_reused` (same key, different body — send a \
                           new key or resend the original request unchanged), `account_unknown` \
                           (a posting names an account that does not exist or does not hold \
                           that currency), `resolve_target_unknown` (`resolves_id` names no \
                           transaction on this tenant's book), `resolve_target_not_pending` \
                           (only a pending transaction can be resolved — its status never \
                           mutates), `reverse_target_unknown` (`reverses_id` names no \
                           transaction on this tenant's book), `reverse_target_not_reversible` \
                           (only an ordinary posting that is itself neither a resolution nor a \
                           reversal can be reversed), `target_already_superseded` (the named target \
                           already has its one supersession — resolved or reversed, either \
                           fate is final).",
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
pub(crate) async fn post_transaction<L, R>(
    State(state): State<crate::AppState<L, R>>,
    Body(body): Body<TransactionBody>,
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
    match state.ledger.post(&command).await {
        Ok(posted) => answer_the_stored_result(posted),
        Err(refused) => refusal_for(refused),
    }
}

/// The accepted answer, rendered from what the writer stored. The one decision
/// here is 201-vs-200, and the `Idempotency-Replayed` header is read off the
/// same flag, so the two cannot disagree: a replay re-renders the stored
/// result, and the caller is told apart by the header and the code, not by a
/// cached body (ADR-0013 §2).
fn answer_the_stored_result(posted: ledger::Posted) -> Response {
    let status = if posted.replayed {
        StatusCode::OK
    } else {
        StatusCode::CREATED
    };
    let replayed = if posted.replayed { "true" } else { "false" };
    (
        status,
        [(IDEMPOTENCY_REPLAYED, replayed)],
        axum::Json(TransactionCreated {
            event_id: posted.event_id,
            transaction_id: posted.transaction_id,
        }),
    )
        .into_response()
}

/// Every refusal the writer can produce here, on the wire — the whole table in
/// one place, because the nine named `type`s ARE the domain and they are what
/// the `#[utoipa::path]` responses above document. Exhaustive by construction:
/// a new [`ledger::WriteError`] variant does not compile until it is named a
/// `type` and given its prose.
fn refusal_for(error: ledger::WriteError) -> Response {
    match error {
        // 422, not 400 or 409: the caller must CHANGE the request to escape
        // (ADR-0013 §2 takes the IETF draft's split by what the client must do).
        ledger::WriteError::KeyReused => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "idempotency_key_reused",
            "this idempotency key was already used by a request with a different body; \
             nothing was written — send a new key, or resend the original request unchanged"
                .to_owned(),
        ),
        ledger::WriteError::AccountUnknown {
            account_id,
            currency,
        } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "account_unknown",
            format!("account {account_id} does not exist, or does not hold {currency}"),
        ),
        ledger::WriteError::Overflow => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "invalid_request",
            "the posting amounts overflow 64-bit minor units".to_owned(),
        ),
        ledger::WriteError::ResolveTargetUnknown { resolves_id } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "resolve_target_unknown",
            format!("resolves_id {resolves_id} names no transaction on this tenant's book"),
        ),
        ledger::WriteError::ResolveTargetNotPending { resolves_id } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "resolve_target_not_pending",
            format!(
                "transaction {resolves_id} is not pending — only a pending transaction can be \
                 resolved, and its status never mutates"
            ),
        ),
        ledger::WriteError::ReverseTargetUnknown { reverses_id } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "reverse_target_unknown",
            format!("reverses_id {reverses_id} names no transaction on this tenant's book"),
        ),
        ledger::WriteError::ReverseTargetNotReversible { reverses_id } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "reverse_target_not_reversible",
            format!(
                "transaction {reverses_id} cannot be reversed — only an ordinary posting that \
                 is itself neither a resolution nor a reversal can be; recovery from a \
                 mistaken correction is a fresh posting"
            ),
        ),
        ledger::WriteError::TargetAlreadySuperseded { transaction_id } => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "target_already_superseded",
            format!(
                "transaction {transaction_id} already has its one supersession — it was \
                 resolved or reversed, and either fate is final"
            ),
        ),
        // Same wire shape for both 500 classes: the caller gets no
        // internals, the operator's log gets the difference — a storage
        // failure reads as the backend's error, an Internal as the writer
        // naming its own can't-happen state.
        ledger::WriteError::Storage(e) => {
            eprintln!("openledger: write failed: {e}");
            refuse(
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal",
                "the write failed; nothing was committed".to_owned(),
            )
        }
        ledger::WriteError::Internal(detail) => {
            eprintln!("openledger: write failed: {detail}");
            refuse(
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal",
                "the write failed; nothing was committed".to_owned(),
            )
        }
    }
}

fn to_command(body: TransactionBody) -> Result<ledger::PostTransaction, ledger::Invalid> {
    let postings = body
        .postings
        .into_iter()
        .map(|posting| {
            ledger::Posting::new(
                posting.source,
                posting.destination,
                posting.amount_minor,
                posting.currency,
            )
        })
        .collect::<Result<Vec<_>, _>>()?;
    // Omitted means posted — the wire's default is decided here, at the
    // boundary, so the domain constructor never sees an absence.
    let status = match body.status.unwrap_or(StatusBody::Posted) {
        StatusBody::Pending => ledger::TransactionStatus::Pending,
        StatusBody::Posted => ledger::TransactionStatus::Posted,
    };
    ledger::PostTransaction::new(
        body.tenant_id,
        body.idempotency_key,
        body.effective_at,
        status,
        body.resolves_id,
        body.reverses_id,
        postings,
    )
}

/// The query half of `GET /v1/transactions/{transaction_id}` — which book to
/// look in. Named in the query string for the same reason the write path
/// names it in the body (ADR-0017): data scoping, never an identity claim.
#[derive(Deserialize, IntoParams)]
#[into_params(parameter_in = Query)]
pub(crate) struct TransactionParams {
    /// The book to read.
    #[param(example = "t1")]
    tenant_id: String,
}

/// A transaction as the book holds it, with its entries.
#[derive(Serialize, ToSchema)]
pub(crate) struct TransactionRead {
    transaction_id: Uuid,
    /// `posting` for an ordinary transaction, `period_close` for a close.
    kind: String,
    /// `pending` or `posted`. **It never mutates**: a pending transaction
    /// becomes posted by a NEW transaction naming it in `resolves_id`
    /// (ADR-0016), so a `pending` here is what was recorded and not a stage
    /// this row is passing through.
    status: String,
    /// When the movement is deemed to have happened — the caller's clock.
    #[serde(with = "time::serde::rfc3339")]
    effective_at: OffsetDateTime,
    /// When the row was written — the database's clock. The two axes are
    /// different questions (ADR-0006) and neither is derivable from the other.
    #[serde(with = "time::serde::rfc3339")]
    recorded_at: OffsetDateTime,
    /// The pending transaction this one resolved, if it is a resolution.
    #[schema(required)]
    resolves_id: Option<Uuid>,
    /// The transaction this one reversed, if it is a reversal.
    #[schema(required)]
    reverses_id: Option<Uuid>,
    /// The event that caused this transaction.
    event_id: Uuid,
    /// The legs. **Empty is a real answer**: a reversal of a pending
    /// transaction is a zero-posting void marker (ADR-0016).
    entries: Vec<EntryRead>,
}

/// One leg. `amount_minor` is a JSON number here and a decimal STRING on
/// every report, and the asymmetry is deliberate (ADR-0019): a single posting
/// is bounded by its column, and only an aggregate can exceed what a JSON
/// number carries exactly.
#[derive(Serialize, ToSchema)]
pub(crate) struct EntryRead {
    account_id: Uuid,
    /// `debit` or `credit`. Direction carries the sign; the amount never does.
    direction: String,
    #[schema(example = 2500)]
    amount_minor: i64,
    currency: String,
    /// The account's own gapless sequence number for this leg. The counter is
    /// per `(account, stripe)` — documented, never exposed: no stripe appears
    /// in any response (ADR-0013 §4).
    account_seq: i64,
}

/// Read a transaction back.
///
/// No cursor and no chart version: a transaction and its entries are
/// immutable (`ck_txn__append_only` and `ck_entries__append_only`, both
/// `ENABLE ALWAYS`), so there is nothing for an as-of to pin (ADR-0019).
#[utoipa::path(
    get,
    path = "/v1/transactions/{transaction_id}",
    operation_id = "getTransaction",
    tag = "transactions",
    params(
        ("transaction_id" = Uuid, Path, description = "The transaction to read."),
        TransactionParams,
    ),
    responses(
        (
            status = 200,
            description = "The transaction and its entries. `entries` is empty for a void — the \
                           zero-posting marker a reversal of a PENDING transaction writes \
                           (ADR-0016).",
            body = TransactionRead
        ),
        (
            status = 404,
            description = "No such transaction on this tenant's book. `type` is \
                           `transaction_unknown`. Note that an unknown TENANT is not 404 but \
                           200-with-nothing on the report routes, and 404 here: there is no \
                           tenant registry to consult, so a wrong `tenant_id` is \
                           indistinguishable from a book that does not hold this transaction.",
            body = ErrorBody
        ),
        (
            status = 422,
            description = "Refused. `type` is `tenant_mismatch` — the `tenant_id` asked about is \
                           not the scope the read path set on the session. Vacuous today by \
                           construction and declared anyway (ADR-0019).",
            body = ErrorBody
        ),
        (
            status = 400,
            description = "A required query parameter is missing, or a value would not \
                           deserialize into its documented type — including a \
                           `transaction_id` path segment that is not a UUID. `type` is \
                           `invalid_request`.",
            body = ErrorBody
        ),
        (
            status = 503,
            description = "The read exceeded the read pool's `statement_timeout` (`57014`). \
                           `type` is `report_timed_out`. **503, not 500 and not 504**: the \
                           service is healthy, the request was too expensive, and retrying it \
                           unchanged fails identically (ADR-0019).",
            body = ErrorBody
        ),
        (
            status = 500,
            description = "The read failed. `type` is `internal`, and the caller gets no \
                           internals — the operator's log has the error.",
            body = ErrorBody
        ),
    ),
)]
pub(crate) async fn get_transaction<L, R>(
    State(state): State<crate::AppState<L, R>>,
    Segment(transaction_id): Segment<Uuid>,
    Params(params): Params<TransactionParams>,
) -> Response
where
    L: Ledger,
    R: Reports,
{
    let query = ledger::TransactionQuery {
        tenant_id: params.tenant_id,
        transaction_id,
    };
    match state.reports.transaction(&query).await {
        Ok(found) => answer_the_transaction(found),
        Err(refused) => refusal_for_read(refused),
    }
}

/// The transaction on the wire, rendered from what the book holds.
fn answer_the_transaction(found: ledger::Transaction) -> Response {
    axum::Json(TransactionRead {
        transaction_id: found.transaction_id,
        kind: found.kind,
        status: found.status,
        effective_at: found.effective_at,
        recorded_at: found.recorded_at,
        resolves_id: found.resolves_id,
        reverses_id: found.reverses_id,
        event_id: found.event_id,
        entries: found
            .entries
            .into_iter()
            .map(|entry| EntryRead {
                account_id: entry.account_id,
                direction: entry.direction,
                amount_minor: entry.amount_minor,
                currency: entry.currency,
                account_seq: entry.account_seq,
            })
            .collect(),
    })
    .into_response()
}
