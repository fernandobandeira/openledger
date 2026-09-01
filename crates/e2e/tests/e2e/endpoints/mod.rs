//! One file per (resource, verb), split only when one verb's contract
//! outgrows a single read: a test file here is one half of an endpoint's
//! contract at most — see the layout rule in main.rs.
//!
//! `cursor` is a file rather than a directory because `/v1/cursor` has one
//! verb and one scalar: it is a resource of its own — not `/v1/reports/*`,
//! pinned by nothing, naming no range, no instant and no chart version — and
//! it is where ADR-0019's refusal of a cursor-minting endpoint is held as
//! qualified rather than overturned.

pub mod accounts;
pub mod cursor;
pub mod periods;
pub mod reports;
pub mod transactions;
