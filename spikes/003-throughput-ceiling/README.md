# Spike 003 — Where does the Postgres design top out?

**Question:** [ADR-0001](../../docs/decisions/0001-go-and-postgres.md) chose Postgres on the
grounds that "throughput is not the constraint" — justified by *knowing* the volume. If this
becomes a general open-source ledger, we no longer know our users' volume. So: what is the
actual ceiling, what limits it, and how far can it be pushed?

**Status:** closed. Produced [ADR-0007](../../docs/decisions/0007-open-source-positioning.md).

## Method

A Go harness ([`main.go`](./main.go)) drives the clearing path from
[v1-vision §06 step 02](../../docs/v1-vision.md) — one transaction header plus three balanced
entries:

```
DR customer_receivable   500     (per-company: spreads across 500 companies)
CR network_settlement_pay 491    (HOUSE: touched by every clearing in the system)
CR interchange_revenue      9    (HOUSE: same)
```

Each entry goes through [`post_entry()`](./bench_schema.sql), the M2 upsert that returns the new
balance and the next per-account sequence in one statement. Legs are sorted by account id before
locking — the deterministic-ordering fix from [spike 001](../001-formance/README.md).

**The house accounts are the whole story.** `customer_receivable` spreads across companies and
barely contends. `network_settlement_payable` and `interchange_revenue` are single rows that
*every* clearing must lock. That is the global serialization point.

**Environment, stated honestly:** Postgres 18.6 in Docker on a 16-core laptop, stock config
(`shared_buffers` 128MB), table under 50MB so everything is cached. Durability is **on** —
`fsync=on`, `synchronous_commit=on`, `full_page_writes=on`. These are not fsync-disabled numbers.

## Result 1 — the unsharded ceiling is ~840 clearings/s

| concurrency | clearings/s | entries/s |
| --- | --- | --- |
| 1 | 657 | 1,971 |
| 2 | 833 | 2,498 |
| **4** | **844** | **2,532** |
| 8 | 819 | 2,458 |
| 16 | 784 | 2,353 |
| 32 | 725 | 2,174 |
| 48 | 723 | 2,170 |

Textbook serialization: it plateaus at concurrency **4** and then **declines**. Past the point
where the hot row is saturated, more concurrency buys only lock waiting. Adding application
workers to a system in this state makes it slower, which is worth knowing before someone does it
in production at 3am.

**For scale:** v1-vision sized for 30k–150k transactions/month — under 1 TPS average, 20–50 TPS
peak. The unsharded design delivers **roughly 17–40× that stated peak** without any tuning. If
peak runs 20–30× average for card spend, ~840/s peak supports something on the order of 50–100M
transactions/month. That is a very large fintech, on one unremarkable Postgres.

## Result 2 — per-account contention on the CUSTOMER account is irrelevant

Companies varied, house accounts left unsharded (c=16):

| companies | clearings/s |
| --- | --- |
| 1 | 714 |
| 10 | 814 |
| 100 | 794 |
| 1,000 | 799 |

**Routing every single clearing through ONE company account costs only ~12%.** The per-company
receivable is not a bottleneck at any cardinality, because the shared house accounts saturate
first. This is the finding that reorients everything: *contention on the account a tenant owns
does not matter. Contention on the account everybody shares is the entire ceiling.*

## Result 3 — tenants stripe for free, IF house accounts are per-tenant

Each tenant given its **own** house accounts, one stripe each (c=16):

| tenants | clearings/s | vs 1 tenant |
| --- | --- | --- |
| 1 | 790 | 1.0× |
| 2 | 1,250 | 1.6× |
| 4 | 2,126 | 2.7× |
| 8 | 3,367 | 4.3× |
| 16 | 4,319 | 5.5× |

Tenant count scales almost exactly like stripe count — 16 tenants ≈ 16 stripes. Multi-tenancy
*is* striping, for free.

**But our schema gets this backwards.** `owner_type = 'house'` accounts carry `tenant_id NULL`
and are global — so `uq_accounts__house` guarantees there is exactly **one**
`interchange_revenue` row for the entire deployment. In a single-product deployment that is
correct. In a multi-tenant open-source ledger it means **every tenant contends with every other
tenant on the same two rows**, and the system gets slower as it gets more successful. House
accounts must be per-tenant. See [ADR-0007](../../docs/decisions/0007-open-source-positioning.md).

## Result 4 — striping the hot accounts gives ~8×

Split each house account into K rows, pick one at random per posting, sum them to read the
balance. Formance recommends the same shape (`@world:<random_id>`).

At concurrency 16:

| stripes | clearings/s | entries/s | vs unsharded |
| --- | --- | --- | --- |
| 1 | 804 | 2,413 | 1.0× |
| 2 | 1,071 | 3,213 | 1.3× |
| 4 | 1,581 | 4,744 | 2.0× |
| 8 | 2,460 | 7,381 | 3.1× |
| 16 | 3,643 | 10,928 | 4.5× |
| 32 | 4,441 | 13,322 | 5.5× |

Pushing stripes to 64 and raising concurrency:

| concurrency | clearings/s | entries/s |
| --- | --- | --- |
| 8 | 3,187 | 9,560 |
| 16 | 5,063 | 15,188 |
| **32** | **6,524** | **19,573** |
| 48 | 6,476 | 19,428 |

**~7.7× over unsharded**, and the curve now plateaus at concurrency 32 on a 16-core machine —
i.e. it has stopped being lock-bound and become CPU-bound. **The ceiling moved from the design
to the hardware.**

## Result 5 — naive batching deadlocks; coalesced batching gives ~4.4×

Batching N clearings into one DB transaction, sorting legs *within* each clearing (the
[spike 001](../001-formance/README.md) deterministic-ordering fix):

| batch | clearings/s | |
| --- | --- | --- |
| 1 | 779 | |
| 2 | 87 | **deadlocks** |
| 5 | 45 | **deadlocks** |
| 25 | 70 | **deadlocks** |

Sorting legs within one clearing does **not** order locks across a batch. Two workers take the
same accounts in opposite orders and deadlock. Throughput collapses by 10×.

The fix requires **batch-wide** lock ordering — and once you sort batch-wide, you may as well
collapse N postings to the same account into **one** upsert that advances the balance by the
total and `last_seq` by the count, then derive each entry's running balance by **walking
backwards** from the returned totals.

That is precisely Formance's inverted write order, which [spike 001](../001-formance/README.md)
recorded as them "demoting" the running balance. **It is not a demotion. It is what makes
batching possible**, and we mis-read it the first time.

| batch (coalesced) | clearings/s | entries/s | vs batch=1 |
| --- | --- | --- | --- |
| 1 | 787 | 2,362 | 1.0× |
| 2 | 1,211 | 3,632 | 1.5× |
| 5 | 2,089 | 6,267 | 2.7× |
| 10 | 2,834 | 8,502 | 3.6× |
| **25** | **3,420** | **10,260** | **4.4×** |
| 50 | 3,300 | 9,900 | 4.2× |
| 100 | 3,460 | 10,380 | 4.4× |

Zero deadlocks, no striping, no schema change. Plateaus around 25.

**Correctness verified**, not assumed — after a coalesced run over 1,721 accounts:

```
balance mismatches:                    0
accounts with gapped/duplicated seq:   0
transactions that do not balance:      0
```

## Result 6 — striping and batching are ANTAGONISTIC

The result nobody would predict from reasoning. Same stripe sweep, two batch settings (c=32):

| stripes | batch=1 | batch=25 |
| --- | --- | --- |
| 1 | 746 | **3,338** |
| 2 | — | 3,256 |
| 4 | — | 3,112 |
| 8 | 2,526 | 2,875 |
| 16 | — | 2,562 |
| 32 | — | 2,406 |
| **64** | **6,850** | 2,356 |

Monotonic in both directions, in **opposite** directions.

The mechanism: striping reduces contention by *spreading* writes across rows; coalescing reduces
lock acquisitions by *concentrating* writes onto one row. Stripe a house account 64 ways and a
batch of 25 clearings lands on ~25 different stripes — so you take ~75 row locks instead of ~27,
and coalescing has nothing left to collapse. **Doing both gives the worst of each.**

**Pick one, based on whether you control the write pattern:**

- **Batching** when clearings arrive as a stream you own — a processor webhook queue drained by a
  Temporal workflow. Needs no schema change and no read-side `SUM`.
- **Striping** when writes arrive independently and cannot be grouped — the auth path.

## Result 7 — `synchronous_commit=off` buys nothing here

~790/s unsharded and ~6,800/s striped either way. The bottleneck is row-lock contention and CPU,
not WAL flush. **Do not trade durability for throughput in a ledger** — and here you would not
even get paid for it.

*(An earlier run of this measurement was invalid: `ALTER SYSTEM` cannot execute inside a
transaction block, so `psql -c "ALTER SYSTEM ...; SELECT pg_reload_conf();"` silently failed and
the setting never changed. Re-run with separate statements.)*

## Summary — the levers, ranked

| Configuration | clearings/s | entries/s | notes |
| --- | --- | --- | --- |
| baseline (unsharded, unbatched) | ~800 | ~2,400 | plateaus at c=4 |
| + coalesced batching (25) | 3,420 | 10,260 | no schema change |
| + striping (64) | **6,850** | **20,550** | needs read-side `SUM` |
| both | 2,356 | 7,069 | **worse than either** |
| tenants=16, own house accounts | 4,319 | 12,956 | free if multi-tenant |

## What this means

1. **The Postgres choice survives the reframing, but the reasoning must change.** ADR-0001's
   "throughput is not the constraint" was an argument from *known* volume. The defensible version
   for an open-source project is: *here is the measured ceiling, here is what limits it, and here
   is the lever.* Same conclusion, honest reasoning.
2. **Hot-account striping is the single highest-leverage feature** and must be designed in, not
   left as folklore. It is the difference between 840/s and 6,500/s, and it costs one integer on
   the account row plus a `SUM` on the balance read.
3. **The bottleneck is structural, not incidental.** It is not I/O, not connections, not the
   deferred balance trigger, and not WAL flush. It is *N writers contending for one row*. No
   amount of hardware fixes it; only reducing contention does. Worth stating plainly in the docs,
   because the instinct when a ledger is slow is to buy a bigger instance, and here that does
   nothing.
4. **House accounts must be per-tenant in a multi-tenant deployment.** Our current
   `uq_accounts__house` guarantees exactly one `interchange_revenue` per *deployment*. That is
   right for one product and wrong for a shared ledger — it makes tenants contend with each other
   and the system slow down as it succeeds.
5. **Batching and striping must not both be recommended.** They cancel. The docs need to say
   which one applies to which write path, or users will apply both and land at 2,356/s wondering
   why their "optimised" ledger is 3× slower than the default.

## What this does NOT measure

Stated so the numbers are not over-read:

- **Small table.** Under 50MB, fully cached. At 100M+ entries, index maintenance, vacuum, and
  cache misses all bite. The *contention* finding is structural and will not improve with size,
  but the absolute numbers will fall.
- **Single node.** No replication, no failover, no `synchronous_standby`. Synchronous replication
  will cost meaningfully on every commit.
- **Stock config on a laptop.** Tuned RDS/Aurora with provisioned IOPS behaves differently —
  probably better on I/O, similar on the contention limit since that is a lock-ordering property.
- **The clearing path only.** The auth hot path is cheaper (writes no ledger entry) and
  serializes *per company*, so it parallelizes far better. It was not measured here and has a
  latency deadline rather than a throughput target — it deserves its own spike.
- **No batching.** Everything is one clearing per transaction. Batching N clearings per
  transaction would amortize commit cost substantially.

## Reproduce

```sh
make up
psql "$DB_URL" -f ../002-sqlc-vs-jet/schema.sql
psql "$DB_URL" -f bench_schema.sql
go run . -c 16 -stripes 1  -d 5s     # unsharded
go run . -c 32 -stripes 64 -d 5s     # striped
```
