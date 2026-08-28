//! Nothing lives here. This crate exists to hold the e2e suite (`tests/e2e`)
//! and to OWN its capability allowances: deny.toml's map grants sqlx,
//! reqwest and testcontainers to `e2e` — test instrumentation, scoped and
//! named — so that no shipping crate has to carry them to keep the suite
//! running. The suite spawns the compiled `openledger` binary by path; see
//! `tests/e2e/support/postgres.rs` for why the binary must be built first.
