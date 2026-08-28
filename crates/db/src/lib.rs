//! How a process reaches PostgreSQL: the pool a serving process runs on, the
//! startup gate that refuses to serve an unmigrated database (`verify`), and
//! `migrate` — the pre-deploy job that puts the schema there first (ADR-0003).
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
mod verify;

pub use verify::verify_schema_is_current;

/// Small on purpose: every write serializes on its balance rows, so a large
/// pool buys queueing in the database instead of the process. Revisit with the
/// concurrency proof (M2), measured, not before.
const POOL_CONNECTIONS: u32 = 8;

/// Pool exhaustion should surface as a hard signal, not hide behind a long
/// wait: a caller that cannot get a connection in fifteen seconds is watching
/// an incident, and an error names it where a queue conceals it.
const ACQUIRE_TIMEOUT: Duration = Duration::from_secs(15);

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
/// 5s max, nowhere near any of these.
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

/// `println!` panics on a broken pipe, and this workspace denies `panic`. A
/// closed stdout after a committed migration must not turn a success into
/// exit 101.
pub(crate) fn say(message: &str) {
    let _ = writeln!(std::io::stdout(), "{message}");
}
