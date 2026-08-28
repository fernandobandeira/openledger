//! Spike 021 — ADR-0013's write-path contract expressed with `utoipa` 5.5.0 + `utoipa-axum` 0.2.0.
//!
//! The handler bodies are stubs. The point of this file is the *annotation* side:
//! whether the contract in ADR-0013 §2 can be stated in a way that reaches the spec.
//!
//!   `cargo run -- emit <path>`  writes openapi.json and exits (the CI artifact path)
//!   `cargo run -- serve`        serves the API on 127.0.0.1:8021

use axum::Json;
use axum::extract::Path;
use axum::http::{HeaderName, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use utoipa::{IntoResponses, OpenApi, ToSchema};
use utoipa_axum::router::OpenApiRouter;
use utoipa_axum::routes;
use uuid::Uuid;

// ---------------------------------------------------------------- the contract

/// One leg of a transaction. Amounts are in minor units and always positive;
/// direction is carried by `source` / `destination`, never by the sign.
#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct Posting {
    /// Account the value leaves.
    #[schema(example = "assets:cash:usd")]
    pub source: String,
    /// Account the value arrives at.
    #[schema(example = "liabilities:customer:9f3a")]
    pub destination: String,
    /// Minor units. Positive.
    #[schema(minimum = 1, example = 250_00)]
    pub amount: i64,
    /// ISO-4217 alphabetic code.
    #[schema(min_length = 3, max_length = 3, example = "USD")]
    pub currency: String,
}

/// The body of `POST /v1/transactions`.
#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct CreateTransactionRequest {
    /// Caller-supplied replay key. Scoped to the tenant; never expires (ADR-0013 §2).
    #[schema(min_length = 1, example = "5f0a1e4c-1c0f-4b1e-8f9d-2b7a9f0e4c11")]
    pub idempotency_key: String,
    /// When the movement is deemed to have happened, RFC 3339.
    pub effective_at: DateTime<Utc>,
    /// At least one posting.
    #[schema(min_items = 1)]
    pub postings: Vec<Posting>,
}

/// The stored result of an accepted write: the event, and the transaction it caused.
#[derive(Debug, Serialize, ToSchema)]
pub struct TransactionAccepted {
    /// The `ledger_events` row this call claimed or replayed.
    pub event_id: Uuid,
    /// The transaction the event caused. **`null` for the majority of accepted
    /// operations, which write no transaction at all** (ADR-0013 §2).
    pub transaction_id: Option<Uuid>,
}

/// A problem document. `type` is a stable machine-readable identifier.
#[derive(Debug, Serialize, ToSchema)]
pub struct ProblemDetail {
    /// Stable error identifier, e.g. `idempotency_key_reused_with_different_body`.
    #[serde(rename = "type")]
    #[schema(rename = "type", example = "idempotency_key_reused_with_different_body")]
    pub kind: String,
    /// Human-readable explanation. Not stable; do not parse.
    pub detail: String,
}

// ------------------------------------------------- the error enum -> responses

/// One Rust enum, two documented HTTP responses.
#[derive(Debug, IntoResponses)]
pub enum ApiError {
    /// The idempotency key was reused with a different body. Correct the request
    /// and resend; nothing was written (ADR-0013 §2).
    #[response(status = 422)]
    PoisonedReplay(#[to_schema] ProblemDetail),

    /// No such account in this tenant.
    #[response(status = 404)]
    UnknownAccount(#[to_schema] ProblemDetail),
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, body) = match self {
            ApiError::PoisonedReplay(p) => (StatusCode::UNPROCESSABLE_ENTITY, p),
            ApiError::UnknownAccount(p) => (StatusCode::NOT_FOUND, p),
        };
        (status, Json(body)).into_response()
    }
}

// ------------------------------------------------------------------- handlers

const IDEMPOTENCY_REPLAYED: HeaderName = HeaderName::from_static("idempotency-replayed");

/// Record a transaction.
///
/// Claims the idempotency key and, in the same database transaction, writes what it
/// causes. A replay of the same key with the same body returns the original answer
/// and `Idempotency-Replayed: true`.
#[utoipa::path(
    post,
    path = "/v1/transactions",
    operation_id = "createTransaction",
    tag = "transactions",
    request_body = CreateTransactionRequest,
    responses(
        (
            status = 201,
            description = "Accepted, or replayed with the original stored result.",
            body = TransactionAccepted,
            headers(
                ("Idempotency-Replayed" = bool,
                 description = "`true` when this call replayed an existing event rather than \
                                claiming the key. The body is byte-identical either way.")
            )
        ),
        ApiError,
    ),
)]
async fn create_transaction(
    Json(req): Json<CreateTransactionRequest>,
) -> Result<(StatusCode, [(HeaderName, HeaderValue); 1], Json<TransactionAccepted>), ApiError> {
    // Stubbed: no database in this spike. One branch each so both documented
    // responses are reachable from a real call.
    if req.idempotency_key == "poison" {
        return Err(ApiError::PoisonedReplay(ProblemDetail {
            kind: "idempotency_key_reused_with_different_body".into(),
            detail: "The key has already been used with a different request body.".into(),
        }));
    }
    let replayed = req.idempotency_key.starts_with("replay-");
    Ok((
        StatusCode::CREATED,
        [(
            IDEMPOTENCY_REPLAYED,
            HeaderValue::from_static(if replayed { "true" } else { "false" }),
        )],
        Json(TransactionAccepted {
            event_id: Uuid::nil(),
            // null unless the event caused a transaction.
            transaction_id: req.postings.first().map(|_| Uuid::nil()),
        }),
    ))
}

/// The current balance of one account, summed over its stripes.
#[derive(Debug, Serialize, ToSchema)]
pub struct AccountBalance {
    pub account_id: Uuid,
    pub currency: String,
    /// Minor units. May be negative.
    pub balance: i64,
}

/// Read one account's balance.
#[utoipa::path(
    get,
    path = "/v1/accounts/{id}/balance",
    operation_id = "getAccountBalance",
    tag = "accounts",
    params(
        ("id" = Uuid, Path, description = "Account id."),
    ),
    responses(
        (status = 200, description = "The account's balance.", body = AccountBalance),
        ApiError,
    ),
)]
async fn get_account_balance(Path(id): Path<Uuid>) -> Result<Json<AccountBalance>, ApiError> {
    Ok(Json(AccountBalance {
        account_id: id,
        currency: "USD".into(),
        balance: 0,
    }))
}

// ------------------------------------------------------------------- the spec

#[derive(OpenApi)]
#[openapi(
    info(
        title = "OpenLedger write path",
        version = "0.0.0",
        description = "Spike 021. The ADR-0013 write-path contract, generated by utoipa.",
    ),
    tags(
        (name = "transactions", description = "The write path."),
        (name = "accounts", description = "Reads."),
    ),
)]
struct ApiDoc;

fn router() -> OpenApiRouter {
    // `routes!` reads the path and method back out of `#[utoipa::path]` and builds
    // the axum route from them, so the route and the annotation cannot disagree.
    OpenApiRouter::with_openapi(ApiDoc::openapi())
        .routes(routes!(create_transaction))
        .routes(routes!(get_account_balance))
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("emit") => {
            let out = args.next().ok_or("usage: utoipa-api emit <path>")?;
            let (_, api) = router().split_for_parts();
            let mut json = api.to_pretty_json()?;
            json.push('\n');
            std::fs::write(&out, json)?;
            eprintln!("wrote {out}");
            Ok(())
        }
        Some("serve") => {
            let rt = tokio::runtime::Runtime::new()?;
            rt.block_on(async {
                let (app, _api) = router().split_for_parts();
                let l = tokio::net::TcpListener::bind("127.0.0.1:8021").await?;
                eprintln!("listening on http://127.0.0.1:8021");
                axum::serve(l, app).await?;
                Ok::<_, Box<dyn std::error::Error>>(())
            })
        }
        _ => Err("usage: utoipa-api emit <path> | serve".into()),
    }
}
