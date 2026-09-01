//! Spike 022's harness: one configuration per process, one measurement at a
//! time. RUN.sh is what makes the sequence sequential — spike 003's recorded
//! methodology error was two harnesses on one database, and nothing here
//! overlaps two runs by itself.
//!
//! Every run: a fresh scratch database, the real migrations applied by the
//! compiled `openledger migrate`, `schema/chart.sql`, the accounts, the
//! workload, and then the oracle. `SELECT check_name, breaks FROM
//! reconciliation` must come back ten checks at zero breaks; the verdict
//! rides the result line, and a configuration that does not reconcile says
//! so in that line rather than being silently averaged in.
//!
//! TWO LOAD SHAPES, and the difference between them is the whole reason a
//! second one exists. CLOSED loop (`--concurrency N`) holds N requests
//! outstanding and starts the next one only when the last completes: it
//! measures a CEILING, and its batches are always full because the offered
//! load is whatever the system will take. OPEN loop (`--offered-rate N`)
//! drives arrivals at a fixed mean rate that does not care whether anything
//! completed, so a window can expire half-empty — which is what ADR-0002's
//! own 20-50 TPS peak would do to a 25-member window every single time. A
//! saturated batcher's ceiling is not the value of batching at the load the
//! ADR is sizing for, and the two numbers are labelled `"loop"` so they can
//! never be averaged together.

// The repo's clippy.toml disallows `Instant::now`: a LEDGER's time is the
// database's (`recorded_at`) or the caller's (`effective_at`), ADR-0006, and
// nothing in the product may invent a third clock. A benchmark harness is
// where that rule does not apply — none of these instants is ever written to
// a ledger column; they measure elapsed wall time and a batch window, which
// is exactly the scheduling-duration-not-timestamp distinction
// DESIGN-QUESTIONS.md §2 draws. Allowed here, in throwaway spike code, and
// nowhere in crates/.
#![allow(clippy::disallowed_methods, clippy::too_many_arguments)]

mod setup;
mod sql;

use std::collections::{BTreeMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use clap::Parser;
use sha2::{Digest, Sha256};
use sqlx::{AssertSqlSafe, PgPool, Postgres, Transaction};
use uuid::Uuid;

use setup::{Fallible, TenantAccounts};
use sql::{BalanceOrder, Mode, Placement, Shape};

/// One instant, chosen once, bound as `effective_at` by every member and
/// covered by every idempotency hash. The shipped writer's `effective_at` is
/// the CALLER's, so binding a real one is not decoration: an omitted
/// `effective_at` hashes as zero bytes under domain.rs's length prefix and
/// would silently exercise a different canonical form from the one the API
/// actually sends.
const EFFECTIVE_AT: &str = "2026-08-31T00:00:00Z";

// ---------------------------------------------------------------- arguments

#[derive(Clone, Copy, PartialEq, Eq, Debug, clap::ValueEnum)]
enum Experiment {
    Throughput,
    Poison,
    Headofline,
    Deadlock,
}

impl Experiment {
    fn as_str(self) -> &'static str {
        match self {
            Experiment::Throughput => "throughput",
            Experiment::Poison => "poison",
            Experiment::Headofline => "headofline",
            Experiment::Deadlock => "deadlock",
        }
    }
}

/// WHEN A PARTLY-FILLED BATCH IS DISPATCHED. Two policies, and the second is
/// the one the peer survey says should have been the default all along.
///
/// `window` is a fixed timer: the batch waits `--window-ms` for more members
/// whether or not anybody else is coming. It is a LATENCY TAX PAID
/// UNCONDITIONALLY, and at ADR-0002's derived 20-50 TPS against a 25-member
/// window it buys a true fill of about 2 — every request pays the whole
/// window to be batched with nobody.
///
/// `on-completion` never waits on a timer at all. It is Nagle's rule, and it
/// is what TigerBeetle states as its own model (tigerbeetle#489: "maintain at
/// least one request in flight", no timer) and what PostgreSQL's
/// `commit_delay = 0` default says by refusing to spend one: take whatever is
/// queued RIGHT NOW, dispatch it, and take whatever accumulated while that
/// statement ran. `--batch` stops being a target and becomes a pure safety
/// ceiling. At low offered load the batch is one member and the latency is
/// the single-writer path's; at saturation the queue forms the batches by
/// itself, because that is the only time there is anything to form them from.
///
/// THE MECHANISM IS BACKPRESSURE, NOT A ZERO TIMER. `--window-ms 0` already
/// never sleeps — the deadline has passed by the time it is first tested — but
/// it does not give this, because the accumulator hands batches to an
/// UNBOUNDED channel. With no writer free the accumulator still drains the
/// queue as fast as arrivals land, so the backlog moves into the channel as a
/// long line of one-member batches and the queue it would have coalesced from
/// is always empty. Under `on-completion` the accumulator must hold one of
/// `writers` permits before it may form a batch, and the permit is released
/// only when the statement has committed and its members have been answered.
/// That is what makes the queue — and therefore the batch — form at all.
#[derive(Clone, Copy, PartialEq, Eq, Debug, clap::ValueEnum)]
enum Dispatch {
    Window,
    OnCompletion,
}

impl Dispatch {
    fn as_str(self) -> &'static str {
        match self {
            Dispatch::Window => "window",
            Dispatch::OnCompletion => "on-completion",
        }
    }
}

/// WHAT MAKES TWO WRITERS DISAGREE ABOUT LOCK ORDER. Three mechanisms, and
/// they are three because they are not the same hazard and must never be
/// reported as one.
#[derive(Clone, Copy, PartialEq, Eq, Debug, clap::ValueEnum)]
enum LockOrderHazard {
    /// Nothing injected. Every writer takes the rows the same way.
    None,
    /// THE REAL M2 HAZARD, and it lives on the SINGLE path only: half the
    /// writers present their legs in reverse account order, so their bound
    /// delta arrays — which are the statement's insert order when the
    /// `ORDER BY` is gone — disagree. This is a caller doing something a
    /// caller can actually do.
    CallerLegs,
    /// THE REAL BATCHED-PATH HAZARD, and it needs nothing injected at all:
    /// concurrent batches coalesce down to DIFFERENT ACCOUNT SUBSETS,
    /// because which per-company receivables a batch happens to collect
    /// varies. Two batches whose subsets overlap partially can take the
    /// shared rows in different relative orders with no caller involvement
    /// and no model. This is the mechanism that produced the original eight
    /// deadlocks — arrived at honestly, and misattributed at the time to
    /// reversed presentation.
    AccountSubsets,
    /// A MODEL, and labelled as one in the result line. Half the writers run
    /// a statement whose balance insert carries an explicit DESC. It forces
    /// the maximal adversity that `AccountSubsets` only sometimes produces,
    /// and it is a supplementary stress case — never the headline, because
    /// no caller can cause it.
    DescendingModel,
}

impl LockOrderHazard {
    fn as_str(self) -> &'static str {
        match self {
            LockOrderHazard::None => "none",
            LockOrderHazard::CallerLegs => "caller-legs",
            LockOrderHazard::AccountSubsets => "account-subsets",
            LockOrderHazard::DescendingModel => "descending-model",
        }
    }

    /// Whether this hazard is something a caller can cause, or something the
    /// harness manufactured. The distinction rides in the result line so a
    /// reader cannot mistake the second for the first.
    fn is_a_model(self) -> bool {
        self == LockOrderHazard::DescendingModel
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, clap::ValueEnum)]
enum PathChoice {
    /// The single-member statement at B = 1, the batched one above it.
    Auto,
    /// The single-member statement, always — refuses B > 1.
    Single,
    /// The batched statement, always, B = 1 included. This is how the
    /// window-function walk-back is measured against the Rust-computed
    /// offsets at B = 1 (SPEC.md §Batching), and how the two `--select`
    /// placements are checked to agree where they must.
    Batched,
}

impl PathChoice {
    fn as_str(self, batch: usize) -> &'static str {
        match self {
            PathChoice::Auto if batch > 1 => "batched",
            PathChoice::Auto => "single",
            PathChoice::Single => "single",
            PathChoice::Batched => "batched",
        }
    }
}

#[derive(Parser, Clone)]
#[command(about = "spike 022 — batching and stripe selection, on the shipped schema")]
struct Args {
    #[arg(long, value_enum, default_value = "throughput")]
    experiment: Experiment,
    #[arg(long, value_enum, default_value = "none")]
    mode: Mode,
    /// Where the stripe is chosen relative to the cross-member coalesce.
    /// Identical by construction at B = 1.
    #[arg(long, value_enum, default_value = "per-batch")]
    select: Placement,
    #[arg(long, default_value_t = 1)]
    stripes: i16,
    #[arg(long, default_value_t = 1)]
    batch: usize,
    /// CLOSED-LOOP offered load: requests held outstanding, one per producer.
    /// This is NOT database concurrency — see `--writers`.
    #[arg(long, default_value_t = 8)]
    concurrency: usize,
    /// OPEN-LOOP offered load: mean arrivals per second, independent of
    /// completions. Mutually exclusive with the closed loop's saturation.
    #[arg(long)]
    offered_rate: Option<f64>,
    #[arg(long, default_value = "3s")]
    duration: String,
    /// Load driven and then DISCARDED before the clock starts: a cold pool,
    /// unprepared statements and an empty book are all one-off costs, and
    /// charging them to the measurement makes a short run look slower than
    /// the system is.
    #[arg(long, default_value = "3s")]
    warmup: String,
    #[arg(long, default_value_t = 8)]
    companies: usize,
    #[arg(long, default_value_t = 1)]
    tenants: usize,
    /// Fraction of the offered load that goes to tenant t0 (section C).
    #[arg(long, default_value_t = 0.0)]
    whale: f64,
    /// Remove the ORDER BY from the balance CTE (section E).
    #[arg(long)]
    no_order_by: bool,
    /// What makes two concurrent writers disagree about lock order
    /// (section E). See `LockOrderHazard` — the three are not one hazard.
    #[arg(long, value_enum, default_value = "none")]
    lock_order_hazard: LockOrderHazard,
    /// Post reversals of what was just posted, on the SINGLE path. The
    /// mirror CTE's `GROUP BY` is half of M2's deliverable and nothing else
    /// in this harness reaches it.
    #[arg(long)]
    reversals: bool,
    /// Restrict a batch to members of a single tenant. Off by default:
    /// batches may span tenants, which is the simplest implementation and
    /// the one the fill-rate number is measured against.
    #[arg(long)]
    tenant_homogeneous: bool,
    /// How long a partly-filled batch waits for more members before it is
    /// dispatched. Inert under `--dispatch on-completion`, which never waits.
    #[arg(long, default_value_t = 2)]
    window_ms: u64,
    /// When a partly-filled batch is dispatched: on a fixed timer, or the
    /// moment a writer is free. See `Dispatch`.
    #[arg(long, value_enum, default_value = "window")]
    dispatch: Dispatch,
    /// Concurrent database transactions. Independent of `--batch` on
    /// purpose: see `writers_and_offered_load`.
    #[arg(long)]
    writers: Option<usize>,
    #[arg(long, value_enum, default_value = "auto")]
    path: PathChoice,
    /// Drop the in-statement admissibility gate: a batch is then answered
    /// the way the single writer answers today — diagnosed AFTER the
    /// statement and rolled back whole, then retried member by member.
    #[arg(long)]
    no_admissibility_gate: bool,
    /// How long the head-of-line experiment holds its uncommitted claim.
    #[arg(long, default_value_t = 1500)]
    hold_ms: u64,
    /// Scratch database suffix: the book is `spike022_<label>`.
    #[arg(long, default_value = "run")]
    label: String,
    /// Print the statement this configuration would run, and exit.
    #[arg(long)]
    dump_sql: bool,
    /// Append the result object to this file, one JSON object per line.
    #[arg(long)]
    results: Option<String>,
    /// The runner's identifier for this whole invocation, and this
    /// configuration's position in it. `tee -a` into one transcript with
    /// colliding labels cannot be reduced safely; these two can.
    #[arg(long, default_value = "")]
    run_uuid: String,
    #[arg(long, default_value_t = 0)]
    seq: u64,
    /// Which sweep of the whole matrix this configuration belongs to. The
    /// runner sweeps every cell once per pass; carrying the pass number in
    /// the result line is what lets a multi-hour run's drift be SEPARATED
    /// from the treatment instead of averaged into it.
    #[arg(long, default_value_t = 1)]
    pass: u64,
    /// SMOKE ONLY — perturb one cached balance after the workload and before
    /// the verdict. The harness must exit 2. Proves the correctness gate
    /// reaches red.
    #[arg(long)]
    corrupt: bool,
    /// SMOKE ONLY — put the same idempotency key on two members of one
    /// batch, and record what the statement does about it.
    #[arg(long)]
    duplicate_key: bool,
    /// Keep the scratch database for a post-mortem instead of dropping it.
    #[arg(long)]
    keep_database: bool,
}

fn parse_duration(text: &str) -> Fallible<Duration> {
    let trimmed = text.trim();
    let (value, scale) = match trimmed.strip_suffix("ms") {
        Some(v) => (v, 1u64),
        None => match trimmed.strip_suffix('s') {
            Some(v) => (v, 1000),
            None => (trimmed, 1000),
        },
    };
    Ok(Duration::from_millis(
        value.trim().parse::<u64>().map_err(|e| e.to_string())? * scale,
    ))
}

// ---------------------------------------------------------------- workload

/// A posting, as the HTTP surface accepts it: an amount LEAVES `source` and
/// ARRIVES at `destination`. This is the only shape the API can express, and
/// the harness must not be able to express more than it.
#[derive(Clone)]
struct Posting {
    source: Uuid,
    destination: Uuid,
    amount_minor: i64,
}

#[derive(Clone)]
struct Leg {
    account_id: Uuid,
    direction: &'static str,
    amount_minor: i64,
}

/// `expand_postings`, from crates/ledger/src/postings.rs, reproduced: each
/// posting becomes exactly TWO legs, the credit on `source` first and the
/// debit on `destination` second, in posting order.
///
/// This is why the old three-leg hand-built clearing was not a measurement
/// of anything the product can do: leg counts through the shipped API are
/// always EVEN, and no request can produce three. Spike 003's clearing
/// expressed as postings is two of them — the interchange share and the fee
/// share, both landing on the same receivable — so the receivable takes TWO
/// legs, consumes two `account_seq` values, and is the only thing in this
/// harness that exercises a non-zero walk-back offset at all.
fn expand_postings(postings: &[Posting]) -> Vec<Leg> {
    let mut legs = Vec::with_capacity(postings.len() * 2);
    for posting in postings {
        legs.push(Leg {
            account_id: posting.source,
            direction: "credit",
            amount_minor: posting.amount_minor,
        });
        legs.push(Leg {
            account_id: posting.destination,
            direction: "debit",
            amount_minor: posting.amount_minor,
        });
    }
    legs
}

/// SPEC.md's clearing, as the API would have to send it: 500 minor units
/// arriving at one per-company receivable, sourced 9 from the shared
/// interchange row and 491 from the shared fee row. Two postings, four legs,
/// three deltas.
fn clearing(accounts: &TenantAccounts, company: usize, poison: Option<Uuid>) -> Vec<Posting> {
    let receivable = poison
        .unwrap_or_else(|| accounts.receivables[company % accounts.receivables.len().max(1)]);
    vec![
        Posting {
            source: accounts.interchange,
            destination: receivable,
            amount_minor: 9,
        },
        Posting {
            source: accounts.fee,
            destination: receivable,
            amount_minor: 491,
        },
    ]
}

struct Member {
    tenant: String,
    key: String,
    legs: Vec<Leg>,
    /// The SHA-256 over the canonical byte form, per member, computed here
    /// exactly as the shipped writer computes it. A bound `[0u8; 32]` would
    /// have made every V0 number quotable only as "the writer minus its
    /// hashing", which is not a baseline.
    hash: Vec<u8>,
    /// The versioned payload object the writer stores beside the claim —
    /// rendered per post, so the jsonb the book carries is the size the book
    /// would really carry. A `serde_json::Value`, because that is what
    /// crates/ledger/postgres/src/repository.rs binds; the batched path
    /// renders it to text to unnest it and casts back with `::jsonb`.
    payload: serde_json::Value,
}

impl Member {
    fn new(tenant: String, key: String, postings: &[Posting]) -> Member {
        let legs = expand_postings(postings);
        let hash = idempotency_hash(&tenant, &key, postings);
        let payload = event_payload(&tenant, &key, postings);
        Member {
            tenant,
            key,
            legs,
            hash,
            payload,
        }
    }
}

/// crates/ledger/src/domain.rs `canonical_bytes`, reproduced field for field:
/// a version tag, then each value length-prefixed. Reproduced rather than
/// imported because the harness is deliberately not a workspace member — so
/// this function is the one place the two can drift, and it is commented in
/// both directions.
fn canonical_bytes(tenant: &str, key: &str, postings: &[Posting]) -> Vec<u8> {
    fn put(buf: &mut Vec<u8>, bytes: &[u8]) {
        buf.extend_from_slice(&(bytes.len() as u64).to_le_bytes());
        buf.extend_from_slice(bytes);
    }
    let mut buf = Vec::new();
    buf.extend_from_slice(b"openledger.post.v1");
    put(&mut buf, tenant.as_bytes());
    put(&mut buf, EFFECTIVE_AT.as_bytes());
    put(&mut buf, b"posted");
    put(&mut buf, b""); // resolves_id: absent
    put(&mut buf, b""); // reverses_id: absent
    buf.extend_from_slice(&(postings.len() as u64).to_le_bytes());
    for posting in postings {
        buf.extend_from_slice(posting.source.as_bytes());
        buf.extend_from_slice(posting.destination.as_bytes());
        buf.extend_from_slice(&posting.amount_minor.to_le_bytes());
        put(&mut buf, b"USD");
    }
    // The idempotency key is NOT in the canonical form — it is the identity
    // the form is stored under, not part of what is hashed (domain.rs). Bound
    // here so a reader does not go looking for it.
    let _ = key;
    buf
}

fn idempotency_hash(tenant: &str, key: &str, postings: &[Posting]) -> Vec<u8> {
    Sha256::digest(canonical_bytes(tenant, key, postings)).to_vec()
}

/// crates/ledger/src/domain.rs `payload`, reproduced.
fn event_payload(tenant: &str, key: &str, postings: &[Posting]) -> serde_json::Value {
    let rendered: Vec<serde_json::Value> = postings
        .iter()
        .map(|posting| {
            serde_json::json!({
                "source": posting.source.to_string(),
                "destination": posting.destination.to_string(),
                "amount_minor": posting.amount_minor,
                "currency": "USD",
            })
        })
        .collect();
    serde_json::json!({
        "version": 1,
        "tenant_id": tenant,
        "idempotency_key": key,
        "effective_at": EFFECTIVE_AT,
        "status": "posted",
        "resolves_id": serde_json::Value::Null,
        "reverses_id": serde_json::Value::Null,
        "postings": rendered,
    })
}

struct Pending {
    tenant_ix: usize,
    member: Member,
    enqueued: Instant,
    reply: tokio::sync::oneshot::Sender<()>,
}

// ---------------------------------------------------------------- metrics

/// Every counter is gated on `measuring`. Warmup traffic and the post-deadline
/// drain both run through exactly the same code and are both invisible to the
/// numbers — the drain matters, it was over 10% of the total in deadlocking
/// configurations, and counting it made a slow configuration look fast.
#[derive(Default)]
struct Metrics {
    measuring: AtomicBool,
    /// Clearings inside the measurement window — the number that is reported.
    clearings: AtomicU64,
    /// Clearings the harness committed AT ALL, warmup and post-deadline drain
    /// included. This is the one the book can be checked against: the book
    /// has no idea when the clock started, so `count(*) FROM
    /// ledger_transactions` can only ever equal the TOTAL. Asserting the
    /// windowed count against it would be asserting that warmup wrote
    /// nothing, which is the opposite of what warmup is for.
    clearings_total: AtomicU64,
    refused: AtomicU64,
    replayed: AtomicU64,
    statements: AtomicU64,
    members_dispatched: AtomicU64,
    window_wait_us: AtomicU64,
    deadlocks: AtomicU64,
    arrivals: AtomicU64,
    announced: Mutex<std::collections::BTreeSet<String>>,
    latencies_us: Mutex<Vec<u32>>,
    errors: Mutex<BTreeMap<String, u64>>,
}

impl Metrics {
    fn on(&self) -> bool {
        self.measuring.load(Ordering::Relaxed)
    }

    fn add(&self, counter: &AtomicU64, by: u64) {
        if self.on() {
            counter.fetch_add(by, Ordering::Relaxed);
        }
    }

    /// Every commit is counted twice: once for the report, once for the
    /// invariant. Nothing else may touch `clearings`.
    fn note_commits(&self, n: u64) {
        if n == 0 {
            return;
        }
        self.clearings_total.fetch_add(n, Ordering::Relaxed);
        if self.on() {
            self.clearings.fetch_add(n, Ordering::Relaxed);
        }
    }

    fn note_latency(&self, waited: Duration) {
        if self.on() {
            self.latencies_us
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(waited.as_micros().min(u32::MAX as u128) as u32);
        }
    }

    fn note_error(&self, error: &sqlx::Error) {
        let class = error_class(error);
        if class == "deadlock" && self.on() {
            self.deadlocks.fetch_add(1, Ordering::Relaxed);
        }
        // The first of each class is printed WHOLE, ONCE. An error budget with
        // no message in it is how a harness measures its own bug — but the
        // announcement is tracked apart from the count, because the count only
        // advances inside the measurement window and a warmup that failed
        // every request would otherwise reprint the same line thousands of
        // times.
        if self
            .announced
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(class.clone())
        {
            eprintln!("first {class}: {error}");
        }
        if self.on() {
            *self
                .errors
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .entry(class)
                .or_insert(0) += 1;
        }
    }

    fn percentile_ms(&self, sorted: &[u32], q: f64) -> f64 {
        if sorted.is_empty() {
            return 0.0;
        }
        let rank = ((sorted.len() - 1) as f64 * q).round() as usize;
        sorted[rank] as f64 / 1000.0
    }
}

fn error_class(error: &sqlx::Error) -> String {
    match error {
        sqlx::Error::Database(db) => match db.code().as_deref() {
            Some("40P01") => "deadlock".to_owned(),
            Some("40001") => "serialization_failure".to_owned(),
            Some(code) => format!("sqlstate_{code}"),
            None => "database".to_owned(),
        },
        sqlx::Error::PoolTimedOut => "pool_timeout".to_owned(),
        sqlx::Error::Io(_) => "io".to_owned(),
        other => format!("client_{}", short(other)),
    }
}

fn short(error: &sqlx::Error) -> String {
    error
        .to_string()
        .chars()
        .take(40)
        .filter(|c| *c != '"' && *c != '\\' && *c != '\n')
        .collect()
}

fn loadavg() -> String {
    std::fs::read_to_string("/proc/loadavg")
        .ok()
        .and_then(|line| {
            let mut parts = line.split_whitespace();
            Some(format!(
                "{} {} {}",
                parts.next()?,
                parts.next()?,
                parts.next()?
            ))
        })
        .unwrap_or_else(|| "?".to_owned())
}

/// `/proc/stat`'s cumulative jiffies, as (busy, total).
///
/// The 1-minute loadavg has a 60-SECOND time constant, so on a 3-second run
/// followed by a 3-second settle `load_before` is not a reading of this
/// machine's idleness — it is a reading of the PREVIOUS configuration, which
/// is the one thing it must not be. A `/proc/stat` delta has no memory: it
/// reports exactly the interval it was measured across, and nothing else.
fn cpu_jiffies() -> Option<(u64, u64)> {
    let stat = std::fs::read_to_string("/proc/stat").ok()?;
    let line = stat.lines().next()?;
    let fields: Vec<u64> = line
        .split_whitespace()
        .skip(1)
        .filter_map(|f| f.parse::<u64>().ok())
        .collect();
    if fields.len() < 5 {
        return None;
    }
    let total: u64 = fields.iter().sum();
    let idle = fields[3] + fields[4]; // idle + iowait
    Some((total.saturating_sub(idle), total))
}

fn busy_pct_since(before: Option<(u64, u64)>) -> f64 {
    match (before, cpu_jiffies()) {
        (Some((busy0, total0)), Some((busy1, total1))) if total1 > total0 => {
            (busy1 - busy0) as f64 / (total1 - total0) as f64 * 100.0
        }
        _ => -1.0,
    }
}

// ---------------------------------------------------------------- statements

#[derive(sqlx::FromRow)]
struct SingleRow {
    #[allow(dead_code)]
    event_id: Uuid,
    transaction_id: Option<Uuid>,
    last_seq: Option<i64>,
}

#[derive(sqlx::FromRow)]
struct MemberRow {
    #[allow(dead_code)]
    ord: i32,
    event_id: Option<Uuid>,
    transaction_id: Option<Uuid>,
    admissible: bool,
}

/// Two batched statements, not one. A writer presenting its legs in reverse
/// cannot express that through its BINDS on the batched path — the coalesce
/// destroys member identity before the insert, and the insert's row order
/// comes from a group-key set that is identical whichever way the legs
/// arrived. The disagreement has to live in the STATEMENT, so it does.
struct Statements {
    single: Arc<str>,
    batched_forward: Arc<str>,
    batched_reversed: Arc<str>,
}

impl Statements {
    fn batched(&self, reversed: bool) -> &Arc<str> {
        if reversed {
            &self.batched_reversed
        } else {
            &self.batched_forward
        }
    }
}

async fn begin(pool: &PgPool) -> Result<Transaction<'static, Postgres>, sqlx::Error> {
    // ADR-0013 §1, in the ADR's own words: the transaction opens WITH the
    // isolation level, one round trip, never an inherited deployment default
    // plus a second SET.
    pool.begin_with("BEGIN ISOLATION LEVEL READ COMMITTED").await
}

/// One clearing through the shipped statement's shape. Returns
/// `Ok(committed)` — `false` means the statement refused (an account it
/// named does not exist, or the key was already held) and the transaction
/// was rolled back, which is the promise the writer already makes.
async fn post_single(
    pool: &PgPool,
    statement: &Arc<str>,
    member: &Member,
    affinity: i32,
    presentation_order: bool,
    reverses: Option<Uuid>,
) -> Result<(bool, Option<Uuid>), sqlx::Error> {
    // The coalesced deltas. The shipped writer walks a BTreeMap, so its
    // arrays arrive in account-id order; under `--lock-order-hazard
    // caller-legs` half the writers instead send the
    // arrays in the order they PRESENTED their legs, which is what makes the
    // statement's own ORDER BY the only thing standing between two writers
    // and an AB-BA deadlock. This is the one path where a caller can reach
    // lock order at all.
    let mut order: Vec<Uuid> = Vec::new();
    let mut deltas: BTreeMap<Uuid, (i64, i64, i64)> = BTreeMap::new();
    for leg in &member.legs {
        let entry = deltas.entry(leg.account_id).or_insert_with(|| {
            order.push(leg.account_id);
            (0, 0, 0)
        });
        match leg.direction {
            "debit" => entry.0 += leg.amount_minor,
            _ => entry.1 += leg.amount_minor,
        }
        entry.2 += 1;
    }
    if !presentation_order {
        order = deltas.keys().copied().collect();
    }
    let delta_accounts: Vec<Uuid> = order.clone();
    let delta_currencies: Vec<String> = order.iter().map(|_| "USD".to_owned()).collect();
    let delta_inputs: Vec<i64> = order.iter().map(|a| deltas[a].0).collect();
    let delta_outputs: Vec<i64> = order.iter().map(|a| deltas[a].1).collect();
    let delta_legs: Vec<i64> = order.iter().map(|a| deltas[a].2).collect();

    // The walk-back, computed in Rust exactly as
    // `offsets_back_from_last_seq` does: leg i's offset is the number of
    // later legs on the same account.
    let mut later: BTreeMap<Uuid, i64> = BTreeMap::new();
    let mut offsets = vec![0i64; member.legs.len()];
    for (i, leg) in member.legs.iter().enumerate().rev() {
        let count = later.entry(leg.account_id).or_insert(0);
        offsets[i] = *count;
        *count += 1;
    }
    let leg_accounts: Vec<Uuid> = member.legs.iter().map(|l| l.account_id).collect();
    let leg_directions: Vec<String> = member.legs.iter().map(|l| l.direction.to_owned()).collect();
    let leg_amounts: Vec<i64> = member.legs.iter().map(|l| l.amount_minor).collect();
    let leg_currencies: Vec<String> = member.legs.iter().map(|_| "USD".to_owned()).collect();

    // A reversal carries no legs and no deltas of its own: the mirror CTEs
    // derive both from the target's entries. Empty arrays, and `$18` set.
    let mirroring = reverses.is_some();
    let empty_uuid: Vec<Uuid> = Vec::new();
    let empty_text: Vec<String> = Vec::new();
    let empty_i64: Vec<i64> = Vec::new();

    let mut tx = begin(pool).await?;
    let rows: Vec<SingleRow> = sqlx::query_as(AssertSqlSafe(statement.clone()))
        .bind(&member.tenant)
        .bind(&member.key)
        .bind(&member.hash)
        .bind(&member.payload)
        .bind(EFFECTIVE_AT)
        .bind(if mirroring { &empty_uuid } else { &delta_accounts })
        .bind(if mirroring { &empty_text } else { &delta_currencies })
        .bind(if mirroring { &empty_i64 } else { &delta_inputs })
        .bind(if mirroring { &empty_i64 } else { &delta_outputs })
        .bind(if mirroring { &empty_i64 } else { &delta_legs })
        .bind(if mirroring { &empty_uuid } else { &leg_accounts })
        .bind(if mirroring { &empty_text } else { &leg_directions })
        .bind(if mirroring { &empty_i64 } else { &leg_amounts })
        .bind(if mirroring { &empty_text } else { &leg_currencies })
        .bind(if mirroring { &empty_i64 } else { &offsets })
        .bind("posted")
        .bind(None::<Uuid>)
        .bind(reverses)
        .bind(affinity)
        .fetch_all(&mut *tx)
        .await?;
    let admitted = !rows.is_empty()
        && rows[0].transaction_id.is_some()
        && rows.iter().all(|r| r.last_seq.is_some());
    let transaction_id = rows.first().and_then(|r| r.transaction_id);
    if admitted {
        tx.commit().await?;
    } else {
        tx.rollback().await?;
    }
    Ok((admitted, if admitted { transaction_id } else { None }))
}

struct BatchOutcome {
    committed: usize,
    refused: usize,
    replayed: usize,
    /// Members the batch abandoned and re-posted one at a time, when the
    /// admissibility gate is off.
    retried_singly: usize,
}

async fn post_batch(
    pool: &PgPool,
    statements: &Statements,
    members: &[Member],
    affinity: i32,
    gate: bool,
    reverse_legs: bool,
    descending_statement: bool,
) -> Result<BatchOutcome, sqlx::Error> {
    let tenants: Vec<String> = members.iter().map(|m| m.tenant.clone()).collect();
    let keys: Vec<String> = members.iter().map(|m| m.key.clone()).collect();
    let hashes: Vec<Vec<u8>> = members.iter().map(|m| m.hash.clone()).collect();
    let payloads: Vec<String> = members.iter().map(|m| m.payload.to_string()).collect();
    let mut leg_member: Vec<i32> = Vec::new();
    let mut leg_ord: Vec<i32> = Vec::new();
    let mut leg_accounts: Vec<Uuid> = Vec::new();
    let mut leg_directions: Vec<String> = Vec::new();
    let mut leg_amounts: Vec<i64> = Vec::new();
    let mut leg_currencies: Vec<String> = Vec::new();
    for (m, member) in members.iter().enumerate() {
        for (l, leg) in member.legs.iter().enumerate() {
            leg_member.push(m as i32 + 1);
            leg_ord.push(l as i32 + 1);
            leg_accounts.push(leg.account_id);
            leg_directions.push(leg.direction.to_owned());
            leg_amounts.push(leg.amount_minor);
            leg_currencies.push("USD".to_owned());
        }
    }

    let mut tx = begin(pool).await?;
    let rows: Vec<MemberRow> = sqlx::query_as(AssertSqlSafe(statements.batched(descending_statement).clone()))
        .bind(&tenants)
        .bind(&keys)
        .bind(&hashes)
        .bind(&payloads)
        .bind(EFFECTIVE_AT)
        .bind(&leg_member)
        .bind(&leg_ord)
        .bind(&leg_accounts)
        .bind(&leg_directions)
        .bind(&leg_amounts)
        .bind(&leg_currencies)
        .bind(affinity)
        .fetch_all(&mut *tx)
        .await?;

    let inadmissible = rows.iter().filter(|r| !r.admissible).count();
    if !gate && inadmissible > 0 {
        // Today's answer, applied to a batch: the refusal is diagnosed
        // AFTER the statement and answered by rolling the whole database
        // transaction back — which destroys every innocent member. The
        // fallback is to re-post them one at a time.
        tx.rollback().await?;
        let mut committed = 0;
        let mut refused = 0;
        for member in members {
            match post_single(pool, &statements.single, member, affinity, reverse_legs, None)
                .await
            {
                Ok((true, _)) => committed += 1,
                Ok((false, _)) => refused += 1,
                Err(error) => return Err(error),
            }
        }
        return Ok(BatchOutcome {
            committed,
            refused,
            replayed: 0,
            retried_singly: members.len(),
        });
    }
    let committed = rows.iter().filter(|r| r.transaction_id.is_some()).count();
    // Three outcomes, and they are three because the gate made them three.
    // With the claim gated, a refused member has NO event row — `event_id`
    // is null because it was never claimed, not because someone else holds
    // the key — so "inadmissible" and "key already held" have to be counted
    // apart or the second would absorb the first.
    let refused = rows.iter().filter(|r| !r.admissible).count();
    let replayed = rows
        .iter()
        .filter(|r| r.admissible && r.event_id.is_none())
        .count();
    tx.commit().await?;
    Ok(BatchOutcome {
        committed,
        refused,
        replayed,
        retried_singly: 0,
    })
}

async fn dispatch(
    pool: &PgPool,
    statements: &Statements,
    args: &Args,
    members: &[Member],
    affinity: i32,
    reverse_legs: bool,
    descending_statement: bool,
) -> Result<BatchOutcome, sqlx::Error> {
    let batched = match args.path {
        PathChoice::Batched => true,
        PathChoice::Single => false,
        PathChoice::Auto => members.len() > 1,
    };
    if batched {
        post_batch(
            pool,
            statements,
            members,
            affinity,
            !args.no_admissibility_gate,
            reverse_legs,
            descending_statement,
        )
        .await
    } else {
        let mut committed = 0;
        let mut refused = 0;
        for member in members {
            match post_single(pool, &statements.single, member, affinity, reverse_legs, None)
                .await
            {
                Ok((true, posted)) => {
                    committed += 1;
                    // Section E's single-path reversal arm, and the only
                    // thing in this harness that reaches the mirror CTEs at
                    // all. The mirror derives its own legs and deltas from
                    // the target's entries, and its `GROUP BY account_id,
                    // currency` is the order source the ORDER BY then sorts
                    // — untested until now, and half of M2's deliverable.
                    if args.reversals {
                        if let Some(target) = posted {
                            // No postings: a reversal names only its target,
                            // and the mirror CTEs derive the legs and deltas
                            // from the target's own entries. Two reversals in
                            // one tenant therefore hash alike — the canonical
                            // form covers the postings, and there are none.
                            // Harmless here (nothing is unique-indexed on the
                            // hash and this harness never replays) and NOT
                            // harmless in the product, where the shipped form
                            // also covers `reverses_id`, which this
                            // reproduction does not carry.
                            let mirror = Member::new(
                                member.tenant.clone(),
                                format!("{}-rev", member.key),
                                &[],
                            );
                            match post_single(
                                pool,
                                &statements.single,
                                &mirror,
                                affinity,
                                reverse_legs,
                                Some(target),
                            )
                            .await
                            {
                                Ok((true, _)) => committed += 1,
                                Ok((false, _)) => refused += 1,
                                Err(error) => return Err(error),
                            }
                        }
                    }
                }
                Ok((false, _)) => refused += 1,
                Err(error) => return Err(error),
            }
        }
        Ok(BatchOutcome {
            committed,
            refused,
            replayed: 0,
            retried_singly: 0,
        })
    }
}

// ---------------------------------------------------------------- the queue

struct Queue {
    items: Mutex<VecDeque<Pending>>,
    notify: tokio::sync::Notify,
}

impl Queue {
    fn push(&self, pending: Pending) {
        self.items
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push_back(pending);
        self.notify.notify_waiters();
    }

    fn take(&self, batch: &mut Vec<Pending>, limit: usize, tenant: Option<usize>) {
        let mut items = self.items.lock().unwrap_or_else(|e| e.into_inner());
        match tenant {
            None => {
                while batch.len() < limit {
                    match items.pop_front() {
                        Some(pending) => batch.push(pending),
                        None => break,
                    }
                }
            }
            Some(wanted) => {
                let mut i = 0;
                while i < items.len() && batch.len() < limit {
                    if items[i].tenant_ix == wanted {
                        if let Some(pending) = items.remove(i) {
                            batch.push(pending);
                        }
                    } else {
                        i += 1;
                    }
                }
            }
        }
    }

    fn is_empty(&self) -> bool {
        self.items
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .is_empty()
    }
}

/// A whale-skewed tenant draw. `--whale 0.9` sends 90% of the offered load
/// to t0 and spreads the rest over the others; `--whale 0` is uniform.
fn draw_tenant(rng: &mut u64, tenants: usize, whale: f64) -> usize {
    if tenants <= 1 {
        return 0;
    }
    if whale > 0.0 {
        if next_unit(rng) < whale {
            return 0;
        }
        return 1 + (next(rng) as usize) % (tenants - 1);
    }
    (next(rng) as usize) % tenants
}

fn next(state: &mut u64) -> u64 {
    let mut x = *state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *state = x;
    x
}

fn next_unit(state: &mut u64) -> f64 {
    (next(state) % 1_000_000) as f64 / 1_000_000.0
}

// ------------------------------------------------- writers and offered load

/// Batch size and database concurrency are TWO knobs, and the old default
/// welded them into one: `writers = ceil(concurrency / batch)` with
/// closed-loop producers holding one request each meant the achievable fill
/// at `-c 32` was 1, 8, 16 or 32 — never the 10, 25 or 100 the matrix asks
/// for — and at B = 100 there was exactly ONE writer, so section B's largest
/// batch measured a system with no lock contention in it at all and would
/// have reported that as the benefit of batching.
///
/// So: `--writers` is database concurrency and is pinned; the offered load
/// scales WITH the batch size to keep it fed. `--writers 32 --concurrency
/// $((32 * B))` is the shape, and anything short of it is refused rather
/// than silently measured, because a starved batcher's fill rate is
/// arithmetic (`concurrency / writers`) rather than workload.
fn writers_and_offered_load(args: &Args) -> Fallible<usize> {
    let writers = args.writers.unwrap_or(args.concurrency).max(1);
    // The poison and head-of-line experiments build ONE batch of exactly
    // `--batch` members by hand and never start a producer, so there is no
    // offered load for the batch to be starved of.
    if matches!(args.experiment, Experiment::Poison | Experiment::Headofline) {
        return Ok(writers);
    }
    if args.offered_rate.is_some() {
        // Nothing to check: in the open loop the offered load is an arrival
        // rate, not a population of outstanding requests, so a batch fills
        // (or does not) from arrivals alone. That is the point of it.
        return Ok(writers);
    }
    let needed = writers.saturating_mul(args.batch);
    if args.batch > 1 && args.concurrency < needed {
        return Err(format!(
            "--batch {b} with --writers {writers} needs at least {needed} outstanding \
             requests to fill a batch, and --concurrency is {c}. Below that the fill \
             rate is {c}/{writers} — arithmetic, not workload — and the configuration \
             would measure concurrency collapse and label it batching. Pass \
             --concurrency {needed} (or lower --writers).",
            b = args.batch,
            c = args.concurrency,
        )
        .into());
    }
    Ok(writers)
}

/// How many distinct stripes this configuration can actually REACH. A cell
/// where this is below `--stripes` is degenerate — `--mode worker` with 8
/// writers and 64 stripes uses 8 of them, and at B = 25 the old default gave
/// it 2, which is `--mode none` wearing a different name. Emitted in every
/// result line so a degenerate cell is visible rather than inferred from the
/// other columns after the fact.
fn stripes_reachable(args: &Args, writers: usize) -> i64 {
    match args.mode {
        Mode::None => 1,
        Mode::Random => args.stripes as i64,
        Mode::Tenant => (args.tenants as i64).min(args.stripes as i64),
        Mode::Worker => (writers as i64).min(args.stripes as i64),
    }
}

// ---------------------------------------------------------------- results

struct Environment {
    writers: usize,
    load_before: String,
    load_after: String,
    cpu_pre_pct: f64,
    cpu_window_pct: f64,
    reconciled: bool,
    verdict: String,
    transactions_in_book: i64,
    analyze_s: f64,
    oracle_s: f64,
}

fn result_line(
    args: &Args,
    metrics: &Metrics,
    elapsed: Duration,
    env: &Environment,
    extra: &str,
) -> String {
    let clearings = metrics.clearings.load(Ordering::Relaxed);
    let clearings_total = metrics.clearings_total.load(Ordering::Relaxed);
    let statements = metrics.statements.load(Ordering::Relaxed);
    let members = metrics.members_dispatched.load(Ordering::Relaxed);
    let deadlocks = metrics.deadlocks.load(Ordering::Relaxed);
    let arrivals = metrics.arrivals.load(Ordering::Relaxed);
    let seconds = elapsed.as_secs_f64().max(1e-9);
    let fill = if statements == 0 {
        0.0
    } else {
        members as f64 / statements as f64
    };
    let window_wait_ms = if members == 0 {
        0.0
    } else {
        metrics.window_wait_us.load(Ordering::Relaxed) as f64 / members as f64 / 1000.0
    };
    let deadlocks_per_1k = if statements == 0 {
        0.0
    } else {
        deadlocks as f64 * 1000.0 / statements as f64
    };
    // A deadlock loses a WHOLE BATCH and nothing retries it. The clearings
    // that batch would have committed are not slow, they are absent — so the
    // rate is not a throughput measurement of anything, and it is emitted as
    // null rather than as a number somebody will later average.
    let rate = if deadlocks > 0 {
        "null".to_owned()
    } else {
        format!("{:.1}", clearings as f64 / seconds)
    };
    let achieved = rate.clone();
    let mut latencies = metrics
        .latencies_us
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone();
    latencies.sort_unstable();
    let errors = metrics.errors.lock().unwrap_or_else(|e| e.into_inner());
    let error_json: Vec<String> = errors
        .iter()
        .map(|(class, count)| format!("\"{class}\":{count}"))
        .collect();
    let offered = match args.offered_rate {
        Some(rate) => format!("{rate}"),
        None => "null".to_owned(),
    };
    format!(
        "{{\"run_uuid\":\"{run_uuid}\",\"seq\":{seq},\"pass\":{pass},\"label\":\"{label}\",\
\"experiment\":\"{experiment}\",\"loop\":\"{loop_shape}\",\"mode\":\"{mode}\",\
\"select\":\"{select}\",\"stripes\":{stripes},\"stripes_reachable\":{reachable},\
\"batch\":{batch},\"concurrency\":{concurrency},\"offered_rate\":{offered},\
\"arrival_streams\":{streams},\
\"writers\":{writers},\"path\":\"{path}\",\"order_by\":{order_by},\
\"lock_order_hazard\":\"{hazard}\",\"hazard_is_a_model\":{is_model},\
\"reversals\":{reversals},\
\"tenant_homogeneous\":{homogeneous},\"gate\":{gate},\"companies\":{companies},\
\"tenants\":{tenants},\"whale\":{whale},\"window_ms\":{window_ms},\
\"dispatch_policy\":\"{dispatch}\",\"warmup\":\"{warmup}\",\
\"seconds\":{seconds:.3},\"clearings\":{clearings},\"clearings_per_s\":{rate},\
\"arrivals\":{arrivals},\"achieved_rate_per_s\":{achieved},\
\"statements\":{statements},\"batch_fill\":{fill:.2},\"window_wait_ms\":{window_wait_ms:.3},\
\"latency_p50_ms\":{p50:.2},\"latency_p95_ms\":{p95:.2},\"latency_p99_ms\":{p99:.2},\
\"latency_samples\":{samples},\"refused\":{refused},\"replayed\":{replayed},\
\"deadlocks\":{deadlocks},\"deadlocks_per_1k_statements\":{deadlocks_per_1k:.2},\
\"errors\":{{{errors}}},\"load_before\":\"{load_before}\",\"load_after\":\"{load_after}\",\
\"cpu_busy_pre_pct\":{cpu_pre:.1},\"cpu_busy_window_pct\":{cpu_window:.1},\
\"clearings_all_phases\":{clearings_total},\"transactions_in_book\":{txns},\
\"count_matches_clearings\":{matches},\
\"reconciled\":{reconciled},\"verdict\":\"{verdict}\",\
\"analyze_s\":{analyze_s:.2},\"oracle_s\":{oracle_s:.2}{extra}}}",
        run_uuid = args.run_uuid,
        seq = args.seq,
        pass = args.pass,
        label = args.label,
        experiment = args.experiment.as_str(),
        loop_shape = if args.offered_rate.is_some() {
            "open"
        } else {
            "closed"
        },
        mode = args.mode.as_str(),
        select = args.select.as_str(),
        stripes = args.stripes,
        reachable = stripes_reachable(args, env.writers),
        batch = args.batch,
        concurrency = args.concurrency,
        streams = match args.offered_rate {
            Some(rate) => arrival_streams(rate),
            None => args.concurrency,
        },
        writers = env.writers,
        path = args.path.as_str(args.batch),
        order_by = !args.no_order_by,
        hazard = args.lock_order_hazard.as_str(),
        is_model = args.lock_order_hazard.is_a_model(),
        reversals = args.reversals,
        homogeneous = args.tenant_homogeneous,
        gate = !args.no_admissibility_gate,
        companies = args.companies,
        tenants = args.tenants,
        whale = args.whale,
        window_ms = args.window_ms,
        dispatch = args.dispatch.as_str(),
        warmup = args.warmup,
        p50 = metrics.percentile_ms(&latencies, 0.50),
        p95 = metrics.percentile_ms(&latencies, 0.95),
        p99 = metrics.percentile_ms(&latencies, 0.99),
        samples = latencies.len(),
        refused = metrics.refused.load(Ordering::Relaxed),
        replayed = metrics.replayed.load(Ordering::Relaxed),
        errors = error_json.join(","),
        load_before = env.load_before,
        load_after = env.load_after,
        cpu_pre = env.cpu_pre_pct,
        cpu_window = env.cpu_window_pct,
        txns = env.transactions_in_book,
        matches = env.transactions_in_book as u64 == clearings_total,
        reconciled = env.reconciled,
        verdict = env.verdict,
        analyze_s = env.analyze_s,
        oracle_s = env.oracle_s,
    )
}

// ---------------------------------------------------------------- main

#[tokio::main]
async fn main() {
    match run().await {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("spike022: {error}");
            std::process::exit(1);
        }
    }
}

async fn run() -> Fallible<i32> {
    let args = Args::parse();
    let shape = |balance_order| Shape {
        mode: args.mode,
        placement: args.select,
        order_by: !args.no_order_by,
        balance_order,
        admissibility_gate: !args.no_admissibility_gate,
    };
    // Both statement variants are built here so the choice is visible in one
    // place. Which one a writer runs is decided per writer, by the hazard.
    let (forward_order, reversed_order) = match (args.no_order_by, args.lock_order_hazard) {
        // The sort present: every writer canonical, whatever the hazard.
        // This is the control arm of all three.
        (false, _) => (BalanceOrder::Canonical, BalanceOrder::Canonical),
        // The sort gone, and a MODEL asked for: half the writers get an
        // explicit DESC. Nothing a caller can cause — hence the label.
        (true, LockOrderHazard::DescendingModel) => {
            (BalanceOrder::Canonical, BalanceOrder::Reversed)
        }
        // The sort gone and nothing modelled: the row order is whatever the
        // plan emits, which is the honest batched-path condition. Whether
        // that alone deadlocks is `account-subsets`' question to answer.
        (true, _) => (BalanceOrder::PlanOrder, BalanceOrder::PlanOrder),
    };
    let statements = Statements {
        single: Arc::from(sql::single_member(&shape(forward_order)).into_boxed_str()),
        batched_forward: Arc::from(sql::batched(&shape(forward_order)).into_boxed_str()),
        batched_reversed: Arc::from(sql::batched(&shape(reversed_order)).into_boxed_str()),
    };
    if args.dump_sql {
        println!("-- single-member path\n{}\n", statements.single);
        println!(
            "-- batched path, balance order {}\n{}\n",
            forward_order.as_str(),
            statements.batched_forward
        );
        println!(
            "-- batched path, balance order {}\n{}",
            reversed_order.as_str(),
            statements.batched_reversed
        );
        return Ok(0);
    }
    // Validation runs AFTER --dump-sql: dumping the statement a configuration
    // WOULD run has to work for configurations that are refused, or the
    // refusal cannot be inspected.
    let writers = writers_and_offered_load(&args)?;
    if args.path == PathChoice::Single && args.batch > 1 {
        return Err("--path single cannot carry --batch > 1".into());
    }
    // A window under a policy that never opens one. Refused rather than
    // ignored: the result line carries `window_ms`, and a run labelled
    // `--window-ms 25 --dispatch on-completion` would read as evidence about
    // a 25ms window that was never waited.
    if args.dispatch == Dispatch::OnCompletion && args.window_ms != 0 {
        return Err("--dispatch on-completion never waits on a timer, so --window-ms \
                    has nothing to describe. Pass --window-ms 0 with it, or use \
                    --dispatch window if the timer is the thing under test."
            .into());
    }
    // Only the throughput experiment drives an arrival process at all. Poison
    // and head-of-line hand-build ONE batch of exactly `--batch` members and
    // never start an accumulator, so there is no dispatch policy to choose.
    if args.dispatch == Dispatch::OnCompletion
        && matches!(args.experiment, Experiment::Poison | Experiment::Headofline)
    {
        return Err("--experiment poison and headofline build one batch by hand and \
                    never run the accumulator: there is no dispatch policy to choose."
            .into());
    }
    // `--mode tenant` at one tenant is `--mode none` with a hash in front of
    // it: `hashtext('t0') % 64` is a CONSTANT, so every writer picks the same
    // stripe and the configuration measures the unstriped writer. The
    // transcript already contains the tautology — 778.7 against 778.6 — and
    // a number that cannot differ is worse than a missing one, because it
    // reads as evidence. Refused, with the remedy named.
    if args.mode == Mode::Tenant && args.tenants < 2 {
        return Err("--mode tenant with --tenants 1 chooses a CONSTANT stripe: \
                    hashtext('t0') does not vary, so every writer lands on the same \
                    row and the run is --mode none under another name. Pass \
                    --tenants 32 (or more) so the mode has something to spread over."
            .into());
    }
    // THE FINDING, ENFORCED AS A REFUSAL. A caller cannot influence lock
    // order on the batched path: `member_delta` coalesces every member down
    // to (tenant, account, currency) before the insert, so member identity —
    // and with it the order the caller presented its legs in — is gone
    // before any row is locked. Reversing a member's legs there is not
    // merely weak evidence, it is provably inert, and the old
    // `--reverse-half` silently ran it anyway and reported the deadlocks a
    // different mechanism produced.
    if args.lock_order_hazard == LockOrderHazard::CallerLegs && args.batch > 1 {
        return Err("--lock-order-hazard caller-legs is a SINGLE-path hazard. On the \
                    batched path the coalesce normalizes lock order before the insert, \
                    so a caller cannot influence it — that is the finding, not a \
                    limitation to work around. For the batched path's real hazard pass \
                    --lock-order-hazard account-subsets; for a deliberate worst-case \
                    model, --lock-order-hazard descending-model."
            .into());
    }
    // The DESC variant is a property of the BATCHED statement. The single
    // statement's insert order comes from its bound arrays, so a
    // statement-level DESC would model nothing there.
    if args.lock_order_hazard == LockOrderHazard::DescendingModel && args.batch < 2 {
        return Err("--lock-order-hazard descending-model models the BATCHED statement's \
                    row order and does nothing at --batch 1, where the single \
                    statement's order comes from its bound arrays. Pass --batch > 1, \
                    or --lock-order-hazard caller-legs for the single path."
            .into());
    }
    if args.reversals && args.batch > 1 {
        return Err("--reversals runs on the SINGLE path only: the batched statement \
                    hardcodes 'posted' and carries no supersession columns, by design \
                    (SPEC.md). Pass --batch 1."
            .into());
    }

    // One second of `/proc/stat`, before anything of ours runs. This is the
    // idleness evidence the loadavg could not give: no 60-second memory, no
    // previous configuration bleeding into it.
    let cpu_pre_before = cpu_jiffies();
    let load_before = loadavg();
    tokio::time::sleep(Duration::from_secs(1)).await;
    let cpu_pre_pct = busy_pct_since(cpu_pre_before);

    let started_setup = Instant::now();
    let (db_url, pool) = setup::fresh_book(&args.label).await?;
    let accounts = setup::open_accounts(&pool, args.tenants, args.companies, args.stripes).await?;
    let accounts = Arc::new(accounts);
    eprintln!(
        "setup: {} in {:.1}s ({} tenant(s), {} companies, stripe_count {} on the house rows, \
         {} writer(s), {} stripe(s) reachable)",
        db_url,
        started_setup.elapsed().as_secs_f64(),
        args.tenants,
        args.companies,
        args.stripes,
        writers,
        stripes_reachable(&args, writers),
    );

    if args.lock_order_hazard != LockOrderHazard::None && writers < 2 {
        eprintln!(
            "spike022: WARNING — --lock-order-hazard {} with {writers} writer task: no two \
             writers can race, so a deadlock count of 0 means nothing. Raise --writers.",
            args.lock_order_hazard.as_str()
        );
    }
    let pool = {
        drop(pool);
        sqlx::postgres::PgPoolOptions::new()
            .max_connections((writers + 6) as u32)
            .acquire_timeout(Duration::from_secs(30))
            .connect(&db_url)
            .await?
    };

    let metrics = Arc::new(Metrics::default());
    let statements = Arc::new(statements);
    let args_shared = Arc::new(args.clone());

    let (elapsed, cpu_window_pct, extra) = match args.experiment {
        Experiment::Throughput | Experiment::Deadlock => {
            drive_load(&pool, &statements, &args_shared, &accounts, &metrics, writers).await?
        }
        Experiment::Poison => {
            let window = cpu_jiffies();
            let (elapsed, extra) =
                poison(&pool, &statements, &args_shared, &accounts, &metrics).await?;
            (elapsed, busy_pct_since(window), extra)
        }
        Experiment::Headofline => {
            let window = cpu_jiffies();
            let (elapsed, extra) =
                head_of_line(&pool, &statements, &args_shared, &accounts, &metrics, &db_url).await?;
            (elapsed, busy_pct_since(window), extra)
        }
    };

    let load_after = loadavg();
    // Where a configuration's wall time actually goes. The matrix is ~500
    // configurations and the measurement window is 30s of it; anything else
    // that costs minutes decides whether the matrix is runnable at all, so
    // it is timed rather than estimated.
    let phase = Instant::now();

    // The correctness gate, given something to catch. `--corrupt` moves one
    // cached balance by one minor unit AFTER the workload and BEFORE the
    // verdict; the oracle recomputes balances from entries, so it must go
    // red and this process must exit 2.
    let mut corrupted = String::new();
    if args.corrupt {
        let where_ = setup::corrupt_one_cached_balance(&pool).await?;
        eprintln!("corrupt: perturbed input by 1 on {where_} — the oracle must now break");
        corrupted = format!(",\"corrupted\":\"{where_}\"");
    }

    let transactions_in_book = setup::transactions_in_the_book(&pool).await?;
    // Statistics, before the oracle reads the book. A scratch database is
    // created, filled in thirty seconds and read once — autovacuum's
    // analyze threshold may or may not have fired by then, and the ten
    // checks are large joins over `ledger_entries` whose plans are chosen
    // from whatever `pg_statistic` happens to hold. Analyzing explicitly
    // costs a second and removes a source of variance that has nothing to do
    // with what is being measured.
    let analyze_at = Instant::now();
    sqlx::raw_sql(AssertSqlSafe(
        "ANALYZE ledger_entries, ledger_transactions, ledger_account_balances, ledger_accounts"
            .to_owned(),
    ))
    .execute(&pool)
    .await?;
    let analyze_s = analyze_at.elapsed().as_secs_f64();
    let oracle_at = Instant::now();
    let (reconciled, verdict) = setup::reconciliation_verdict(&pool).await?;
    let oracle_s = oracle_at.elapsed().as_secs_f64();
    eprintln!(
        "phases: drain {:.1}s, analyze {analyze_s:.1}s, oracle {oracle_s:.1}s",
        phase.elapsed().as_secs_f64() - analyze_s - oracle_s
    );

    let env = Environment {
        writers,
        load_before,
        load_after,
        cpu_pre_pct,
        cpu_window_pct,
        reconciled,
        verdict: verdict.clone(),
        transactions_in_book,
        analyze_s,
        oracle_s,
    };
    let line = result_line(&args, &metrics, elapsed, &env, &format!("{extra}{corrupted}"));
    println!("{line}");
    if let Some(path) = &args.results {
        use std::io::Write as _;
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)?;
        writeln!(file, "{line}")?;
    }

    // Three ways to fail, all of them exit 2, all of them named. The count
    // assertion is the one that had never been written down: the result line
    // reports an in-process counter, and nothing checked it against the book.
    let clearings = metrics.clearings.load(Ordering::Relaxed);
    let clearings_total = metrics.clearings_total.load(Ordering::Relaxed);
    let mut failures: Vec<String> = Vec::new();
    if !reconciled {
        failures.push(format!("THE ORACLE BROKE — {verdict}"));
    }
    if transactions_in_book as u64 != clearings_total {
        failures.push(format!(
            "the book holds {transactions_in_book} transactions and the harness \
             committed {clearings_total} clearings across the whole run (of which \
             {clearings} fell inside the measurement window) — one of the two is \
             fiction, and until this line existed nothing had ever compared them"
        ));
    }
    // A run that committed nothing reconciles trivially: ten checks over an
    // empty book are ten zeros. Every green verdict in the transcript would
    // otherwise be consistent with a harness that never wrote anything.
    // `--corrupt` is exempt because it is on its way to red on purpose, and
    // `--duplicate-key` because committing nothing IS its expected result.
    if clearings_total == 0 && !args.corrupt && !args.duplicate_key {
        failures.push("the run committed ZERO clearings: ten zeros over an empty book \
                       is not evidence of anything"
            .to_owned());
    }
    // The duplicate-key configuration exists to pin a DESIGN FINDING, so it
    // asserts the finding rather than merely recording it: two members of one
    // batch carrying one idempotency key must abort the whole batch on
    // `uq_txn__one_per_event` (23505). If that ever stops happening — a
    // schema change, a statement change — the configuration goes red and
    // says so, instead of quietly passing with a different outcome.
    if args.duplicate_key && !extra.contains("\"poison_raised\":\"sqlstate_23505\"") {
        failures.push(
            "--duplicate-key did NOT raise 23505: the batch was expected to abort on \
             uq_txn__one_per_event (migrations/00001_baseline.sql:581) because one \
             claimed event joins two members and `txn` then attempts two transactions \
             against it. Something changed; the finding needs re-deriving."
                .to_owned(),
        );
    }
    let code = if failures.is_empty() { 0 } else { 2 };
    for failure in &failures {
        eprintln!("spike022: {failure}");
    }

    pool.close().await;
    if args.keep_database {
        eprintln!("kept {db_url}");
    } else {
        setup::drop_book(&args.label).await?;
    }
    Ok(code)
}

/// Sections A, B, C and E. A single accumulator forms batches — on `--batch`
/// members or `--window-ms`, whichever comes first — and `--writers`
/// dispatchers run them. Both load shapes share this; only the arrival
/// process differs.
async fn drive_load(
    pool: &PgPool,
    statements: &Arc<Statements>,
    args: &Arc<Args>,
    accounts: &Arc<Vec<TenantAccounts>>,
    metrics: &Arc<Metrics>,
    writers: usize,
) -> Fallible<(Duration, f64, String)> {
    let duration = parse_duration(&args.duration)?;
    let warmup = parse_duration(&args.warmup)?;
    let queue = Arc::new(Queue {
        items: Mutex::new(VecDeque::new()),
        notify: tokio::sync::Notify::new(),
    });
    let stop = Arc::new(AtomicBool::new(false));
    // A batch travels with the PERMIT that entitled it to exist, and the
    // permit is dropped by the writer only after the statement has committed
    // and its members have been answered. Under `--dispatch window` there is
    // no permit and the channel is the unbounded queue it always was.
    type Dispatched = (Vec<Pending>, Option<tokio::sync::OwnedSemaphorePermit>);
    let (batches_out, batches_in) = tokio::sync::mpsc::unbounded_channel::<Dispatched>();
    let batches_in = Arc::new(tokio::sync::Mutex::new(batches_in));
    // One permit per concurrent database transaction. This is the whole of
    // dispatch-on-completion: with every permit held there is no free writer,
    // the accumulator stops forming batches, and the arrivals it is not
    // draining are exactly the members the NEXT batch coalesces.
    let free_writers = Arc::new(tokio::sync::Semaphore::new(writers));

    // -- arrivals
    let mut producers = Vec::new();
    match args.offered_rate {
        None => {
            // CLOSED loop: one outstanding request per producer, the next
            // one issued only when the last completes.
            for p in 0..args.concurrency {
                producers.push(tokio::spawn(request_stream(
                    p,
                    queue.clone(),
                    stop.clone(),
                    accounts.clone(),
                    args.clone(),
                    metrics.clone(),
                    None,
                )));
            }
        }
        Some(rate) => {
            // OPEN loop: a Poisson arrival process of mean `rate` per second
            // (exponential inter-arrivals — the standard model, and the one
            // that produces real queueing rather than a metronome's
            // artificial smoothness). Nothing here waits for a completion.
            //
            // Realized as the SUPERPOSITION of `arrival_streams(rate)`
            // independent processes of rate `rate / n`, which is the same
            // process exactly, and is what lifts the load generator's own
            // 1ms-tick ceiling off the high-rate cells. See `arrival_streams`.
            let streams = arrival_streams(rate);
            for p in 0..streams {
                producers.push(tokio::spawn(request_stream(
                    p,
                    queue.clone(),
                    stop.clone(),
                    accounts.clone(),
                    args.clone(),
                    metrics.clone(),
                    Some(rate / streams as f64),
                )));
            }
        }
    }

    // -- the accumulator
    let accumulator = {
        let queue = queue.clone();
        let stop = stop.clone();
        let args = args.clone();
        let free_writers = free_writers.clone();
        let window = Duration::from_millis(args.window_ms);
        let on_completion = args.dispatch == Dispatch::OnCompletion;
        tokio::spawn(async move {
            loop {
                let mut batch: Vec<Pending> = Vec::new();
                loop {
                    // THE WAKEUP IS ARMED BEFORE THE QUEUE IS READ, and that
                    // order is the whole point. `Notify::notify_waiters`
                    // stores no permit: it wakes whoever is registered at the
                    // instant it is called and nobody else. Constructing the
                    // future after the `take` — which is what a bare
                    // `select!` on `notified()` does — leaves a gap in which
                    // an arrival's notification is dropped on the floor, and
                    // the accumulator then sits out the 1ms fallback sleep
                    // (tokio's timer wheel ticks at 1ms, so 200us and 1ms are
                    // the same sleep). At the 20-50 TPS this section exists
                    // to measure, that lost tick IS the latency being
                    // reported: it is the same order as the whole clearing.
                    let notified = queue.notify.notified();
                    tokio::pin!(notified);
                    notified.as_mut().enable();
                    queue.take(&mut batch, 1, None);
                    if !batch.is_empty() {
                        break;
                    }
                    if stop.load(Ordering::Relaxed) && queue.is_empty() {
                        return;
                    }
                    tokio::select! {
                        _ = notified.as_mut() => {}
                        _ = tokio::time::sleep(Duration::from_millis(1)) => {}
                    }
                }
                let tenant = if args.tenant_homogeneous {
                    Some(batch[0].tenant_ix)
                } else {
                    None
                };
                let permit = if on_completion {
                    // THE ONLY WAIT IN THIS POLICY, and it is not a timer: it
                    // is the wait for a writer to become free, which at low
                    // offered load is over before it starts. Whatever arrives
                    // while it lasts is queued, and the `take` below — the
                    // very next statement — collects exactly that. Nothing
                    // here is timed, sized or tuned.
                    match free_writers.clone().acquire_owned().await {
                        Ok(permit) => Some(permit),
                        Err(_) => return,
                    }
                } else {
                    // The window is a REAL window: it starts when the first
                    // member of this batch arrives, and it expires whether or
                    // not the batch filled. That is the whole point of the
                    // open loop — at 20-50 TPS a 25-member window collects
                    // one or two members and dispatches anyway, and the fill
                    // rate that falls out of that is the number ADR-0002
                    // actually needs.
                    let deadline = Instant::now() + window;
                    while batch.len() < args.batch {
                        // Armed before the read, for the reason above.
                        let notified = queue.notify.notified();
                        tokio::pin!(notified);
                        notified.as_mut().enable();
                        queue.take(&mut batch, args.batch, tenant);
                        if batch.len() >= args.batch || Instant::now() >= deadline {
                            break;
                        }
                        if stop.load(Ordering::Relaxed) && queue.is_empty() {
                            break;
                        }
                        tokio::select! {
                            _ = notified.as_mut() => {}
                            _ = tokio::time::sleep_until(
                                (Instant::now() + Duration::from_micros(200)).min(deadline).into(),
                            ) => {}
                        }
                    }
                    None
                };
                if on_completion {
                    // `--batch` as a SAFETY CEILING and nothing else. One
                    // non-blocking sweep of the queue: whatever is there is
                    // taken, whatever is not is not waited for.
                    queue.take(&mut batch, args.batch, tenant);
                }
                if batches_out.send((batch, permit)).is_err() {
                    return;
                }
            }
        })
    };

    // -- the writers
    let mut dispatchers = Vec::new();
    for w in 0..writers {
        let stop = stop.clone();
        let pool = pool.clone();
        let statements = statements.clone();
        let args = args.clone();
        let metrics = metrics.clone();
        let batches_in = batches_in.clone();
        // TWO flags, because they are two mechanisms. `reverse_legs` changes
        // what the CALLER presents (single path, real hazard);
        // `descending_statement` changes which STATEMENT the writer runs
        // (batched path, a model). The old single `reversed` flag meant both
        // at once, which is how an inert reversal came to be reported as the
        // cause of somebody else's deadlocks. Keyed on the writer, not the
        // request: it is lock order under test.
        let odd = w % 2 == 1;
        let reverse_legs = odd && args.lock_order_hazard == LockOrderHazard::CallerLegs;
        let descending_statement =
            odd && args.lock_order_hazard == LockOrderHazard::DescendingModel;
        dispatchers.push(tokio::spawn(async move {
            loop {
                let (batch, permit) = {
                    let mut rx = batches_in.lock().await;
                    match rx.recv().await {
                        Some(dispatched) => dispatched,
                        None => return,
                    }
                };
                if batch.is_empty() {
                    drop(permit);
                    if stop.load(Ordering::Relaxed) {
                        return;
                    }
                    continue;
                }
                let dispatched_at = Instant::now();
                let mut waited_us = 0u64;
                let mut members: Vec<Member> = Vec::with_capacity(batch.len());
                for pending in &batch {
                    waited_us += dispatched_at
                        .saturating_duration_since(pending.enqueued)
                        .as_micros() as u64;
                }
                for pending in &batch {
                    let mut legs = pending.member.legs.clone();
                    if reverse_legs {
                        legs.reverse();
                    }
                    members.push(Member {
                        tenant: pending.member.tenant.clone(),
                        key: pending.member.key.clone(),
                        legs,
                        hash: pending.member.hash.clone(),
                        payload: pending.member.payload.clone(),
                    });
                }
                metrics.add(&metrics.statements, 1);
                metrics.add(&metrics.members_dispatched, members.len() as u64);
                metrics.add(&metrics.window_wait_us, waited_us);
                match dispatch(
                    &pool,
                    &statements,
                    &args,
                    &members,
                    w as i32,
                    reverse_legs,
                    descending_statement,
                )
                .await
                {
                    Ok(outcome) => {
                        metrics.note_commits(outcome.committed as u64);
                        metrics.add(&metrics.refused, outcome.refused as u64);
                        metrics.add(&metrics.replayed, outcome.replayed as u64);
                    }
                    Err(error) => metrics.note_error(&error),
                }
                let completed = Instant::now();
                for pending in batch {
                    metrics.note_latency(completed.saturating_duration_since(pending.enqueued));
                    let _ = pending.reply.send(());
                }
                // LAST, and it is load-bearing: releasing the permit is what
                // lets the accumulator form the next batch, so the next batch
                // contains precisely what arrived while this statement ran.
                // Dropped earlier, the policy would be `--window-ms 0`.
                drop(permit);
            }
        }));
    }

    // -- the clock. Warmup runs the same code and is discarded whole.
    if !warmup.is_zero() {
        tokio::time::sleep(warmup).await;
    }
    let cpu_window_before = cpu_jiffies();
    metrics.measuring.store(true, Ordering::Relaxed);
    let started = Instant::now();
    tokio::time::sleep(duration).await;
    // Counters are read at the DEADLINE, not after the drain. In deadlocking
    // configurations the drain was over 10% of the total, and charging its
    // clearings to a window that had already closed inflated the rate.
    metrics.measuring.store(false, Ordering::Relaxed);
    let elapsed = started.elapsed();
    let cpu_window_pct = busy_pct_since(cpu_window_before);

    stop.store(true, Ordering::Relaxed);
    queue.notify.notify_waiters();
    for producer in producers {
        let _ = tokio::time::timeout(Duration::from_secs(30), producer).await;
    }
    queue.notify.notify_waiters();
    let _ = tokio::time::timeout(Duration::from_secs(30), accumulator).await;
    for dispatcher in dispatchers {
        let _ = tokio::time::timeout(Duration::from_secs(30), dispatcher).await;
    }
    Ok((elapsed, cpu_window_pct, String::new()))
}

/// HOW MANY ARRIVAL STREAMS ONE OFFERED RATE IS SPLIT ACROSS, and this is a
/// correction to a measurement that was quietly impossible.
///
/// Tokio's timer wheel ticks at 1ms. A single arrival stream sleeping the
/// exponential gap therefore cannot emit faster than about one arrival per
/// tick, and it does not report that it failed — `--offered-rate 2000`
/// measured 710 ARRIVALS per second, so the "achieved rate" was the
/// PRODUCER's ceiling wearing the database's name, and every cell at 800 and
/// 2000 TPS would have compared four dispatch policies against one shared
/// artefact of the load generator.
///
/// The superposition of `n` independent Poisson processes of rate `r/n` is a
/// Poisson process of rate `r` — exactly, not approximately — so splitting
/// the offered load across enough streams that each one's mean gap is
/// comfortably above the tick keeps the arrival model intact and removes the
/// ceiling. Each stream also schedules against an ABSOLUTE accumulated
/// deadline rather than sleeping a fresh gap, so a tick's worth of rounding
/// is repaid on the next arrival instead of compounding into a rate error.
fn arrival_streams(rate: f64) -> usize {
    // One stream per 250 arrivals/s: a 4ms mean gap against a 1ms tick.
    ((rate / 250.0).ceil() as usize).clamp(1, 64)
}

/// One arrival stream. `rate` absent is the closed loop — the next request
/// waits on the last one's reply; `rate` present is the open loop — arrivals
/// are exponentially spaced and nothing waits.
async fn request_stream(
    p: usize,
    queue: Arc<Queue>,
    stop: Arc<AtomicBool>,
    accounts: Arc<Vec<TenantAccounts>>,
    args: Arc<Args>,
    metrics: Arc<Metrics>,
    rate: Option<f64>,
) {
    let mut rng = 0x9E37_79B9_7F4A_7C15u64 ^ ((p as u64 + 1) << 32) ^ (p as u64 + 7);
    let mut n = 0u64;
    // The open loop's schedule, kept as an absolute instant. See
    // `arrival_streams`: sleeping a fresh gap each time turns the timer's
    // rounding into a systematic rate deficit; sleeping until an accumulated
    // deadline does not.
    let mut next_arrival = Instant::now();
    while !stop.load(Ordering::Relaxed) {
        let tenant_ix = draw_tenant(&mut rng, accounts.len(), args.whale);
        let company = (next(&mut rng) as usize) % args.companies.max(1);
        let postings = clearing(&accounts[tenant_ix], company, None);
        let member = Member::new(
            accounts[tenant_ix].tenant.clone(),
            format!("s022-{p}-{n}"),
            &postings,
        );
        n += 1;
        let (reply, wait) = tokio::sync::oneshot::channel();
        metrics.add(&metrics.arrivals, 1);
        queue.push(Pending {
            tenant_ix,
            member,
            enqueued: Instant::now(),
            reply,
        });
        match rate {
            None => {
                if wait.await.is_err() {
                    break;
                }
            }
            Some(rate) => {
                // Exponential inter-arrival: -ln(U) / rate, added to the
                // stream's own schedule rather than to "now".
                drop(wait);
                let u = next_unit(&mut rng).max(1e-6);
                let gap = -u.ln() / rate.max(1e-9);
                next_arrival += Duration::from_secs_f64(gap.min(1.0));
                let now = Instant::now();
                if next_arrival <= now {
                    // Behind schedule: emit at once, and do not let the
                    // arrears accumulate without bound either — a stream
                    // that has fallen a whole second behind would otherwise
                    // spend the rest of the run emitting flat out.
                    if now.saturating_duration_since(next_arrival) > Duration::from_millis(100) {
                        next_arrival = now;
                    }
                    tokio::task::yield_now().await;
                } else {
                    tokio::time::sleep_until(next_arrival.into()).await;
                }
            }
        }
    }
}

/// Section D.1 — the poison pill. One batch of `--batch` members, one of
/// which names an account that does not exist. `--duplicate-key` replaces
/// that with a different injury: two members carrying the SAME idempotency
/// key.
async fn poison(
    pool: &PgPool,
    statements: &Arc<Statements>,
    args: &Arc<Args>,
    accounts: &Arc<Vec<TenantAccounts>>,
    metrics: &Arc<Metrics>,
) -> Fallible<(Duration, String)> {
    metrics.measuring.store(true, Ordering::Relaxed);
    let guilty = args.batch / 2;
    let phantom = Uuid::new_v4();
    let mut members = Vec::with_capacity(args.batch);
    for m in 0..args.batch {
        let injured = m == guilty;
        let postings = clearing(
            &accounts[0],
            m,
            if injured && !args.duplicate_key {
                Some(phantom)
            } else {
                None
            },
        );
        // The duplicate-key injury: member `guilty` carries member 0's key.
        // `ON CONFLICT DO NOTHING` tolerates a self-conflicting row and
        // claims ONE event; `proceeding` then joins that one claimed row to
        // BOTH members on (tenant, key), so `txn` attempts two transactions
        // against one event_id and `uq_txn__one_per_event` raises 23505. The
        // whole batch aborts, as an unmapped storage error.
        let key = if injured && args.duplicate_key {
            "s022-poison-0".to_owned()
        } else {
            format!("s022-poison-{m}")
        };
        members.push(Member::new(accounts[0].tenant.clone(), key, &postings));
    }
    let started = Instant::now();
    let outcome = dispatch(pool, statements, args, &members, 0, false, false).await;
    let elapsed = started.elapsed();
    let mut raised = "none".to_owned();
    let outcome = match outcome {
        Ok(outcome) => outcome,
        Err(error) => {
            raised = error_class(&error);
            metrics.note_error(&error);
            BatchOutcome {
                committed: 0,
                refused: 0,
                replayed: 0,
                retried_singly: 0,
            }
        }
    };
    metrics.add(&metrics.statements, 1);
    metrics.add(&metrics.members_dispatched, members.len() as u64);
    metrics.note_commits(outcome.committed as u64);
    metrics.add(&metrics.refused, outcome.refused as u64);
    metrics.add(&metrics.replayed, outcome.replayed as u64);

    let (events, txns, entries): (i64, i64, i64) = sqlx::query_as(
        "SELECT (SELECT count(*) FROM ledger_events),
                (SELECT count(*) FROM ledger_transactions),
                (SELECT count(*) FROM ledger_entries)",
    )
    .fetch_one(pool)
    .await?;
    // The event count is the gate's evidence. With the gate ABOVE the claim
    // a refused member leaves NO event row, so its idempotency key is still
    // free and its retry is a fresh request rather than a replay of a
    // refusal. With the gate below it — the shape this spike started with —
    // `events` would come back at `--batch` and the key would be burned.
    eprintln!(
        "poison: injury {} at ord {}; committed {} refused {} replayed {} retried-singly {}; \
         statement raised {raised}; book holds {events} events, {txns} transactions, \
         {entries} entries",
        if args.duplicate_key {
            "duplicate idempotency key"
        } else {
            "phantom account"
        },
        guilty + 1,
        outcome.committed,
        outcome.refused,
        outcome.replayed,
        outcome.retried_singly
    );
    metrics.measuring.store(false, Ordering::Relaxed);
    Ok((
        elapsed,
        format!(
            ",\"poison_injury\":\"{injury}\",\"poison_guilty_ord\":{ord},\
\"poison_committed\":{committed},\"poison_refused\":{refused},\
\"poison_retried_singly\":{retried},\"poison_raised\":\"{raised}\",\
\"events\":{events},\"transactions\":{txns},\"entries\":{entries},\
\"statement_ms\":{ms:.3}",
            injury = if args.duplicate_key {
                "duplicate_key"
            } else {
                "phantom_account"
            },
            ord = guilty + 1,
            committed = outcome.committed,
            refused = outcome.refused,
            retried = outcome.retried_singly,
            ms = elapsed.as_secs_f64() * 1000.0
        ),
    ))
}

/// Section D.2 — head-of-line blocking. An uncommitted claim on key K in a
/// second session; the batch containing K waits on the index tuple, and the
/// innocent members wait with it. A cost to state, not a bug to fix.
async fn head_of_line(
    pool: &PgPool,
    statements: &Arc<Statements>,
    args: &Arc<Args>,
    accounts: &Arc<Vec<TenantAccounts>>,
    metrics: &Arc<Metrics>,
    db_url: &str,
) -> Fallible<(Duration, String)> {
    metrics.measuring.store(true, Ordering::Relaxed);
    let held_key = "s022-hol-0".to_owned();
    let tenant = accounts[0].tenant.clone();
    let rival_pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .connect(db_url)
        .await?;
    let mut rival = begin(&rival_pool).await?;
    sqlx::query(
        "INSERT INTO ledger_events
                (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
         VALUES ($1, 'posting', 'api', $2, decode('00','hex'), '{}'::jsonb, now())",
    )
    .bind(&tenant)
    .bind(&held_key)
    .execute(&mut *rival)
    .await?;

    let mut members = Vec::with_capacity(args.batch);
    for m in 0..args.batch {
        let postings = clearing(&accounts[0], m, None);
        members.push(Member::new(
            tenant.clone(),
            if m == 0 {
                held_key.clone()
            } else {
                format!("s022-hol-{m}")
            },
            &postings,
        ));
    }

    let hold = Duration::from_millis(args.hold_ms);
    let started = Instant::now();
    let blocked = {
        let pool = pool.clone();
        let statements = statements.clone();
        let args = args.clone();
        tokio::spawn(
            async move { dispatch(&pool, &statements, &args, &members, 0, false, false).await },
        )
    };
    tokio::time::sleep(hold).await;
    // The rival ABANDONS its claim, so the book it leaves behind is the one
    // the batch wrote and the oracle's ten zeros still bind.
    rival.rollback().await?;
    let outcome = blocked.await.map_err(|e| e.to_string())?;
    let elapsed = started.elapsed();
    rival_pool.close().await;

    let (committed, refused) = match outcome {
        Ok(outcome) => (outcome.committed, outcome.refused),
        Err(error) => {
            metrics.note_error(&error);
            (0, 0)
        }
    };
    metrics.add(&metrics.statements, 1);
    metrics.add(&metrics.members_dispatched, args.batch as u64);
    metrics.note_commits(committed as u64);
    metrics.add(&metrics.refused, refused as u64);
    eprintln!(
        "head-of-line: held key {held_key} uncommitted for {}ms; the batch of {} took {:.0}ms \
         and committed {committed}",
        args.hold_ms,
        args.batch,
        elapsed.as_secs_f64() * 1000.0
    );
    metrics.measuring.store(false, Ordering::Relaxed);
    Ok((
        elapsed,
        format!(
            ",\"hold_ms\":{},\"stall_ms\":{:.1},\"hol_committed\":{committed}",
            args.hold_ms,
            elapsed.as_secs_f64() * 1000.0
        ),
    ))
}
