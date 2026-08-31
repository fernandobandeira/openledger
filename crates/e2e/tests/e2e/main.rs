//! End to end: the compiled binary, spawned as a process and spoken to over
//! HTTP, against a real PostgreSQL — migrated by `openledger migrate` and
//! seeded with the published chart, exactly as an adopter would run it. The
//! oracle is `SELECT * FROM reconciliation`: ten checks, ten zeros, asserted
//! at the end of every test.
//!
//! One test binary, so the suite shares one PostgreSQL. The admin URL is
//! DATABASE_URL when set (CI's schema job, `make test`), else one
//! `postgres:18-alpine` testcontainer for the whole binary (`support::postgres`).
//!
//! **The layout rule:** `support/` holds helpers and contains no `#[test]`;
//! `endpoints/` holds one file per (resource, verb) — split only when one
//! verb's contract outgrows a single read (transactions POST holds `post`
//! for posting-and-idempotency and `pending` for pending → posted,
//! ADR-0016); suite-wide checks live at the top level.
//! Today those are `conformance` (whether the committed OpenAPI document and
//! the running router still describe the same surface), `startup` (whether
//! `serve` refuses a database its migrate job never reached, is behind, or
//! mismatches), `exit_codes` (the binary's 2-and-3 half of the exit-code
//! contract), `roles` (the writer as a policy-admitted role, and the
//! reader's RLS scoping), `reconcile` (the sweep subcommand: clean and
//! pending controls to exit 0, a red-path injection for EVERY one of the
//! summary's ten checks — spike 013's drift classes and the four checks
//! that joined after the spike — each named on stderr at exit 1, the
//! command's contract edges, and the sweep racing live writers), and
//! `schema_snapshot` (ADR-0007 §2: the migrated catalog, dumped as
//! deterministic text and diffed against the committed `schema/snapshot.txt`).

mod conformance;
mod endpoints;
mod exit_codes;
mod reconcile;
mod roles;
mod schema_snapshot;
mod startup;
mod support;
