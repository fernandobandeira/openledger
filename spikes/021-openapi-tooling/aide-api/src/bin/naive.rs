//! Spike 021 — what `aide` emits when the handlers are written the ordinary axum
//! way rather than aide's way. Nothing here is wrong Rust and nothing here fails
//! to compile; the routes serve correctly. The spec is what suffers.
//!
//! Two failure modes, both silent at compile time:
//!
//!   1. `-> (StatusCode, [(HeaderName, HeaderValue); 1], Json<T>)` — aide's
//!      `OperationOutput` impl for tuples is empty, so the 201, the body schema
//!      and the header all vanish from the spec.
//!   2. `Path<Uuid>` — aide builds path parameters out of an *object* schema's
//!      properties, so a bare scalar produces no parameter at all.
//!
//!   `cargo run --bin aide-naive -- emit <path>`

#[path = "../contract.rs"]
mod contract;

use aide::axum::routing::{get, post};
use aide::axum::ApiRouter;
use aide::openapi::OpenApi;
use axum::extract::Path;
use axum::http::{HeaderName, HeaderValue, StatusCode};
use axum::Json;
use uuid::Uuid;

use contract::{AccountBalance, CreateTransactionRequest, TransactionAccepted};

const IDEMPOTENCY_REPLAYED: HeaderName = HeaderName::from_static("idempotency-replayed");

async fn create_transaction(
    Json(req): Json<CreateTransactionRequest>,
) -> (StatusCode, [(HeaderName, HeaderValue); 1], Json<TransactionAccepted>) {
    (
        StatusCode::CREATED,
        [(IDEMPOTENCY_REPLAYED, HeaderValue::from_static("false"))],
        Json(TransactionAccepted {
            event_id: Uuid::nil(),
            transaction_id: req.postings.first().map(|_| Uuid::nil()),
        }),
    )
}

async fn get_account_balance(Path(id): Path<Uuid>) -> Json<AccountBalance> {
    Json(AccountBalance { account_id: id, currency: "USD".into(), balance: 0 })
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let Some("emit") = args.next().as_deref() else {
        return Err("usage: aide-naive emit <path>".into());
    };
    let out = args.next().ok_or("usage: aide-naive emit <path>")?;

    // Without this handler aide drops the diagnostics on the floor and the only
    // symptom is a thin spec. WITH it, the errors below are printed to stderr --
    // but nothing in a normal `cargo build`/`cargo test` run fails.
    aide::generate::on_error(|e| eprintln!("aide error: {e}"));
    aide::generate::extract_schemas(true);

    let mut api = OpenApi::default();
    let _router: axum::Router = ApiRouter::new()
        .api_route("/v1/transactions", post(create_transaction))
        .api_route("/v1/accounts/{id}/balance", get(get_account_balance))
        .finish_api(&mut api);

    let mut json = serde_json::to_string_pretty(&api)?;
    json.push('\n');
    std::fs::write(&out, json)?;
    eprintln!("wrote {out}");
    Ok(())
}
