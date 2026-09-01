//! One file per (resource, verb), split only when one verb's contract
//! outgrows a single read: a test file here is one half of an endpoint's
//! contract at most — see the layout rule in main.rs.

pub mod accounts;
pub mod reports;
pub mod transactions;
