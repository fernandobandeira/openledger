//! `/v1/transactions` — one file per verb; POST is the only verb today, in
//! two files so each reads whole: `post` is the posting-and-idempotency
//! contract, `pending` the pending → posted half (ADR-0016).

pub mod pending;
pub mod post;
