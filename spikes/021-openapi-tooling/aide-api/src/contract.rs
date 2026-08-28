//! The same types as `utoipa-api/src/main.rs`, described for `schemars` instead
//! of for `utoipa`. Deliberately field-for-field identical so the two emitted
//! specs are comparable.

use chrono::{DateTime, Utc};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// One leg of a transaction. Amounts are in minor units and always positive;
/// direction is carried by `source` / `destination`, never by the sign.
#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct Posting {
    /// Account the value leaves.
    #[schemars(example = &"assets:cash:usd")]
    pub source: String,
    /// Account the value arrives at.
    #[schemars(example = &"liabilities:customer:9f3a")]
    pub destination: String,
    /// Minor units. Positive.
    #[schemars(range(min = 1), example = 250_00)]
    pub amount: i64,
    /// ISO-4217 alphabetic code.
    #[schemars(length(min = 3, max = 3), example = &"USD")]
    pub currency: String,
}

/// The body of `POST /v1/transactions`.
#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct CreateTransactionRequest {
    /// Caller-supplied replay key. Scoped to the tenant; never expires (ADR-0013 §2).
    #[schemars(length(min = 1), example = &"5f0a1e4c-1c0f-4b1e-8f9d-2b7a9f0e4c11")]
    pub idempotency_key: String,
    /// When the movement is deemed to have happened, RFC 3339.
    pub effective_at: DateTime<Utc>,
    /// At least one posting.
    #[schemars(length(min = 1))]
    pub postings: Vec<Posting>,
}

/// The stored result of an accepted write: the event, and the transaction it caused.
#[derive(Debug, Serialize, JsonSchema)]
pub struct TransactionAccepted {
    /// The `ledger_events` row this call claimed or replayed.
    pub event_id: Uuid,
    /// The transaction the event caused. **`null` for the majority of accepted
    /// operations, which write no transaction at all** (ADR-0013 §2).
    pub transaction_id: Option<Uuid>,
}

/// A problem document. `type` is a stable machine-readable identifier.
#[derive(Debug, Serialize, JsonSchema)]
pub struct ProblemDetail {
    /// Stable error identifier, e.g. `idempotency_key_reused_with_different_body`.
    #[serde(rename = "type")]
    #[schemars(example = &"idempotency_key_reused_with_different_body")]
    pub kind: String,
    /// Human-readable explanation. Not stable; do not parse.
    pub detail: String,
}

/// The current balance of one account, summed over its stripes.
#[derive(Debug, Serialize, JsonSchema)]
pub struct AccountBalance {
    pub account_id: Uuid,
    pub currency: String,
    /// Minor units. May be negative.
    pub balance: i64,
}

/// `aide` derives path parameters from an *object* schema, so the path segment
/// has to be a named struct field; `Path<Uuid>` alone carries no name.
#[derive(Debug, Deserialize, JsonSchema)]
pub struct AccountPath {
    /// Account id.
    pub id: Uuid,
}
