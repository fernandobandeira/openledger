//! `/v1/periods/*` — one file per verb (ADR-0024). `define` is the write that
//! looks exactly like opening an account: a caller's idempotency key, the
//! replay contract inherited whole, and two refusals only the database can
//! make. `close` is the one that looks like nothing else on this surface — a
//! DERIVED key, no replay, and four writes in one transaction whose order is
//! the decision.
//!
//! These are the first tests in this suite to close a period through the front
//! door. The fixture next door (`support::close_the_period`) stays, and it is
//! not a duplicate: it writes closes in SQL because `reconcile.rs` needs
//! FORGED ones — a cursor below its own transaction, a missing close row, a
//! missing checkpoint — and an endpoint that would produce those is an
//! endpoint with a defect.

pub mod close;
pub mod define;
