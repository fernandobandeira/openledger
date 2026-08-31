//! The Postgres adapter — its own crate, because deny.toml's capability map
//! forbids sqlx to the domain, and an in-crate module cannot be forbidden
//! anything. It nests under `crates/ledger/` as a workspace member with its
//! own manifest; the package name stays flat (`ledger-postgres`).
//!
//! What lives here is exactly the [`ledger::Repository`] implementation: the
//! SQL, and nothing that decides when to run it. The use-case — hash,
//! coalesce, number, claim-and-append-or-replay, commit — is the writer
//! service in the `ledger` crate, orchestrating over the repository port;
//! the pure computation before the statements is that crate's domain. The
//! one piece of ADR-0013's contract that is this crate's to honor is §1:
//! `begin` opens every transaction WITH `READ COMMITTED` rather than
//! inheriting it.
//!
//! `repository` is the whole of it: [`PgRepository`] and its trait impl,
//! implemented where the SQL lives — one statement per method, all of this
//! crate's SQL in that one file, and no forwarding layer between the trait
//! and the statements.

mod repository;

pub use repository::PgRepository;
