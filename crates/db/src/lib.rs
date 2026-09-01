//! How a process reaches PostgreSQL: the TWO pools a serving process runs on,
//! the startup gate that refuses to serve an unmigrated database (`verify`),
//! `migrate` — the pre-deploy job that puts the schema there first (ADR-0003)
//! — and `reconcile`, the scheduled sweep that turns the ten reconciliation
//! checks into an exit code (ADR-0010).
//! The migration files themselves stay at the repository root; they are
//! adopter-facing, and this crate only compiles them in.
//!
//! **Two pools since ADR-0019, and they are not two sizes of the same thing.**
//! [`Database`] is the writer's — one connection per dispatcher, timeouts sized
//! for three-round-trip appends. [`ReadDatabase`] is the read path's, on its
//! own login, whose only role membership should be `openledger_read`: RLS
//! policies are permissive and OR'd, so a login that can also WRITE matches the
//! writer's `USING (true)` and reads every tenant, with every policy in the
//! schema exactly as written. That is why the split is a credential boundary
//! rather than a capacity decision — and why the two pools' sizes are not
//! coupled to each other.
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
/// startup schema gate from waiting behind a pool of writers that is full by
/// design.
///
/// **The "and any future reader" clause this comment used to carry is
/// withdrawn** (ADR-0019 A6). That reader has arrived — it is
/// [`ReadDatabase`] — and six is not the number for it: a report holds its
/// connection for 4–11 s on a million-entry book, so six concurrent reports
/// exhaust the headroom and the seventh loses its 15 s acquire against 32
/// dispatchers that are full by design. But capacity is not the deciding
/// argument; the login is. A reader on the WRITER's login reads every tenant,
/// because RLS policies are permissive and OR'd and the writer's `USING
/// (true)` unions with the reader's tenant qual. So the read path takes a
/// pool of its own, neither of these two numbers moves, and the `const`
/// assertion in `crates/openledger/src/batching.rs` that couples them stays
/// true untouched.
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

/// How many reports may be in flight at once. **A concurrency limit on
/// reports, not a throughput knob**: a report holds its connection for the
/// whole of its transaction — 4–11 s on a million-entry book (ADR-0019) — so
/// a deeper pool does not make reports faster, it makes more of them wait in
/// the database instead of in this process, and the process is where a wait
/// is visible.
///
/// Eight, and the number is chosen rather than measured: it is enough that a
/// handful of concurrent reports do not queue behind each other, and small
/// enough that a book slow enough to hold connections for ten seconds cannot
/// open forty backends by being asked forty questions. The ninth concurrent
/// report waits, and loses its acquire at [`ACQUIRE_TIMEOUT`] — which is the
/// hard signal that number exists to give.
///
/// It is deliberately NOT coupled to [`POOL_CONNECTIONS`]: the two pools run
/// on different logins by design, and nothing in the read path can take a
/// writer's connection.
pub const READ_POOL_CONNECTIONS: u32 = 8;

/// The read pool's session settings — the writer's [`SESSION_TIMEOUTS`] with
/// two numbers changed and one kept, plus the role.
///
/// **`statement_timeout` is 90 s against the writer's 30 s** (ADR-0019 A7).
/// The writer's statements are single-millisecond appends and 30 s is a
/// generous outer bound; a report's are seconds and 30 s is a live limit —
/// `balance_sheet_at` measured 11.4 s at a million entries. **And this buys
/// less than one order of magnitude**, which is worth stating rather than
/// hoping: 90 s is reached at ~8 M entries instead of ~2.5 M. The real fix is
/// the period checkpoint (ADR-0020), not this constant.
///
/// **`idle_in_transaction_session_timeout` is 120 s against the writer's
/// 60 s**, for the same reason one step down: 60 s is sized for a transaction
/// that is three round trips, and a read transaction is legitimately
/// longer-lived. It still matters — an idle read transaction holds `xmin`,
/// and holding `xmin` holds every later report's cursor (ADR-0019's cost
/// list).
///
/// **`lock_timeout` stays 10 s**, unchanged and not because nobody looked: a
/// read takes `ACCESS SHARE` and blocks only behind DDL, where waiting ten
/// seconds for a migration to finish is exactly the right behaviour.
///
/// **`SET ROLE openledger_read` comes last** so the three timeouts are set as
/// the login, which is guaranteed to be allowed to set them. The role is what
/// makes the tenant fence structural rather than remembered — RLS applies to
/// `current_user`, so a connection that has not assumed the read role is
/// fenced by nothing. It is not sufficient alone (`RESET ROLE` climbs back
/// out of it), which is why every read transaction issues `SET LOCAL ROLE`
/// again; and it is not free of assumptions either — the login behind
/// `READ_DATABASE_URL` must be a member of `openledger_read`, or the pool's
/// first connection fails here with the backend's own message.
const READ_SESSION_SETTINGS: &str = "\
    SET statement_timeout = '90s'; \
    SET lock_timeout = '10s'; \
    SET idle_in_transaction_session_timeout = '120s'; \
    SET ROLE openledger_read";

/// The pool the READ path runs on — a second newtype, because ADR-0019 makes
/// the read path a second pool on a second login and ADR-0015 puts pool
/// hardening in this crate rather than in the caller's.
///
/// Everything that differs from [`Database`] is above: the depth, the two
/// timeouts, and the role. What is the same is the shape — lazy, sqlx-free
/// on the outside except for the one accessor the composition root feeds to
/// `PgReportStore`, and `min_connections` at zero under the same
/// [`IDLE_TIMEOUT`], so a process that is answering no reports holds no read
/// backends at all.
pub struct ReadDatabase {
    pool: PgPool,
}

impl ReadDatabase {
    /// Synchronous and LAZY, exactly as [`Database::connect_lazy`] is: this
    /// parses the URL and configures the pool and opens no connection. That
    /// matters more here than it does for the writer, because a deployment
    /// that has not yet created the read login should fail on its first READ
    /// with the backend's message, not refuse to start.
    pub fn connect_lazy(database_url: &str) -> Result<Self, sqlx::Error> {
        let options: PgConnectOptions = database_url.parse()?;
        let pool = PgPoolOptions::new()
            .max_connections(READ_POOL_CONNECTIONS)
            .min_connections(MIN_CONNECTIONS)
            .idle_timeout(IDLE_TIMEOUT)
            .acquire_timeout(ACQUIRE_TIMEOUT)
            .after_connect(|conn, _meta| {
                Box::pin(async move {
                    sqlx::raw_sql(READ_SESSION_SETTINGS).execute(conn).await?;
                    Ok(())
                })
            })
            .connect_lazy_with(options);
        Ok(Self { pool })
    }

    /// The pool itself, for the one place that wires the Postgres reader.
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
