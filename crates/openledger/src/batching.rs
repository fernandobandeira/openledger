//! The accumulator: postings from independent requests combined into one
//! statement when there are any to combine, and never waiting for company
//! that has not arrived (ADR-0018 §2).
//!
//! It lives here, in the binary, rather than in the core — which is also what
//! keeps ADR-0002's *"the core needs no scheduler, ever"* true instead of
//! reinterpreted. What is here is the
//! MACHINERY, the half that needs a runtime: the queue, the dispatcher pool,
//! the permit each dispatcher holds, the task. The use-case it calls —
//! plan each member, run the bracket, resolve each member's outcome, answer
//! each caller — is `LedgerService::post_batch`, in the core beside the
//! single-command writer and the fake-repository tests that hold every
//! branching property of both (ADR-0018 §5). This module calls that one
//! method and nothing else.
//!
//! **The policy is dispatch on completion, and there is no window to size.**
//! A dispatcher takes whatever is queued right now, posts it, and on return
//! takes whatever accumulated meanwhile. At ADR-0002's derived load nothing
//! is ever queued, every batch has one member, and latency is within 0.7 ms
//! of not batching at all; at saturation the queue forms batches by itself
//! and the batch grows exactly as fast as the database falls behind. A fixed
//! window was measured and refused: at 50 TPS offered, a 25 ms window costs
//! 10× the median latency to collect 2.26 members.
//!
//! **The mechanism is backpressure, not a zero timer** — and that distinction
//! is reasoned about rather than measured, which is how ADR-0018 §2 states it
//! too. There is no hand-off left in the shipped design to benchmark, so
//! measuring the alternative would mean building a writer we deliberately did
//! not build. The reasoning: setting the window to zero removes the wait but
//! not the buffer. A collector still forms batches and still hands them off to
//! a dispatching stage, and if that hand-off is unbounded nothing pushes back
//! on the collector — so under a backlog it forms a batch the instant one
//! member is available and the queue simply migrates into the channel as a
//! long run of one-member batches. Coalescing never receives anything to
//! coalesce, because the coalesce happens after the point where the queue used
//! to be. What produces the policy is removing the hand-off entirely: here a
//! batch is formed by the dispatcher that is about to post it, inside the loop
//! body that owns it until the commit returns, so formation, statement and
//! answer are one turn of one dispatcher. A backlog has nowhere to accumulate
//! except the queue the next drain reads, the next batch is exactly as large
//! as the database is behind, and the number of statements in flight is the
//! pool depth by construction.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex, PoisonError};

use ledger::{
    AccountOpened, ClosePeriod, ClosePeriodError, DefinePeriod, DefinePeriodError, Ledger,
    LedgerService, OpenAccount, OpenAccountError, PeriodClosed, PeriodDefined, PostTransaction,
    Posted, Repository, TransactionStatus, WriteError,
};
use tokio::sync::{Notify, oneshot};
use tokio::task::JoinSet;

/// How many dispatchers the pool runs — and, because a dispatcher owns one
/// stripe affinity for its lifetime, how many stripes a hot account's balance
/// row can be spread over: **a pool of N reaches at most N stripes, however
/// many an account declares**.
///
/// **This one number serves two masters and they pull opposite ways.** A
/// shallow pool caps striping: 8 dispatchers reach 8 stripes and measure
/// 3.42× against 32 dispatchers' 4.31×. But the dispatch policy self-limits
/// to exactly this many concurrent statements, so above the unbatched write
/// ceiling (~1,940 clearings/s) a deep pool means that many concurrent
/// BATCHED statements on the same contended rows, where 32 collapses —
/// 1,964/s at p50 185 ms against 8's 1,999/s at 25 ms.
///
/// **32, because a shallow pool pays its 21% striping penalty on every
/// posting forever and a deep one pays only above ~39× the peak ADR-0002
/// derives for this ledger.** An operator who genuinely sustains load near
/// the ceiling should lower it, and should know what that costs: every
/// posting, forever, on fewer stripes. Lowering it is also the only thing
/// that makes raising an account's `stripe_count` past this number do
/// anything — `stripe_count` above the pool depth is inert.
///
/// **The saturation half of that trade is borrowed, and this binary is
/// single-threaded.** Every figure above comes from the spike's harness, which
/// runs a multi-threaded runtime; `main` builds `new_current_thread()` and the
/// workspace `tokio` does not enable `rt-multi-thread`, so these 32 dispatchers
/// are I/O-concurrent on ONE OS thread. That is sound — they spend their time
/// awaiting round trips — and striping is untouched, since it needs only that
/// concurrent writers hold distinct indices. But serialization, hashing and
/// payload rendering share a single core here, so this binary's own ceiling is
/// lower than the harness's and has never been measured (ADR-0018, "what it
/// costs").
///
/// It is also one connection each: a dispatcher without a connection cannot
/// write, so this number and `db`'s pool size are one knob and move together.
pub const DISPATCHERS: usize = 32;

// ...and "move together" is this line, not the sentence above it. A
// dispatcher without a connection does not fail fast: it forms its batch,
// blocks in `begin` for the full acquire timeout — fifteen seconds, `db`'s
// ACQUIRE_TIMEOUT — and then 500s every member it was carrying, while the
// members that were going to coalesce with them keep arriving. Both
// constants were private to their own crate and coupled only by prose in two
// doc comments; raising this one to 64 compiled clean and produced exactly
// that failure at run time. Now it fails the build.
const _: () = assert!(
    DISPATCHERS + db::CONNECTIONS_ABOVE_THE_WRITERS as usize <= db::POOL_CONNECTIONS as usize,
    "the writer pool has no connection for every dispatcher, plus db's headroom for the \
     startup schema gate: raise db::POOL_CONNECTIONS or lower DISPATCHERS"
);

/// The most members one statement may carry. **A ceiling, not a target**:
/// nothing waits to reach it, and below saturation no batch comes near it.
/// It exists so that a long stall cannot assemble an unbounded statement out
/// of the backlog behind it — the one thing dispatch-on-completion still owes
/// a bound. 25 is the size every measured configuration ran with.
const MAX_BATCH_MEMBERS: usize = 25;

/// Whether a command may ride a SHARED statement (ADR-0018 §4).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Batchability {
    /// A plain posted posting: it may share a statement with other callers'
    /// plain posted postings.
    RidesWithOthers,
    /// A pending transaction, a resolution or a reversal. It keeps the
    /// single statement it has today, which carries the supersede gate, the
    /// server-derived mirror and the pending rule — none of which the batched
    /// statement has: that one writes the literal status `'posted'` and
    /// would turn a claim about money into money moved, with the pointer
    /// dropped. The adapter refuses a misrouted member outright; this is what
    /// makes sure it never has to.
    PostsAlone,
}

/// Which of the two a command is. Pure, and the whole of the routing rule:
/// the accumulator routes rather than refuses, so nothing is rejected for
/// being unbatchable — a command that posts alone becomes a batch of one,
/// and a batch of one takes the single statement it was always going to.
fn batchability_of(command: &PostTransaction) -> Batchability {
    if command.resolves_id().is_some()
        || command.reverses_id().is_some()
        || command.status() == TransactionStatus::Pending
    {
        return Batchability::PostsAlone;
    }
    Batchability::RidesWithOthers
}

/// One caller, waiting: the command it wants posted and the channel its own
/// answer goes back down.
struct Submission {
    command: PostTransaction,
    answer: oneshot::Sender<Result<Posted, WriteError>>,
}

/// The arrivals that have not been taken by a dispatcher yet. Nothing here is
/// timed: the queue is read, never waited on with a deadline, and an empty
/// read is an empty batch.
#[derive(Default)]
struct Queue {
    waiting: Mutex<VecDeque<Submission>>,
    arrived: Notify,
}

impl Queue {
    /// Hand a command over and wake one dispatcher. `notify_one` rather than
    /// waking the pool: an arrival needs one writer, and waking 32 tasks to
    /// have 31 find an empty queue is the low-load cost this policy exists to
    /// not pay.
    fn push(&self, submission: Submission) {
        self.waiting
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push_back(submission);
        self.arrived.notify_one();
    }

    /// Take whatever is waiting RIGHT NOW — never more than the ceiling, and
    /// never anything the head cannot share a statement with. This is the
    /// whole of dispatch-on-completion: no deadline, no target, and an empty
    /// queue yields an empty batch rather than a wait.
    ///
    /// **The head decides the batch**: a command that posts alone travels
    /// alone, and a plain posting collects the company
    /// [`rides_with_the_batch`] admits, stepping over everyone else rather
    /// than stopping at them.
    fn take_whatever_is_waiting(&self, ceiling: usize) -> Vec<Submission> {
        let mut waiting = self.waiting.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(head) = waiting.pop_front() else {
            return Vec::new();
        };
        let collects_company = batchability_of(&head.command) == Batchability::RidesWithOthers;
        let tenant = head.command.tenant_id().to_owned();
        let mut batch = vec![head];
        if collects_company {
            collect_the_company_behind(&tenant, &mut batch, &mut waiting, ceiling);
        }
        self.hand_the_baton_on(&waiting);
        batch
    }

    /// A drain that leaves work behind wakes the next dispatcher itself, so a
    /// tenant this one stepped over is taken CONCURRENTLY rather than after
    /// the statement in front of it commits.
    ///
    /// **Stated exactly, because the obvious stronger claim is false.** It is
    /// not liveness: the loop always drains again before it sleeps, so the
    /// dispatcher that stepped over globex would come back for it as soon as
    /// its own batch committed, baton or no baton. What the baton buys is
    /// that globex does not WAIT for that commit — which is the same thing
    /// tenant-homogeneous batching is for, confining a tenant's head-of-line
    /// stall to its own writes. It is also why no test in this file holds
    /// this line red: deleting it changes latency under a multi-tenant queue
    /// and nothing an assertion can see. It stays for the same reason the
    /// adapter's redundant supersede fast path does — cheap, strictly better
    /// on the common case, and recorded as untested rather than dressed up.
    fn hand_the_baton_on(&self, waiting: &VecDeque<Submission>) {
        if !waiting.is_empty() {
            self.arrived.notify_one();
        }
    }
}

/// Grow the head's batch out of the queue behind it, up to the ceiling: every
/// waiter [`rides_with_the_batch`] admits is taken OUT of the queue and into
/// the batch, and every waiter it does not is STEPPED OVER — the scan looks
/// past a tenant it cannot carry rather than stopping at it, which is what
/// keeps one tenant's head-of-line stall out of another's writes. What it
/// steps over stays queued for the next dispatcher, which is what the baton
/// wakes.
fn collect_the_company_behind(
    tenant: &str,
    batch: &mut Vec<Submission>,
    waiting: &mut VecDeque<Submission>,
    ceiling: usize,
) {
    let mut position = 0;
    while position < waiting.len() && batch.len() < ceiling {
        let joins = waiting
            .get(position)
            .is_some_and(|waiter| rides_with_the_batch(batch, tenant, waiter));
        if !joins {
            position += 1;
            continue;
        }
        // Taken from the position just tested, so the next waiter slides into
        // it and `position` stays where it is. `remove` answers with the
        // caller it took; an absence is impossible here — the position is in
        // range — and is stepped over rather than spun on.
        match waiting.remove(position) {
            Some(joining) => batch.push(joining),
            None => position += 1,
        }
    }
}

/// Whether one waiting caller may join the batch being formed behind `tenant`.
/// Three clauses, and each is a decision:
///
/// **Its tenant is the head's.** Measured, tenant-homogeneous batching clears
/// 2,350/s at a true fill of 6.22 against spanning batches' 2,177/s at 25 —
/// what pays is account OVERLAP inside the batch, not batch size, and
/// homogeneity is the cheapest way to guarantee it. It also confines a
/// tenant's head-of-line stall to its own writes.
///
/// **It can share a statement at all** — a pending, resolving or reversing
/// command keeps the single statement (ADR-0018 §4).
///
/// **And its key is not already travelling.** Two callers racing one
/// idempotency key are ADR-0013 §2's race, which the writer answers by having
/// the loser block on the winner's in-flight claim and then read the
/// committed result from a separate statement — one 201, the rest 200
/// replayed. Inside ONE statement there is no winner to block on: the claim's
/// `ON CONFLICT DO NOTHING` takes one event, the join fans it to both
/// ordinals, and `uq_txn__one_per_event` aborts the whole batch — its
/// innocent members included — which reaches those callers as a 500.
/// ADR-0018 §3 accepts that as failing closed for "one retry"; leaving the
/// second member for the NEXT batch costs nothing and gives it the race
/// semantics it already had, so the abort mode is simply not reached from
/// here. The tenant is fixed for the whole batch, so the key alone identifies
/// the claim the two would race for.
fn rides_with_the_batch(batch: &[Submission], tenant: &str, waiter: &Submission) -> bool {
    waiter.command.tenant_id() == tenant
        && batchability_of(&waiter.command) == Batchability::RidesWithOthers
        && !batch
            .iter()
            .any(|member| member.command.idempotency_key() == waiter.command.idempotency_key())
}

/// The [`Ledger`] the HTTP surface is served with: the same port, the same
/// wire contract, the same error grammar — a caller cannot tell whether its
/// posting shared a statement. It is not a decorator over another `Ledger`,
/// because a batch is ONE call for N commands rather than N calls.
///
/// **Only the posting half is batched, and the other three say so by sharing
/// a writer of their own.** Opening an account (ADR-0021) never joins a
/// batch: there is nothing to share — it writes no entries and upserts no
/// balance row, so it has no accounts to overlap with anyone and no lock to
/// order — and it is rare where a posting is hot. Defining a period
/// (ADR-0024) is the same shape. Closing one is the opposite shape and lands
/// in the same place: it writes a great deal, but none of it is what the
/// batched statement carries, and a sweep linear in account count must not
/// hold a dispatcher. All three take the writer below directly, out of the
/// queue's way entirely, so a burst of them cannot occupy a dispatcher that
/// postings are waiting on.
///
/// Generic in the repository, where the posting half is not, and that is the
/// cost of the second method: the queue hands its members to whichever
/// dispatcher takes them and needs no type, while this call runs the writer
/// service HERE, on the request's own task.
#[derive(Clone)]
pub struct BatchingLedger<R> {
    queue: Arc<Queue>,
    /// The writer an opening runs on. A `LedgerService` like every dispatcher
    /// holds, and it carries a stripe affinity it will never use — a stripe
    /// is a row of `ledger_account_balances`, and opening an account writes
    /// none.
    opener: LedgerService<R>,
}

impl<R: Repository + Clone + 'static> BatchingLedger<R> {
    /// Start the pool: one task per writer, each owning its writer — and
    /// therefore the stripe affinity that writer holds for its lifetime — for
    /// as long as the process serves. That ownership is the point of the
    /// pool and not an implementation detail: worker affinity is constant per
    /// writer, so a single writer puts every write for one account on ONE
    /// stripe and sixty-four stripes become one; the measured 4.31× needs
    /// concurrent writers holding DIFFERENT indices, and this is what
    /// supplies them. Because a batch of one is dispatched through the same
    /// pool, every post carries a dispatcher's affinity whether it shared a
    /// statement or not.
    ///
    /// The tasks outlive this handle — the queue they hold is what they wait
    /// on, not it — but they are NOT unwatched. A dispatcher's loop has no
    /// return: it ends only by panicking, and a panicking task is joined
    /// silently by default. The pool would then shrink with no signal
    /// anywhere — striping narrowing with it, since a dispatcher is a stripe
    /// affinity — and when the last one goes, every caller waits forever on a
    /// `oneshot` whose sender is still sitting in the queue: the request
    /// hangs instead of failing. So the handles are kept and watched
    /// ([`end_the_process_when_a_dispatcher_stops`]).
    ///
    /// `opener` is the writer the un-batched half runs on — see the struct's
    /// own doc for why opening an account has one of its own rather than a
    /// place in the queue.
    pub fn dispatching_over(writers: Vec<LedgerService<R>>, opener: LedgerService<R>) -> Self {
        let queue = Arc::new(Queue::default());
        let mut pool = JoinSet::new();
        for writer in writers {
            pool.spawn(take_batches_until_the_process_ends(
                writer,
                Arc::clone(&queue),
            ));
        }
        tokio::spawn(end_the_process_when_a_dispatcher_stops(pool));
        Self { queue, opener }
    }
}

/// The pool's watcher: a dispatcher stopping is a fault the process must not
/// serve through, so it is announced and the process ends.
///
/// **Failing beats degrading, and this is where that is chosen.** A pool that
/// has lost a dispatcher still answers — more slowly, over fewer stripes, and
/// with no way for an operator to see either — until the last one goes and
/// requests begin to hang rather than fail. An exit is a signal every
/// supervisor already knows how to read, and a restarting process comes back
/// with its full pool.
///
/// An empty pool is the same fault arrived at sooner: no dispatcher will ever
/// take anything, so the first request would hang. `join_next` answers `None`
/// for it, and it is refused here rather than served.
async fn end_the_process_when_a_dispatcher_stops(mut pool: JoinSet<()>) {
    let stopped = match pool.join_next().await {
        // A dispatcher's loop never returns, so this is a panic inside one —
        // the join error carries the panic's own message.
        Some(Err(panicked)) => format!("a writer dispatcher stopped: {panicked}"),
        Some(Ok(())) => "a writer dispatcher's loop returned".to_owned(),
        None => "the writer pool is empty — no dispatcher will ever take a posting".to_owned(),
    };
    eprintln!("openledger: {stopped}; exiting rather than serving on a degraded writer pool");
    std::process::exit(1);
}

impl<R: Repository> Ledger for BatchingLedger<R> {
    /// Queue the command and wait for the dispatcher that takes it. The
    /// command is CLONED because the port hands out a borrow and the caller's
    /// answer is produced on another task: one clone per post, of a few
    /// strings and its postings, against a statement shared with N callers.
    async fn post(&self, command: &PostTransaction) -> Result<Posted, WriteError> {
        let (answer, answered) = oneshot::channel();
        self.queue.push(Submission {
            command: command.clone(),
            answer,
        });
        // The sender is dropped without sending only if the dispatcher task
        // died — a can't-happen state, answered as one rather than as a
        // refusal the caller could act on.
        answered.await.unwrap_or_else(|_| {
            Err(WriteError::Internal(
                "the dispatcher holding this posting stopped before answering it".to_owned(),
            ))
        })
    }

    /// Open the account on this request's own task, through the writer this
    /// value holds. No queue, no dispatcher, no clone of the command: an
    /// opening has nothing to share with a batch-mate (it writes no entries
    /// and no balance row), and routing it through the queue would put it
    /// behind postings and put postings behind it.
    async fn open_account(&self, command: &OpenAccount) -> Result<AccountOpened, OpenAccountError> {
        self.opener.open_account(command).await
    }

    /// Define the period on this request's own task, for the reason opening
    /// an account takes one: it writes no entries and upserts no balance row,
    /// so there is nothing for a batch to share.
    async fn define_period(
        &self,
        command: &DefinePeriod,
    ) -> Result<PeriodDefined, DefinePeriodError> {
        self.opener.define_period(command).await
    }

    /// Close the period on this request's own task too — and here the reason
    /// is the opposite one. A close writes plenty: a transaction, a leg pair
    /// per swept account, a balance upsert for each, a close record and a
    /// checkpoint row per account. What it cannot do is share the BATCHED
    /// statement, which carries plain posted postings only (ADR-0018 §4) and
    /// derives none of that; and it must not occupy a dispatcher for the
    /// length of a sweep that is linear in account count (ADR-0024's second
    /// cost: ~49 s for a million accounts), because a dispatcher held is
    /// every posting behind it held.
    async fn close_period(&self, command: &ClosePeriod) -> Result<PeriodClosed, ClosePeriodError> {
        self.opener.close_period(command).await
    }
}

/// One dispatcher's whole life: take whatever is waiting, post it, answer its
/// callers, take whatever arrived while that ran. The loop body IS the
/// permit — a batch is formed by the writer that is about to post it and the
/// turn is not over until the statement has committed and its members have
/// been answered — so the pool depth bounds how many statements are in
/// flight, and the members that accumulate during one statement are exactly
/// the next batch.
///
/// The only wait in the policy is the wait for work, and it is not a timer.
async fn take_batches_until_the_process_ends<R: Repository>(
    writer: LedgerService<R>,
    queue: Arc<Queue>,
) {
    loop {
        let batch = queue.take_whatever_is_waiting(MAX_BATCH_MEMBERS);
        if batch.is_empty() {
            // `notify_one` STORES a permit when no dispatcher is waiting, so
            // an arrival between the read above and this wait wakes this
            // dispatcher immediately instead of being dropped on the floor.
            // That is load-bearing: with no timer anywhere in this policy,
            // there is no fallback tick to rescue a lost notification — the
            // request would wait for the next one to arrive.
            queue.arrived.notified().await;
            continue;
        }
        post_the_batch_and_answer_its_callers(&writer, batch).await;
    }
}

/// One batch POSTED — this is where the database statement runs, and it is
/// the whole of the dispatcher's turn — and then answered, each caller on its
/// own. The writer decides which statement it takes: a batch of one is the
/// single statement M3 shipped. Every member gets its OWN answer, so a
/// refused member is refused alone while its batch-mates commit, which is the
/// property this whole feature is built around. A caller that hung up is
/// dropped without ceremony; its write happened, and its idempotency key is
/// what lets it find out.
async fn post_the_batch_and_answer_its_callers<R: Repository>(
    writer: &LedgerService<R>,
    batch: Vec<Submission>,
) {
    let mut commands = Vec::with_capacity(batch.len());
    let mut callers = Vec::with_capacity(batch.len());
    for submission in batch {
        commands.push(submission.command);
        callers.push(submission.answer);
    }
    let answers = writer.post_batch(&commands).await;
    for (answer, caller) in answers.into_iter().zip(callers) {
        let _ = caller.send(answer);
    }
}

#[cfg(test)]
mod tests {
    //! The accumulator's two decisions, held without a runtime and without a
    //! database: WHICH commands may share a statement, and WHICH of the
    //! waiting ones a dispatcher takes when its turn comes. Everything below
    //! those — what the shared statement then does to the book, which member
    //! is refused, which replays — is `LedgerService::post_batch`'s and is
    //! held over the fake repository in the core crate; nothing here
    //! re-proves it.

    use ledger::Posting;
    use time::OffsetDateTime;
    use uuid::Uuid;

    use super::*;

    const SOURCE: Uuid = Uuid::from_u128(1);
    const DESTINATION: Uuid = Uuid::from_u128(2);
    const TARGET: Uuid = Uuid::from_u128(0xA0);

    /// One command of a given kind. Only the tenant and the kind matter to
    /// anything below; the postings are shape, not subject.
    fn a_command(
        tenant_id: &str,
        idempotency_key: &str,
        status: TransactionStatus,
        resolves_id: Option<Uuid>,
        reverses_id: Option<Uuid>,
    ) -> Result<PostTransaction, ledger::Invalid> {
        let postings = match reverses_id {
            Some(_) => Vec::new(),
            None => vec![Posting::new(SOURCE, DESTINATION, 100, "USD".to_owned())?],
        };
        PostTransaction::new(
            tenant_id.to_owned(),
            idempotency_key.to_owned(),
            Some(OffsetDateTime::UNIX_EPOCH),
            status,
            resolves_id,
            reverses_id,
            postings,
        )
    }

    /// A plain posted posting for this tenant, queued. The receiver is
    /// dropped: no dispatcher runs in these tests, and nothing answers.
    fn queue_a_posting(queue: &Queue, tenant_id: &str, idempotency_key: &str) -> TestResult {
        queue_the(
            queue,
            a_command(
                tenant_id,
                idempotency_key,
                TransactionStatus::Posted,
                None,
                None,
            )?,
        );
        Ok(())
    }

    fn queue_the(queue: &Queue, command: PostTransaction) {
        let (answer, _answered) = oneshot::channel();
        queue.push(Submission { command, answer });
    }

    /// The same posting, queued with its caller's answer channel handed back
    /// rather than dropped — what a test that actually RUNS a dispatcher
    /// needs, since the answer arriving is the whole observable.
    fn queue_for_an_answer(
        queue: &Queue,
        tenant_id: &str,
        idempotency_key: &str,
    ) -> Result<oneshot::Receiver<Result<Posted, WriteError>>, ledger::Invalid> {
        let (answer, answered) = oneshot::channel();
        queue.push(Submission {
            command: a_command(
                tenant_id,
                idempotency_key,
                TransactionStatus::Posted,
                None,
                None,
            )?,
            answer,
        });
        Ok(answered)
    }

    /// Whether one caller was answered at all, waited for under a bound. The
    /// bound is the point: a dispatcher that never takes this caller must
    /// FAIL the test rather than hang the suite on it.
    async fn answered_within_five_seconds(
        answered: oneshot::Receiver<Result<Posted, WriteError>>,
    ) -> bool {
        matches!(
            tokio::time::timeout(std::time::Duration::from_secs(5), answered).await,
            Ok(Ok(Ok(_)))
        )
    }

    /// A repository that appends whatever it is handed, single statement or
    /// batched — exactly enough for a dispatcher to complete a turn and
    /// answer its callers. What the real statements DO to the book is
    /// `ledger`'s to prove over its own fake, and nothing here re-proves it.
    struct AlwaysAppends;

    struct NoTransaction;

    impl ledger::Repository for AlwaysAppends {
        type Tx = NoTransaction;

        async fn begin(&self) -> Result<NoTransaction, ledger::StorageError> {
            Ok(NoTransaction)
        }

        async fn claim_and_append(
            &self,
            _tx: &mut NoTransaction,
            _command: &PostTransaction,
            _hash: &[u8],
            _payload: &serde_json::Value,
            append: &ledger::Append,
        ) -> Result<Option<ledger::Claimed>, ledger::StorageError> {
            Ok(Some(ledger::Claimed::Appended(ledger::Appended {
                event_id: Uuid::from_u128(0xE0),
                transaction_id: Uuid::from_u128(0xF0),
                // One answer per delta, every account found: the shape the
                // service checks before it commits.
                balance_upserts: append
                    .deltas
                    .iter()
                    .map(|((account_id, currency), delta)| ledger::BalanceUpsert {
                        account_id: *account_id,
                        currency: currency.clone(),
                        last_seq: Some(delta.legs),
                    })
                    .collect(),
            })))
        }

        async fn claim_and_append_batch(
            &self,
            _tx: &mut NoTransaction,
            members: &[ledger::BatchMember<'_>],
        ) -> Result<Vec<ledger::MemberOutcome>, ledger::StorageError> {
            Ok((0..members.len())
                .map(|position| ledger::MemberOutcome::Appended {
                    event_id: Uuid::from_u128(0xE00 + position as u128),
                    transaction_id: Uuid::from_u128(0xF00 + position as u128),
                })
                .collect())
        }

        async fn stored_result(
            &self,
            _tx: &mut NoTransaction,
            _command: &PostTransaction,
            _hash: &[u8],
        ) -> Result<Option<ledger::StoredResult>, ledger::StorageError> {
            Ok(None)
        }

        // The three opening statements and the five the period needs,
        // refused rather than faked. Nothing in this module's tests opens an
        // account, defines a period or closes one — none of the three ever
        // joins a batch or reaches a dispatcher (ADR-0021, ADR-0024) — so a
        // call landing here would mean the routing this file owns had changed
        // underneath the tests, and it should say so instead of answering.
        async fn chart_triple_for_purpose(
            &self,
            _tx: &mut NoTransaction,
            _purpose: &str,
        ) -> Result<Option<ledger::ChartTriple>, ledger::StorageError> {
            Err("the dispatcher's repository was asked to read the chart".into())
        }

        async fn claim_and_open_account(
            &self,
            _tx: &mut NoTransaction,
            _command: &OpenAccount,
            _hash: &[u8],
            _payload: &serde_json::Value,
            _triple: &ledger::ChartTriple,
        ) -> Result<Option<ledger::OpenedAccount>, ledger::StorageError> {
            Err("the dispatcher's repository was asked to open an account".into())
        }

        async fn stored_account(
            &self,
            _tx: &mut NoTransaction,
            _command: &OpenAccount,
            _hash: &[u8],
        ) -> Result<Option<ledger::StoredAccount>, ledger::StorageError> {
            Err("the dispatcher's repository was asked for a stored account".into())
        }

        async fn claim_and_define_period(
            &self,
            _tx: &mut NoTransaction,
            _command: &DefinePeriod,
            _hash: &[u8],
            _payload: &serde_json::Value,
        ) -> Result<Option<ledger::DefinedPeriod>, ledger::StorageError> {
            Err("the dispatcher's repository was asked to define a period".into())
        }

        async fn stored_period(
            &self,
            _tx: &mut NoTransaction,
            _command: &DefinePeriod,
            _hash: &[u8],
        ) -> Result<Option<ledger::StoredPeriod>, ledger::StorageError> {
            Err("the dispatcher's repository was asked for a stored period".into())
        }

        async fn period_close_context(
            &self,
            _tx: &mut NoTransaction,
            _command: &ClosePeriod,
        ) -> Result<Option<ledger::PeriodCloseContext>, ledger::StorageError> {
            Err("the dispatcher's repository was asked to read a period's close context".into())
        }

        async fn claim_and_close_period(
            &self,
            _tx: &mut NoTransaction,
            _command: &ClosePeriod,
            _hash: &[u8],
            _payload: &serde_json::Value,
            _plan: &ledger::ClosePlan,
        ) -> Result<Option<ledger::ClosedPeriod>, ledger::StorageError> {
            Err("the dispatcher's repository was asked to close a period".into())
        }

        async fn checkpoint_the_close(
            &self,
            _tx: &mut NoTransaction,
            _command: &ClosePeriod,
            _plan: &ledger::ClosePlan,
            _transaction_id: Uuid,
            _computed_at_xid: &str,
        ) -> Result<u64, ledger::StorageError> {
            Err("the dispatcher's repository was asked to write a checkpoint".into())
        }

        async fn stored_close(
            &self,
            _tx: &mut NoTransaction,
            _command: &ClosePeriod,
            _hash: &[u8],
        ) -> Result<Option<Uuid>, ledger::StorageError> {
            Err("the dispatcher's repository was asked for a stored close".into())
        }

        async fn stored_result_batch(
            &self,
            _tx: &mut NoTransaction,
            members: &[ledger::BatchMember<'_>],
        ) -> Result<Vec<Option<ledger::StoredResult>>, ledger::StorageError> {
            Ok(members.iter().map(|_| None).collect())
        }

        async fn commit(&self, _tx: NoTransaction) -> Result<(), ledger::StorageError> {
            Ok(())
        }

        async fn rollback(&self, _tx: NoTransaction) -> Result<(), ledger::StorageError> {
            Ok(())
        }
    }

    /// A drained batch, read as the keys it took, in order.
    fn keys(batch: &[Submission]) -> Vec<&str> {
        batch
            .iter()
            .map(|submission| submission.command.idempotency_key())
            .collect()
    }

    type TestResult = Result<(), ledger::Invalid>;

    /// Dispatch-on-completion's own shape: a dispatcher takes everything
    /// waiting for it in one sweep — it never leaves a member behind to wait
    /// for a timer — and stops at the safety ceiling, which is what keeps a
    /// long stall from assembling an unbounded statement out of the backlog.
    #[test]
    fn a_drain_takes_everything_waiting_and_stops_at_the_ceiling() -> TestResult {
        let queue = Queue::default();
        for n in 0..5 {
            queue_a_posting(&queue, "acme", &format!("key-{n}"))?;
        }

        let batch = queue.take_whatever_is_waiting(3);
        let rest = queue.take_whatever_is_waiting(3);

        assert_eq!(keys(&batch), ["key-0", "key-1", "key-2"]);
        // Nothing was dropped or reordered by stopping: the members the
        // ceiling excluded are the next batch, in arrival order.
        assert_eq!(keys(&rest), ["key-3", "key-4"]);
        Ok(())
    }

    /// A batch is tenant-homogeneous: the head's tenant decides, and another
    /// tenant's postings are stepped over rather than swept in. Measured at
    /// 2,350 clearings/s against 2,177 for tenant-spanning batches, on a
    /// QUARTER of the members — what pays is account overlap inside the
    /// batch, not batch size.
    #[test]
    fn a_drain_never_mixes_tenants() -> TestResult {
        let queue = Queue::default();
        // Interleaved on purpose: the other tenant's posting sits BETWEEN
        // two of the head's, so a drain that stopped at the first stranger
        // would pass this by accident.
        queue_a_posting(&queue, "acme", "acme-1")?;
        queue_a_posting(&queue, "globex", "globex-1")?;
        queue_a_posting(&queue, "acme", "acme-2")?;

        let batch = queue.take_whatever_is_waiting(MAX_BATCH_MEMBERS);
        let next = queue.take_whatever_is_waiting(MAX_BATCH_MEMBERS);

        assert_eq!(keys(&batch), ["acme-1", "acme-2"]);
        // ...and the tenant that was stepped over is still waiting, first in
        // line for the next dispatcher rather than starved.
        assert_eq!(keys(&next), ["globex-1"]);
        Ok(())
    }

    /// One idempotency key travels once: a second caller racing it is left
    /// for the next batch rather than carried alongside its rival. In one
    /// statement the two would claim one event between them, fan it to both
    /// ordinals and abort the whole batch on `uq_txn__one_per_event` —
    /// innocent members included, and reaching every one of those callers as
    /// a 500. Split across two batches it is ADR-0013 §2's ordinary race: the
    /// loser blocks on the winner's in-flight claim and reads the committed
    /// result from the separate lookup, which is one 201 and one 200 replayed.
    #[test]
    fn a_drain_never_carries_one_idempotency_key_twice() -> TestResult {
        let queue = Queue::default();
        queue_a_posting(&queue, "acme", "charge-race")?;
        queue_a_posting(&queue, "acme", "charge-race")?;
        queue_a_posting(&queue, "acme", "charge-2")?;

        let batch = queue.take_whatever_is_waiting(MAX_BATCH_MEMBERS);
        let next = queue.take_whatever_is_waiting(MAX_BATCH_MEMBERS);

        assert_eq!(keys(&batch), ["charge-race", "charge-2"]);
        // The rival is still queued, and the batch it joins next will find
        // the key claimed rather than claim it twice.
        assert_eq!(keys(&next), ["charge-race"]);
        Ok(())
    }

    /// The routing rule enforced where it bites: each of the three kinds the
    /// batched statement cannot carry is drained ALONE, whatever is queued
    /// behind it. Batch one with company and it reaches the batched
    /// statement, which has no supersede gate and writes the literal status
    /// `'posted'` — so a misrouted member would not be refused, it would be
    /// POSTED with its pointer dropped. The adapter refuses that as a storage
    /// error; this is what makes sure it never has to.
    ///
    /// The plain posting queued behind each offender is what keeps the rule
    /// honest in the other direction: it is company that WAS available, so a
    /// router answering `PostsAlone` to everything would still fail the next
    /// test rather than pass this one for free.
    #[test]
    fn a_command_that_posts_alone_is_drained_alone() -> TestResult {
        let posts_alone = [
            (
                "a pending transaction",
                a_command("acme", "alone-1", TransactionStatus::Pending, None, None)?,
            ),
            (
                "a resolution",
                a_command(
                    "acme",
                    "alone-2",
                    TransactionStatus::Posted,
                    Some(TARGET),
                    None,
                )?,
            ),
            (
                "a reversal",
                a_command(
                    "acme",
                    "alone-3",
                    TransactionStatus::Posted,
                    None,
                    Some(TARGET),
                )?,
            ),
        ];

        for (what, command) in posts_alone {
            let queue = Queue::default();
            let key = command.idempotency_key().to_owned();
            queue_the(&queue, command);
            queue_a_posting(&queue, "acme", "posting-1")?;

            let batch = queue.take_whatever_is_waiting(MAX_BATCH_MEMBERS);

            assert_eq!(keys(&batch), [key.as_str()], "{what}");
        }
        Ok(())
    }

    /// The dispatcher's loop itself, RUN — over a fake writer, on a real
    /// runtime, with nothing calling the drain by hand. Every test above
    /// holds what ONE drain takes; this is the only one that executes the
    /// loop, and the only one that awaits `Queue::arrived`.
    ///
    /// **The arrivals come after the dispatcher is already asleep**, and that
    /// ordering is the test: the loop has read an empty queue and is waiting,
    /// so every one of these three callers is answered only because
    /// [`Queue::push`] woke it. Queue them ahead of the spawn instead and the
    /// wake-up never has to work.
    ///
    /// The three are acme / globex / acme so the loop must come back for a
    /// tenant its first drain stepped over: one drain answers the two acme
    /// callers, the drain after it answers globex.
    #[tokio::test]
    async fn the_dispatch_loop_answers_every_caller_it_was_queued() -> TestResult {
        let queue = Arc::new(Queue::default());
        let dispatcher = tokio::spawn(take_batches_until_the_process_ends(
            LedgerService::new(AlwaysAppends),
            Arc::clone(&queue),
        ));
        // Let it run down to the wait. From here nothing but an arrival's own
        // notification can move it.
        tokio::task::yield_now().await;

        let acme_1 = queue_for_an_answer(&queue, "acme", "acme-1")?;
        let globex = queue_for_an_answer(&queue, "globex", "globex-1")?;
        let acme_2 = queue_for_an_answer(&queue, "acme", "acme-2")?;

        let answered = [
            answered_within_five_seconds(acme_1).await,
            answered_within_five_seconds(globex).await,
            answered_within_five_seconds(acme_2).await,
        ];

        assert_eq!(
            answered, [true; 3],
            "a queued caller was never answered by the dispatch loop: [acme-1, globex-1, acme-2]"
        );
        dispatcher.abort();
        Ok(())
    }
}
