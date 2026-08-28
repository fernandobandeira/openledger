//! Spike 021 — the cost baseline. The same two handlers, the same types, the same
//! axum version, and no OpenAPI crate. `cargo tree` and a clean build here are
//! what the utoipa and aide numbers are measured against.

use axum::extract::Path;
use axum::http::{HeaderName, HeaderValue, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Serialize, Deserialize)]
pub struct Posting {
    pub source: String,
    pub destination: String,
    pub amount: i64,
    pub currency: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CreateTransactionRequest {
    pub idempotency_key: String,
    pub effective_at: DateTime<Utc>,
    pub postings: Vec<Posting>,
}

#[derive(Debug, Serialize)]
pub struct TransactionAccepted {
    pub event_id: Uuid,
    pub transaction_id: Option<Uuid>,
}

#[derive(Debug, Serialize)]
pub struct ProblemDetail {
    #[serde(rename = "type")]
    pub kind: String,
    pub detail: String,
}

#[derive(Debug, Serialize)]
pub struct AccountBalance {
    pub account_id: Uuid,
    pub currency: String,
    pub balance: i64,
}

#[derive(Debug)]
pub enum ApiError {
    PoisonedReplay(ProblemDetail),
    UnknownAccount(ProblemDetail),
}

impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        let (status, body) = match self {
            ApiError::PoisonedReplay(p) => (StatusCode::UNPROCESSABLE_ENTITY, p),
            ApiError::UnknownAccount(p) => (StatusCode::NOT_FOUND, p),
        };
        (status, Json(body)).into_response()
    }
}

const IDEMPOTENCY_REPLAYED: HeaderName = HeaderName::from_static("idempotency-replayed");

async fn create_transaction(
    Json(req): Json<CreateTransactionRequest>,
) -> Result<(StatusCode, [(HeaderName, HeaderValue); 1], Json<TransactionAccepted>), ApiError> {
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
            transaction_id: req.postings.first().map(|_| Uuid::nil()),
        }),
    ))
}

async fn get_account_balance(Path(id): Path<Uuid>) -> Result<Json<AccountBalance>, ApiError> {
    Ok(Json(AccountBalance { account_id: id, currency: "USD".into(), balance: 0 }))
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let rt = tokio::runtime::Runtime::new()?;
    rt.block_on(async {
        let app = Router::new()
            .route("/v1/transactions", post(create_transaction))
            .route("/v1/accounts/{id}/balance", get(get_account_balance));
        let l = tokio::net::TcpListener::bind("127.0.0.1:8020").await?;
        eprintln!("listening on http://127.0.0.1:8020");
        axum::serve(l, app).await?;
        Ok::<_, Box<dyn std::error::Error>>(())
    })
}
