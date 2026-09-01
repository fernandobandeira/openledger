//! M2's concurrency proof: N writers over HTTP against overlapping account
//! sets, with batching enabled, producing zero deadlocks, gapless per-stripe
//! sequences, balanced transactions and `SELECT * FROM reconciliation` at ten
//! zeros.
//!
//! **What this file can prove, and what it cannot.** What it ASSERTS is
//! green: the workload runs, nothing deadlocks, and the oracle reads ten
//! zeros. The red path is not committed and cannot be — an end-to-end test
//! cannot mutate the statement the binary ships, and a test that could would
//! be testing a statement nobody ships. So this is the same division M1 used
//! for the schema snapshot: **proved red before trusted green**, with the
//! injections recorded rather than automated.
//!
//! Recorded, then, and measured against this file before it was trusted:
//!
//! - **Delete the batched statement's `ORDER BY`** and
//!   `concurrent_writers_over_overlapping_account_subsets_deadlock_never`
//!   fails on every run — 95 to 218 deadlocks per run, reaching callers as
//!   500s. That is what pins the batched sort, and it is the sort
//!   [spike 018 §E](/spikes/018-batching-and-stripe-selection) measured at
//!   **833 deadlocks per 1,000 statements** without it.
//! - **Give the batched or the single statement an order two writers can
//!   DISAGREE about** — the spike's descending model, or any content-derived
//!   key such as `ORDER BY s.input, s.output, s.account_id` — and BOTH tests
//!   below fail.
//! - **Delete the SINGLE statement's `ORDER BY`** and the reversal test
//!   stays green. Stated plainly rather than papered over: with that clause
//!   gone the plan still happens to emit the contended rows in one agreed
//!   order, which is the spike harness's own recorded finding
//!   (`sql.rs`: *"removing the ORDER BY does not by itself make two writers
//!   disagree"*) and the reason its descending model exists. The mirror path
//!   is held here against a disagreeing order, not against the clause's
//!   absence — exactly as far as the spike's own reversal arm reaches.
//!
//! **Eight accounts is a floor, not a round number.** With two, the planner
//! emits a transaction's legs in account order for free and no deadlock can
//! be produced at all — which is exactly why "removing or inverting the
//! statement's `ORDER BY` survives the entire suite today" was true of a
//! suite built on two-account fixtures (the roadmap's M2 section, verbatim).
//! Eight here — six receivables and two house revenues — and each transaction
//! touches four of them, so what two concurrent statements hold is a
//! partially overlapping SUBSET rather than one shared set.
//!
//! **Both order sources, one arrangement each.** The planned path takes its
//! delta order from the arrays the writer binds; the mirror path
//! ([ADR-0016](/decisions/0016-pending-to-posted)'s server-derived reversal)
//! takes its order from a `GROUP BY` over the target's own entries. Two
//! different producers feeding one `ORDER BY`, and a regression in either was
//! invisible until this file existed.
//!
//! Each arrangement carries TWO tests, because it produces two properties
//! with two different diagnoses: no deadlock is a lock-ordering claim, and a
//! gapless counter is a numbering one. Held together under a name ending
//! `_deadlock_never`, a numbering regression sent whoever read the failure
//! into the `ORDER BY`.

use std::collections::BTreeSet;

use uuid::Uuid;

use crate::support::{PostAnswer, TestBook, TestResult, assert_every_member_was_accepted};

/// How many receivables the load spreads over. Six of the eight accounts the
/// roadmap names as the floor, and the postings below touch TWO of them at a
/// time — a subset
/// rather than the whole set, so two concurrent statements can draw
/// genuinely different account sets rather than one shared set in a
/// different order.
const RECEIVABLES: usize = 6;

/// The house accounts the postings credit. Two, and EVERY transaction touches
/// both — `(n + leg) % REVENUES` over `leg ∈ {0,1}` is a permutation, not a
/// choice, so the revenue side is a constant set in a rotating order. That is
/// fine for a deadlock proof and stated rather than dressed up: the subset
/// that genuinely varies between concurrent statements is the receivable one
/// below, and it is the one doing the work.
const REVENUES: usize = 2;

/// How many writers run at once, and how many transactions each posts in
/// turn. The product is the load; the SHAPE is what does the work, and both
/// halves were arrived at by measurement rather than by taste.
///
/// **The writer count is the sensitive one.** It is well above the
/// dispatcher pool's depth (32, ADR-0018 §2), which is what keeps arrivals
/// queueing and batches forming — and the deeper the queue, the more
/// dispatchers hold batches at the same moment, whose coalesced account
/// subsets then differ. Measured against the removed batched `ORDER BY`:
/// the same 1,024 transactions offered as 64 writers × 16 rounds caught the
/// removal on one run in four, and as 128 × 8 caught it on four of four.
/// Concurrency, not volume, is what puts differing subsets in flight
/// together.
///
/// Sustained rather than one burst for the same reason. A single burst is
/// drained by a couple of dispatchers into a couple of maximal batches, each
/// coalescing down to the whole account set — and two statements over the
/// SAME set take its rows in the same order however that order is chosen.
const WRITERS: usize = 128;
const ROUNDS: usize = 8;

/// How many transactions the reversal proof puts on the book before undoing
/// them all at once. A reversal never rides a batch (ADR-0018 §4), so every
/// one of these is its own statement and the contention is between them —
/// there is no drain to spread over rounds.
const TARGETS: usize = 64;

/// The book this proof runs on: six owned customer receivables and two house
/// revenue accounts, all from the published chart. `customer_receivable` and
/// the two revenue types are chosen for the same reason
/// [`TestBook::fixture_accounts`] chooses them — none is a perimeter type, so
/// `chart_lint`'s perimeter_unattested error stays out of the oracle.
async fn a_book_of_eight_accounts(
    book: &TestBook,
) -> Result<(Vec<Uuid>, Vec<Uuid>), Box<dyn std::error::Error>> {
    let mut receivables = Vec::with_capacity(RECEIVABLES);
    for n in 0..RECEIVABLES {
        receivables.push(
            book.account(
                "t1",
                Some(&format!("co_{n}")),
                "customer_receivable",
                "asset",
                "debit",
                "per_shard",
            )
            .await?,
        );
    }
    let mut revenues = Vec::with_capacity(REVENUES);
    // One house account per (tenant, purpose, currency), so two revenue
    // accounts means two revenue TYPES.
    for purpose in ["fee_revenue", "interchange_revenue"] {
        revenues.push(
            book.account("t1", None, purpose, "revenue", "credit", "none")
                .await?,
        );
    }
    Ok((receivables, revenues))
}

/// The nth transaction of the run: two postings, over two of the six
/// receivables and both revenue accounts, the pair sliding with `n` —
/// `{r0,r2}`, `{r1,r3}`, `{r2,r4}` … so six overlapping pairs recur, each
/// sharing one receivable with two others. Two accounts of six rather than
/// all six is what leaves a coalesced batch a SUBSET to differ over —
/// **differing account subsets across concurrent statements** is the batched
/// path's lock-order hazard, and it needs nothing injected: which
/// receivables a batch happens to collect varies on its own.
///
/// **A caller cannot influence lock order on either path, so nothing here
/// tries to.** An earlier version of this fixture presented odd
/// transactions' postings in the opposite order and called that the single
/// path's own hazard; it was inert. `plan_append` coalesces into a
/// `BTreeMap`, `columns_for_deltas` emits that map's account order, and the
/// statement re-sorts on top of it — three normalizations, and the caller's
/// order is gone at the first. The rotating receivable subset above is what
/// puts differing lock orders in flight, and it is the only thing that does.
#[expect(
    clippy::indexing_slicing,
    reason = "both pools are built by a_book_of_eight_accounts to the very lengths the \
              moduli below are taken over, so neither index can leave its slice"
)]
fn a_transaction_touching_a_rotating_subset(
    n: usize,
    receivables: &[Uuid],
    revenues: &[Uuid],
) -> serde_json::Value {
    let postings: Vec<serde_json::Value> = [0_usize, 2]
        .into_iter()
        .enumerate()
        .map(|(leg, step)| {
            serde_json::json!({
                "source": revenues[(n + leg) % REVENUES],
                "destination": receivables[(n + step) % RECEIVABLES],
                "amount_minor": (100 + leg as i64).to_string(),
                "currency": "USD",
            })
        })
        .collect();
    serde_json::json!({
        "tenant_id": "t1",
        "idempotency_key": format!("charge-{n}"),
        "effective_at": "2026-08-27T12:00:00Z",
        "postings": postings,
    })
}

/// How many deadlocks PostgreSQL has resolved on THIS book's database. Scoped
/// by `datname`, so a sibling test's database cannot contribute one.
///
/// It is the belt, not the braces: `pg_stat_database` is flushed
/// asynchronously and can lag a moment behind, so the load-bearing signal is
/// the responses themselves — a deadlock victim's statement raises `40P01`,
/// which is a storage failure, which reaches its caller as a 500 (and on the
/// batched path reaches every member of the batch that way). A run with zero
/// 500s and a counter that has not moved is green on both.
async fn deadlocks_resolved_on_this_book(book: &TestBook) -> Result<i64, sqlx::Error> {
    let (deadlocks,): (i64,) = sqlx::query_as(
        "SELECT coalesce((SELECT deadlocks FROM pg_stat_database
                          WHERE datname = current_database()), 0)",
    )
    .fetch_one(&book.pool)
    .await?;
    Ok(deadlocks)
}

/// The transaction id each answer carries. Nothing is asserted here — the
/// statuses are [`assert_every_member_was_accepted`]'s, called from each
/// test's own assert phase, because on this file a 500 is exactly what a
/// deadlock victim looks like and that belongs where the reader can see it.
fn transactions_created_by(
    answers: &[PostAnswer],
) -> Result<Vec<Uuid>, Box<dyn std::error::Error>> {
    let mut created = Vec::with_capacity(answers.len());
    for (_, _, body) in answers {
        created.push(
            body.get("transaction_id")
                .and_then(serde_json::Value::as_str)
                .ok_or("an accepted write answered no transaction_id")?
                .parse()?,
        );
    }
    Ok(created)
}

/// One run of the sustained load, arranged: a fresh book of eight accounts,
/// the deadlock counter read BEFORE anything runs, and [`WRITERS`] clients
/// each posting its own [`ROUNDS`] transactions one after another, answered
/// in issue order. The nth transaction of client `c` is the
/// `(c * ROUNDS + r)`th of the run, so no two clients ever send the same
/// subset at the same moment.
///
/// Two tests hold two different properties of this one arrangement, and each
/// pays for its own run: a `#[tokio::test]` cannot share a served book with
/// its neighbour, and the alternative — one test asserting both — is what
/// sent a reader after a lock-ordering bug when a COUNTER regressed.
struct SustainedWriters {
    book: TestBook,
    deadlocks_before: i64,
    answers: Vec<PostAnswer>,
}

async fn a_book_under_sustained_concurrent_writers(
    name: &str,
) -> Result<SustainedWriters, Box<dyn std::error::Error>> {
    let book = TestBook::new(name).await?;
    let (receivables, revenues) = a_book_of_eight_accounts(&book).await?;
    let deadlocks_before = deadlocks_resolved_on_this_book(&book).await?;
    let handles: Vec<_> = (0..WRITERS)
        .map(|writer| {
            let bodies = (0..ROUNDS)
                .map(|round| {
                    a_transaction_touching_a_rotating_subset(
                        writer * ROUNDS + round,
                        &receivables,
                        &revenues,
                    )
                })
                .collect();
            book.spawn_client(bodies)
        })
        .collect();
    let mut answers = Vec::with_capacity(WRITERS * ROUNDS);
    for handle in handles {
        for answer in handle.await? {
            answers.push(answer?);
        }
    }
    Ok(SustainedWriters {
        book,
        deadlocks_before,
        answers,
    })
}

/// A batch that carried company really did form. It matters on this file
/// specifically: the batched statement's sort is the one the spike measured
/// at 833 deadlocks per 1,000 without it, against the single path's 294, so
/// a run that never filled a batch proves nothing about the clause it names.
async fn assert_the_load_actually_batched(book: &TestBook) -> TestResult {
    assert!(
        book.statements_that_carried_more_than_one_transaction()
            .await?
            > 0,
        "{WRITERS} writers over {ROUNDS} rounds filled no batch, so this ran the single \
         statement only"
    );
    Ok(())
}

#[tokio::test]
async fn concurrent_writers_over_overlapping_account_subsets_deadlock_never() -> TestResult {
    let SustainedWriters {
        book,
        deadlocks_before,
        answers,
    } = a_book_under_sustained_concurrent_writers("concurrency_planned").await?;

    assert_every_member_was_accepted(&answers);
    let created = transactions_created_by(&answers)?;
    assert_eq!(
        created.iter().collect::<BTreeSet<_>>().len(),
        WRITERS * ROUNDS,
        "two writers were handed one transaction"
    );
    assert_the_load_actually_batched(&book).await?;
    assert_eq!(
        deadlocks_resolved_on_this_book(&book).await? - deadlocks_before,
        0,
        "PostgreSQL resolved a deadlock on this book"
    );

    // The oracle, under the load. `unbalanced_transactions` is one of the
    // ten, so "balanced transactions" — M2's third acceptance criterion — is
    // held here rather than re-asked above it.
    book.assert_reconciled().await
}

#[tokio::test]
async fn every_stripes_counter_stays_gapless_under_concurrent_writers() -> TestResult {
    // The same load, a different property — and a different diagnosis. A
    // counter that skips is a numbering bug, not a lock-ordering one, and
    // asserting it under a name ending `_deadlock_never` sent whoever read
    // the failure to the wrong statement.
    let SustainedWriters { book, answers, .. } =
        a_book_under_sustained_concurrent_writers("concurrency_gapless").await?;

    assert_every_member_was_accepted(&answers);
    assert_the_load_actually_batched(&book).await?;
    book.assert_every_counter_is_gapless_from_one().await?;

    book.assert_reconciled().await
}

/// One run of the mirror load, arranged: [`TARGETS`] ordinary transactions on
/// the book, then a reversal of every one of them, posted at once. A reversal
/// carries NO postings — the server derives the mirror from the target's own
/// entries, so this statement takes its lock order from a `GROUP BY` rather
/// than from the arrays a writer bound (ADR-0016) — and reversals never ride
/// a batch (ADR-0018 §4), so every one of these is its own statement
/// contending with the others.
struct ReversedBook {
    book: TestBook,
    deadlocks_before: i64,
    answers: Vec<PostAnswer>,
}

async fn a_book_whose_every_transaction_was_reversed_at_once(
    name: &str,
) -> Result<ReversedBook, Box<dyn std::error::Error>> {
    let book = TestBook::new(name).await?;
    let (receivables, revenues) = a_book_of_eight_accounts(&book).await?;
    let posted = book
        .post_all_at_once(
            &(0..TARGETS)
                .map(|n| a_transaction_touching_a_rotating_subset(n, &receivables, &revenues))
                .collect::<Vec<_>>(),
        )
        .await?;
    assert_every_member_was_accepted(&posted);
    let targets = transactions_created_by(&posted)?;
    let deadlocks_before = deadlocks_resolved_on_this_book(&book).await?;
    let undos: Vec<serde_json::Value> = targets
        .iter()
        .enumerate()
        .map(|(n, target)| {
            serde_json::json!({
                "tenant_id": "t1",
                "idempotency_key": format!("undo-{n}"),
                "effective_at": "2026-08-29T00:00:00Z",
                "reverses_id": target,
            })
        })
        .collect();
    let answers = book.post_all_at_once(&undos).await?;
    Ok(ReversedBook {
        book,
        deadlocks_before,
        answers,
    })
}

#[tokio::test]
async fn concurrent_reversals_of_overlapping_transactions_deadlock_never() -> TestResult {
    let ReversedBook {
        book,
        deadlocks_before,
        answers,
    } = a_book_whose_every_transaction_was_reversed_at_once("concurrency_mirror").await?;

    assert_every_member_was_accepted(&answers);
    let reversals = transactions_created_by(&answers)?;
    assert_eq!(
        reversals.iter().collect::<BTreeSet<_>>().len(),
        TARGETS,
        "two reversals were handed one transaction"
    );
    assert_eq!(
        deadlocks_resolved_on_this_book(&book).await? - deadlocks_before,
        0,
        "PostgreSQL resolved a deadlock while the mirrors contended"
    );
    // Every target reversed exactly once, and every ACCOUNT back where it
    // started: a mirror moves the cache back, so a fully reversed book holds
    // no position anywhere. Per account rather than book-wide — a book-wide
    // sum is zero on any balanced book and would assert nothing.
    let (still_holding,): (i64,) = sqlx::query_as(
        "SELECT count(*) FROM (
             SELECT account_id FROM ledger_account_balances WHERE tenant_id = 't1'
             GROUP BY account_id HAVING sum(input) <> sum(output)
         ) AS holding",
    )
    .fetch_one(&book.pool)
    .await?;
    assert_eq!(
        still_holding, 0,
        "account(s) still hold a position after every transaction was reversed"
    );

    book.assert_reconciled().await
}

#[tokio::test]
async fn every_stripes_counter_stays_gapless_under_concurrent_reversals() -> TestResult {
    // The mirror path's own counters. A mirror is numbered by the STATEMENT's
    // window function walking back from each stripe's counter, which is a
    // different producer from the planned path's Rust offsets — so its
    // gaplessness is a separate property, and it is held under its own name
    // rather than as a line inside the deadlock proof.
    let ReversedBook { book, answers, .. } =
        a_book_whose_every_transaction_was_reversed_at_once("concurrency_mirror_gapless").await?;

    assert_every_member_was_accepted(&answers);
    book.assert_every_counter_is_gapless_from_one().await?;

    book.assert_reconciled().await
}
