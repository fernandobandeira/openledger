//! The core: the posting types, their validation, the canonical idempotency
//! hash, the pure posting math, the [`Ledger`] port, and the writer service
//! that stands behind it — and deliberately not one line of SQL.
//!
//! This crate and its Postgres writer used to be one crate, co-located under
//! ADR-0004's reasoning that PostgreSQL is half the product. The co-location
//! is superseded: deny.toml's bans ratchet is the hexagonal boundary made
//! machine-checked, and it only means something if the crate that holds the
//! domain can be FORBIDDEN sqlx outright — so the adapter lives in
//! `postgres/`, and this crate compiles with no database in the room. That
//! directory is a SEPARATE crate (`ledger-postgres`), a nested workspace
//! member with its own manifest and its own deny.toml allowance — never a
//! module of this one, because a module cannot be forbidden a dependency.
//! What ADR-0004 still decides is what the adapter looks like on the inside:
//! the SQL there is the product's reasoning about PostgreSQL, not an
//! interchangeable backend behind a storage-agnostic interface, and no such
//! interface is pretended here — both ports below are the ledger's contract,
//! not a generic store's.
//!
//! Inside the crate the layout is: `domain` is the pure core's types —
//! entities, value objects, their validation, the canonical hash and the
//! versioned payload rendering; `postings` is the posting math the writer
//! runs before its SQL does; `port` is the one trait a consumer sees;
//! `repository` is the outbound port the adapter implements; and `service`
//! is the writer — the claim-or-replay use-case, orchestrated over the
//! repository.

mod domain;
mod port;
mod postings;
mod repository;
mod service;

// Consumers write `ledger::Posting`; the module layout is this crate's own
// business. Of the posting math only the TYPES are exported — the adapter
// needs `Append` (and the `Leg`, `Delta`, `Direction` inside it) because the
// `Repository` port's signatures name them; the functions are `pub(crate)`,
// called by the writer service alone, so the math's order of operations
// cannot be re-orchestrated outside this crate.
pub use domain::{Invalid, PostTransaction, Posted, Posting, TransactionStatus};
pub use port::{Ledger, WriteError};
pub use postings::{Append, Delta, Direction, Leg};
pub use repository::{
    Appended, BalanceUpsert, BatchMember, Claimed, MemberOutcome, Repository, StorageError,
    StoredResult, SupersedeRefusal,
};
pub use service::LedgerService;
