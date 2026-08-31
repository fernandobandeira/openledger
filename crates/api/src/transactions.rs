//! The one endpoint: its wire types, its handler, and the `#[utoipa::path]`
//! annotation the committed spec is generated from. The types double as the
//! schema — what the handler deserializes IS what the spec documents, so body
//! drift is structurally impossible; status, header and path drift are not,
//! which is what `tests/spec.rs` and the e2e conformance test hold.

use axum::extract::{FromRequest, Request, State};
use axum::http::{HeaderName, StatusCode};
use axum::response::{IntoResponse, Response};
use ledger::Ledger;
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use utoipa::ToSchema;
use uuid::Uuid;

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

/// The error body: a stable machine-readable `type`, prose in `detail`.
#[derive(Serialize, ToSchema)]
pub(crate) struct ErrorBody {
    /// Stable machine-readable identifier. Parse this, never `detail`.
    #[schema(example = "invalid_request")]
    r#type: &'static str,
    /// Human-readable explanation. Not stable; do not parse.
    detail: String,
}

fn refuse(status: StatusCode, r#type: &'static str, detail: String) -> Response {
    (status, axum::Json(ErrorBody { r#type, detail })).into_response()
}

/// `axum::Json`, wearing the documented refusal shape: axum's own body
/// rejections (syntax, wrong type, missing content-type, oversized) render
/// its default plain-text bodies, which are not the [`ErrorBody`] the spec
/// documents. This wrapper keeps the status axum chose — 400 for broken
/// JSON, 413 for an oversized body, 415 for the wrong `Content-Type`, 422
/// for a field that fails to deserialize — and re-renders the message as
/// `{type: "invalid_request", detail}`, so every refusal on this surface is
/// machine-readable the same way.
pub(crate) struct Body<T>(pub(crate) T);

impl<S, T> FromRequest<S> for Body<T>
where
    S: Send + Sync,
    T: serde::de::DeserializeOwned,
{
    type Rejection = Response;

    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        match axum::Json::<T>::from_request(req, state).await {
            Ok(axum::Json(value)) => Ok(Self(value)),
            Err(rejection) => Err(refuse(
                rejection.status(),
                "invalid_request",
                rejection.body_text(),
            )),
        }
    }
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
pub(crate) async fn post_transaction<L>(
    State(state): State<crate::AppState<L>>,
    Body(body): Body<TransactionBody>,
) -> Response
where
    L: Ledger,
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
        Ok(posted) => {
            // Replay re-renders the stored result; the caller told apart by the
            // header and the code, not by a cached body (ADR-0013 §2).
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
        // 422, not 400 or 409: the caller must CHANGE the request to escape
        // (ADR-0013 §2 takes the IETF draft's split by what the client must do).
        Err(ledger::WriteError::KeyReused) => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "idempotency_key_reused",
            "this idempotency key was already used by a request with a different body; \
             nothing was written — send a new key, or resend the original request unchanged"
                .to_owned(),
        ),
        Err(ledger::WriteError::AccountUnknown {
            account_id,
            currency,
        }) => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "account_unknown",
            format!("account {account_id} does not exist, or does not hold {currency}"),
        ),
        Err(ledger::WriteError::Overflow) => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "invalid_request",
            "the posting amounts overflow 64-bit minor units".to_owned(),
        ),
        Err(ledger::WriteError::ResolveTargetUnknown { resolves_id }) => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "resolve_target_unknown",
            format!("resolves_id {resolves_id} names no transaction on this tenant's book"),
        ),
        Err(ledger::WriteError::ResolveTargetNotPending { resolves_id }) => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "resolve_target_not_pending",
            format!(
                "transaction {resolves_id} is not pending — only a pending transaction can be \
                 resolved, and its status never mutates"
            ),
        ),
        Err(ledger::WriteError::ReverseTargetUnknown { reverses_id }) => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "reverse_target_unknown",
            format!("reverses_id {reverses_id} names no transaction on this tenant's book"),
        ),
        Err(ledger::WriteError::ReverseTargetNotReversible { reverses_id }) => refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "reverse_target_not_reversible",
            format!(
                "transaction {reverses_id} cannot be reversed — only an ordinary posting that \
                 is itself neither a resolution nor a reversal can be; recovery from a \
                 mistaken correction is a fresh posting"
            ),
        ),
        Err(ledger::WriteError::TargetAlreadySuperseded { transaction_id }) => refuse(
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
        Err(ledger::WriteError::Storage(e)) => {
            eprintln!("openledger: write failed: {e}");
            refuse(
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal",
                "the write failed; nothing was committed".to_owned(),
            )
        }
        Err(ledger::WriteError::Internal(detail)) => {
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
        .map(|p| ledger::Posting::new(p.source, p.destination, p.amount_minor, p.currency))
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
