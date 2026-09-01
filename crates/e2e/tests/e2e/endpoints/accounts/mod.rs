//! `/v1/accounts/*` — one file per verb. `balance` is the only read this
//! resource has: *posted, now*, pinned by nothing, because it reads the
//! balance CACHE and the cache means posted (ADR-0010). The journal-based
//! answer to the same question is the trial balance, next door under
//! `endpoints/reports/`.

pub mod balance;
