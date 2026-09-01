# 0018 — Stripe selection on the write path, and batching across requests

**Status:** accepted (2026-09-01).
**Evidence:** [spike 018](/spikes/018-batching-and-stripe-selection): 302 measured configurations in
**two separate runs**, every one gated on `SELECT * FROM reconciliation` at ten zeros.

**Correction, 2026-09-01: this line used to read "302 measured configurations over seven interleaved
passes … no machine drift (pass medians 1.000–1.010 against pass 1)".** That summed two runs' passes
as if they were one sequence and applied the closed loop's drift band to both. Passes are the
outermost loop *within* a run and never interleave across runs, and the two runs drift differently:

| run | configurations | passes | drift, pass medians against pass 1 |
| --- | --: | --: | --- |
| closed loop (throughput) | 227 | 4 | **rate** 1.000, 1.010, 1.000, 1.002 |
| open loop (section F) | 75 | 3 | **p50** 1.000, 1.012, 1.013 |

The open loop pins its rate to the offered arrival trace, so rate drift there is 1.000 by
construction and latency is the only thing that can move. It moved by 1.2–1.3%, outside the
1.000–1.010 band this line used to claim for everything.

---

## The decision

**Two levers were designed into the schema and never built into the writer: an account can declare
`stripe_count`, and postings can be coalesced. The writer binds a literal stripe `0` and coalesces
only within one request. This decides how both get built — and, as it turned out, how a batch is
allowed to fail.**

- **A hot account's balance row is split, and the writer picks which split to write by *which
  writer it is*, never by whose money it is.** Splitting on a business key relocates the hot spot
  wherever that key is skewed — worth **4.3×** keyed on the writer against an unstriped control, and
  on the whale workload where the two keys are measured side by side, the writer key beats the
  tenant key **2.8×** (1,897 against 677 clearings/s).
- **Postings from independent requests are combined into one statement when there are any to
  combine — and never wait for company that has not arrived.** A fixed window is refused.
- **A bad member of a batch is refused on its own, and the others commit.** Getting this wrong is
  not a performance bug: it silently converts a refusal into a success the caller cannot tell from
  a real one.
- **A batch carries plain posted postings only.** Pending, resolutions and reversals keep the
  single-statement path they have today.
- **The scheduler lives in the binary and the use-case stays in the core** — which is what keeps
  [ADR-0002](/decisions/0002-scaling)'s "no scheduler in the core" true instead of reinterpreted.

---

## 1 · The stripe is chosen inside the statement, and materialized before it is used

`ledger_accounts.stripe_count` is read by the same statement that writes, in a CTE that joins
`ledger_accounts` for the account's frozen identity columns anyway — so selection costs **no extra
round trip** and the writer stays at ADR-0013's three. `ledger_account_balances` gains its row per
`(tenant, account, currency, stripe)` through the upsert it was already running, and `ledger_entries`
takes its `stripe` from that upsert's `RETURNING` rather than recomputing it — `fk_entries__stripe`
makes a mismatch a refused write rather than silent drift.

**The CTE must be `MATERIALIZED`.** PostgreSQL inlines a single-reference CTE by default, and the
stripe expression appears twice — as the inserted value and as the `ORDER BY` key that carries the
lock ordering. With a `VOLATILE` selection expression (`random()`) an inlined CTE may evaluate the
two independently, inserting at one stripe while sorting as another, which silently breaks the
deadlock defense. `AS MATERIALIZED` states the barrier instead of depending on a planner rule.

**The lock order becomes `(account_id, currency, stripe)`.** ADR-0013 recorded that gaplessness
becomes per `(account, stripe)`; the sort has to follow the counter's grain for the same reason.

### The key is the writer, not the tenant — and spike 004's refinement is refuted

Single tenant, contended, 32 writers — an unstriped control against two selection expressions:

| selection | stripes | clearings/s | vs baseline |
| --- | --- | --- | --- |
| none | 1 | 623 | 1.00× |
| random | 64 | 2,503 | 4.02× |
| **worker** | **64** | **2,687** | **4.31×** |

**Worker-keyed selection wins at every stripe count**, and it wins at 64 while *reaching* only 32
stripes, because the writer count bounds it — 32 writers can occupy at most 32 stripes.

**Tenant-keyed selection is refused on measurement**, and the measurement that refuses it is a
*paired* one — the same whale workload, 32 tenants with one generating 90% of traffic, 64 stripes,
only the selection expression changing:

| selection, on the identical whale workload | stripes | clearings/s |
| --- | --- | --- |
| tenant | 64 | **677** |
| **worker** | **64** | **1,897 — 2.8×** |

**Correction, 2026-09-01: this section used to report tenant-keyed striping as "1.09× (677 against
an unstriped 623)", and that ratio had no control behind it.** Every whale configuration in the
results files is `mode: tenant` or `mode: worker`; **`mode: none` with a whale was never run.** The
623 is the single-tenant, no-whale baseline — a different workload — so the 1.09× compared two
things that differ in more than the treatment. That is precisely the confounded comparison this
spike's own "why this spike exists" section says it corrected twice, and it survived into the ADR a
third time. The 1.09× is withdrawn; the worker-versus-tenant pair above is what decides the key, and
it is the comparison the decision actually rests on. **No unstriped whale control was run**, so
"what tenant-keyed striping buys over no striping at all, under a whale" remains unmeasured.

[Spike 004](/spikes/004-chart-of-accounts) proposed the tenant key because a business key survives a
restart and needs no sweep process. That reason was already void —
[ADR-0013](/decisions/0013-write-path-contract) §4 removed the sweep by putting the stripe below the
account — and the choice itself now fails on throughput: the whale hashes to one stripe, so
sixty-four stripes are one stripe for nearly all the traffic. **This is
[spike 003](/spikes/003-throughput-ceiling)'s own whale finding — the one that collapsed per-tenant
house accounts to 1.07× — reproduced one table lower down.** Splitting on a business key relocates
the hot spot wherever the business key is skewed, and payment volume is always skewed.

### The affinity value is the accumulator's dispatcher index — and that is why the two halves ship together

Worker affinity is **constant per writer**, which has a consequence worth stating plainly because it
is easy to build the plumbing and get none of the benefit: **a single `serve` process holding a
single affinity value puts every write for one account on one stripe, and striping then buys
nothing.** Sixty-four stripes with one writer is one stripe. The 4.31× requires concurrent writers
holding *different* indices, and nothing in the M3 writer had a writer identity at all.

§5's accumulator is what supplies it. Its dispatcher pool is a fixed set of N writers, each owning a
stable index for its lifetime — and because **a single-member batch is routed through the same
dispatcher** to the existing single statement, every post carries a dispatcher affinity whether it
was batched or not. The unbatched path is striped by the same mechanism as the batched one.

The property that matters is only that concurrent dispatchers hold *different* values, never which
values they are. A restart may reshuffle the whole pool and nothing is stranded: `stripe_count` is a
hint rather than an invariant (ADR-0013 §4), a reader `SUM`s the stripes that exist rather than
enumerating `0..n-1`, and `recon_balance_breaks` groups per stripe — so a stripe created lazily by
whichever dispatcher first picks it reconciles clean on its first write. Verified.

**One home for the non-negativity rule.** The affinity is masked to `i32::MAX` in the Rust function
that produces it, which is unit-tested at `2^31`, `2^31 + 1` and `u32::MAX`. The statement does not
re-mask: it trusts its bound parameter exactly as it trusts every other bind, and a redundant mask
in SQL would be a check no test could hold red — the shape
[ADR-0013](/decisions/0013-write-path-contract) already refused when it declined to assert the
isolation level at connection start. The mask is not decoration: an unmasked `hashtext` raises
`22003` on `INT_MIN`, and a negative stripe would trip `ck_balances__stripe_non_negative`.

### Placement: after the coalesce, and it matters less than expected

| | 64 stripes, B=25 |
| --- | --- |
| `random`, chosen **per batch** (after the coalesce) | **1,964** |
| `random`, chosen **per member** (before it) | 1,825 |
| `worker`, either placement | 2,020 / 1,999 — statistically identical |

Choosing after the coalesce is worth **+7.6%** for a volatile key, and nothing at all for a constant
one — exactly as predicted, since a constant expression cannot scatter a batch across stripes. **The
hypothesis that per-batch placement would remove the need for an affinity key is refuted**: random
per-batch (1,964) still loses to worker (2,020), and loses far more decisively on the unbatched path
where it is 2,503 against 2,687.

So: **per-batch placement, worker key.** The placement is taken because it is free and strictly
better; the key is what does the work.

*(The arithmetic hazard behind the mask is stated above, under "one home for the non-negativity
rule": an unmasked `abs(hashtext(x))` raises `22003` on `INT_MIN` — one key in 2³², whose every
write would then fail forever.)*

## 2 · Batching dispatches on completion. There is no window to size

**Refused: a fixed accumulation window.** The obvious design — collect for N milliseconds, then
dispatch — has a cost that falls entirely on the case this ledger is actually sized for. At
[ADR-0002](/decisions/0002-scaling)'s own derived load, *"under 1 TPS average, and maybe 20–50 TPS
at a Monday-morning peak"* against a measured **623 clearings/s** single-write baseline (660 at 8
writers), a 25-member window essentially never fills: **measured open-loop at 50 TPS offered with a
25 ms window, the true batch fill was 2.26.** Two members. Every request would pay the full window to
be batched with almost nobody.

*(**Correction, 2026-09-01:** this paragraph used to say "~671 clearings/s" and "fill was 2.21".
Neither figure is in either results file. The committed single-write baseline is **623** clearings/s
at 32 writers, **660** at 8 — 671 matches no cell — and the 25 ms window's fill at 50 TPS offered is
**2.26**, which the paragraph below already quoted correctly.)*

**Taken instead: dispatch on completion.** A batch is whatever queued while the previous statement
was in flight. At low load nothing is queued, the batch is one member, and latency is unchanged from
today's writer. At saturation the queue forms batches by itself, and the batch grows exactly as fast
as the database falls behind — which is when coalescing is worth having.

This is not a novel invention and should not be presented as one. **TigerBeetle states the same
policy explicitly as Nagle-like** — maintain at least one request in flight rather than wait on a
timer ([issue #489](https://github.com/tigerbeetle/tigerbeetle/issues/489)). And **PostgreSQL itself
ships the same reasoning at the commit layer**: `commit_delay` defaults to 0 and `commit_siblings`
to **5**, because a delay is pure latency cost if nobody else is around to join
([wiki](https://wiki.postgresql.org/wiki/Group_commit)). We are building on the database that
already made this decision.

### Measured: free below the ceiling, and the window is a pure tax

Open loop, whale workload, deterministic arrival trace so every arm at a rate saw the *identical*
trace — these are paired comparisons.

| offered TPS | on-completion p50 | **no batching** p50 | window 5 ms | window 25 ms | on-completion fill |
| --: | --: | --: | --: | --: | --: |
| 20 | 6.16 ms | **5.46 ms** | 13.64 | 31.49 | 1.00 |
| 50 | 3.07 | **2.95** | 9.62 | 29.47 | 1.00 |
| 200 | 2.27 | **2.28** | 8.32 | 29.44 | 1.00 |
| 800 | 2.38 | **2.41** | 8.38 | 29.24 | 1.02 |

**Across ADR-0002's entire derived range and forty times past it, dispatch-on-completion is
indistinguishable from not batching at all** — within 0.7 ms at 20 TPS and within 0.03 ms at 800 —
while a 25 ms window costs **10× the median latency at 50 TPS** to collect 2.26 members. That is the
tax the fixed window charges every request for company that has not arrived.

### The correction: it is not knob-free, and "no timer" is not "no tuning"

At 2,000 TPS — where the unbatched arm can no longer carry the offered load (it reaches **at or a
little above ~1,940/s**; the ladder stops there and does not bracket the knee, see
[spike 018 §F](/spikes/018-batching-and-stripe-selection)) — the ordering inverts:

| arm | achieved | p50 | p95 | fill |
| --- | --: | --: | --: | --: |
| on-completion, **32 writers** | **1,964** | 184.6 ms | 1,056 ms | 18.7 |
| on-completion, **8 writers** | 1,999 | 25.1 | 195.5 | 11.6 |
| window 5 ms | 2,002 | **12.6** | **24.1** | 11.5 |
| no batching | 1,934 | 82.2 | 319.9 | 1.00 |

**Dispatch-on-completion self-limits to exactly `writers` concurrent statements by construction** —
the permit spans batch formation through commit. Above the ceiling that means 32 concurrent
*batched* statements on the whale's shared rows, which is §B's concurrency collapse arriving by
another road. The windowed arm avoids it only because its timer incidentally caps how many
statements it puts in flight (~1.3 writers busy at 2,000 TPS).

So the honest statement is: **the policy removes a latency knob and exposes a pool-depth knob.** The
writer pool is sized separately from HTTP concurrency, and **32 is the default** — see the cost list
for why not 8, which is what this section's row alone would suggest: the pool also bounds how many
stripes are reachable, so sizing it for the saturation row would cap striping at 3.42× on every
posting forever to protect a load ~39× past this ledger's derived peak.

**And the mechanism is backpressure, not a zero timer.** This is an argument from construction, not
a measurement, and it is stated that way on purpose.

A zero window does not by itself produce this policy. Setting the timer to zero leaves the shape
intact: a collector still forms batches and still *hands them off* to a dispatching stage. If that
hand-off is unbounded, nothing pushes back on the collector, so under a backlog it forms a batch the
instant one member is available and the queue simply migrates into the channel as a long run of
one-member batches. Coalescing never receives anything to coalesce, because the coalesce happens
after the point where the queue used to be. The zero timer removes the wait; it does not remove the
buffer, and the buffer is what was absorbing the backlog.

What produces the policy is removing the hand-off entirely. **Formation, statement and answer are
one turn of one dispatcher**: it drains whatever is queued, runs its statement, answers its callers,
and only then looks at the queue again. A backlog therefore has nowhere to accumulate except the
queue the next drain reads, so the next batch is exactly as large as the database is behind. That is
backpressure, and it is a property of the topology rather than of a timer value. In-flight statements
are bounded by the pool depth for the same structural reason — there are N dispatchers and each holds
at most one statement — which is why a semaphore sized to the pool, sitting behind exactly that many
tasks, would be a permit that can never block. The spike modelled the turn as such a permit; the
shipped form makes it redundant.

**Correction, 2026-09-01: this paragraph used to cite two measurements, and one of them does not
exist.** It read *"with an unbounded hand-off the backlog migrates into the channel as a queue of
one-member batches and nothing ever coalesces (measured: fill 1.05, 1,789/s, p50 695 ms). What
produces it is that formation, statement and answer are one turn of one writer (fill 18.5, 1,964/s,
p50 185 ms)."* **No configuration with fill 1.05 at 1,789/s and p50 695 ms appears in either results
file or in `transcript.txt`.** The open-loop run's arms at 2,000 TPS are on-completion at 32 writers,
on-completion at 8, a 5 ms window, a 25 ms window, and an unbatched control — there is no
`--batch 25 --window-ms 0` hand-off arm among them. The second figure is real but was misquoted: the
committed fill median for on-completion at 32 writers is **18.66**, not 18.5, which is the 18.7 the
table two rows above already prints.

All three numbers are withdrawn rather than corrected, because the shipped design has no channel
hand-off left to measure: there is no stage between formation and statement for a backlog to sit in.
Measuring the alternative would mean building a writer we deliberately did not build. **The
alternative was reasoned about, not measured**, and the paragraph above is the reasoning.

**The connection pool must be at least the dispatcher count.** A dispatcher without a connection
forms its batch and then blocks in `begin` while the members it meant to coalesce keep arriving —
32 dispatchers on 8 connections is strictly worse than 8 dispatchers. The pool is sized
`DISPATCHERS + 6`, the margin the spike's own harness used.

**The single-member fast path is what makes this safe to ship.** Below the ceiling every batch has
exactly one member, and a one-member batch is routed to the **existing single statement** rather
than the batched one. So the new statement — with its per-member gate, its window-function
numbering and its three batch-wide abort modes — is only reachable under genuine queueing pressure.
The common path is the path that shipped in M3 and has been exercised since.

**What this costs:** a maximum batch size is still needed as a safety bound (a long stall must not
assemble an unbounded statement), but it is a ceiling, not a target, and nothing waits to reach it.

## 3 · A refused member is refused alone — and the gate sits above the claim

Every `WriteError` except `Storage` promises **"nothing was written"**, and the single-statement
writer keeps that promise by rolling back. **A batch cannot roll back for one member without
destroying the others**, so the promise is kept by *withholding* instead: a member that cannot
proceed contributes nothing to the shared statement.

**The gate must sit above the key claim, and this is the part that is easy to get wrong.** Gating
only the downstream inserts leaves the refused member's `ledger_events` row committed — its
idempotency key permanently burned. Its retry then finds the claim already held, the replay lookup
finds an event joined to no transaction, and the caller is answered
`transaction_id: null, replayed: true` — which [ADR-0013](/decisions/0013-write-path-contract) says
is the legitimate shape for the majority of accepted operations, which write no transaction at all.
**A refusal becomes indistinguishable from success, permanently.** Reproduced, then fixed by
hoisting the gate: the same poison-pill batch went from 25 events / 24 transactions to 24 / 24.

**And no reconciliation check would have caught it.** None of the ten reads `ledger_events`, so an
orphaned event is invisible to `SELECT * FROM reconciliation` by construction. The oracle reported
ten zeros on a book carrying the defect. Any per-member isolation claim has to be tested against the
transaction count directly, not against the sweep.

**The gate covers account existence, and that is all it needs to cover** — because §4 keeps
supersessions off this path entirely. That is worth stating, because the supersede refusals have the
same shape and no available fix: the shipped single statement withholds the transaction while still
claiming, and its own comment says *"which is why the service rolls back BEFORE answering the
refusal"* — a rescue a batch does not have. Hoisting the supersede predicates above the claim would
handle a **pre-existing** target, but not two members of one batch superseding the same target,
where same-statement snapshot invisibility means neither sees the other. **Scoping supersessions out
of the batch is what makes that unreachable rather than merely unlikely.**

**Peer practice agrees, in the two systems that document it:** failure isolation is
independent-by-default, atomic-by-opt-in — TigerBeetle's events succeed or fail independently unless
explicitly `linked`; Formance's bulk elements are independent unless `atomic=true`. **No system
defaults to whole-batch failure.**

### Three failures that abort the whole batch, and are accepted

| | what happens | why it is accepted |
| --- | --- | --- |
| **Two members share an idempotency key** | `ON CONFLICT DO NOTHING` claims one event; joined back by key it fans to both ordinals; two transactions on one `event_id` hit `uq_txn__one_per_event` and the statement raises `23505`. **Measured: 0 events, 0 transactions, 0 entries** | It fails **closed** — and the accumulator now makes it **unreachable**, see below |
| **Two members supersede the same target** | Same-statement snapshot invisibility means neither sees the other; `uq_txn__one_supersession` raises | Moot under §4 — supersessions never ride a batch |
| **Cross-member arithmetic overflow** | `plan_append` refuses overflow per member in Rust with `checked_add`; the batch re-coalesces in SQL at `bigint`, so a **cross-member** sum can overflow where no member does. `22003`, whole batch | Genuinely new, and the honest answer is that it is not gated. Recorded as a cost, not hidden |

### A batch never carries one idempotency key twice — and this is not a nicety

The duplicate-key abort above is not a theoretical row in a table: routing every post through one
queue makes it **the common case**, because a client retry and its original arrive milliseconds
apart and land in the same drain. Built naively, it reproduced immediately — **40 concurrent posts
of one key gave 1 × 201, 33 × 200 and 6 × 500**, and it broke a committed end-to-end test that pins
[ADR-0013](/decisions/0013-write-path-contract) §2's guarantee of no invented 409 and no 500. **The
batching layer would have regressed the replay contract**, which is the one thing on this write path
that callers are told they can rely on.

**So the drain leaves a rival key for the next batch.** A key already present in the batch being
formed is not taken; it waits, and on its next turn it is ADR-0013's ordinary race — block on the
in-flight claim, then read the committed result from the separate lookup. Re-measured: **1 × 201,
39 × 200, zero 500s.**

This is the difference between a failure that fails closed and one that cannot occur. The statement
keeps its `23505` as a backstop for anything that reaches it another way; the accumulator is what
means nothing does.

**A storage failure mid-batch fails every member**, including ones that would have succeeded. Their
keys were never claimed, so retry is safe. `Storage` was always the variant that promised nothing;
batching widens its blast radius from one caller to the batch.

**Head-of-line blocking is real and is not fixed.** `INSERT … ON CONFLICT DO NOTHING` waits on a
concurrent uncommitted insert of the same key: **measured, a 1,500 ms held claim stalled a batch of
25 for 1,519.5 ms** (three passes at 1,519.4 / 1,520.4 / 1,519.5 — the median, as everywhere else on
this page). It is the price of one statement.

*(**Correction, 2026-09-01:** this read "1,521 ms", which is neither the median nor any committed
pass value.)*

### Measured: a batch is tenant-homogeneous, and fill rate was the wrong metric

Whale workload, worker striping, 64 stripes, B=25:

| grouping | clearings/s | true fill |
| --- | --: | --: |
| **tenant-homogeneous** | **2,350** | **6.22** |
| spanning tenants | 2,177 | 25.00 |

*(**Correction, 2026-09-01:** the homogeneous fill read **6.37**, which is the maximum of the four
passes, not their median. The reducer's own statistic — `fill_med` in `RUN.sh` — is **6.22**, and
every neighbouring figure in this table is a median.)*

**Homogeneous batching is 8% faster while collecting a quarter of the members.** An earlier draft of
this decision proposed settling the question on fill rate, and that would have chosen wrong: what
pays is **account overlap inside the batch**, not batch size. Six members sharing one tenant's house
pair coalesce to one upsert; twenty-five spread across tenants coalesce to nothing and pay a
statement twenty-five times longer.

That is the same mechanism the spike measures from the other side (its section B) — **batching trades lock count for lock
hold time, and only wins when coalescing removes more acquisitions than the longer hold costs.** It
is a property of overlap, and tenant-homogeneity is the cheapest way to guarantee overlap.

So homogeneity is taken on throughput, and the three arguments that already favoured it come along
for free: a tenant's stall stays inside its own writes; ADR-0013's option of tightening the writer
policy to a per-tenant `WITH CHECK` stays open; and the whale — the case where batching matters —
fills its own batches anyway.

## 4 · A batch carries posted postings only

Pending transactions, resolutions and reversals **do not ride a batch**. They keep the single
statement they have today, which already carries the supersede gate, the server-derived mirror and
the pending rule.

This is a scope decision taken deliberately rather than a gap. Carrying them would mean reapplying
per member, inside SQL, what `plan_append` decides in pure Rust today — including
[ADR-0010](/decisions/0010-reconciliation)'s ruling that **the cache means posted**, so a pending
member's `input`/`output` are withheld while its `last_seq` advances. That ruling currently lives in
`postings.rs` *"where it is pure and testable, not in the statement"*, and moving it into a
per-member SQL branch trades a unit-tested invariant for one only an integration test can see.

**The accumulator routes rather than refuses.** A mixed arrival stream is partitioned: plain posted
postings accumulate, and a pending, resolving or reversing command dispatches on its own through the
existing statement. The caller sees no difference — same endpoint, same wire contract, same error
grammar — and nothing has to be rejected for being unbatchable.

The cost: the batching speedup applies to the plain posting path only, and any measured figure is an
upper bound on a writer that carried the rest.

## 5 · The use-case stays in the core; only the scheduler goes in the binary

The `Ledger` port is one method and `api` is generic over it, so an accumulating writer is **another
implementation of the same port** — the HTTP surface, the wire contract and the committed OpenAPI
spec do not move. It is not a *pure* decorator, because a batch is one statement rather than N calls:
`Repository` gains one method, implemented in `ledger-postgres` where the SQL lives.

**The split is by what needs a runtime, and only the half that does leaves the core.**

| half | where | why |
| --- | --- | --- |
| **the use-case** — given N members, run the bracket, resolve each member's outcome, answer each caller | `crates/ledger` | It is orchestration over the `Repository` port with no SQL and no runtime in it — the same thing `service.rs` already is for one member. It stays testable against a fake repository, which is where every branching property of this feature is held |
| **the machinery** — the queue, the dispatcher pool, the permits, the task | `crates/openledger` | Channels and a permit need `tokio`, and this is the only half that does |

**So no `tokio` enters the domain crate after all**, and the objection §1 was weighing disappears
rather than being traded away. `crates/openledger` already depends on `tokio` and is already the one
place `PgRepository` is wired into `LedgerService`; what it gains is a scheduler, not business
logic. The two alternatives both cost something this buys for free:

| | why not |
| --- | --- |
| **The whole thing in `crates/ledger`** | puts `tokio` in a crate whose entire dependency list is `serde_json`, `sha2`, `time`, `uuid` — no async runtime at all. `deny.toml` does not ban it, which is exactly why it would need arguing rather than discovering in a diff. The split above takes what this option wanted (the logic in the core) without the dependency it cost |
| **The whole thing in `crates/openledger`** | puts branching business logic — which member is refused, which replays, which commits — in the composition root, where the fake-repository test module that holds every other writer branch does not live |
| **A new `ledger-batch` crate** | defensible, and note that [ADR-0015](/decisions/0015-workspace-enforcement)'s refusal of a `ports` crate does **not** transfer: its operative reason was that *"the split buys a boundary nothing crosses"*, and a boundary keeping `tokio` off the domain crate is precisely what the capability map exists to check. Refused only because the split above already achieves that with no new manifest |

**The cost, stated:** ADR-0015 describes `openledger` as *"clap's derive, the exit codes, and the
composition root"*, and a dispatcher pool is a component rather than composition. That description
widens, even with the logic kept out of it. If the machinery grows past a few hundred lines,
`ledger-batch` is the right move and this ADR should be revisited rather than stretched.

## 6 · ADR-0002's scheduler sentence is untouched, not reinterpreted

*(**Correction, 2026-09-01:** this heading read "ADR-0002 is amended, not reinterpreted", which the
section's own body contradicts — it concludes that "ADR-0002's sentence stands untouched" and that
an amendment would have been owed only had the accumulator gone in `crates/ledger`. Neither
amendment nor reinterpretation happened to the scheduler sentence, and the heading now says so.
ADR-0002's **rule 3** is a different matter and *is* amended by this decision — corrected in place
[there](/decisions/0002-scaling), not here.)*

[ADR-0002](/decisions/0002-scaling) says, without qualification: **"The core needs no scheduler,
ever — every timer belongs to a rail."** Its layer table answers "needs a scheduler?" with a flat
**no** for layer 1.

An earlier draft of this decision proposed reading that as *really* meaning **durable** timers, since
ADR-0002's examples are hold expiry and the ACH return window. **That reading does not hold.** The
word "durable" appears nowhere in it; the sentence is universal; the examples used to narrow it are
imported from M8, a later document — and reading a rule's scope off a later document's examples is
the move that lets any timer in, since every future timer will also claim to drive nothing. The
roadmap argues the other side directly: *"A scheduler is not a throughput mechanism… Its place is
owning the sweep… **and draining events in batches.**"*

So the honest resolution is the one §5 already takes: **the accumulator is not in the core.** It is
in the binary, which is not layer 1, and ADR-0002's sentence stands untouched. Had it gone in
`crates/ledger`, this ADR would owe ADR-0002 an explicit amendment — and would have had to say so in
that word.

**The clock ban is not engaged either, and an earlier draft claimed it was.** `clippy.toml`
disallows `std::time::SystemTime::now` and `std::time::Instant::now` because a ledger's time is the
database's or the caller's ([ADR-0006](/decisions/0006-time-and-as-of)). `tokio::time` is not on
that list, so the lint would not fire. The substantive point survives — dispatch-on-completion reads
no clock at all, which is one more reason to prefer it to a window — but it is a property of the
design, not something the lint enforces.

## What has no peer, and is stated as our own

Three claims in this decision have **no citable precedent**, established by a targeted survey rather
than assumed:

- **Randomly-chosen stripes defeat batching**, because a batch scatters across stripes and leaves
  nothing to coalesce. **And it is weaker than spike 003 claimed**: measured here at +7.6% for
  choosing late, not the "worse than either lever alone" cancellation spike 003 reported on its
  bench schema. Published nowhere either way. **And this is the weaker direction of the
  antagonism** — the one that bites is batching defeating *striping*, which the cost list records
  under "the accumulator defeats striping's spread".
- **Choosing the stripe per *batch* rather than per *request* removes that antagonism.** No source
  discusses the distinction at all.
- **What a batch does when two members share an idempotency key.** Neither of the two systems that
  batch across requests documents it, nor does anyone else.

And one correction this decision makes to an existing document: **spike 003's external-validation
table conflated two mechanisms**, listing TigerBeetle's within-one-caller request packing beside
Uber's and Modern Treasury's cross-request accumulation. Only the latter two do what this ADR
proposes. Corrected in place.

## What it costs

- **The two levers are not equals, and the ADR should not present them as a pair.** Striping is
  worth **4.3×** for roughly ten lines of SQL and introduces no new failure mode. Batching is worth
  **nothing at all** until offered load approaches the unbatched ceiling — *at or a little above*
  ~1,940 clearings/s, which the ladder brackets from below only, about **39× ADR-0002's 50 TPS peak** —
  and it introduces a per-member gate, three batch-wide abort modes, head-of-line blocking, a
  walk-back that moves from unit-tested Rust into a SQL window function, and a statement that
  cannot carry supersessions. It ships because the single-member fast path makes it inert until it
  is needed, not because it pays at this ledger's sizing.
- **Batching is a net loss when members do not overlap** — measured at **2–2.8× slower** across 32
  uniform tenants, where a batch of 25 touches 25 different account pairs. Tenant-homogeneous
  grouping is what keeps that case out of the batched path.
- **Every saturation figure above comes from a multi-threaded harness, and the shipped binary is
  single-threaded.** The spike's harness sets `tokio = { features = ["full"] }` and runs its writers
  on a multi-threaded runtime. `openledger serve` builds `new_current_thread()`, and the workspace
  `tokio` does not enable `rt-multi-thread` — so it *cannot* be multi-threaded: the 32 dispatchers
  are I/O-concurrent on **one OS thread**. **Correctness is unaffected**, and so is striping:
  dispatchers awaiting database round trips need I/O concurrency rather than threads, and striping's
  only requirement — concurrent writers holding distinct indices — holds either way. What is
  affected is the **ceiling**. Serialization, the canonical hash and payload rendering all share one
  core in the shipped binary, so its saturation point is lower than the harness's, and **it has never
  been measured.** This bounds the *batching* argument specifically: the ~1,940 clearings/s unbatched
  ceiling, the "~39× ADR-0002's peak" headroom, and "32 concurrent batched statements collapse at
  2,000 TPS" are all properties of the harness's runtime, not of what ships. The pool depth of 32 is
  still the right default for the reason the bullet below gives — striping is what it buys, and
  striping does not depend on threads — but the load at which the deep pool starts costing something
  is unknown rather than known to be ~39× away. **The runtime is deliberately not changed here**:
  that is a design change and would need its own evidence, not a footnote in this one.
- **Cross-member overflow is an ungated new failure mode** (§3).
- **Head-of-line blocking crosses whatever a batch spans** (§3).
- **The batched statement omits the supersede machinery**, so its speedup does not transfer to
  resolutions and reversals (§4).
- **`openledger` stops being only a composition root** (§5).
- **`stripe_count` remains a hint, not an invariant** — unchanged from ADR-0013, and it is what lets
  an operator raise it with no backfill: `recon_balance_breaks` groups per stripe and a lazily
  created stripe reconciles clean on its first write, verified.
- **Striping is bounded by the dispatcher pool, not by `stripe_count`.** A pool of N reaches at most
  N stripes however many an account declares — measured at 64 declared, 32 reached, with the
  remaining gap to 64 closable only by more writers. So `stripe_count` above the pool depth is
  inert, and the two numbers are tuned together or not at all. An operator raising `stripe_count`
  alone, on the reasonable assumption that it is the striping knob, gets nothing; that surprise is
  this decision's, and it belongs in the operator documentation rather than in a comment. Written up
  in [ADR-0002 §"the operator story"](/decisions/0002-scaling).
- **The accumulator defeats striping's spread, and N is a ceiling nothing approaches.** The bullet
  above says "a pool of N reaches at most N stripes", and with `DISPATCHERS = 32` that will be read
  as 32. It is not what the books show. Counting distinct stripes on the 32-stripe receivable in the
  books the committed end-to-end tests leave behind — 40 concurrent postings each, one suite run:

  | book | stripes declared | stripes reached | largest single stripe |
  | --- | --: | --: | --: |
  | `e2e_striping_total` | 32 | **4** | 25 of 40 |
  | `e2e_striping_spread` | 32 | **3** | 22 of 40 |
  | `e2e_striping_gapless` | 32 | **4** | 25 of 40 |
  | `e2e_striping_raised` | 32 | **6** | 25 of 41 |

  Never anywhere near 32, and the largest stripe is **25 — `MAX_BATCH_MEMBERS` exactly**. One drain
  absorbed 62% of the burst onto one stripe. (The counts move a little between suite runs; the shape
  does not.)

  **The mechanism is dispatch-on-completion doing precisely what §2 designed it to do.** A dispatcher
  takes *everything* queued, so a burst arriving faster than a statement completes is swallowed by
  whichever handful of dispatchers happen to be free — and a dispatcher *is* a stripe, because the
  affinity value is its index. The more effective the batching, the fewer stripes the traffic
  touches. **This is the antagonism between the two levers running the other way**, and it is the
  direction that bites: the ADR documents only "randomly-chosen stripes defeat batching" and calls
  that novel, but a batch of 25 on one stripe is batching defeating striping, and no amount of
  `stripe_count` fixes it.

  It does not threaten correctness — a stripe is a hint, gaplessness is per `(account, stripe)`, and
  `recon_balance_breaks` groups per stripe — but it means the 4.31× is a *saturated closed-loop*
  figure and a bursty arrival pattern will not see it. **These are burst measurements**, taken from
  test books that post as fast as they can. **The steady-state low-load case is unmeasured**: there,
  each post takes whichever dispatcher is free, batches are one member, and spread should be better —
  should, because nobody has counted it.
- **The pool depth is one number serving two masters, and they pull opposite ways.** A pool of N
  reaches at most N stripes, so a shallow pool caps striping: 8 dispatchers reach 8 stripes and
  measure **3.42×** against 32 dispatchers' **4.31×**. But above the unbatched ceiling the policy's
  self-limiting means N concurrent *batched* statements on the shared rows, and 32 collapses there
  (1,964/s at p50 185 ms against 8's 1,999/s at 25 ms).

  **The default is 32, not 8.** A shallow pool pays its 21% striping penalty on *every* posting
  forever; a deep pool pays only above the unbatched ceiling — at or a little above ~1,940
  clearings/s, which is ~39× the peak ADR-0002 derives
  and past the point where this deployment has other problems. Section F's own run recommended 8 on
  the strength of the saturation row alone — that optimises the one load this ledger is documented
  not to have. A deployment that genuinely sustains load near the ceiling should lower it, and that
  belongs in operator documentation as a named trade rather than as a tuned constant.
