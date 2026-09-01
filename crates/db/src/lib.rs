//! How a process reaches PostgreSQL: the pool a serving process runs on, the
//! startup gate that refuses to serve an unmigrated database (`verify`),
//! `migrate` — the pre-deploy job that puts the schema there first (ADR-0003)
//! — and `reconcile`, the scheduled sweep that turns the ten reconciliation
//! checks into an exit code (ADR-0010).
//! The migration files themselves stay at the repository root; they are
//! adopter-facing, and this crate only compiles them in.
//!
//! `PgPool` is deliberately NOT re-exported: sqlx is PostgreSQL's dialect,
//! and deny.toml's bans ratchet lists the crates allowed to speak it. A
//! re-export here would hand every consumer of this crate that dialect back
//! and make the ratchet decorative.

use std::io::Write;
use std::time::Duration;

use sqlx::PgPool;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};

pub mod migrate;
pub mod reconcile;
mod verify;

pub use verify::verify_schema_is_current;

/// One per dispatcher in the writer pool, plus six. It was 8 — "small on
/// purpose: every write serializes on its balance rows, so a large pool buys
/// queueing in the database instead of the process", to be revisited "with
/// the concurrency proof, measured, not before". It has now been measured
/// (ADR-0018, 302 configurations): the balance row a write serializes on is
/// STRIPED, and which stripe it takes is which writer wrote it — 32 writers
/// clear 4.31× one writer's rate, 8 writers only 3.42×.
///
/// So this number is not independently choosable any more. A dispatcher
/// without a connection cannot write: it would form its batch, then block in
/// `begin` while the members it was going to coalesce keep arriving. **This
/// and `batching::DISPATCHERS` are one knob and move together** — the spike's
/// own harness sized its pool as writers + 6, and the six are the headroom
/// that keeps the startup schema gate (and any future reader) from waiting
/// behind a full pool of writers.
///
/// **Public because "they move together" was prose until it became a `const`
/// assertion.** `batching` owns the pool depth this number is sized for and
/// asserts against this one at compile time, so setting the two apart fails
/// the build rather than the deployment. Nothing else reads it.
pub const POOL_CONNECTIONS: u32 = 38;

/// The headroom above the dispatcher pool, and the reason this crate can
/// state the coupling as an assertion rather than a sentence: every
/// dispatcher needs a connection of its own, and these six are what keep the
/// startup schema gate — and any future reader — from waiting behind a pool
/// of writers that is full by design.
pub const CONNECTIONS_ABOVE_THE_WRITERS: u32 = 6;

/// Pool exhaustion should surface as a hard signal, not hide behind a long
/// wait: a caller that cannot get a connection in fifteen seconds is watching
/// an incident, and an error names it where a queue conceals it.
const ACQUIRE_TIMEOUT: Duration = Duration::from_secs(15);

/// How long an unused connection stays open. **Without this, sqlx's default
/// is ten minutes and a pool does not shrink in any interval that matters**:
/// a process's connection footprint becomes its PEAK concurrency rather than
/// its current demand, and stays there.
///
/// Measured on this workspace, one serving process, a burst of 40 concurrent
/// posts and then nothing: at sqlx's default the process still held **10
/// backends open 37 seconds later**, and would have held them for ten
/// minutes. With this set to five seconds it holds **zero within twelve** —
/// the reaper runs on its own interval, so reclamation lands a little after
/// the timeout rather than on it.
///
/// **What this does NOT fix, stated because it was measured and expected to:**
/// a `make test` run's peak backend count does not move: four 16-thread runs
/// peaked at **225 / 227** at sqlx's default and **187 / 225** with this set —
/// one range, 187–227, and the spread is run-to-run noise on the same machine
/// rather than an effect of this constant. That 187–227 is the number
/// `docker-compose.yml` and the e2e fallback container are both sized against.
/// The suite kills each test's serving process when its test
/// ends, so no pool there lives long enough to hold anything idle; its peak
/// is genuine simultaneous demand across parallel tests, and docker-compose's
/// `max_connections=400` is what covers that. This constant is for the
/// DEPLOYED process, which lives for weeks.
///
/// Five seconds, with [`MIN_CONNECTIONS`] at zero underneath it: a dispatcher
/// under load takes its next turn in milliseconds, so a working pool never
/// reaps a connection it is about to want; a pool that stops working gives
/// everything back promptly. Reconnecting costs one TCP handshake plus
/// [`SESSION_TIMEOUTS`], paid by a process that had nothing to do.
const IDLE_TIMEOUT: Duration = Duration::from_secs(5);

/// No connection is held just for being early. This is sqlx's default made
/// explicit and stated beside [`IDLE_TIMEOUT`], which is the constant that
/// does the work: a floor above zero would keep exactly what the timeout is
/// there to give back, so the two have to be read together or not at all.
const MIN_CONNECTIONS: u32 = 0;

/// Session timeouts, set on every connection the pool opens. For a ledger
/// these turn a stuck transaction into a bounded error instead of an outage:
/// a query pinned behind a lock dies at `statement_timeout`, a lock wait dies
/// at `lock_timeout`, and a connection that went idle mid-transaction — the
/// one that silently holds `xmin` and every row lock it took — is killed at
/// `idle_in_transaction_session_timeout`.
///
/// Scope, checked when these numbers were chosen: `migrate` does NOT run on
/// this pool — it opens its own `PgConnection` (migrate.rs) with its own 5s
/// `lock_timeout`, so a future long `CREATE INDEX` is not killed by the 30s
/// here. The e2e suite's bounded reconciliation wait polls 25ms SELECTs for
/// 15s max, each nowhere near any of these.
const SESSION_TIMEOUTS: &str = "\
    SET statement_timeout = '30s'; \
    SET lock_timeout = '10s'; \
    SET idle_in_transaction_session_timeout = '60s'";

/// The pool a serving process runs on, behind a newtype so that this crate's
/// public surface stays sqlx-free except for the one accessor the composition
/// root feeds to the Postgres writer (which lives in crates/ledger and
/// declares sqlx itself — see deny.toml's wrapper list).
pub struct Database {
    pool: PgPool,
}

impl Database {
    /// Synchronous and LAZY: this parses the URL and configures the pool, but
    /// opens no connection — the first acquire does. A serving process
    /// therefore no longer fails at pool construction on an unreachable
    /// database; its startup failure point is [`verify_schema_is_current`],
    /// which fails with a message an operator can act on.
    ///
    /// Sizing is this crate's decision (the constants above), not the
    /// caller's — the numbers are coupled to how the writer serializes and to
    /// what a stuck session may hold, not to anything the composition root
    /// knows.
    pub fn connect_lazy(database_url: &str) -> Result<Self, sqlx::Error> {
        let options: PgConnectOptions = database_url.parse()?;
        let pool = PgPoolOptions::new()
            .max_connections(POOL_CONNECTIONS)
            .min_connections(MIN_CONNECTIONS)
            .idle_timeout(IDLE_TIMEOUT)
            .acquire_timeout(ACQUIRE_TIMEOUT)
            .after_connect(|conn, _meta| {
                Box::pin(async move {
                    sqlx::raw_sql(SESSION_TIMEOUTS).execute(conn).await?;
                    Ok(())
                })
            })
            .connect_lazy_with(options);
        Ok(Self { pool })
    }

    /// The pool itself, for the one place that wires the Postgres writer.
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }
}

/// What went wrong, split the way the binary's exit codes need it: `Usage` is
/// exit 2 (retrying changes nothing), `Locked` is exit 3 (safe to re-run),
/// `Failed` is exit 1 (read the error first). The codes themselves are the
/// binary's contract; this enum only preserves the distinction for it.
pub enum MigrateError {
    /// The invocation is wrong. Retrying changes nothing.
    Usage(String),
    /// Someone else held the lock for the whole budget. Safe to re-run.
    Locked(String),
    /// The migration or the connection failed. Read the error first.
    Failed(String),
}

/// What the sweep can report, split the way the binary's exit codes need it:
/// `Usage` is exit 2, and both `Failed` and `Drift` are exit 1 — "read the
/// error first" is exactly what a drifted book demands, and ADR-0010 assigns
/// no code of its own, so the sweep stays inside the contract `Failure`
/// already prints under `--help`. `Drift` is still its own variant because
/// it is not a malfunction: the command worked, and the book is wrong.
pub enum ReconcileError {
    /// The invocation is wrong. Retrying changes nothing.
    Usage(String),
    /// The sweep could not run or could not be trusted. Read the error first.
    Failed(String),
    /// The sweep ran and found breaks — the checks are named in the message.
    Drift(String),
}

/// `println!` panics on a broken pipe, and this workspace denies `panic`. A
/// closed stdout after a committed migration must not turn a success into
/// exit 101.
pub(crate) fn say(message: &str) {
    let _ = writeln!(std::io::stdout(), "{message}");
}
