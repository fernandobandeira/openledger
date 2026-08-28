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
//! `endpoints/` holds one file per (resource, verb) — a file there is that
//! endpoint's contract, whole; suite-wide checks live at the top level.
//! Today those are `conformance` (whether the committed OpenAPI document and
//! the running router still describe the same surface), `startup` (whether
//! `serve` refuses a database its migrate job never reached, is behind, or
//! mismatches), `exit_codes` (the binary's 2-and-3 half of the exit-code
//! contract), and `roles` (the writer as a policy-admitted role, and the
//! reader's RLS scoping).

mod conformance;
mod endpoints;
mod exit_codes;
mod roles;
mod startup;
mod support;
