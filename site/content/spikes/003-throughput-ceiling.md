# Spike 003 — Where does the Postgres design top out?

> ## ⚠️ Read this before quoting any number below
>
> **The machine was never idle and its load was never recorded.** A re-audit measured
> the same A/B/C configuration twice, at loadavg ~1.5 and ~6.3:
>
> | | idle-ish | loaded |
> | --- | --- | --- |
> | A contended | 833 | 482 |
> | B contention-free | 9,873 | 3,994 |
> | C append | 10,913 | 5,514 |
> | **A→B ratio** | **11.85×** | **8.29×** |
>
> This document says elsewhere to "treat the ratios as the finding." **That is only
> half right — the ratios move ~30% too.** A is lock-bound and degrades least; B and
> C are CPU-bound and lose more, compressing the ratio. Every figure here is a
> *shape*, not a benchmark, and the honest form of each is a range.
>
> **The lock-free append row is not comparable to the others and must not be read as
> such.** Measured on 98,409 entries it produced a ledger that fails three of our own
> invariants: `balance_after = 0` on *every* entry, `account_seq` from a global
> sequence so *all 502 accounts* violate gaplessness, and `ledger_account_balances`
> entirely empty. It is not a faster ledger; it is not a ledger.


**The question.** [ADR-0001](/decisions/0001-rust-and-postgres) chose Postgres because
"throughput is not the constraint" — an argument that only works if you *know* the volume. As a
general open-source ledger we don't. So: what is the actual ceiling, what limits it, and what
moves it?

**Status:** closed. Produced [ADR-0002](/decisions/0002-scaling).

---

## The answer

**~800 clearings/s out of the box. ~8,200/s once you remove contention on one row. The
bottleneck is a single shared account row, and no amount of hardware fixes it.**

A *clearing* here is one card purchase settling: one transaction header plus three balanced
entries. A *hot account* is a ledger account touched by nearly every transaction — for us
`interchange_revenue` and `network_settlement_payable`, the accounts the business itself owns
rather than a customer. Every clearing must update those rows, and a row update takes a lock
held until commit, so every writer in the system queues behind them.

| Configuration | clearings/s | what changed |
| --- | --- | --- |
| baseline | ~800 | nothing — plateaus at 4 concurrent writers, then *declines* |
| contention removed, running balance kept | **8,222** | **the recommended shape** |
| ~~lock-free append~~ | ~~10,025~~ | ⚠️ **produces an INVALID ledger** — see banner |

Two ways to remove the contention, and they are not equivalent:

- **Striping** — store one logical account as N physical rows, pick one per write, `SUM` them to
  read. Gives ~8× **regardless of how traffic is distributed**, including with a single tenant.
  This is the mechanism.
- **Per-tenant house accounts** — give each tenant its own copy. Gives 8× *only if load is
  evenly spread across tenants*. At a realistic 90/10 skew (*skew* = one customer generating most
  of the volume) it gives **1.07×**, because that customer's own rows become the new hot row.

**Striping is the scaling story. Per-tenant splitting is a special case of it that happens to
pay under even load** — though it earns its place for other reasons ([spike
004](/spikes/004-chart-of-accounts): it is the modelling-correct thing to do, and it is
better for reconciliation).

## What it costs

- **Striping** needs a read-side `SUM` across stripes and a stripe column on the account.
- **Batching** (coalescing many postings into one write) is worth 4.4× on its own and needs no
  schema change — but it *cancels out* with random striping. Pick one, or use affinity striping
  where each writer owns a stripe, which makes them compose (4,790/s).

  > **Corrected 2026-09-01 by [spike 018](/spikes/018-batching-and-stripe-selection), which
  > re-measured this on the shipped writer. The cancellation does not reproduce.** Striping under
  > batching is still worth **1.42×** there, and choosing the stripe after the coalesce rather than
  > per member is worth **+7.6%** — a real effect and a small one, not "pick one". What replaces it
  > is worse for batching and was not visible on this bench schema: **batching itself is a net loss
  > unless members share accounts**, measured 2–2.8× *slower* across 32 uniform tenants. The
  > affinity-striping half of this bullet stands and is what shipped. The 4.4× is coalescing *within*
  > one request; coalescing *across* requests is worth nothing until offered load approaches the
  > unbatched ceiling.
- **Dropping the running balance** buys only 22% over contention-free locking and costs the O(1)
  balance read (0.018 ms → 105.91 ms at a million entries -- unmeasured here, see below), the corruption cross-check, and the
  gaplessness proof. **Recommendation: don't.**

## What this does NOT measure

- **Network latency.** Everything is localhost, where a round trip costs 0.05 ms. On RDS it is
  ~0.5 ms, which *reorders* the levers (batching matters more, striping less). **No number here
  should be published as an AWS figure until an RDS benchmark exists.**

  **A figure struck here as fabricated turns out to be real, and it was struck for the wrong
  reason.** The repository grep was correct — `1,631` is in no commit — but the number is published
  in the author's write-up, not the repository:
  [1,631.2 transfers/s at 36.8 ms each](https://pgrs.net/2025/05/16/pgledger-in-postgresql-is-fast/),
  measured on a Neon free tier against 10,636.8 and 7,558.9 on localhost. **That is the only
  measured over-a-network ledger number this project has found anywhere**, and it corroborates the
  RDS argument directly: 36.8 ms per transfer against 1.9 ms locally. The two localhost figures also
  corroborate this document's own thesis — same machine, same worker count, 1.41x purely from
  account contention.
- **`operating_cash`.** The benchmark posts only three legs and never touches the accounts that
  *cannot* be split (see [The account that breaks the model](#the-account-that-breaks-the-model)).
  It excluded the hard case.
- **Single node, no replication.** Synchronous replication will cost on every commit.
- **The auth path.** Cheaper (it writes no ledger entry) and serializes per company, so it
  parallelises far better. It has a latency deadline rather than a throughput target and needs
  its own spike.
- **500M entries or months of vacuum bloat.** Tested to 5M / 2 GB; see
  [Table size](#table-size-barely-matters).

---

# The evidence

## Method

A Go harness (`main.go`) drives the clearing path from
[the reference product spec §06 step 02](/card):

```
DR customer_receivable   500     per-company — spreads across 500 companies
CR network_settlement_pay 491    HOUSE account: touched by every clearing
CR interchange_revenue      9    HOUSE account: same
```

Each entry goes through `post_entry()` (`spikes/003-throughput-ceiling/bench_schema.sql`), an upsert that returns the new
balance and the next per-account sequence number in one statement. Legs are sorted by account id
before locking — the deterministic-ordering fix from [spike 001](/spikes/001-formance).

**Environment:** Postgres 18.6 in Docker, 16-core laptop, stock config (`shared_buffers` 128 MB).
Durability **on** — `fsync`, `synchronous_commit`, `full_page_writes` all enabled. These are not
fsync-disabled numbers.

**Read the ratios, not the absolutes.** Repeating one comparison three times gave 668/799/695,
8781/8222/4814, and 10025/9892/10889. Single-run figures elsewhere in this document should be
read the same way.

## The baseline, and the shape of the problem

| concurrency | clearings/s |
| --- | --- |
| 1 | 657 |
| **4** | **844** |
| 8 | 819 |
| 16 | 784 |
| 32 | 725 |
| 48 | 723 |

Textbook serialization: plateaus at 4 concurrent writers and then **declines**. Past saturation,
more concurrency buys only lock waiting — **adding workers to a struggling ledger makes it
slower.** Worth knowing before someone tries it at 3am.

For scale: the reference product spec sized for 20–50 TPS peak. The untuned baseline is **17–40× that**.

### The contention is on the shared row, not the customer's

Companies varied, house accounts left unsharded:

| companies | clearings/s |
| --- | --- |
| 1 | 714 |
| 1,000 | 799 |

**Routing every clearing through ONE company account costs ~12%.** The per-company receivable is
never the bottleneck, because the shared house rows saturate first. Contention on the account a
tenant owns does not matter; contention on the account everybody shares is the entire ceiling.

Confirmed again under lock-free append, where the numbers are identical at 3 accounts (10,952/s)
and 502 accounts (11,036/s). **Under locking, the ceiling is per contended *row*** — global
throughput ≈ (per-row rate) × (number of distinct hot rows), which is exactly why striping works.

### It is not I/O, not WAL, not table size

`synchronous_commit=off` changes nothing (~790/s unsharded, ~6,800/s striped either way). **Do
not trade durability for throughput in a ledger** — here you would not even get paid for it.

*(An earlier run of this was invalid: `ALTER SYSTEM` cannot execute inside a transaction block, so
`psql -c "ALTER SYSTEM …; SELECT pg_reload_conf();"` silently failed and the setting never
changed.)*

## Striping — the mechanism that works

Split each house account into K rows, pick one at random per posting, `SUM` to read. Formance
recommends the same shape (`@world:<random_id>`).

| stripes | clearings/s (c=16) | vs unsharded |
| --- | --- | --- |
| 1 | 804 | 1.0× |
| 8 | 2,460 | 3.1× |
| 32 | 4,441 | 5.5× |

At 64 stripes and c=32: **6,524/s**, and the curve now plateaus because the machine ran out of
cores rather than because of a lock. **The ceiling moved from the design to the hardware.**

### Striping survives skew. Per-tenant splitting does not.

*Skew* is uneven traffic — real payment volume is Zipfian, with one or two customers generating
most of it. The original tenant measurement used uniform random selection, which flatters any
per-tenant scheme.

Re-measured with a whale tenant, 32 tenants each with their own house accounts, c=32:

| distribution | clearings/s | vs 1-tenant baseline (875) |
| --- | --- | --- |
| uniform | 7,991 | 9.1× |
| whale = 50% | 1,435 | 1.6× |
| **whale = 90%** | **936** | **1.07×** |
| whale = 95% | 897 | 1.03× |

**At realistic skew the gain is 7%, not 8×.** The whale's own house accounts become the new hot
row. Per-tenant splitting *relocates* the bottleneck; striping *removes* it:

| config (c=32) | stripes=1 | stripes=64 | gain |
| --- | --- | --- | --- |
| 32 tenants, whale = 0.9 | 948 | 7,405 | 7.8× |
| **1 tenant** (per-tenant splitting is meaningless here) | 872 | **6,970** | **8.0×** |

Striping splits *within* whatever account is hot, so load distribution cannot defeat it.

### The uniform-load number, for completeness

Holding concurrency fixed at 32 and varying only how many tenants it divides among — so any gain
is purely removed lock collisions:

| tenants | total clearings/s |
| --- | --- |
| 1 | 881 |
| 8 | 3,848 |
| 32 | **7,296** |

Real, but conditional on even load. And the ceiling is **global, not per-tenant**: with 4 writers
per tenant, total rises (941 → 6,028) while per-tenant throughput *falls* (941 → 376). ~13k/s is
shared across everyone on that database, not 13k each. To get a ceiling *per* tenant you shard
tenants across database instances.

## Batching — 4.4×, and how it interacts

Batching means putting N clearings in one database transaction. Done naively it **deadlocks**:

| batch | clearings/s | |
| --- | --- | --- |
| 1 | 779 | |
| 2 | 87 | **deadlocks** |
| 25 | 70 | **deadlocks** |

Sorting legs *within* one clearing does not order locks *across* a batch — two workers take the
same accounts in opposite orders. Throughput collapses 10×.

The fix needs **batch-wide** ordering; and once sorted batch-wide you may as well collapse N
postings to one account into a single upsert, deriving each entry's running balance by walking
backwards from the returned total.

| batch (coalesced) | clearings/s | vs batch=1 |
| --- | --- | --- |
| 1 | 787 | 1.0× |
| 10 | 2,834 | 3.6× |
| **25** | **3,420** | **4.4×** |
| 100 | 3,460 | 4.4× |

Zero deadlocks, no striping, no schema change. **Correctness verified** over 1,721 accounts: zero
balance mismatches, zero sequence gaps, zero unbalanced transactions.

That coalesced write order is precisely what [spike 001](/spikes/001-formance) recorded as
Formance "demoting" the running balance. **It is not a demotion — it is what makes batching
possible.** We misread it the first time.

### Batching and random striping cancel — on this bench schema only

> **Corrected in place, 2026-09-01.** This heading and the "worst of each" conclusion below are
> **overturned by [spike 018](/spikes/018-batching-and-stripe-selection) §B**, which re-ran the
> comparison against the shipped writer — `migrations/00001_baseline.sql`, a single-call CTE pipeline
> at three round trips — rather than against `bench_schema.sql` and a per-leg `post_entry()` over
> six. There, striping under batching is still worth **1.42×** and per-batch placement is worth
> **+7.6%** over per-member. The table below is real; what it is not is a property of this design.
> The mechanism spike 018 substitutes generalizes better: **batching trades lock count for lock hold
> time, and pays only when members overlap** — which is why this section's uniform workload made it
> look like a cancellation.

| stripes | batch=1 | batch=25 |
| --- | --- | --- |
| 1 | 746 | **3,338** |
| 8 | 2,526 | 2,875 |
| **64** | **6,850** | 2,356 |

Monotonic in both directions — in *opposite* directions. Striping reduces contention by
*spreading* writes; coalescing reduces lock acquisitions by *concentrating* them. Stripe 64 ways
and a batch of 25 lands on ~25 different stripes: ~75 locks instead of ~27, with nothing left to
coalesce. **Doing both gives the worst of each** — *on this bench schema; see the correction above.
On the shipped writer doing both is worth 1.42×, and the penalty for choosing the stripe per member
rather than per batch is 7.6%, not a cancellation.*

### Affinity striping makes them compose

Give each writer its own stripe, so a whole batch lands on one row — coalescing perfectly *and*
contending with nobody:

| concurrency | worker-affinity | random (control) |
| --- | --- | --- |
| 16 | 4,580 | 2,645 |
| 32 | **4,790** | 2,395 |
| 48 | 4,640 | 2,385 |

**~2× random striping and flat across concurrency** — no longer contention-bound. The antagonism
is an artifact of random stripe *selection*, not a law.

The accounting name is a **per-writer clearing account**: each writer posts the shared leg to a
row it alone owns, every transaction stays balanced, and a periodic sweep consolidates into the
real house account. [Spike 004](/spikes/004-chart-of-accounts) refines the affinity key: it
should be the **tenant**, not the worker, because a business key survives a restart and needs no
sweep process.

> **That refinement is refuted, 2026-09-01, and this spike supplied the evidence against it.**
> [Spike 018](/spikes/018-batching-and-stripe-selection) §C measured both keys on the identical
> workload — 32 tenants, one generating 90% of traffic, 64 stripes — and the **worker** key delivers
> **2.8× what the tenant key does**, 1,897 against 677 clearings/s. The whale hashes to one stripe,
> so 64 stripes are 1 for 90% of the traffic. **That is this spike's own whale finding — the one two
> sections up, where per-tenant house accounts collapse from 9.1× under uniform load to 1.07× at
> 90/10 skew — applied one level lower.** A business key relocates the hot spot wherever the key is
> skewed, and the reason spike 004 gave was void anyway:
> [ADR-0013](/decisions/0013-write-path-contract) §4 removed the sweep by putting the stripe below
> the account, so no key needs to survive a restart. **The worker key is what shipped**
> ([ADR-0018](/decisions/0018-batching-and-stripe-selection) §1).

## Do we need the lock at all? (No — but that is not the lever)

Two `INSERT`s into `ledger_entries` never block each other. What serializes is the
read-modify-write on the balance row, and that exists **only because we carry a running balance
and a per-account sequence number**. The lock is a consequence of the running balance, not of
double-entry.

| strategy (unsharded, worst case) | c=4 | c=16 | c=32 |
| --- | --- | --- | --- |
| **pessimistic** (`ON CONFLICT DO UPDATE`, current) | 1,006 | 866 | 836 |
| **optimistic** (compare-and-swap + retry) | 679 | 493 | **437** |
| ~~**lock-free append**~~ (no balance row) | ~~2,482~~ | ~~8,046~~ | ~~**11,269**~~ ⚠️ **produces an INVALID ledger** — see banner |

### Optimistic locking is actively worse

Half the throughput, degrading with concurrency: 2.9 retries per success at c=4, **11.8 at c=32**.

*Optimistic* concurrency doesn't take a lock — it reads a version marker, does the work, then
writes conditionally on the version being unchanged, retrying if someone beat it. That wins when
conflicts are **rare**. On a row every writer touches conflicts are the norm, so almost every
attempt is wasted: it replaces efficient queuing with busy-retrying. (Same reasoning rules out
`SERIALIZABLE`, which is optimistic concurrency with extra bookkeeping.)

### THE CORRECTION — the lever is contention, not the lock

Lock-free append reaching 11,269/s (climbing to ~13,000 at c=96, the first configuration bounded
by *hardware* rather than a lock) looked like a 13× prize. **It contains a confound.** Append
writes one row per leg; pessimistic writes two — the balance upsert *and* the entry. Some of the
gap is doing less work, not avoiding locks.

Isolated, c=32, medians of 3 runs on a dedicated database:

| | writes balance row? | contended? | clearings/s |
| --- | --- | --- | --- |
| **A** pessimistic, one shared house row | yes | **yes** | 695 |
| **B** pessimistic, affinity stripes (no collisions) | yes | **no** | 8,222 |
| ~~**C** append, no balance row at all~~ | no | no | ~~10,025~~ ⚠️ **produces an INVALID ledger** — see banner |

- **A → B: 11.8×** — removing *contention*, running balance fully intact.
- **B → C: 1.22×** — everything else.

**~92% of the prize is contention removal. Abandoning the running balance adds ~20% more.** So the
choice was never "keep the running balance at 800/s or drop it for 13k". It is:

> **Keep the running balance AND remove the contention** — 8,222/s, with every correctness
> property retained.

### What dropping it would cost, measured

| entries in the account | running balance | aggregate on read |
| --- | --- | --- |
| 100 | 0.073 ms | 0.10 ms |
| 10,000 | 0.017 ms | 0.97 ms |
| 100,000 | 0.015 ms | 8.96 ms |
| 1,000,000 | **0.018 ms** | **105.91 ms** |

> **NO HARNESS IN THIS REPOSITORY PRODUCES THIS TABLE.** `main.go` here measures the
> WRITE path only; nothing in `tests/`, `spikes/` or `schema/` builds a
> 1M-entry account or times a balance read, and `tests/query_plans.sql` asserts
> plan SHAPE at 200,000 rows without timing anything. These four points are the
> most-quoted figures in the repository and the basis for "O(1) reads" everywhere
> it appears — and by this project's own rule they are **observations from a
> one-off run, not reproducible measurements**. What IS attested, on every run, is
> the shape: `tests/query_plans.sql` proves the current-balance read uses
> `uq_entries__account_seq` with no sort, and that the business-date aggregate is a
> scan. The ratio is the claim; the milliseconds are not.

The running balance is genuinely **O(1)** — flat across four orders of magnitude. The aggregate is
exactly linear and at a million entries is **~6,000× slower**, growing forever. Not survivable on
the auth path's ~1s deadline, so **checkpointing becomes mandatory** (materialise at entry N, read
`checkpoint + SUM(after N)`), which puts write work back and shrinks the gain further.

Monzo's latency figures are real — P99 400–500 ms falling to ~200 ms after March 2023 — but
**they attribute that to time-series reindexing of the entries table, not to precomputed blocks**,
which they describe as an option considered. "Monzo shipped exactly this" was this document's
inference and is withdrawn.

Three further losses beyond speed:

1. **The self-audit.** [ADR-0006](/decisions/0006-time-and-as-of) relies on the
   running balance and the recomputed aggregate always agreeing; divergence is a corruption alarm.
   With aggregation as the only source there is nothing left to check against.
2. **Gaplessness.** `UNIQUE (account_id, account_seq)` proves no entry is missing. A global
   sequence gives ordering but not gaplessness — sequences have holes after rollbacks.
3. **Cheap as-of reads** on the recorded axis become aggregates too.

**Recommendation: do not pursue lock-free append.** The contention was always the thing worth
removing; the lock never was.

## Round trips, and why localhost lies

Our clearing costs **6 round trips**: `BEGIN`, insert the transaction, three `post_entry` calls,
`COMMIT`. Collapsing into one server-side call:

| stripes | 6 round trips | 1 round trip | gain |
| --- | --- | --- | --- |
| 1 | 748 | 842 | +13% |
| 64 | 6,756 | **7,816** | +16% |

Only ~14%. Isolated at c=1: 6 round trips = 1.55 ms per clearing, 1 round trip = 1.30 ms.
**5 round trips cost 0.25 ms ⇒ ~0.05 ms each on localhost.**

That number is the whole point. On RDS in the same AZ a round trip is ~**0.5 ms**, ten to twenty
times higher. Modelled from the measured 1.30 ms of real work:

| | work | + round trips | total | per-connection |
| --- | --- | --- | --- | --- |
| 6 round trips | 1.30 ms | +3.0 ms | 4.3 ms | ~232/s |
| 1 round trip | 1.30 ms | +0.5 ms | 1.8 ms | ~555/s |

**On managed Postgres round trips dominate and the ordering of the levers changes** — batching and
single-call posting matter more, striping less, because striping buys parallelism against a
bottleneck network latency has already displaced. Modelled, not measured.

## Table size barely matters

The biggest caveat on every number above was "small, fully-cached table". Tested at 5,001,944
entries, **2,056 MB against 128 MB of `shared_buffers`** — 16× oversubscribed:

| Configuration | 43 MB table | 2 GB table | delta |
| --- | --- | --- | --- |
| unsharded | 748 | 744 | 0% |
| striped-64 | 6,756 | 6,212 | −8% |
| striped-64 + single call | 7,816 | **7,897** | 0% |

Essentially unchanged. The workload is append-only, so new entries land on the rightmost index
pages which stay hot regardless of cold history behind them, and the balance table is tiny. Many
ledger designs degrade badly here; this one does not. (5M is not 500M, and vacuum bloat over
months is not simulated — but the *mechanism*, a hot set bounded by account count rather than
entry count, should hold.)

## The account that breaks the model

An earlier claim that tenant-sharding gives "no cross-shard transactions, ever" is **false, and
the schema already said so.**

A *perimeter account* mirrors exactly one external balance — the reference product spec requires that "every
perimeter account has exactly one external balance that must agree with it". `operating_cash` and
`fbo_cash` are perimeter accounts: the money physically sits in **one bank account**, so they
cannot be split per tenant without destroying the reconciliation the design is built around. Same
for `facility_borrowings` — one warehouse line, one lender, one number.

**7 transactions touch `operating_cash`.** (Of 13 in this spike's own trace; the shipped
`tests/golden_trace.sql` that supersedes it runs 24, still 7 of them on `operating_cash`.) But the four *clearing*
transactions do not. So:

> **Clearings become tenant-local. Treasury does not.**

Clearings are the volume; treasury is a daily batch. Cross-shard treasury may be an acceptable
trade — but it is a trade to state explicitly, not a property to claim. See [spike
004](/spikes/004-chart-of-accounts) for the fix (intercompany clearing accounts), which is
required for per-tenant reporting to be correct at all.

**And the benchmark never touches these accounts.** `main.go` posts three legs only —
`customer_receivable`, `network_settlement_payable`, `interchange_revenue`. It omits
`operating_cash`, `fbo_cash`, `facility_borrowings`, `accrued_interest_payable`: precisely the
accounts that cannot be split. **Every tenant-scaling number here is conditional on a workload
that excludes the hard case.** Re-running against the full golden-trace account set, including a
daily treasury batch, is required before any of this informs M1.

## Summary — the levers, ranked

| Configuration | clearings/s | notes |
| --- | --- | --- |
| baseline (unsharded, unbatched) | ~800 | plateaus at c=4, then declines |
| optimistic locking | 437 | **worse**; 11.8 retries/success |
| + coalesced batching (25) | 3,420 | no schema change |
| tenants=16, own house accounts | 4,319 | uniform load only |
| + affinity striping + batching | 4,790 | levers compose; flat in concurrency |
| + random striping (64) | 6,850 | needs read-side `SUM` |
| random striping + batching | 2,356 | **worse than either** |
| + single-call posting, striped | **7,816** | best measured |
| best config on a **2 GB** table | 7,897 | size-insensitive |
| **contention-free pessimistic** | **8,222** | **the recommended shape** |
| ~~lock-free append~~ | ~~10,025~~ | ⚠️ **produces an INVALID ledger** — see banner |

**Caveat that outranks the table:** localhost numbers, where a round trip costs 0.05 ms. On RDS it
costs ~0.5 ms and reorders the levers. Treat the *ranking* as hardware-specific and the
*mechanisms* as general.

## Methodology caveats found auditing our own numbers

- **Two harnesses on one database invalidate everything.** A concurrent run (whose `setup()`
  issues `TRUNCATE … CASCADE`) produced deadlocks and wild variance until the benchmark moved to a
  dedicated database.
- **`post_clearing_mode()` does not sort accounts before locking**, unlike the Go path. With
  `stripes=1` no cycle can form so it happens not to deadlock, but it is not doing the
  deterministic ordering the design requires. **Production posting code must sort; this benchmark
  path does not.** A trap for anyone reading it as reference code.

## External validation — what the industry does

> **SOURCING: most third-party figures below were UNVERIFIED, and three of them no longer are.**
> The original charge stands for everything still unmarked: no fetchable URL makes a figure
> unverified, not merely unsourced, and twice already a figure attributed to a named project turned
> out never to have existed. Do not quote an unmarked number here as evidence without finding the
> source first.
>
> **Updated 2026-08-31 by [spike 018](/spikes/018-batching-and-stripe-selection)'s peer survey.** The
> Uber and Modern Treasury rows now carry primary sources and are verified. The TigerBeetle row is
> **corrected**: it was measuring a different mechanism from the other three, and this table's
> conclusion rested partly on that conflation. See the note under the table.


**We rediscovered a benchmark from 1985.** Jim Gray et al., *"A Measure of Transaction Processing
Power"* (Datamation, 1985) — the **DebitCredit** benchmark, later TPC-A/TPC-B — models 10
branches, 100 tellers, 10,000 accounts, so ~10 branch rows absorb every write. The
hot-shared-account bottleneck was constructed deliberately, forty years ago, as the defining OLTP
stress case. Our `network_settlement_payable` is TPC-B's branch record.

**The consensus fix is batching, not splitting** — and two teams rejected splitting explicitly.
**But "batching" names two different mechanisms in this table, and only two of these four teams do
the one this project means** (corrected 2026-08-31; the distinction is drawn below):

| Team | Approach | Which batching? | Evidence |
| --- | --- | --- | --- |
| **Uber** | 250 ms batch windows, one read + one write per batch | **across independent requests** | 3–4 → **30+ ops/sec per account**; bulk jobs 21–24 h → minutes. ~1 s hold SLA is the stated reason for 250 ms ([source](https://www.uber.com/en-SE/blog/high-throughput-processing/)) — **verified 2026-08-31** |
| **Modern Treasury** | Sync/async router; hot entries queued and coalesced | **across independent requests** | p90 processing 1 s; **1,200 txn/s** ([source](https://www.moderntreasury.com/journal/behind-the-scenes-how-we-built-ledgers-for-high-throughput)) — **verified 2026-08-31** |
| **TigerBeetle** | Up to 8,189 transfers per request ([docs](https://docs.tigerbeetle.com/coding/requests/)) | **within one caller** — *not* the same mechanism | — |
| **Fragment** | Coalesced balance updates | balance-update coalescing | p95 staleness 10 s at 10k entries/s ([source](https://fragment.dev/blog/building-balances-high-throughput-writes)) — **eventually-consistent path only** |

> **The Fragment row carried no source until 2026-08-27; it does now.** Fragment's own words: *"With
> 4 granularity levels, an average hierarchy depth of 5, and 4 lines per Ledger Entry, a typical
> Ledger Entry triggers 80 balance updates. At 10k Ledger Entries per second, the eventually
> consistent balance system has a p95 staleness of 10 seconds."* **Read the qualifier**: that path is
> their *default*, but accounts an authorization depends on must be configured `strong` and update
> synchronously, so the figure is not the latency of a balance you are allowed to enforce against.
> [Spike 009](/spikes/009-where-the-balance-lives#on-the-sourcing-of-this-spike) has how this was
> verified, and why that took two attempts.

Uber: *"Using multiple DynamoDB rows for a single account complicates the single-balance concept
and hot account detection."* TigerBeetle: *"a small number of hot accounts are often involved in a
large proportion of the transactions, so the shards responsible for those accounts become
bottlenecks."* — though that objection is against **distributed** sharding, not N rows in one
Postgres; ADR-0002 leaned on it slightly too heavily.

This ranks batching **above** striping more strongly than our localhost numbers do — which is
exactly the reordering the round-trip finding predicts for managed Postgres.

> **That ranking is weaker than it looks, and the reason is a conflation in the table above**
> (corrected 2026-08-31 by [spike 018](/spikes/018-batching-and-stripe-selection)'s peer survey).
> **"Batching" names two mechanisms that are not the same thing.** One accumulates *independent
> client requests* server-side and commits them together; the other packs work that was always
> **one caller's** unit into one storage transaction. Only **Uber** and **Modern Treasury** do the
> first. TigerBeetle does the second — its own protocol-batching PR describes a client library
> accumulating concurrent calls that share **one client instance**, and two client processes are
> never merged by the server ([PR #2617](https://github.com/tigerbeetle/tigerbeetle/pull/2617),
> [issue #489](https://github.com/tigerbeetle/tigerbeetle/issues/489)). Formance's `_bulk` endpoint
> and pgledger's multi-transfer call are the same within-one-caller shape.
>
> So the "consensus" is **two teams, not four** — and this row was being read as corroboration for a
> mechanism TigerBeetle does not implement. The 4.4× this document measured for coalesced batching
> is unaffected: that number is ours, measured here. What weakens is the external support for
> ranking batching above striping.
>
> **What TigerBeetle should be cited for instead is its *window policy*, which is more useful to us
> than the row it replaces.** It uses no timer at all: the stated model is explicitly Nagle-like —
> maintain at least one request in flight, so nothing waits when nothing is queued. PostgreSQL
> reaches the same conclusion at the commit layer, where `commit_siblings` defaults to **5** rather
> than 0 because a delay is pure latency cost if nobody else is around to join
> ([wiki](https://wiki.postgresql.org/wiki/Group_commit)).

**A third option we never measured**, from Modern Treasury's published guidance: *"ensure that the
hot account receives only asynchronous entries… the optimal design is locking only on these user
accounts."* Lock the tenant leg synchronously, let the house leg land asynchronously. Our own data
says the tenant leg is nearly free to lock (12% cost even fully concentrated). This is **memo
posting**, which core banking has used since the 1970s.

**Escrow is not the technique we were missing.** Escrow (O'Neil, TODS 1986; IMS/VS Fast Path,
1985) exists to enforce an invariant — *balance must not go negative* — on a hot account without
serializing. Our house accounts have no such invariant. Applied to an unconstrained accumulator,
escrow degenerates to "don't take the lock at all", which is exactly lock-free append. Where it
*would* apply: a per-tenant credit line with a hard limit on the auth path.

**Practices worth stealing:**

- **Shopify enforces cross-shard safety in CI** with verifiers named "Cross Shard Transaction".
  Our tenant-locality claim is only true if *enforced* — a CI check that no transaction's entry
  set spans more than one `tenant_id` is the mechanical version.
- **Modern Treasury degrades automatically on cache drift**: they verify cached balances against
  the sum of entries and *"automatically turn off cache reads for Accounts that have drifted"* —
  strengthening ADR-0006's self-audit from "alarm" to "alarm and fall back to truth".
- **A widely-cited sharding regret** is a missing customer ID on every transaction, which
  *"dramatically"* complicated later sharding — our `tenant_id NULL` problem exactly. This line
  attributed it to Nubank and `docs/roadmap.md` attributed the same lesson to Notion; neither has a
  source, so **the company is unverified**. The mechanics are the load-bearing part.

**The counter-argument to engage:** Adyen rejected domain-based sharding, shards round-robin
instead — *"if we would put each processing merchant in one database, you still need to go to
every shard when you need aggregate data."* Weaker for a ledger (balances, statements and a
tenant's own P&L are all tenant-local) but worth answering.

**Formance is said to self-report** being *"optimized for 1K writes per second on commodity
storage"* — **unverified**. No URL was recorded next to it, and an authenticated code search across
the whole `formancehq` org returns zero hits for "1K writes", "writes per second" or "commodity
storage". Treat the comparison as unsupported until someone finds the page.

## Reproduce

```sh
make up
psql "$DB_URL" -f ../002-sqlc-vs-jet/schema.sql
psql "$DB_URL" -f bench_schema.sql
go run . -c 16 -stripes 1  -d 5s     # unsharded
go run . -c 32 -stripes 64 -d 5s     # striped
```
