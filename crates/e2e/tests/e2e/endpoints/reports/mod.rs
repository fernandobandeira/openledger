//! `/v1/reports/*` — the three report routes, GET, split the way the
//! transactions directory next door is: one file per half of the contract
//! that reads whole on its own.
//!
//! `reproducibility` is M5's first acceptance criterion (an as-of query at
//! instant T answers the same thing when re-run under concurrent writes) and
//! the control that makes it mean something; `backdating` is the second
//! (insertion order ≠ effective order, on both of ADR-0006's axes);
//! `refusals` is every value ADR-0019 says the read path must refuse before it
//! reaches SQL, one test per refusal, because a `type` crossed with another
//! hands the caller the wrong instruction; `tenant_fence` is the
//! `SET LOCAL ROLE` that keeps one tenant's report free of another's money,
//! held on both credentials a deployment can be wearing; and `checkpoint` is
//! the regression guard on migration `00004`'s reader — the face over HTTP
//! against the same position scanned from inception.
//!
//! **What is deliberately not here.** The account balance is
//! `endpoints/accounts/balance.rs` and the transaction read-back is
//! `endpoints/transactions/read_back.rs`: neither is a report, neither is
//! pinned by anything, and the layout rule keeps a file with its resource.

pub mod backdating;
pub mod checkpoint;
pub mod refusals;
pub mod reproducibility;
pub mod tenant_fence;
