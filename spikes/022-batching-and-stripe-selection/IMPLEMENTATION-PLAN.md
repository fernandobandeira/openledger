# Implementation plan

> **This is the plan as written, kept as the record of what was intended. At least nine things
> changed on contact with the code, and [ADR-0018](/decisions/0018-batching-and-stripe-selection) is
> the authority where they differ.** *(This header said "four", listing the first four below. The
> remaining five were found by reading the plan against the shipped tree on 2026-09-01; a plan kept
> as a record is only worth keeping if the delta is complete.)*
>
> 1. **The accumulator did not all go in the composition root.** The use-case (`post_batch`) stayed
>    in `crates/ledger`, where the fake-repository tests live; only the queue, the dispatcher pool
>    and the task went to `crates/openledger`. That keeps `tokio` out of the domain crate, which was
>    the cost §1 of `DESIGN-QUESTIONS.md` was weighing.
> 2. **`MemberOutcome::Appended` carries only `event_id` and `transaction_id`.** Reusing `Appended`
>    meant an always-empty `balance_upserts`, because the cross-member coalesce destroys per-member
>    grain — a trap for anything shaped like `commit_or_refuse_unknown_account`.
> 3. **The permit became the dispatcher's own turn**, not a semaphore over a hand-off. Removing the
>    hand-off removes the queue a backlog could migrate into, which was the measured hazard.
> 4. **The drain refuses to carry one idempotency key twice.** Without it, a client retry and its
>    original land in the same batch and abort it — measured at 6 × HTTP 500 in 40 concurrent posts
>    of one key, regressing ADR-0013 §2's guarantee.
> 5. **The connection pool went from 8 to 38, and stopped being independently choosable.**
>    `db::POOL_CONNECTIONS` is now `batching::DISPATCHERS + 6`, asserted at compile time
>    (`const _: () = assert!(…)` in `batching.rs`) so the two cannot drift. The plan treated the pool
>    as untouched. It is not: a dispatcher without a connection forms its batch and then blocks in
>    `begin` while the members it meant to coalesce keep arriving, so 32 dispatchers on 8 connections
>    is strictly worse than 8 dispatchers. This has an operator consequence the plan never
>    contemplated — a serving process now holds 38 connections against PostgreSQL's default
>    `max_connections` of 100 — written up in [ADR-0002](/decisions/0002-scaling).
> 6. **The port gained _two_ methods, not one.** The plan drew `claim_and_append_batch` and said
>    "the port does not change" of everything else. `Repository` also gained
>    **`stored_result_batch`**: a batch's unclaimed subset needs its replay lookups resolved in one
>    round trip, and running the single-row `stored_result` N times would have put the batch's
>    saving back into the path it was taken out of.
> 7. **`BatchingLedger` is not the generic decorator this plan drew, and batching has no opt-out.**
>    The sketch below is `impl<L: Ledger> Ledger for BatchingLedger<L>` with an inner ledger and a
>    `batchability_of` fork that falls through to `self.inner.post`. What shipped is
>    `BatchingLedger { queue }` — no type parameter and no inner ledger — constructed by
>    `dispatching_over(writers: Vec<LedgerService<R>>)`. **Every post goes through the queue**,
>    including the unbatchable ones and the single-member ones; the routing happens *inside* the
>    drain, and a one-member batch is dispatched to the existing single statement. That is what makes
>    the unbatched path striped by the same mechanism as the batched one — a decorator with a
>    fall-through would have left every non-batchable post on a writer with no dispatcher identity.
>    It also means there is **no configuration that turns batching off**: `main.rs` always wraps.
> 8. **`PgRepository::new` was deleted, not extended.** A repository now belongs to a writer:
>    `PgRepository::for_writer(&database, writer_index)`, because the stripe affinity is a property
>    of the repository's lifetime rather than of a call. And ⟨MEASURED⟩ `stripe_for` shipped as
>    **`stripe_affinity_of`**, named for what it produces, in `crates/ledger/postgres` — a third
>    crate, not the two this plan's file list names.
> 9. **Drains are tenant-homogeneous**, which this plan does not mention at all: the head of the
>    queue decides the batch's tenant and a member of another tenant waits for the next turn. Taken
>    on throughput (8% faster while collecting a quarter of the members — ADR-0018 §3), with fairness
>    and ADR-0013's open per-tenant `WITH CHECK` option coming along for free.
>
> And one more, in the acceptance criteria rather than the design: **M2's concurrency proof shipped
> as eight accounts with rotating overlapping subsets**, not as the "six accounts, half presenting
> legs reversed" the table below specifies. Reversed presentation is the *single* path's hazard and
> cannot reach the batched path at all, because the coalesce normalizes lock order before any row is
> locked; the batched path's real hazard is concurrent batches drawing *different* account subsets,
> which needs nothing injected. The shape was arrived at by measurement — 128 writers × 8 rounds
> catches the removed `ORDER BY` on 4 runs of 4, where 64 × 16 caught it on 1 of 4.

Written while the matrix runs. Everything here is settled independently of the numbers; the two
parameters the measurements decide (the stripe expression, and whether selection sits before or
after the coalesce) are marked ⟨MEASURED⟩ and touch **one function each**, deliberately.

The shape follows `crates/ledger/src/service.rs`: a short orchestrator whose body reads as the
use-case in domain terms, delegating each concrete effect to a named function below it. You should
be able to read the top function and know what happens, then descend one layer at a time for how.
Nothing is named for its mechanism (`do_the_work`, `handle`, `process`); every helper is named for
the effect it has on the book.

---

## Part 1 — Stripe selection on the single-member path

**Schema: no migration.** `ledger_accounts.stripe_count`, `ledger_account_balances.stripe`,
`ledger_entries.stripe`, `pk_balances` and `fk_entries__stripe` all shipped in the baseline. This is
writer work only, which is the whole point of ADR-0013 having put the stripe below the account.

### `crates/ledger/postgres/src/repository.rs` — `CLAIM_AND_APPEND`

Three edits, and only three:

1. A `striped AS MATERIALIZED` CTE between `delta` and `balance`, joining `ledger_accounts` for the
   frozen identity columns the upsert already copies, and computing the stripe once. `MATERIALIZED`
   is load-bearing, not stylistic — see the ADR §1.
2. `balance` selects `FROM striped`, orders by `(account_id, currency, stripe)`, and adds `stripe`
   to its `RETURNING`.
3. `entry` takes `b.stripe` from that `RETURNING` instead of the literal `0`.

**The port does not change.** `BalanceUpsert` still carries `(account_id, currency, last_seq)` —
the service's only questions are "did every delta come back?" and "did any counter come back
`None`?", and neither needs the stripe. A port change here would be scope the feature does not
require.

### The one open parameter

⟨MEASURED — section C: the affinity key.⟩ It reaches the statement as a bound parameter and is
produced by exactly one function:

```rust
/// Which physical stripe of this account's balance row this writer takes.
/// A stripe shards the write lock and nothing else: it never appears in a
/// report, a reconciliation, an API answer or the chart (ADR-0013 §4).
fn stripe_for(...) -> i32
```

If the winning key is worker-affinity, the writer needs a worker identity it does not have today,
and that identity is the accumulator's dispatcher index (Part 2) — which is why the two halves of
this feature land together rather than separately.

---

## Part 2 — Batching across requests

### `crates/ledger/src/repository.rs` — one more port method

```rust
/// One member of a batch: the command and everything computed for it
/// before any SQL ran.
pub struct BatchMember<'a> { command: &'a PostTransaction, hash: &'a [u8],
                             payload: &'a serde_json::Value, append: &'a Append }

/// What the batched statement answered for ONE member. Every variant except
/// `Appended` means nothing was written FOR THIS MEMBER while its batch-mates
/// committed — the per-member form of the port's standing promise.
pub enum MemberOutcome {
    Appended(Appended),
    /// A posting named an account that does not exist: the gate withheld the
    /// member's claim, so its idempotency key is untouched and its retry is a
    /// fresh request (ADR-0018 §3 — the laundered-refusal failure).
    AccountUnknown { account_id: Uuid, currency: String },
    /// The key was already held. This member did not append; its answer is
    /// the replay lookup's, run for the whole unclaimed subset at once.
    KeyAlreadyClaimed,
}

fn claim_and_append_batch(&self, tx, members: &[BatchMember])
    -> impl Future<Output = Result<Vec<MemberOutcome>, StorageError>> + Send;
```

One outcome per member, in the order given. That invariant is asserted by the service, exactly as
`commit_or_refuse_unknown_account` asserts one upsert per delta today — a length mismatch means the
adapter and the service disagree about the statement, which is `Internal`, never a caller error.

### `crates/openledger` — the accumulator

Lives in the composition root (ADR-0018 §5), which already has `tokio` and is already where
`PgRepository` meets `LedgerService`.

```rust
impl<L: Ledger> Ledger for BatchingLedger<L> {
    /// Post through the batch, or straight through when this command cannot
    /// ride one. The caller cannot tell which happened: same endpoint, same
    /// wire contract, same error grammar.
    async fn post(&self, command: &PostTransaction) -> Result<Posted, WriteError> {
        match batchability_of(command) {
            Batchable::No(reason) => self.inner.post(command).await,
            Batchable::Yes => self.enqueued_and_awaited(command).await,
        }
    }
}
```

Below that, one layer at a time:

| function | what it does |
| --- | --- |
| `batchability_of(command)` | pure, unit-testable: a plain posted posting rides a batch; pending, resolving and reversing commands take the single statement they already have (ADR-0018 §4) |
| `enqueued_and_awaited(command)` | hands the command to the drain task with a one-shot reply channel and waits on it |
| `drain_until_shutdown()` | the loop. Dispatch-on-completion: take whatever is queued *now*, post it, repeat. Nothing waits for company that has not arrived (ADR-0018 §2) |
| `batch_waiting_now(max)` | drains the queue without blocking, up to the safety bound. Pure given a queue — testable without a runtime |
| `post_batch(members)` | the bracket: begin, one statement, resolve outcomes, commit or roll back. The direct analogue of today's `post` in `service.rs` |
| `answers_for_members(outcomes)` | maps each `MemberOutcome` to its caller's `Result` |
| `replayed_answers_for(unclaimed)` | statement B, once, for every member whose key was already held — the batched form of `replay_or_refuse` |
| `fan_out(answers)` | sends each answer down its member's reply channel |

**Why `replayed_answers_for` is one call and not N:** a batch containing any replay costs a second
statement, so the round-trip count is three plus one *for the batch*, not per member. That is the
honest cost and it belongs in the ADR's cost list.

---

## Part 3 — Tests

The standard: **AAA throughout, one behaviour per test, and no two tests holding the same thing.**
Tests here are how the feature is understood, so a test whose name does not state the property it
holds is a test that has failed at its main job.

### Pure, no database (`crates/ledger`, `crates/openledger`)

| test | property |
| --- | --- |
| `batchability_of` — a plain posted posting is batchable | routing, positive |
| `batchability_of` — pending, resolving and reversing commands are not | routing, negative, one table-driven test over all three rather than three near-copies |
| `batch_waiting_now` takes everything queued and stops at the bound | dispatch-on-completion: it never waits, and it never exceeds the safety ceiling |
| `batch_waiting_now` on an empty queue yields nothing | the low-load case — the one that makes the fixed window unnecessary |
| `stripe_for` ⟨MEASURED⟩ | the selection function's own contract, incl. the `INT_MIN` mask |

### Orchestration over a fake repository (`crates/openledger`, mirroring `service.rs`'s test module)

Holds **branching and round-trip shape**, never SQL behaviour — the same division `service.rs`'s
test module documents in its own doc comment.

| test | property |
| --- | --- |
| a batch of first writers posts in one statement between begin and commit | the round-trip shape batching exists to buy |
| a batch carrying one unknown-account member commits the rest and refuses that one by name | per-member isolation — the ADR's central claim |
| a batch carrying one already-claimed key replays that member and appends the others | the mixed batch, and that the replay lookup runs **once** |
| a storage failure mid-batch fails every member and commits nothing | the widened blast radius, asserted rather than assumed |

### Against real PostgreSQL (`crates/e2e`)

| test | property |
| --- | --- |
| concurrent posts over HTTP land in one batch and the book reconciles at ten zeros | the feature works end to end, oracle-checked |
| a poison-pill batch leaves **N−1** transactions **and N−1 events** | the laundered-refusal defect, pinned. Asserting the event count is the point: no reconciliation check reads `ledger_events`, so the sweep cannot see this and the test must |
| the refused member's key is reusable afterwards | the other half of the same defect — its retry must post, not replay |
| two members sharing one idempotency key abort the batch and write nothing | fails closed, asserted at 0/0/0 |
| striped posting spreads across stripes and stays gapless per `(account, stripe)` | striping, oracle-checked |
| **M2's concurrency proof**: N writers, six accounts, half presenting legs reversed, batching on | zero deadlocks, gapless sequences, `SELECT * FROM reconciliation` at ten zeros |

**On the M2 proof's red path.** The suite asserts green; the spike is where it was proved red, by
removing the `ORDER BY` and reproducing deadlocks. That is the same division M1 used for the schema
snapshot — *"proved red before trusted green"*, with the injections recorded in the spike rather
than living in the suite. The e2e test cannot mutate the shipped statement, and a test that could
would be testing a statement nobody ships.

### Duplication to avoid, specifically

- The existing `endpoints/transactions/post.rs` already holds single-post replay, key reuse and
  unknown-account refusals. The batch tests hold the **batch-specific** forms only and must not
  re-prove the single-member contract.
- `postings.rs`'s coalescing and offset tests already hold the walk-back arithmetic. The batched
  walk-back is a **window function**, so its test belongs in e2e against real PostgreSQL, not as a
  second pure test of the same arithmetic.
- One table-driven test over the three non-batchable command kinds, not three tests.

---

## Order of work

1. Stripe threading in `CLAIM_AND_APPEND` + `stripe_for` + its tests. Independent of Part 2, and it
   is what section C's answer plugs into.
2. M2's concurrency proof as an e2e test. Depends on nothing but the workload, and closes the
   roadmap's oldest outstanding complaint about the unpinned `ORDER BY`.
3. The port's batch method and the batched statement.
4. The accumulator and its orchestration tests.
5. The e2e batch tests.
6. Docs: ADR-0018 into `site/content/decisions/`, spike write-up into
   `site/content/spikes/018-…`, then the roadmap (M2 and M3), the decision index and the spike
   index.
