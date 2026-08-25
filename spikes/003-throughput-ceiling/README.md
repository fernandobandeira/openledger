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

## Result 8 — worker-affinity striping makes the two levers COMPOSE

Result 6 showed striping and batching cancel. The mechanism suggests the fix: they cancel because
stripes are chosen **at random**, scattering a batch across many rows so coalescing has nothing to
collapse. Give each writer **its own stripe** and a whole batch lands on one row — which both
coalesces perfectly *and* contends with nobody.

Measured, `-stripe-mode=worker`, stripes = concurrency, batch = 25:

| concurrency | worker-affinity | random (control) |
| --- | --- | --- |
| 4 | 4,435 | — |
| 8 | 4,575 | — |
| 16 | 4,580 | 2,645 |
| 32 | **4,790** | 2,395 |
| 48 | 4,640 | 2,385 |

**~2× random striping, and flat across concurrency** — it has stopped being contention-bound
entirely. The antagonism is an artifact of random stripe selection, not a law.

The accounting name for this is a **per-writer suspense account**: each writer posts the shared
leg to a row it alone owns, every transaction stays balanced, and a periodic sweep consolidates
suspense into the real house account. Worth noting that pure striping without batching still wins
*on localhost* (6,850) — but see Result 9 for why that ordering flips on managed Postgres.

## Result 9 — round trips, and why localhost lies about them

Our clearing costs **6 round trips**: `BEGIN`, insert the transaction, three `post_entry` calls,
`COMMIT`. Collapsing that into one server-side `post_clearing()` call:

| stripes | 6 round trips | 1 round trip | gain |
| --- | --- | --- | --- |
| 1 | 748 | 842 | +13% |
| 16 | 4,043 | 4,301 | +6% |
| 64 | 6,756 | **7,816** | +16% |

Only ~14% — because localhost RTT is negligible. Isolating it at c=1:

| | clearings/s | ms per clearing |
| --- | --- | --- |
| 6 round trips | 645 | 1.55 |
| 1 round trip | 771 | 1.30 |

**5 round trips cost 0.25ms ⇒ ~0.05ms per round trip on localhost.**

That number is the whole point. On RDS in the same AZ, RTT is roughly **0.5ms** — ten to twenty
times higher. Modelled from the measured 1.30ms of actual work:

| | work | + round trips | total | per-connection |
| --- | --- | --- | --- | --- |
| 6 round trips | 1.30ms | +3.0ms | 4.3ms | ~232/s |
| 1 round trip | 1.30ms | +0.5ms | 1.8ms | ~555/s |

**On managed Postgres, round trips dominate, and the ordering of the levers changes.** Batching
and single-call posting matter *more* than they appear here; striping matters *less*, because
striping buys parallelism against a bottleneck that network latency has already displaced.

This is modelled, not measured — a real RDS benchmark is required before publishing a number.
But it is the single strongest reason not to trust a localhost benchmark for an AWS claim.

## Result 10 — table size barely matters

The largest caveat on every number above was "small, fully-cached table." Tested: 5,001,944
entries, **2,056 MB against 128 MB of `shared_buffers`** — 16× oversubscribed.

| Configuration | 43 MB table | **2 GB table** | delta |
| --- | --- | --- | --- |
| unsharded | 748 | 744 | 0% |
| striped-64 | 6,756 | 6,212 | −8% |
| striped-64 + single call | 7,816 | **7,897** | 0% |

**Essentially unchanged.** The workload is append-only, so new entries land on the rightmost
index pages, which stay hot regardless of how much cold history sits behind them — and the
balance table is tiny and fully cached no matter the entry count.

This is a real property of the design worth stating, because many ledger designs degrade badly
here. It does not extend indefinitely: 5M is not 500M, and months of vacuum and bloat are not
simulated. But the *mechanism* — hot set bounded by account count, not entry count — should hold.

## Result 11 — do we need the lock at all? (No.)

The prior results all assume a lock on the shared account. Worth asking whether it is required.

**It is not required by double-entry.** Two `INSERT`s into `ledger_entries` do not block each
other. What serializes is the read-modify-write on the balance row — and that exists **only
because we carry `balance_after` and a per-account `account_seq`**. The lock is a consequence of
the running balance, not of the accounting.

Three strategies, unsharded (worst case), single-call so the comparison is clean:

| strategy | c=4 | c=16 | c=32 |
| --- | --- | --- | --- |
| **pessimistic** (`ON CONFLICT DO UPDATE`, current) | 1,006 | 866 | 836 |
| **optimistic** (compare-and-swap on `last_seq` + retry) | 679 | 493 | **437** |
| **lock-free append** (no balance row, global sequence) | 2,482 | 8,046 | **11,269** |

### Optimistic locking is actively worse here

437/s at c=32 versus 836 — **half**. And the retry count tells the story:

| concurrency | retries per success |
| --- | --- |
| 4 | 2.9 |
| 16 | 10.6 |
| 32 | 11.8 |

Optimistic concurrency wins when conflicts are **rare** — it trades a cheap lock for an
occasional wasted attempt. On a row every writer touches, conflicts are not rare, they are the
norm, so almost every attempt is wasted and the cost grows with concurrency. Postgres's row lock
already queues waiters efficiently; optimistic replaces queuing with **busy-retrying**. It is the
wrong tool for a hot shared account, and the measurement is unambiguous.

(The same reasoning rules out `SERIALIZABLE` isolation here — SSI detects conflicts and aborts,
which is optimistic concurrency with extra bookkeeping.)

### Lock-free append is worth 13×

**11,269 clearings/s (33,807 entries/s)** — and unlike every other configuration it *scales with
concurrency* rather than plateauing or declining. There is no contention left to remove.

This is Formance's `moves` shape: a global `bigserial` (which cannot collide), no per-account
sequence, no balance row, balance computed by aggregation.

**The cost is real and lands on reads.** Without a running balance, every balance read aggregates
the account's entries — O(n) in an account's history. The auth hot path needs `posted` in
milliseconds. The standard resolution is **periodic checkpoints**: materialise the balance at
entry N, then a read is `checkpoint + SUM(entries after N)`, bounding the scan. That is a real
design with real complexity, not a free win.

Note it also interacts with [ADR-0003](../../docs/decisions/0003-bitemporal-balances.md), which
already chose aggregate-on-read for the effective axis. Dropping the running balance would make
*both* axes consistent — one mechanism instead of two.

### Is the number per-account or global? Global — and that is the point

Every run below has `stripes=1`, so **every clearing touches the same two house accounts**:

| accounts in the system | pessimistic | lock-free append |
| --- | --- | --- |
| 3 (one company + one house pair) | 765 | 10,952 |
| 502 (500 companies + one house pair) | 834 | 11,036 |

Two things fall out.

**Under pessimistic locking the ceiling is per contended ROW, not per account and not global.**
Concentrating all traffic on 3 accounts costs almost nothing (765 vs 834) because the two shared
house rows were already the limit. Global throughput ≈ *(per-row rate) × (number of distinct hot
rows)* — which is exactly why striping works, and why a single un-striped shared row caps the
whole system at roughly 800–1,000/s no matter how many accounts exist.

**Under append there is no per-row ceiling at all.** 10,952 with three accounts, 11,036 with 502
— identical. Appends to the same account do not block each other, so account count and account
concentration stop being variables.

### Is 11k a hard limit? No — it is where this laptop stops

| concurrency | clearings/s | entries/s |
| --- | --- | --- |
| 32 | 10,992 | 32,975 |
| 64 | 12,651 | 37,954 |
| **96** | **13,042** | **39,127** |
| 128 | 12,868 | 38,603 |

It keeps climbing to ~13,000 at c=96 on a 16-core machine, then flattens as cores run out. This
is the **first configuration whose ceiling is hardware rather than design** — every other one
plateaued because of a lock. A bigger instance moves this number; a bigger instance did nothing
for any of the others.

### CORRECTION — the lever is contention, not the lock

The framing above ("lock-free append is worth 13×") contains a confound, caught by isolating it.
**Append mode writes one row per leg; pessimistic writes two** (the balance upsert *and* the
entry). So some of the gap is simply doing less work, not avoiding locks.

Isolating it — three configurations at c=32, medians of 3 runs on a dedicated database:

| | writes balance row? | contended? | clearings/s |
| --- | --- | --- | --- |
| **A** pessimistic, one shared house row | yes | **yes** | 695 |
| **B** pessimistic, worker-affinity (each writer owns its rows) | yes | **no** | 8,222 |
| **C** append, no balance row at all | no | no | 10,025 |

- **A → B: 11.8×.** This is removing *contention*, with the running balance fully intact.
- **B → C: 1.22×.** This is everything else — abandoning the balance row entirely.

**About 92% of the prize is contention removal. Abandoning the running balance adds ~20% more,
and costs the O(1) balance read** (0.018ms → 105.91ms at a million entries), **the
`balance_after`-vs-aggregate corruption cross-check, and the gaplessness proof.**

So the earlier framing was wrong in an important way. The choice is not "keep the running balance
at 800/s, or drop it for 13k/s." It is:

> **Keep the running balance AND remove the contention.** That is 8,222/s — 82% of the lock-free
> number — with every correctness property retained.

Lock-free append is not the largest lever. It is a 22% top-up on the largest lever, bought with
the properties the ledger's auditability rests on. **Recommendation: do not pursue it.** Remove
contention instead — per-tenant house accounts, worker affinity, or striping.

### What it costs, measured

The read side, forced onto the index path (20 iterations each):

| entries in the account | running balance | aggregate on read |
| --- | --- | --- |
| 100 | 0.073 ms | 0.10 ms |
| 10,000 | 0.017 ms | 0.97 ms |
| 100,000 | 0.015 ms | 8.96 ms |
| 1,000,000 | **0.018 ms** | **105.91 ms** |

The running balance is genuinely **O(1)** — flat at ~0.02ms across four orders of magnitude. The
aggregate is exactly linear: 10× the rows, 10× the time. At a million entries it is **~6,000×
slower**, and it keeps growing forever.

That is not survivable on the auth path, which has a ~1s deadline it must never be the reason
for missing. So **checkpointing is mandatory, not optional**, if the running balance goes:
materialise the balance at entry N, read `checkpoint + SUM(entries after N)`, and re-checkpoint
often enough to bound the scan. Checkpointing puts write work back, so the true net gain is less
than 13×.

Three other things the running balance buys that the append design loses:

1. **The self-audit.** [ADR-0003](../../docs/decisions/0003-bitemporal-balances.md) leans on
   `balance_after` and the recomputed aggregate always agreeing — divergence is a corruption
   alarm. With aggregation as the only source, the balance is true by construction and there is
   nothing left to check it against.
2. **Gaplessness.** `UNIQUE (account_id, account_seq)` proves no entry is missing from an
   account's history. A global sequence gives ordering but not gaplessness — Postgres sequences
   have holes after rollbacks, and Formance's own migration comments say so explicitly.
3. **Cheap as-of reads on the recorded axis**, which become aggregates too.

**Recommendation: do not pursue lock-free append.** Per the correction above, it is a ~20%
top-up over contention-free pessimistic locking, paid for with O(1) reads, the corruption
cross-check, and gaplessness. The contention was always the thing worth removing; the lock never
was.

## Result 12 — is the ceiling per-tenant or global? Global. But tenant-sharding is free.

The commercially important question: is this "13k per tenant" or "13k across all tenants"? Those
are different products.

**Test A — fixed concurrency (c=32), vary how many tenants it is divided among.** Each tenant has
its own house accounts. Concurrency is held constant, so any gain is purely from removing lock
contention:

| tenants | total clearings/s |
| --- | --- |
| 1 | 881 |
| 2 | 1,332 |
| 4 | 2,256 |
| 8 | 3,848 |
| 16 | 5,958 |
| 32 | **7,296** |

**8× more throughput from the same 32 writers**, purely because their house-account writes stopped
colliding. This isolates the effect: per-tenant house accounts remove lock contention, full stop.

**Test B — 4 writers per tenant, so load grows with tenants:**

| tenants | pessimistic total | per-tenant | append total | per-tenant |
| --- | --- | --- | --- | --- |
| 1 | 941 | 941 | 2,530 | 2,530 |
| 2 | 1,239 | 619 | 4,574 | 2,287 |
| 4 | 2,209 | 552 | 7,692 | 1,923 |
| 8 | 3,859 | 482 | 10,888 | 1,361 |
| 16 | 6,028 | 376 | **13,863** | 866 |

Total rises; **per-tenant throughput falls**. Append converges on the same ~13k hardware ceiling
found in Result 11.

### CORRECTION — the 8× is an artifact of uniform load

Result 12's tenant selection is `rng.Intn(len(ts))` — **uniform**. Real payment volume is
Zipfian: one or two tenants are most of the traffic. Re-measured with a whale tenant
(32 tenants, own house accounts, c=32):

| distribution | clearings/s | vs 1-tenant baseline (875) |
| --- | --- | --- |
| uniform | 7,991 | 9.1× |
| whale = 50% | 1,435 | 1.6× |
| whale = 80% | 1,018 | 1.16× |
| **whale = 90%** | **936** | **1.07×** |
| whale = 95% | 897 | 1.03× |

**At a realistic 90/10 skew the gain is 7%, not 8×.** The mechanism is obvious in hindsight: the
whale's *own* house accounts become the new single hot row. Per-tenant splitting **relocates** the
bottleneck; it does not remove it.

### Striping survives skew. That is the actual scaling mechanism.

| config (c=32) | stripes=1 | stripes=64 | gain |
| --- | --- | --- | --- |
| 32 tenants, whale = 0.9 | 948 | 7,405 | 7.8× |
| **1 tenant** (no tenant split at all) | 872 | **6,970** | **8.0×** |

Striping delivers ~8× **regardless of tenant count or skew** — including with a single tenant,
where per-tenant splitting is definitionally worthless. Striping splits *within* whatever account
is hot, so it cannot be defeated by load distribution.

**Per-tenant house accounts are a degenerate special case of striping**, where the stripe key
happens to be the tenant and the gain depends on load being evenly spread. **Striping is the
scaling story; tenancy is a coincidence.**

### The answer, in three parts

1. **No per-account limit, and no per-tenant *lock* limit** — once the hot accounts are **striped**
   (per-tenant splitting only achieves this under even load; see the correction above). Striping
   removes the per-row ceiling whatever the load distribution.
2. **But the ceiling is global, not per-tenant.** ~13k clearings/s is shared across everyone on
   that database. It is **not** 13k each. What per-tenant house accounts buy is that you can
   actually *reach* the hardware ceiling instead of being stopped at ~800/s by one row.
3. **To get a ceiling per tenant, shard tenants across database instances** — and this design is
   unusually ready for that, for a reason worth spelling out below.

### CORRECTION — "no cross-tenant transactions" is false

An earlier version of this section claimed tenant-sharding gives "no cross-shard transactions,
ever." **That is wrong, and the schema already says so.**

`operating_cash` and `fbo_cash` are **perimeter** accounts. [v1-vision](../../docs/v1-vision.md)
requires that *"every perimeter account has exactly one external balance that must agree with
it"* — the money physically sits in **one bank account**. A perimeter account cannot be split per
tenant without destroying the reconciliation target the design was built around. The same applies
to `facility_borrowings`: one warehouse line, one lender, one number they report on.

Counted against the golden trace: **7 of 13 transactions touch `operating_cash`** — `open`,
`evt_draw`, `evt_settle`, `evt_pull:settle`, and all three `evt_repay:*`.

But the four **clearing** transactions do not. So the honest claim is:

> **Clearings become tenant-local. Treasury does not.**

Clearings are the volume; treasury is batched daily and low-volume. Cross-shard treasury may
therefore be an acceptable trade — but it is a trade to be made explicitly, not a property to
claim we have. An adopter would discover this the first time they ran a settlement.

### What per-tenant house accounts still buy

Even after both corrections, splitting is not worthless:

- Under **even** load it removes contention (the uniform 8× is real, it is just not the common case).
- It makes **clearings** tenant-local, which is most of the transaction volume.
- For **reconciliation it is strictly better**: when Visa's settlement figure is 3 cents off, 1,000
  per-tenant accounts tell you which tenant caused it; one account does not.

**Except our schema currently forbids it.** `uq_accounts__house` guarantees exactly one
`interchange_revenue` per **deployment**, so today a card clearing touches:

| leg | scope |
| --- | --- |
| `customer_receivable` | tenant |
| `network_settlement_payable` | **global** |
| `interchange_revenue` | **global** |
| `platform_rev_share_payable` | tenant |

Half the legs are deployment-global, so **every transaction spans tenants** and no tenant can be
moved to another database without breaking atomicity.

Making house accounts per-tenant removes the deployment-global uniqueness, which is a
prerequisite for tenant-scoped anything. But **striping is what actually moves throughput**, and
it does so without depending on load distribution.

### What this benchmark did NOT measure, and should have

`main.go` posts exactly three legs — `customer_receivable`, `network_settlement_payable`,
`interchange_revenue`. **It never touches `operating_cash`, `fbo_cash`, `facility_borrowings`, or
`accrued_interest_payable`** — which are precisely the accounts that *cannot* be split.

The workload excluded the constraint that breaks the model. Every tenant-scaling number here is
conditional on a workload that omits the hard case. Re-running against the full golden-trace
account set, including a daily treasury batch through a global cash account, is required before
any of this informs M1.

## Summary — the levers, ranked

| Configuration | clearings/s | entries/s | notes |
| --- | --- | --- | --- |
| baseline (unsharded, unbatched) | ~800 | ~2,400 | plateaus at c=4, then declines |
| + coalesced batching (25) | 3,420 | 10,260 | no schema change |
| + random striping (64) | 6,850 | 20,550 | needs read-side `SUM` |
| random striping + batching | 2,356 | 7,069 | **worse than either** |
| + **worker-affinity** striping + batching | 4,790 | 14,370 | levers compose; flat in concurrency |
| + single-call posting (1 RTT), striped | **7,816** | **23,447** | best measured |
| tenants=16, own house accounts | 4,319 | 12,956 | free if multi-tenant |
| best config on a **2 GB** table | 7,897 | 23,692 | size-insensitive |
| optimistic locking | 437 | 1,311 | **worse**; 11.8 retries/success |
| contention-free pessimistic (keeps running balance) | 8,222 | 24,666 | **the recommended shape** |
| lock-free append (no running balance) | 10,025 | 30,074 | only +22% over the row above; costs O(1) reads |

**Caveat that outranks the table:** these are localhost numbers, where a round trip costs 0.05ms.
On RDS it costs ~0.5ms, which reorders the levers (Result 9). Treat the *ranking* as
hardware-specific and the *mechanisms* as general.

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

## Methodology caveats found while auditing our own numbers

- **Two harnesses on one database invalidate everything.** A concurrent run by another process
  (whose `setup()` issues `TRUNCATE ... CASCADE`) produced deadlocks and wild variance until the
  benchmark was moved to a dedicated database. Any re-run must be isolated.
- **Single runs hide variance.** Repeating the A/B/C comparison three times gave 668/799/695,
  8781/8222/4814, and 10025/9892/10889. The 4,814 is an outlier from CPU competition. **Treat
  the ratios as the finding and the absolute numbers as approximate**; earlier single-run figures
  in this document should be read the same way.
- **`post_clearing_mode()` does not sort accounts before locking**, unlike the Go path in
  `clearing()`, which sorts legs by account id. With `stripes=1` no cycle can form so it happens
  not to deadlock, but the SQL path is not doing the deterministic lock ordering the design
  requires. **Production posting code must sort; this benchmark path does not.** It does not
  invalidate the throughput numbers, but it is a bug in the harness and a trap for anyone reading
  it as reference code.

## External validation — what the industry actually does

Researched across published engineering writeups. This reframes several of our conclusions.

### We rediscovered a benchmark from 1985

Jim Gray et al., *"A Measure of Transaction Processing Power"* (Datamation, 1985) — the
**DebitCredit** benchmark, later TPC-A/TPC-B — models 10 branches, 100 tellers, 10,000 accounts.
Every transaction touches a customer account **and** a branch account, so ~10 branch rows absorb
every write. **The hot-shared-account bottleneck was constructed deliberately, forty years ago, as
the defining OLTP stress case.** Our `network_settlement_payable` is TPC-B's branch record.

### The consensus fix is batching, NOT splitting — and two teams rejected splitting explicitly

| Team | Approach | Evidence |
| --- | --- | --- |
| **Uber** | 250ms batch windows, one read + one write per batch | 3–4 → **30+ ops/sec per account**; bulk jobs 21–24h → minutes |
| **Modern Treasury** | Sync/async router; hot entries queued and coalesced | p90 processing 1s; **1,200 txn/s (4,800 entries/s)** in production |
| **TigerBeetle** | Batching up to 8,190 transfers per query | — |
| **Fragment** | Coalesced balance updates | p95 staleness 10s at 10k entries/s |

**Uber considered splitting the account and declined:** *"Using multiple DynamoDB rows for a single
account complicates the single-balance concept and hot account detection."*

**TigerBeetle argues sharding cannot fix it:** *"a small number of hot accounts are often involved
in a large proportion of the transactions, so the shards responsible for those accounts become
bottlenecks."*

This ranks batching **above** striping more strongly than our localhost numbers do — and
[Result 9](#result-9--round-trips-and-why-localhost-lies-about-them) already predicted exactly
that reordering on managed Postgres, where round trips cost 10× more.

### Modern Treasury's published guidance: never lock the hot account

> *"it is best practice to ensure that the hot account receives only asynchronous entries, so that
> it can perform at high throughput… Often, transactions that involve a hot account will write
> other entries that involve lower throughput accounts, like user-specific account. In this case,
> the optimal design is locking only on these user accounts."*

This is a **third option we never measured**: lock the tenant leg synchronously, let the house leg
land asynchronously. [Result 2](#result-2--per-account-contention-on-the-customer-account-is-irrelevant)
already showed the tenant leg is nearly free to lock (12% cost even fully concentrated). This is
also **memo posting**, the technique core banking has used since the 1970s — provisional entries
during the day, hard posting in an end-of-day batch.

### The principled defence of per-tenant accounts is a modelling argument, not a performance one

Martin Richards, on scaling a PSP ledger:

> *"If you have a single account every payment touches, you're probably modeling an aggregate that
> doesn't exist in the business."*

This is the distinction that survives our skew correction. **Random stripes produce sub-accounts
whose individual balances are meaningless. Per-tenant house accounts produce sub-accounts that are
each a real, auditable, reportable figure.** Tenant A's interchange revenue and tenant B's were
never one number in anyone's accounting — the current schema merges them by accident of
`tenant_id NULL`. Richards splits revenue per acquirer BIN for the same reason.

So the honest position: **per-tenant splitting is justified as a modelling correction, and
striping is justified as the performance mechanism.** They are different arguments and we
conflated them.

### Escrow is not the technique we were missing

Escrow (O'Neil, TODS 1986; IMS/VS Fast Path field calls, 1985) exists to enforce an invariant —
*balance must not go negative* — on a hot account **without** serializing. Our house accounts have
no such invariant; nothing checks that interchange revenue stays positive. **Applied to an
unconstrained accumulator, escrow degenerates to "don't take the lock at all"** — which is exactly
[Result 11](#result-11--do-we-need-the-lock-at-all-no). We are not missing it.

Where it *would* apply: a per-tenant credit line with a hard limit checked on the auth path. Worth
keeping for the reference product, not for house accounts.

### Checkpointing is proven in production

Monzo moved from pure aggregate-on-read to precomputed **"block" balances** — exactly the
checkpointing scheme [Result 11](#result-11--do-we-need-the-lock-at-all-no) identified as
mandatory. P99 balance read **400–500ms → ~200ms**. Their root cause is instructive: no time
component in the partition key, so partitions grew unbounded.

### Practices worth stealing

- **Shopify enforces cross-shard safety in CI**, with verifiers named "Cross Shard Transaction",
  "Cross Shard Write", "Cross Keyspace Query". Our "no cross-tenant transactions" claim is only
  true if *enforced*. A CI check that no transaction's entry set spans more than one `tenant_id`
  is the mechanical version — and it would have caught our `uq_accounts__house` problem.
- **Modern Treasury degrades automatically on cache drift**: they verify cached balances against
  the sum of entries and *"automatically turn off cache reads for Accounts that have drifted."*
  That strengthens [ADR-0003](../../docs/decisions/0003-bitemporal-balances.md)'s self-audit from
  "alarm" to "alarm and fall back to truth."
- **Nubank's #1 published regret** is missing a customer ID on every transaction, which
  *"dramatically"* complicated later sharding. That is our `tenant_id NULL` problem exactly.

### The counter-argument to engage

**Adyen rejected domain-based sharding** and shards round-robin instead: *"if we would put each
processing merchant in one database, you still need to go to every shard when you need aggregate
data."* Their objection is weaker for a ledger — balances, statements, and a tenant's own P&L are
all tenant-local, and the operator's cross-tenant P&L is a batch read. But it is worth answering
rather than ignoring.

### What appears to be genuinely unpublished

No source documents per-tenant copies of a house revenue account as a named pattern. Our Result 3
and Result 12 measurements appear to be **novel published data** — which is an asset, but means
ADR-0007 should present it as "the natural consequence of tenant sharding, measured here" rather
than as industry standard.

## What this does NOT measure

Stated so the numbers are not over-read:

- ~~**Small table.**~~ **Closed by Result 10** — retested at 5M entries / 2 GB against 128 MB of
  cache, essentially unchanged. Still not tested at 500M entries or after months of bloat.
- **Single node.** No replication, no failover, no `synchronous_standby`. Synchronous replication
  will cost meaningfully on every commit.
- **Stock config on a laptop.** Tuned RDS/Aurora with provisioned IOPS behaves differently —
  probably better on I/O, similar on the contention limit since that is a lock-ordering property.
- **The clearing path only.** The auth hot path is cheaper (writes no ledger entry) and
  serializes *per company*, so it parallelizes far better. It was not measured here and has a
  latency deadline rather than a throughput target — it deserves its own spike.
- ~~**No batching.**~~ **Closed by Results 5, 6, 8.**
- **Network latency.** Everything runs over localhost, where a round trip costs 0.05ms. On RDS it
  costs ~0.5ms and reorders the levers (Result 9). **A real RDS benchmark is required before any
  number here is published.**

## Reproduce

```sh
make up
psql "$DB_URL" -f ../002-sqlc-vs-jet/schema.sql
psql "$DB_URL" -f bench_schema.sql
go run . -c 16 -stripes 1  -d 5s     # unsharded
go run . -c 32 -stripes 64 -d 5s     # striped
```
