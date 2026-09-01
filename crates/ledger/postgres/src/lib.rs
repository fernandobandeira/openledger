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
//! Two files, one rule each. `repository` is the write path: [`PgRepository`]
//! and its trait impl, implemented where the SQL lives — one statement per
//! method, and no forwarding layer between the trait and the statements.
//! `report_store` is the read path since ADR-0019: [`PgReportStore`] and its
//! [`ledger::ReportStore`] impl, one statement per method again, each inside
//! the `BEGIN … READ ONLY` / `SET LOCAL ROLE` / `set_config` bracket that
//! file owns — because those session statements are PostgreSQL's dialect
//! exactly as the reports' SQL is (ADR-0004), and because the tenant fence
//! they arm is not something a caller should be able to forget.

mod report_store;
mod repository;

pub use report_store::PgReportStore;
pub use repository::PgRepository;
