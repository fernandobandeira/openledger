# Spike 018 — Do batching and stripe selection compose on the shipped writer?

**Status:** closed. Produced [ADR-0018](/decisions/0018-batching-and-stripe-selection).
*(Directory `spikes/022-batching-and-stripe-selection/`; the spike directories carry their own
numbering.)*

---

## The answer

**Stripe selection is worth 4.3× and the key must be the *worker*, not the tenant. Cross-request
batching is worth nothing unless the batch members share accounts — and at the load this project is
sized for, they do not.**

| | |
| --- | --- |
| **The shipped SQL's baseline**, contended, full pipeline | **623 clearings/s** at 32 writers (660 at 8) |
| **Striping**, 64 stripes, worker-keyed | **2,687/s — 4.3×** |
| Striping, 64 stripes, random-keyed | 2,503/s — 4.0× |
| **Worker vs tenant key on the identical whale workload** | **1,897/s against 677/s — 2.8×.** The tenant key does not work |
| Batching at uniform load across 32 tenants | **2–2.8× SLOWER** than not batching |
| Batching under a whale, worker-striped | 2,350/s against 1,897 — 1.24× |
| **Batching's latency, at 20–800 TPS offered** | **identical to not batching** — if it dispatches on completion |
| A 25 ms window, at 50 TPS offered | **10× the median latency**, to collect 2.26 members |

Six results that were not expected going in *(this line read "four" while listing five; it now lists
six)*:

1. **[Spike 004](/spikes/004-chart-of-accounts)'s refinement is refuted.** It proposed keying the
   stripe on the *tenant* because a business key survives a restart and needs no sweep. Its reason
   was already obsolete — [ADR-0013](/decisions/0013-write-path-contract) §4 removed the sweep by
   putting the stripe below the account — and the measurement now refutes the choice itself: under a
   dominant tenant, the worker key delivers **2.8× what the tenant key does on the identical
   workload** (1,897 against 677 clearings/s), because 90% of the traffic hashes to one stripe. This
   is [spike 003](/spikes/003-throughput-ceiling)'s own whale finding, one table lower down.
2. **[Spike 003](/spikes/003-throughput-ceiling)'s "batching and random striping cancel" does not
   reproduce.** On this writer, striping under batching is still worth **1.42×**. What actually
   happens is different and worse: **batching itself is a net loss** unless members contend.
3. **The batched path's `ORDER BY` is the only thing ordering its locks, and the single path's is a
   second line of defence.** Deleting the batched sort fails the committed concurrency test 4 of 4,
   with 95–218 deadlocks reaching callers as HTTP 500s; deleting the single path's leaves the suite
   green, because `coalesce` returns a `BTreeMap` and the order is already settled in Rust.
   **Batching trades a compile-time ordering guarantee for a runtime one.** This is the configuration
   the roadmap said did not exist. *(This item read "the `ORDER BY` is load-bearing on both write
   paths, and the batched path is the more fragile one — 294 deadlocks per 1,000 statements on the
   single path and 833 on the batched", which §E's own correction block retracts: the 294 came from a
   harness arm that let raw leg order reach the bind, which the shipped writer cannot do.)*
4. **The per-member admissibility gate is 3.8× faster than the alternative**, and it is the only one
   of the two that leaves a refused caller able to retry.
5. **Batching is not load-bearing until offered load approaches the unbatched ceiling — at or a
   little above ~1,940 clearings/s, roughly 39× ADR-0002's 50 TPS peak.**
   Below that, a batching policy that dispatches on completion is indistinguishable from not
   batching, and a fixed window is a pure latency tax. The two levers this spike was asked to
   compare are therefore not equals: **striping pays now; batching pays for somebody else's
   deployment**, and ships inert.
6. **The accumulator defeats striping's spread** (§G, added after the shipped writer existed). A
   dispatcher drains everything queued and *is* a stripe, so a burst lands on a handful of stripes:
   32 declared, **3–6 reached**, with 25 of 40 postings on one. The antagonism this spike named as
   novel runs the *other* way in the shipped system, and it is worth far more than the +7.6% the
   named direction costs.

---

## Why this spike exists at all

[Spike 003](/spikes/003-throughput-ceiling) answered both questions in 2026 — on a **bench schema**
(`spikes/003-throughput-ceiling/bench_schema.sql`), driven by a Go harness calling a per-leg
`post_entry()` over six round trips. The shipped writer is a single-call CTE pipeline at three round
trips with in-request coalescing, and by the roadmap's own admission **its throughput had never been
measured**. Every figure below runs against `migrations/00001_baseline.sql` applied by the compiled
`openledger migrate`, plus `schema/chart.sql`.

**Three things this harness does that spike 003's did not**, each of which moves the numbers:

- **The real idempotency hash and the real payload.** Spike 003's harness computed neither. This one
  reproduces `canonical_bytes` byte for byte and renders the versioned payload object per post.
- **The workload the API can actually express.** Spike 003 posted three legs. `expand_postings`
  emits **two legs per `source → destination` posting**, so leg counts are always even — spike 003's
  clearing is 2 postings and **4 legs** here, with the receivable taking two. The first draft of this
  harness hand-built three legs and was 25% cheaper per clearing than the writer under study,
  reproducing spike 003's own confounded-comparison error.
- **Consequently, a non-zero walk-back offset.** With three legs every `seq_offset` is zero, so
  `offsets_back_from_last_seq` — specified in ADR-0013, unit-tested in `postings.rs` — had **never
  been exercised against a database**. Correcting the workload is what first ran it.

Correcting those dropped the baseline from 779 to **623 clearings/s**. The lower number is the
honest one.

**What this measured, stated precisely — and a correction, 2026-09-01.** The summary table above used
to head its first row "this binary's own baseline", and the ADR and the service page repeated the
claim as "this binary's own throughput is measured". **It is an overclaim, and the harness manifest
settles it.** `spikes/022-batching-and-stripe-selection/harness/Cargo.toml` depends on `clap`,
`sqlx`, `tokio`, `uuid`, `serde_json` and `sha2` — and on **none** of `ledger`, `ledger-postgres`,
`api` or `openledger`. It builds the statements as strings, re-implements `canonical_bytes` and the
SHA-256 hash with `sha2`, has no HTTP client and no accumulator. So what these numbers measure is
**the shipped SQL, driven by a bespoke harness against the shipped schema** — which is a large
advance on spike 003's bench schema and per-leg function, and is *not* a load test of the compiled
binary. The HTTP surface, `axum`'s dispatch, `serde` deserialization, the real accumulator's queue
and the real connection pool are all outside the measurement. **A load test of the binary itself is
still owed**, and the roadmap says so.

---

## Method

Every ground rule below is a lesson from [spike 003](/spikes/003-throughput-ceiling)'s own banner,
which exists because it measured on a machine whose load it never recorded and moved its headline
figure by 40% on re-audit.

- **Two runs, 302 configurations: 227 closed-loop over four interleaved passes, and 75 open-loop
  (section F) over three.** Passes are the outermost loop across all sections *of a run*; they do
  **not** interleave across runs, because the two runs were started separately and the open loop
  needs a different harness mode. Drift is therefore reported per run:

  | run | configurations | passes | drift, pass medians against pass 1 |
  | --- | --: | --: | --- |
  | closed loop (§A–§E) | 227 | 4 | **rate** 1.000, 1.010, 1.000, 1.002 |
  | open loop (§F) | 75 | 3 | **p50** 1.000, 1.012, 1.013 |

  The open loop pins its rate to the offered arrival trace, so rate drift is 1.000 by construction
  there and latency is the only thing free to move. It moved 1.2–1.3% — a wider band than the closed
  loop's, and the reason §F's comparisons are all *paired within a pass* against an identical trace.

  **Correction, 2026-09-01.** This bullet, and the ADR it produced, used to describe "302 measured
  configurations over seven interleaved passes" under a single 1.000–1.010 drift band. That summed
  two runs' passes into one sequence they never formed, and applied the closed loop's band to the
  open loop, where the p50 pass medians fall outside it.
- **Idleness measured directly, not inferred.** `loadavg` has a 60-second time constant, so a short
  settle reports the *previous* run's oracle as this run's idleness. Replaced with `/proc/stat`
  deltas sampled per configuration.

  **Correction, 2026-09-01: this bullet used to end "CPU busy held at 8.2–9.1% throughout", and that
  is false — 181 of the 227 closed-loop configurations fall outside that band.** The committed
  `cpu_busy_pre_pct` spans **2.2–18.9%** with a median of **8.7%** across the closed-loop run, and
  the open-loop run's median is **3.2%** on a quieter machine. 8.2–9.1% was the range of the four
  *pass* medians, quoted as though it were the range of the measurements.

  This matters more here than it would elsewhere, because this section exists to state the lessons
  from [spike 003](/spikes/003-throughput-ceiling)'s banner — a spike that measured on a machine
  whose load it never recorded. Recording the load and then summarising it as a band four times
  narrower than it was is the same failure with a better instrument. What the numbers do support is
  the weaker and sufficient claim the drift check makes independently: **no pass-level trend**, and
  a per-cell median over three or four passes that a single noisy configuration cannot move.
- **Every configuration gated on `SELECT * FROM reconciliation` at ten zeros.** All 302 passed —
  227 closed-loop and 75 open-loop. The gate was proved red first, by corrupting a balance row and
  confirming exit 2 — an unfalsified gate is decoration.
- **The transaction count is asserted against the book**, because the oracle has a blind spot this
  spike found the hard way (below).
- **Scratch database dropped per run**, so accumulated debris is not background load on later cells.

**One methodology finding worth carrying forward.** The reconciliation oracle appeared to cost ~200s
and to scale superlinearly. It does neither: a scratch database filled in seconds and read once has
no `pg_statistic` rows, so the ten checks' joins over `ledger_entries` plan as nested loops. Cold
221s, post-analyze **4.6s**. One explicit `ANALYZE` before the oracle costs 0.03–0.20s and took the
whole matrix from infeasible to routine. **Any future spike that builds a scratch book and measures
against it should `ANALYZE` first.**

---

## A · The baseline, and what a stripe is worth

Single tenant — the contended case, where one house-account pair absorbs every clearing. 32 writers.

| selection | stripes | stripes reached | clearings/s | vs baseline |
| --- | --- | --- | --- | --- |
| none | 1 | 1 | **623** | 1.00× |
| none | 8 | 1 | 629 | 1.01× |
| none | 64 | 1 | 617 | 0.99× |
| random | 8 | 8 | 1,646 | 2.64× |
| random | 64 | 64 | 2,503 | 4.02× |
| worker | 8 | 8 | 2,131 | 3.42× |
| **worker** | **64** | **32** | **2,687** | **4.31×** |

The three `none` rows are the variance control — `none` ignores `stripe_count`, so those are three
nominally different cells measuring one configuration, and they agree within 2%. That is the noise
floor, measured rather than assumed.

**Worker beats random at every stripe count**, and at 64 it wins while reaching only 32 stripes,
because `writers = 32` bounds it. Raising the writer count is what would close the remaining gap to
64.

**This is 4.3×, not [ADR-0013](/decisions/0013-write-path-contract)'s 7.7–9.2×, and the two are not
the same measurement.** ADR-0013's figure is **upserts/s against one logical account**. This is
clearings/s through a writer that also hashes a payload, claims a key, and inserts an event, a
transaction and four entries — one of whose accounts is per-company and never contended. A
three-account clearing where one leg spreads cannot reach the single-row ratio, by Amdahl. An
earlier draft of this spike's specification stated the comparison the wrong way round and would have
reported ADR-0013 as overstated; it is not.

**With 32 uniform tenants the whole effect nearly vanishes** — 4,473/s unstriped against 5,016
striped, 1.12×. House accounts are keyed `(tenant_id, purpose, currency)`, so 32 tenants are already
32 independent house-account pairs and there is little contention left for a stripe to remove. This
matters for reading section B.

## B · Placement, and the cancellation that does not reproduce

Uniform 32 tenants, offered load scaled with batch size so database concurrency stays constant.

| selection | placement | stripes | B=1 | B=25 |
| --- | --- | --- | --- | --- |
| none | per-batch | 1 | 3,894 | 1,427 |
| none | per-batch | 64 | 3,998 | 1,428 |
| random | per-batch | 64 | 4,265 | **1,964** |
| random | per-member | 64 | — | **1,825** |
| worker | per-batch | 64 | 4,182 | **2,020** |
| worker | per-member | 64 | — | 1,999 |

**Placement is confirmed and it is small.** For `random`, choosing the stripe *after* the coalesce is
worth **+7.6%** over choosing it per member — the batch lands on one stripe per account instead of
scattering across 25. For `worker`, `tenant` and `none` the two placements are statistically
identical, exactly as predicted: a constant expression cannot scatter. **But per-batch random still
loses to worker**, so choosing late does not substitute for an affinity key.

**Spike 003's cancellation does not reproduce.** Striping under batching is worth 1.42× here
(1,427 → 2,020), not a cancellation. What replaces that finding is worse for batching:

*(**Correction, 2026-09-01:** this read "1.43× (1,425 → 2,020)". The committed medians are 1,427.35
and 2,019.7 — a ratio of **1.415**, so 1.42×. 1.43 is 2,020 ÷ 1,412, which is the `worker` unstriped
row, not the `none` row the parenthetical names. The table's 1,425 was the same slip and is now
1,427.)*

**Batching costs 2–2.8× at uniform load, in every mode and both placements.** The reason is visible
in section A: with 32 tenants there is almost nothing to coalesce, because a batch of 25 drawn
uniformly touches ~25 *different* tenants' account pairs. You pay a much larger statement — 25
events, 25 transactions, 100 legs, window functions, the admissibility join — and coalesce nothing.

**The mechanism, stated so it generalizes:** batching trades *lock count* for *lock hold time*. A
single posting takes three row locks and holds them for one short statement. A batch of 25 that
shares accounts takes the same three and holds them once for all 25 — a clear win. A batch of 25
that shares nothing takes ~50 locks and holds every one of them for the duration of a statement
twenty-five times longer, while 31 other writers do the same. **Batching pays if and only if
coalescing removes more lock acquisitions than the longer hold time costs**, and that is a property
of how much the members overlap, not of the batch size.

> **Read the B=1 against B=25 comparison carefully.** Database concurrency is held constant at 32
> writers — that is the deliberate fix for an earlier version in which batch size and concurrency
> were the *same knob*, so the nominal batch sizes were never reached and B=100 ran with a single
> uncontended writer. What varies with B is therefore the *offered* load (32 × B outstanding). A
> reader may fairly object that 800 outstanding requests is past saturation and that latency, not
> throughput, is what should be compared there. Section F is the cleaner comparison: open loop, a
> fixed arrival rate, and latency percentiles.

## C · The affinity key, under a dominant tenant

32 tenants, one generating 90% of traffic, 64 stripes. **This is the section that decides the key.**

| selection | B | grouping | clearings/s | true fill |
| --- | --- | --- | --- | --- |
| **tenant** | 1 | homogeneous | **677** | 1.00 |
| tenant | 1 | spanning | 698 | 1.00 |
| **worker** | 1 | homogeneous | **1,897** | 1.00 |
| worker | 1 | spanning | 1,851 | 1.00 |
| tenant | 25 | homogeneous | 1,913 | 5.55 |
| tenant | 25 | spanning | 2,051 | 25.00 |
| **worker** | 25 | **homogeneous** | **2,350** | **6.22** |
| worker | 25 | spanning | 2,177 | 25.00 |

*(**Correction, 2026-09-01:** the two homogeneous fills read **6.37** and **5.37**, and neither is a
median. 6.37 is the *maximum* of the worker cell's four passes — 6.22 / 6.16 / 6.22 / 6.37 — and
5.37 is simply the tenant cell's fourth pass of 5.32 / 5.73 / 5.74 / 5.37, neither their median nor
their minimum. Every other figure in this table is a median, and the reducer's own statistic
(`fill_med` in `RUN.sh`) is **6.22** and **5.55**. A first version of this note called 5.37 "the
minimum of the tenant cell's"; the minimum is **5.32**, and a correction that misreads the passes it
is correcting is worth recording rather than quietly rewriting.)*

**Worker-keyed selection delivers 2.8× what tenant-keyed selection does on this workload** — 1,897
against 677 clearings/s, the same 32 tenants, the same whale, the same 64 stripes, only the
selection expression changing. The whale hashes to one stripe, so 64 stripes are 1 for 90% of the
traffic — precisely the mechanism by which per-tenant house accounts collapsed to 1.07× in spike 003.

**Correction, 2026-09-01: this paragraph used to read "tenant-keyed selection at 64 stripes delivers
677 clearings/s against an unstriped baseline of 623 — it buys 9%", and that comparison has no
control.** Every whale configuration in the results files is `mode: tenant` or `mode: worker`;
**`mode: none` under a whale was never run.** The 623 is section A's single-tenant, no-whale
baseline — a different workload — so the ratio was paired against something it does not pair with.
The worker-versus-tenant row above is the same-workload comparison, and it is the one that decides
the key. **What tenant-keyed striping buys over no striping at all, under a whale, is unmeasured**,
and a `--mode none --whale 0.9` arm is the rung that would measure it.

**And batching pays here, where it did not in section B**: worker 1,897 → 2,350 (1.24×), tenant
677 → 1,913 (2.8×). Concentrated traffic means batch members share accounts, so coalescing has work
to do. Batching rescues tenant-keyed striping precisely because tenant-keyed striping has failed.

**Tenant-homogeneous batching wins on throughput while collecting a quarter of the members** — 2,350
at fill 6.22 against 2,177 at fill 25. **Fill rate is the wrong metric.** What pays is account
overlap inside the batch, not batch size, and a homogeneous batch of six sharing one tenant's house
pair coalesces better than a spanning batch of twenty-five that shares nothing.

## D · Failure isolation, and a blind spot in the oracle

| | clearings/s |
| --- | --- |
| poison-pill batch, **admissibility gate on** | **901** |
| poison-pill batch, gate off (abort, retry singly) | 235 |

**3.8× — and throughput is the lesser reason to prefer it.**

**The gate must sit above the key claim, and getting that wrong is a correctness defect the ten
checks cannot see.** In the first implementation the gate filtered *downstream* of the claim, so a
member refused for naming an unknown account still committed its `ledger_events` row. Its
idempotency key was then permanently burned: the retry finds the claim held, the replay lookup finds
an event joined to no transaction, and the caller is answered `transaction_id: null,
replayed: true` — which [ADR-0013](/decisions/0013-write-path-contract) states is the legitimate
shape for the majority of accepted operations, which write no transaction at all. **A refusal became
indistinguishable from success, permanently.**

**No reconciliation check reads `ledger_events`.** All ten were re-read to confirm it. So the oracle
reported ten zeros on a book carrying the defect, and would have kept doing so. It was found by
asserting the event count directly. Hoisting the gate above the claim fixed it: the same batch went
from 25 events / 24 transactions to **24 / 24**.

**Two batch-wide aborts, both reproduced, both failing closed:**

- **Two members sharing one idempotency key.** `ON CONFLICT DO NOTHING` claims one event; joined
  back by key it fans to both ordinals; two transactions against one `event_id` hit
  `uq_txn__one_per_event` and raise `23505`. Measured: **0 events, 0 transactions, 0 entries.** A
  client retrying its own request is the single most likely thing a batch window collects.
- **Head-of-line blocking.** `INSERT … ON CONFLICT DO NOTHING` waits on a concurrent uncommitted
  insert of the same key: a 1,500 ms held claim stalled a batch of 25 for **1,519.5 ms** (three
  passes at 1,519.4 / 1,520.4 / 1,519.5 — the median). *(**Correction, 2026-09-01:** this read
  "1,521 ms", which is neither the median nor any committed pass value.)*

## E · The `ORDER BY`, proved load-bearing on both paths

The roadmap's standing complaint: *"removing or inverting the statement's `ORDER BY` survives the
entire suite today."* Six accounts, writers presenting adversarial orders.

| arm | mechanism | a model? | `ORDER BY` removed | present |
| --- | --- | --- | --- | --- |
| caller-legs, single path | two writers take the same rows in opposite order | no | 10 deadlocks, **294/1k stmts** | **0**, 614–672/s |
| **account-subsets, batched** | concurrent batches draw different account subsets | no | 10–12 deadlocks, **833/1k** | **0**, 2,297–2,330/s |
| descending-model, batched | the statement itself run `DESC` | **yes** | 10 deadlocks, 1000/1k | — |

*(**Correction, 2026-09-01:** the caller-legs `present` column read "634–672/s". The six order-on
caller-legs runs — two stripe counts × three passes — span **613.6 to 671.9 clearings/s**. 634 is the
minimum of the `stripe_count 1` cell only and 672 the maximum of the `stripe_count 64` cell, so the
old range mixed one cell's floor with another's ceiling and excluded the actual minimum. The batched
row's 2,297–2,330 is the full span of its own six runs and is unchanged.)*

**The batched path is the more fragile one**, at 833 deadlocks per 1,000 statements against the
single path's 294. That was not expected: an earlier smoke run showed the honest batched arm at zero
deadlocks and suggested coalescing might make the batched path *harder* to deadlock. At full run
length it does not.

> **Correction, from injecting against the shipped writer rather than the harness (2026-09-01).**
> The single-path row above overstates the shipped writer's exposure, and the reason is worth more
> than the row was.
>
> **The shipped single path is ordered twice.** `coalesce` returns a `BTreeMap`, so
> `columns_for_deltas` binds its arrays already sorted by `(account_id, currency)` — the lock order
> is settled in Rust *before* the statement runs, and the SQL `ORDER BY` re-establishes it. Delete
> the SQL sort from the shipped single statement and the suite stays **green 3 of 3**, because the
> Rust guarantee still holds. The harness's `caller-legs` arm reached 294/1k only by letting leg
> order reach the bind, which the shipped writer cannot do: **that arm measures a writer without the
> `BTreeMap`, not this one.**
>
> **The batched path has no such second line, and that is exactly why its sort is load-bearing.**
> Its delta order comes from a `GROUP BY` across members inside the statement, so the SQL `ORDER BY`
> is the *only* thing ordering those locks. Deleting it fails the committed concurrency test **4 of
> 4**, with 95–218 deadlocks reaching callers as HTTP 500s. And a sort two writers can *disagree*
> about — `ORDER BY input, output, account_id` — fails **both** paths, which is the property the
> sort actually encodes.
>
> So the honest ranking is not "batched is more fragile than single". It is: **batching trades away
> a compile-time ordering guarantee for a runtime one**, and the runtime one has to be tested
> because nothing else holds it.
>
> One trap for anyone repeating this: `cargo test -p e2e` does **not** rebuild the binary the suite
> spawns. Three injection runs came back green against a stale binary. Always `cargo build
> --workspace` first.

**A caller cannot influence lock order on the batched path**, because the coalesce normalizes it
before the insert — so `--lock-order-hazard caller-legs` is *refused* in combination with a batch,
rather than silently doing nothing. That refusal is the finding. An earlier version of this harness
conflated "the caller presents reversed legs" with "the statement runs in a different order", and
credited real deadlocks to a flag that was inert on that path.

Deadlocked transactions write nothing, so every one of these configurations still reconciled at ten
zeros. Throughput is reported as `null` wherever deadlocks occurred: a deadlock loses a whole batch
with no retry and each victim waits out `deadlock_timeout`, so a rate there would be meaningless.

**The reversal arm ran clean** — 628–654 clearings/s, zero deadlocks — exercising the mirror path's
`GROUP BY` order source for the first time. That is the second of the two order sources the roadmap
requires M2's proof to cover.

## F · Latency, and whether the window should exist at all

Every figure above is closed-loop, so its batches are always full — a **ceiling**. This section is
open loop: a fixed Poisson arrival rate, on the whale workload, with a **deterministic arrival
trace** so every policy at a given rate saw the identical trace. These are paired comparisons.

| offered TPS | on-completion p50 | **no batching** p50 | window 5 ms | window 25 ms | on-completion fill |
| --: | --: | --: | --: | --: | --: |
| 20 | 6.16 ms | **5.46 ms** | 13.64 | 31.49 | 1.00 |
| 50 | 3.07 | **2.95** | 9.62 | 29.47 | 1.00 |
| 200 | 2.27 | **2.28** | 8.32 | 29.44 | 1.00 |
| 800 | 2.38 | **2.41** | 8.38 | 29.24 | 1.02 |

**Dispatch-on-completion is indistinguishable from not batching at all**, across ADR-0002's entire
derived range and forty times past it — within 0.7 ms at 20 TPS and within 0.03 ms at 800. It
batched with nobody because there was nobody to batch with, and charged nothing for the privilege.

**The fixed window is a pure, unrecovered latency tax below saturation.** A 25 ms window costs 10×
the median latency at 50 TPS to collect 2.26 members. Its fill of 1.48 at 20 TPS says the same thing
one rung lower: the window essentially never fills at the load this ledger is sized for.

### Above the ceiling it inverts, and the policy is not knob-free

At 2,000 TPS, where the unbatched arm can no longer carry the offered load (it reaches ~1,940/s):

| arm | achieved/s | p50 | p95 | fill |
| --- | --: | --: | --: | --: |
| on-completion, **32 writers** | **1,964** | 184.6 ms | 1,056 ms | 18.7 |
| on-completion, **8 writers** | 1,999 | 25.1 | 195.5 | 11.6 |
| window 5 ms | 2,002 | **12.6** | **24.1** | 11.5 |
| no batching | 1,934 | 82.2 | 319.9 | 1.00 |

> **The ceiling is not precisely bracketed and should not be quoted as if it were.** The ladder
> stops at 2,000 TPS offered, where the unbatched arm carried 1,930–1,962/s across three passes with
> its median latency swinging **14.5 ms, 82.2 ms, 122.8 ms** — that spread is the signature of a
> system at its knee, not a stable measurement. So the ceiling is at or a little above ~1,940/s, and
> a rung at 3,000 or 4,000 TPS is what would locate it. An earlier draft of this write-up quoted
> "~1,790/s", which was this section's `--window-ms 0` diagnostic figure misread as the unbatched
> ceiling; the multiple against ADR-0002's 50 TPS peak is ~39×, not the ~90× that error produced.

Dispatch-on-completion **self-limits to exactly `writers` concurrent statements by construction** —
the permit spans batch formation through commit. Above the ceiling that is 32 concurrent *batched*
statements on the whale's shared rows, which is section B's concurrency collapse arriving by another
road. The windowed arm escapes it only because its timer incidentally caps how many statements it
puts in flight — about 1.3 writers busy at 2,000 TPS, 4% of the pool.

**So the policy removes a latency knob and exposes a pool-depth knob.** "No timer, therefore no
tuning" is not what the numbers say; the tuning moved. At 8 writers the policy is best or tied at
every rate this ledger will see and competitive at one it will not.

### The mechanism is backpressure, not a zero timer — and this is an argument, not a measurement

`--window-ms 0` genuinely never sleeps, and it does **not** by itself produce this policy. Setting
the timer to zero removes the wait but leaves the *shape*: a collector still forms batches and hands
them to a dispatching stage. If that hand-off is unbounded, nothing pushes back on the collector, so
under a backlog it forms a batch the instant one member is available and the queue migrates into the
channel as a long run of one-member batches. Coalescing never receives anything to coalesce, because
the coalesce sits downstream of where the queue moved to. What produces the policy is a bound that
reaches back to formation — the spike's **semaphore of writer permits**, acquired before a batch is
formed and released only after its statement commits, which is the same turn the shipped dispatcher
takes inside its own loop. The permitted arm is the `on-completion, 32 writers` row of the table
above: **fill 18.7, 1,964/s, p50 185 ms.**

**Correction, 2026-09-01: this section used to cite an unbounded-hand-off measurement — "fill 1.05,
1,789/s, p50 695 ms" — and that configuration does not exist.** It appears in neither results file
and nowhere in `transcript.txt`. The open-loop run's arms at each rate are exactly five:
on-completion at 32 writers, on-completion at 8, a 5 ms window, a 25 ms window, and an unbatched
`--batch 1` control. There is no `--batch 25` arm with an unbounded hand-off — the harness never grew
one, because the accumulator it drove already held its permit across the turn. All three numbers are
withdrawn rather than corrected. The companion figure was real but misquoted as **fill 18.5**; the
committed median is **18.66**, the 18.7 the table already prints.

This matters because that sentence was the sole evidence for the paragraph justifying the shipped
architecture. The paragraph survives as reasoning about topology — a buffer between formation and
statement is where a backlog goes, so removing the buffer is what makes the backlog show up as batch
size instead — and the ADR states it that way. **The alternative was reasoned about, not measured.**

### Two load-generator defects found before this section could be trusted

Both would have invalidated every cell at 800 and 2,000 TPS:

- **The arrival stream capped at ~710/s and reported that as achieved.** Tokio's timer wheel ticks
  at 1 ms, so a single stream sleeping an exponential gap cannot exceed it — `--offered-rate 2000`
  measured 710, and all four policies would have been compared against one artefact of the harness.
  Fixed by superposing `ceil(rate/250)` independent Poisson streams of rate `r/n` (exact, not an
  approximation) against an absolute accumulated deadline. Arrivals now land within 0.1% of target.
- **A lost-wakeup race in the accumulator.** `Notify::notify_waiters` stores no permit, and the
  `select!` built its `notified()` future *after* reading the queue, so an arrival landing in that
  gap was dropped until a fallback tick. At 20–50 TPS that lost tick is the same order as the entire
  clearing.

---

## G · Added 2026-09-01 — the accumulator defeats striping's spread, and the harness could not see it

Every section above holds batching and striping in one harness that never routed through the shipped
accumulator. Counting stripes in the books the committed end-to-end suite leaves behind shows an
interaction none of them measured, and it runs the opposite way to the one this spike named as novel.

The four striping tests each fire 40 concurrent postings at one receivable declaring
`stripe_count = 32`, through the real binary over real HTTP. One suite run:

| book | stripes declared | stripes reached | largest single stripe |
| --- | --: | --: | --: |
| `e2e_striping_total` | 32 | **4** | 25 of 40 |
| `e2e_striping_spread` | 32 | **3** | 22 of 40 |
| `e2e_striping_gapless` | 32 | **4** | 25 of 40 |
| `e2e_striping_raised` | 32 | **6** | 25 of 41 |

**Three of the four put 25 postings on one stripe, and 25 is `MAX_BATCH_MEMBERS` exactly.** A single
drain absorbed 62% of the burst.

**The mechanism is dispatch-on-completion working as designed.** A dispatcher takes *everything*
queued, so a burst arriving faster than a statement completes is swallowed by whichever few
dispatchers are free — and a dispatcher **is** a stripe, because the affinity value is its pool
index. The better the batching, the fewer stripes the traffic touches. Section A's 4.31× is a
*saturated closed-loop* figure measured with 32 independent writers each posting one clearing at a
time; put the same 32 dispatchers behind an accumulator and a burst reaches a handful of them.

**This is the antagonism between the levers running the other way**, and it is the direction that
bites. The "What has no peer" section below claims *randomly-chosen stripes defeat batching* — true,
and worth +7.6% to fix. Batching defeating *striping* is worth a great deal more, and no
`stripe_count` fixes it: the reachable count is bounded by the pool, and the *occupied* count by how
concentrated the arrivals are.

Nothing here threatens correctness — a stripe is a hint, gaplessness is per `(account, stripe)`, and
`recon_balance_breaks` groups per stripe, which is what those four tests assert. **But these are
burst measurements**, taken from tests that post as fast as they can, and the counts move between
suite runs. **The steady-state low-load case is unmeasured**: there every batch is one member, each
post takes whichever dispatcher is free, and spread should be much better — *should*, because nobody
has counted it.

---

## What this does not measure

- **The compiled binary.** The harness
  (`spikes/022-batching-and-stripe-selection/harness/Cargo.toml`) depends on `clap`, `sqlx`,
  `tokio`, `uuid`, `serde_json` and `sha2` and on **none** of `ledger`, `ledger-postgres`, `api` or
  `openledger`. It issues the shipped SQL against the shipped schema, but builds the statements as
  strings, re-implements the canonical hash, and has no HTTP client and no accumulator. HTTP
  dispatch, deserialization, the real queue and the real connection pool are outside every figure
  here.
- **Anything over a network.** Localhost, where a round trip is ~0.05 ms. This is
  [spike 003](/spikes/003-throughput-ceiling)'s largest caveat and it is unchanged.
- **The shipped binary's runtime, which is not this one.** This harness sets
  `tokio = { features = ["full"] }` and runs on a multi-threaded runtime, so its writers get real
  parallelism for serialization, hashing and payload rendering. `openledger serve` builds
  `new_current_thread()` and the workspace `tokio` does not enable `rt-multi-thread` at all — its 32
  dispatchers are I/O-concurrent on **one** OS thread. That is sound for what they do (they spend
  their time awaiting database round trips) and it does not touch striping, whose requirement is
  only that concurrent writers hold distinct indices. What it does touch is every **saturation**
  figure on this page — the ~1,940/s unbatched ceiling and the 2,000 TPS collapse rows. On one core
  the shipped binary's own ceiling is necessarily lower, and **it has not been measured.**
- **The batched statement with supersessions.** It hardcodes `'posted'` and binds neither
  `resolves_id` nor `reverses_id`, so it carries no supersede gate and no mirror derivation. **Every
  batching figure here is therefore an upper bound** on a batched writer that carried them.
- **Pending members in a batch.** Same reason. [ADR-0010](/decisions/0010-reconciliation)'s *the
  cache means posted* rule lives in `plan_append` as pure Rust; a batched form would have to
  reapply it per member inside SQL.
- **Cross-member arithmetic overflow.** `plan_append` refuses overflow per member with
  `checked_add`; the batch re-coalesces in SQL at `bigint`, so a cross-member sum can overflow where
  no member does. Ungated, and untested by a workload with fixed amounts.
- **Stripe counts above 64, or writer counts above 32.** `worker` at 64 stripes reached only 32.
- **Stripe occupancy at steady-state low load.** Section G's counts are all bursts. What a pool of 32
  dispatchers occupies when every batch is one member is the case this ledger actually runs at, and
  it has not been counted.
- **Long-run vacuum behaviour.** Runs are ten seconds on a fresh book.

## What has no peer

A targeted survey of TigerBeetle, Formance, Modern Treasury, Uber, Fragment, pgledger, blnk, Midaz
and the escrow literature found **no published source** for three claims this spike makes:

- that randomly-chosen stripes interact badly with batching;
- that choosing the stripe per *batch* rather than per *request* is the fix;
- what a batch should do when two members share an idempotency key — **nobody documents this**, not
  even the two systems that batch across independent requests.

The survey also corrected an error in [spike 003](/spikes/003-throughput-ceiling): its
external-validation table listed TigerBeetle's within-one-caller request packing beside Uber's and
Modern Treasury's cross-request accumulation, as if they were one mechanism. Only the latter two do
what this spike measures. Corrected in place, and Uber's 250 ms window and Modern Treasury's figures
now carry primary sources.

## Reproduce

```sh
cd spikes/022-batching-and-stripe-selection
DURATION=10s WARMUP=3s SETTLE=3 PASSES_A=3 PASSES_B=4 PASSES_C=4 PASSES_D=3 PASSES_E=3 PASSES_F=0 ./RUN.sh trim
DURATION=10s WARMUP=3s SETTLE=3 ./RUN.sh f       # the open-loop dispatch ladder
./RUN.sh reduce results-<uuid>.jsonl      # medians, spread, and the per-pass drift check
```

`SPEC.md` is the specification the harness was built to, with its own falsified claims corrected
inline; `DESIGN-QUESTIONS.md` holds the design arguments the numbers do not settle.
