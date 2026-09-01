//! `/v1/accounts/*` — one file per verb. Four of them since ADR-0023:
//! `open` for the write that had no API at all before it (accounts were
//! seeded by SQL, which made `psql` a required part of onboarding), `list`
//! for the keyset-paginated register — the one listing ADR-0019's refusal was
//! withdrawn for — and `balance`, which reads the balance CACHE and therefore
//! means *posted, now*, pinned by nothing (ADR-0010). The journal-based answer
//! to that last question is the trial balance, next door under
//! `endpoints/reports/`. `entries` is the fourth: the account's STATEMENT —
//! its own legs, in order, on the axis the caller names (ADR-0023) — which is
//! the listing ADR-0019 refused and the axis parameter is why it can ship.

pub mod balance;
pub mod entries;
pub mod list;
pub mod open;
