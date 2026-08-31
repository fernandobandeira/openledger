//! `/v1/transactions` — one file per verb, split when one verb's contract
//! outgrows a single read: `post` is the posting-and-idempotency contract,
//! `pending` the pending → posted half, and `reverse` the reversal-and-void
//! half (ADR-0016).

pub mod pending;
pub mod post;
pub mod reverse;
