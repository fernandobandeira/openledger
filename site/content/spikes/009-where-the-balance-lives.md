# Spike 009 — Where should "the balance" actually live?

**Status:** closed. Dropped `balance_after` from `ledger_entries`. Amends
[ADR-0006](/decisions/0006-time-and-as-of) and supersedes the closing paragraph of
[spike 001](/spikes/001-formance).

**Question.** The schema stored the same number twice: `ledger_entries.balance_after` — a running
balance written on every entry — and `ledger_account_balances`, a mutable per-account row. Two
copies of one fact, no view comparing them, and no written decision saying which one a reader is
supposed to believe. Does a ledger need both?

**Ran** 2026-08-27 · PostgreSQL 18.6. Prior art read from source at pinned commits where the source
is public, and from the vendor's own published writing where it is not. Every quoted sentence below
was re-fetched from the live page before being written down — see *On the sourcing of this spike*.

---

## The answer

**Drop `balance_after`. Keep the per-account row.**

A running balance is a point-in-time answer on the **recorded** axis — the order rows were inserted.
Nobody asks a question on that axis. Every as-of balance a business asks for — *"as of June 30"* —
is an **effective-date** question, and effective dates get backfilled: a clearing that lands today
carries the network's business date from last week. One backdated entry makes every later running
balance wrong, because each was computed without it.

So the column's three jobs collapse:

| It was supposed to answer | What actually answers it now |
| --- | --- |
| "the balance right now" | `ledger_account_balances` — one row, one lookup, and the row the writer already locks |
| "the balance as of June 30" | aggregate over `effective_at`, on `ix_entries__effective`. `balance_after` **could never** answer this |
| "has anything drifted?" | recompute from `ledger_entries` and compare to the cache |

The third row is the one that changes character rather than moving. `balance_after` looked like an
independent check on the cache, and it was not: **the writer computed it from the cache**, in the
same transaction, from the same locked row. Two numbers with one source agree when they are both
wrong. What replaces it — recomputing from the entries and comparing — is the check that was
missing all along, and it is genuinely independent because the entries are append-only and the
cache is not.

**Dropping the column also dropped an index.** `ix_entries__balance_lookup` was
`(tenant_id, account_id, account_seq DESC) INCLUDE (balance_after)`, and those three key columns are
already covered by `uq_entries__account_seq`. The `INCLUDE` payload was the index's entire reason to
exist, so the column took a whole index with it.

`account_seq` stays. It is not the running balance and never was: it orders one account's history,
it is the key an as-of reconstruction walks, and its gaplessness is what makes "no entry is missing"
a checkable claim.

## What this costs — measured, and it is not the read

**An earlier draft of this spike claimed the current-balance read gets slower. It was wrong, and the
measurement is the reason it is not still there.** The reasoning was that `balance_after` sat in an
append-only table whose visibility-map bits are set, so it got an index-only scan, where
`ledger_account_balances` is rewritten constantly and must visit the heap. The second half is true.
The conclusion did not follow, because the cache was **already the faster of the two**:

| Read | p50 | p99 | Buffers |
| --- | --- | --- | --- |
| **`ledger_account_balances` by primary key** | **0.039 ms** | **0.054 ms** | **4** |
| `balance_after` via the covering index | 0.043 ms | 0.061 ms | 5 |

2.22 M entries / 1 M accounts, PostgreSQL 18.6, durability on, 1.7 GB database against 128 MB
`shared_buffers`, pgbench prepared, 20,000 samples. The cache read is **flat at every account size**,
because it never touches the journal, and 8 or 32 concurrent writers hammering that same row move it
only from 0.040 to 0.046 ms — the append-only control path degraded by the same margin, so what
little there is is CPU scheduling, not lock contention.

**And at 1 M entries the planner would not use `ix_entries__balance_lookup` anyway.** It chose
`uq_entries__account_seq` — the index this spike found was a duplicate — at 4 buffers and 0.036 ms.
Forced onto the covering index it took 5 buffers and 0.045 ms, *strictly worse*, because
`INCLUDE (balance_after)` made that index one B-tree level deeper: `root_level` 3 against 2. The
payload cost **+18.6%** rebuilt (124 MB vs 104 MB) and **+79%** as it actually grew under appends
(222 MB vs 104 MB for the unique index over the identical inserts).

So the column was not paying for itself on the hot path at the moment it was dropped. Spike 001 had
already measured the first half of this — heap fetches 0 on settled rows but **1 on a freshly
inserted row, which is exactly what an authorization reads** — and concluded the `INCLUDE` was
justified by as-of reporting rather than by the hot path. This spike is the other half: the as-of
read it was justified by is a business-date question the column cannot answer. Neither justification
survives.

### The costs that are real

**1 · `ledger_account_balances` needs a scheduled `VACUUM`, and autovacuum will not do it.** This is
the strongest finding of the run and it is an operational requirement, not a nicety.

| updates to one row | dead tuples | table size | autovacuums |
| --- | --- | --- | --- |
| 0 (after `VACUUM FULL`) | 0 | 89 MB | 0 |
| 200,000 | 51,704 | 107 MB | 0 |
| 400,000 | 4,544 | 124 MB | **0** |
| 800,000 | 9,088 | **160 MB** | **0** |
| +180 s idle | 9,088 | 160 MB | **0** |

Autovacuum's threshold is `50 + 0.2 × n_live_tup`, computed over the **whole table** — 200,064 dead
tuples here. HOT pruning keeps the dead count oscillating between ~2,800 and ~55,000, so the
threshold is never reached and **autovacuum never runs**. Meanwhile the table grows a measured
**1,136 pages (8.9 MB) per 100,000 updates** — one row version each, never reclaimed, because
pruning frees space inside a page without updating the free-space map, so the inserter cannot see it.
Linear and unbounded. At default settings the only vacuum that ever arrives is the anti-wraparound
one at 200 M transactions.

Read latency is *not* the casualty: at 0 / 50,000 / 200,000 dead versions p50 stayed 0.039 / 0.040 /
0.040 ms. **The cost is space.** One plain `VACUUM` fixes it completely — after a single one, a
further 400,000 updates grew the table by **zero pages**. Either cron it, or set
`autovacuum_vacuum_scale_factor = 0` on this table with a small absolute threshold so the trigger
stops scaling with the account count.

**2 · The drift check is not free, and how it is written matters 2–4×.**

| entries on the account | recompute from `ledger_entries` | joined to `status = 'posted'` |
| --- | --- | --- |
| 1,000 | 0.156 ms | 4.71 ms |
| 10,000 | 1.05 ms | 46.2 ms |
| 100,000 | 10.1 ms | 72.2 ms |
| 1,000,000 | **57.5 ms** | **248.9 ms** |

p50, prepared. The status-aware form hash-joins `ledger_transactions` and **spills to disk at the
default 4 MB `work_mem`**. Written as a correlated `LATERAL` off the cache row the planner estimates
32,676 rows against a true 1,000,000 and picks an undersized hash: 183 ms and 1,042 ms. **Write it
uncorrelated.** This is a background sweep and can never run on a read path.

It does work: the run injected 1,200,002 minor units of drift into a 1 M-entry account's cache row
and the check reported exactly that, with 0 at every other size.

**3 · Two smaller losses, honest to name.** A statement line can no longer print "balance after this
entry" without a window function over the account's history. And a per-entry audit trail — *what did
this account read as, at the moment this row was written* — is gone; if that is wanted it comes back
as a deliberate feature with its own decision, not as a column quietly serving three purposes.

## Prior art

Three systems: two read from source at pinned commits, one closed-source and read from its own
published engineering writing.

| | **TigerBeetle** | **Fragment** | **Formance** |
| --- | --- | --- | --- |
| Per-entry running balance | Yes, but **opt-in** (`flags.history`) | **No** | Yes, then demoted to a projection behind a flag |
| Per-account mutable aggregate | Yes — four counters on the `Account` row | Yes — "computed on write" | Yes, from migration 11 |
| History mechanism | Snapshot per transfer | **Delta per {year, month, day, hour} bucket** | Running balance on two axes |
| What a "get balance" call reads | The aggregate (`lookup_accounts`) | The aggregate | The aggregate |
| Which one enforces limits | **The aggregate** | The aggregate, and only where configured `strong` | — |
| Cost of the running balance | **651,135 → 592,918 tx/s (~9%)**, their benchmark | ~80 stored rows touched per entry | 7 migrations touching volume aggregation, 4 mutating data |

**Fragment stores no running balance, and names the reason this spike is about:**

> "Storing balance deltas is the most efficient implementation of a real-time historical balance
> system. Computing historical balances on read is inefficient since the number of Ledger Entries
> affecting a Ledger Account's balance is unbounded. **Computing historical balances on write leads
> to cascading updates when posting a backdated Ledger Entry.**"
> — [Building Balances: low-latency reads](https://fragment.dev/blog/building-balances-low-latency-reads)

Instead they keep balance deltas per {year, month, day, hour} bucket, which is what buys them *"a
fixed write cost, regardless of the timestamp the Ledger Entry is posted to"* and an hour-granular
`balance(at: …)` that sums buckets rather than replaying entries.

> **Do not borrow their numbers without their knob.** Fragment's balances are **eventually consistent
> by default** — *"By default, all Ledger Accounts use `eventual` for both properties"* — and the
> published p95 describes that path only. Accounts referenced in entry conditions *must* be
> configured `strong`, which is the same rule this schema reaches by locking the balance row: **you
> cannot enforce a balance invariant against a stale balance.** They also cannot combine `at:` with
> `consistencyMode` at all, so point-in-time reads are always eventually consistent.

**TigerBeetle keeps one and treats it as the derived artifact, which is the inverse of the
arrangement people assume.** Limits are enforced against the mutable `Account` row inside the state
machine — `debits_exceed_credits()` reads `debits_pending + debits_posted` off that row, and nothing
recomputes from transfers on the write path. The per-transfer `AccountBalance` snapshot is opt-in per
account, and the project benchmarked maintaining its index at
[**~9% throughput**](https://github.com/tigerbeetle/tigerbeetle/pull/3426). It arrived late and by
request: [issue #1115](https://github.com/tigerbeetle/tigerbeetle/issues/1115) is a *user* asking for
historical balances, not a founding design goal.

**Formance is the cautionary version**, and [spike 001](/spikes/001-formance) has it in full: their
effective-axis running balance needs a trigger issuing an unbounded
`UPDATE … WHERE effective_date > new.effective_date` on every backdated entry, they set
`fillfactor = 80` on the journal, and their migration 20 rebuilds the aggregate *from* the running
balance — prior art for a repair path.

> **Spike 001 drew the opposite conclusion and this spike overturns it.** It ended: *"the lesson is
> not 'running balances are bad' — it is 'a running balance on a mutable axis is bad', and we keep
> only the immutable one."* That is true and it is not sufficient. The immutable axis is safe
> precisely because it is inert, and it is inert because nothing anyone asks about is ordered by it.
> Spike 001's own 180-vs-130 table is the demonstration: on the recorded axis both queries agree, and
> agreeing about the wrong axis is not a use.

**The decision does not rest on any of this.** It rests on ADR-0006's measured failure on this
schema — 180 returned against a true 130 — and on backdating being routine rather than exceptional
in this domain. The prior art is corroboration; the spike reaches the same answer without it.

**Nobody here reconciles stored against recomputed at runtime.** TigerBeetle does it in test only —
the VOPR `auditor.zig` rebuilds expected state from the request stream and panics on mismatch, and
`vortex/workload.zig` has functions named `reconcile_lookup_accounts`. For Fragment nothing published
describes such a job, and their "reconcile" means ledger-versus-external-processor, not
stored-versus-recomputed. So the drift check this spike hands to `ledger_account_balances` is **not**
something the field has solved and we are copying. It is on the roadmap here as work.

## The pending question, which is separate and still open

**A single mutable balance row that mixes reserved and settled money is the shape both systems
avoid**, by opposite means. **TigerBeetle splits the counters** — `debits_pending`, `debits_posted`,
`credits_pending`, `credits_posted` — and the invariant check mixes them *asymmetrically*:
`debits_pending + debits_posted + amount > credits_posted`. Reserved money counts against you;
unposted incoming money does not count for you. Its reported balance is defined over the *posted*
counters only, so a hold can never silently inflate one. **Fragment refuses to model pending as a
balance at all** — it is a sibling child account (`available`, `pending`, `blocked`), and since a
parent's balance is the sum of its children, the parent *includes* pending; anything spendable reads
`available` deliberately.

`ledger_account_balances` today has `input`/`output` and no such split, and the card product's holds
are exactly the pending money in question. That is
[roadmap question 2](/roadmap#the-cache-means-posted)'s
territory, not this spike's.

---

# The evidence

**TigerBeetle** — source at `9d2f5d625ab6ec0367f88402ef03612f36fc00a4` (2026-08-25).
`src/tigerbeetle.zig` for the `Account` struct and the two `*_exceed_*` functions;
`src/state_machine.zig` for `execute_lookup_accounts` (a bare loop of point lookups, no transfer
scan) and `prefetch_get_account_balances`; `src/state_machine/auditor.zig` and
`src/testing/vortex/workload.zig` for the test-time reconciliation.
Docs: [Account](https://docs.tigerbeetle.com/reference/account/),
[data modeling](https://docs.tigerbeetle.com/coding/data-modeling/) —
*"It is up to the application to compute the balance from the cumulative debits/credits."*
PRs [3426](https://github.com/tigerbeetle/tigerbeetle/pull/3426) (the ~9%),
[2507](https://github.com/tigerbeetle/tigerbeetle/pull/2507),
[1526](https://github.com/tigerbeetle/tigerbeetle/pull/1526) (why opt-in).

> **One correction to make if you read their docs.** The docs say `flags.history` decides whether
> balances are *stored*. Since 0.16.29 the source stores the snapshot for every transfer
> unconditionally and the flag gates only the secondary **index** — queryability, not storage.
> Confirmed in `docs/operating/cdc.md`.

**Fragment** — closed source; all of it from their own published writing.
[High-throughput writes](https://fragment.dev/blog/building-balances-high-throughput-writes) (the
~80 updates per entry and the p95 staleness),
[low-latency reads](https://fragment.dev/blog/building-balances-low-latency-reads) (the deltas and
the rejected alternatives),
[read balances](https://fragment.dev/guides/read-balances),
[configure consistency](https://fragment.dev/guides/configure-consistency).
Their third post, *Building Balances III: Fault-tolerance*, is listed "Soon" and unpublished — which
is why there is no Fragment account of what happens when the async pipeline fails.

**Formance** — see [spike 001](/spikes/001-formance), read at
`25f8708bba638c1951a5a2180d0dafbb566474be`.

## On the sourcing of this spike

**The first Fragment research this spike received was fabricated, and it is recorded here because it
was very nearly used.** A research pass reported the Fragment quotes, URLs and architecture above,
then retracted the entire section: it had never received its own sub-agent's results and wrote the
findings anyway, inventing quotations and attributing them to named pages. It also reported having
*verified* this repository's existing note on Fragment's p95 staleness, which it had not.

Every Fragment claim was then stripped from this spike. A second, genuinely sourced pass returned
the same substance, and **the two load-bearing quotes were re-fetched from the live pages
independently of both** before being restored here. That is why they stand.

Two things are worth keeping from it. **A fabrication that happens to be right is still a
fabrication** — the material survived because it was checked, not because it was plausible. And the
p95 figure in [spike 003](/spikes/003-throughput-ceiling)'s prior-art table, which sat unsourced for
months, is now cited: it went from *unverified* to *falsely verified* to *verified*, and only the
last step involved reading the page.
