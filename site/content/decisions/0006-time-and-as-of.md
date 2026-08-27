# 0006 — Two time axes, two mechanisms, and "as of" means a commit-ordered cursor

**Status:** accepted — with the as-of cursor unbuilt and blocking roadmap M5, below.
**Evidence:** [spike 001](/spikes/001-formance),
[spike 003](/spikes/003-throughput-ceiling).

## The decision

Every entry carries two dates that routinely disagree: **recorded** (`recorded_at`, ordered by
`account_seq`) is when we learned of it; **effective** (`effective_at`) is the business date it
belongs to, from the source's clock — a card network's, not our webhook's. An entry recorded today and
effective last week is **backdated**, and normal: late clearings and chargebacks are.

**Two axes, two mechanisms — and no running balance serving either.**

| Question | Mechanism |
| --- | --- |
| Current balance (the hot path) | `ledger_account_balances` — one row per account, read by primary key |
| Balance as *recorded* at instant T | aggregate over `recorded_at <= T`, on `ix_entries__asof_recorded` |
| **Balance as of business date T** | **aggregate over `effective_at <= T`**, denormalized onto `ledger_entries` so it is a single-table index scan, not a join |

> **AMENDED by [spike 009](/spikes/009-where-the-balance-lives).** The first two rows used to read
> `balance_after`, a running balance stored on every entry. It is gone. The argument below is what
> killed it — this ADR made it about the *effective* axis only, and the same argument finishes the
> job: a point-in-time answer on the recorded axis is a point-in-time answer to a question nobody
> asks. The spike has the prior art, the cost, and what replaces the drift check.

**And a timestamp is not an "as of".** A report resolves a business date to a **gap-free watermark
over a global sequence** on [`ledger_events`](/decisions/0005-event-log-and-write-path) — one sequence,
assigned once per accepted event — stores it beside the report and re-runs against it forever. It is
not `max(seq)` but the highest **N where every entry ≤ N has committed**, since
`pg_snapshot_xmin(pg_current_snapshot())` is the lowest transaction id still running: everything below
has finished and can never grow; above it, a row invisible now can appear later. That horizon is in
*transaction ids* and the watermark a position on the *event sequence*, so each event records the
transaction that wrote it and `W = min(seq) - 1` over events whose xid ≥ xmin. Then a rule: **an as-of
query names the column it filters, and a resource has one such column** — naming it on the *parameter*
is not enough.

## Why

**A running balance answers business-date questions wrongly.**

| account_seq | effective | amount | running balance |
| --- | --- | --- | --- |
| 1 | Jan 10 | +100 | 100 |
| 2 | Jan 30 | +50 | 150 |
| 3 | Jan 20 | +30 | **180** |

As of Jan 25 by running-balance lookup: **180**. The truth: **130**. The Jan 20 entry has a *higher*
sequence number than Jan 30's, so `ORDER BY account_seq DESC LIMIT 1` lands on a balance including Jan
30 — and every as-of balance anyone asks for ("as of June 30") is a business-date question.

**That last clause is the whole finding**, and it is why the column is gone rather than merely
restricted. Backfilling is not an edge case in this domain: a clearing carries the network's business
date, so entries arrive out of effective order as a matter of routine. A number that is only correct
on the axis nobody asks about is not a fast path, it is a trap with an index on it.

**Each read must be ordered by the axis it asks about.** A recorded-axis read written as
"current-balance lookup plus `recorded_at <= T`" plans on `account_seq` and filters — **~36,000 rows
removed by filter** against zero for the right one. Hence `ix_entries__asof_recorded`.

**The business date is copied onto the entry, and a key holds the copy honest — not the writer.**
The effective-axis aggregate is a single-table index scan only because `effective_at` is denormalised
from the transaction onto `ledger_entries`, and nothing held that copy to its source: a transaction
dated 2026-06-15 accepted a thousand entries dated 1999-01-01, which is the column every
business-date report in the system reads. `fk_entries__txn_effective` makes the copy part of a
composite foreign key onto `uq_txn__id_effective`, so an entry whose business date disagrees with its
transaction's is unwritable rather than merely wrong — the same trick as the currency copy in
`fk_entries__account`. It is the guard here that needs a test: dropping it loads cleanly, where
dropping the unique index it points at makes the schema fail to load outright. That test is
[0007](/decisions/0007-schema-conventions-and-chart)'s schema snapshot, which is not built.

**Why not a second running balance on the effective axis?** A backdated insert `UPDATE`s every later
row for that account — unbounded write amplification on the one table whose value is immutability.
Spike 001 copied Formance's trigger pair verbatim, inserting N moves into one account in
effective-date order and fully backdated:

| moves | in insertion order | fully backdated |
| --- | --- | --- |
| 200 | — | 679 ms |
| 400 | — | 5,162 ms |
| 1,000 | **114 ms** | **84,342 ms** |

**740× on a thousand rows, and worse than quadratic** — 200→400 is 7.6×, 400→1,000 is 16× — because
each `UPDATE` rewrites a larger set until the HOT-update budget from `fillfactor = 80` runs out. That
fill factor is migration 10; 19, 20 and 28 repair data. Their own best point-in-time path ignores the
column: `/volumes?pit=` re-aggregates from `moves`, and only `/aggregate/balances?pit=` reads
`post_commit_effective_volumes`. **None of it argues against our running balance.** They kept **two**,
their comments separating them: `post_commit_volumes` (insertion axis) *"will never change"*;
`post_commit_effective_volumes` (effective axis) *"can be updated if a transaction is inserted in the
past"*. Only the **mutable** one cost anything: **a running balance on a mutable axis is bad**.

**`recorded_at` is not reproducible.** It is `now()` — *transaction start* time, not commit order:

| Transaction | starts | commits | writes `recorded_at` |
| --- | --- | --- | --- |
| A | T1 | **T3** | T1 |
| B | T2 (> T1) | T2.5 | T2 |

A report "as of T2.6" run at T2.7 sees B but not A, uncommitted; re-run at T4 it sees both.
**Different answer**, and time zones have nothing to do with *this* failure: it needs two concurrent
writers and
one slow transaction — a reporting run overlapping a batched posting run, an ordinary Tuesday.
**Reproduced** on ordinary INSERT grants — one recorded-axis report either side of one commit gave
revenue **110,000.00 then 160,000.00**, `balanced` both times, drift empty.

**The closest prior art has the same hole and knows it.** Formance's `transaction_date()` seeds
`statement_timestamp()` into a session temp table — intra-transaction consistency, nothing about
commit order. Their per-ledger sequence exists *"instead of a sequence of the table as we want to have
contiguous ids"* and carries, three times, the note that *we can still have "holes" on ids since a sql
transaction can be reverted after a usage of the sequence* — a gapless order attempted, its failure
written beside it, while their `logs (ledger, id)` key *is* the cursor this ADR wants. The naming rule
is theirs too: they *do* name the axis (`pit` plus a `useInsertionDate` selector) and `pit` still
resolves to **six columns across seven endpoints**, spelled three ways, undocumented in their OpenAPI.

## Alternatives

| | Why not |
| --- | --- |
| **One running balance for both axes** | Wrong by construction — the first table above. |
| **A second running balance on the effective axis** | 740× on backdated insert, measured on their code. |
| **Keeping the recorded-axis running balance for the hot path** | What this ADR originally decided, reversed by [spike 009](/spikes/009-where-the-balance-lives): it is correct on an axis nobody queries, it was not the independent drift check it looked like, and the per-account row answers "now" anyway. |
| **Forbid backdating** | Breaks on late clearing and chargebacks, which are the normal case. |
| **`recorded_at <= :as_of`** | Not reproducible — the table above. Do not build M5 on it. |
| **A bare `bigserial` as the cursor** | Sequence values are handed out at *insert* time, so the same interleaving leaves gaps that fill in afterwards; `max(seq)` is not yet gap-free. Hence a watermark. |
| **Serialize all ledger writes** behind one commit-ordered lock | Trivially correct, and measured expensive: spike 003's single-contended-row case, roughly **10× unbatched and 2.3× batched** ([0002](/decisions/0002-scaling)). Worse than it looks, because the lock is **global** — every lever 0002 rests on reduces contention on *account* rows, and none touch a lock taken by every writer. **The concurrency-4 plateau is the specific danger**: throughput *declines* past four concurrent writers, so answering a slow ledger by adding workers makes it slower. |
| **Push "as of entry #N" to the caller** | Honest, and fine internally, but a credit agreement says "as of June 30", not "as of entry 4,183,992". Something still has to map a date to a cursor. |

## What it costs

| | |
| --- | --- |
| **The effective-axis aggregate is linear and currently unbounded** | Roughly 0.10 µs per entry in range, and **105.91 ms** for a 1M-entry account (one-off run, no harness in repo). We traded Formance's unbounded `UPDATE` for an unbounded `SCAN`, but ours is on the read path and mutates nothing. |
| **It must be bounded, and accounting already knows how: period close** | Materialize each account's balance at each period end, so a business-date query becomes *"prior period's closing balance + entries in the open period"* — an **effective-axis checkpoint**. A backdated entry in a closed period then needs restatement or a prior-period adjustment, as accounting practice already requires. **Prerequisite for M5.** |
| **The striped read cost is unmeasured** | The accounts every transaction touches are the shared ones, also the accounts accumulating the most entries, so the account most likely to be queried "as of last quarter" has the largest scan, summed across N stripes ([0002](/decisions/0002-scaling)). **Spike before M5.** |
| **The recorded axis is not yet trustworthy** | `recorded_at` should be assigned by the writer; today it is a bare `DEFAULT` and forgeable — verified, an `INSERT` supplying `1999-01-01` was accepted. **A column with a `DEFAULT` is not a constraint** ([0004](/decisions/0004-where-logic-lives)). |
| **The query layer is not bitemporal yet, though storage is** | *The effective-axis February close as known on 1 March* cannot be expressed: `balance_sheet`, `income_statement` and the balance-sheet roll-up have no date predicate, and the accounting equation must take one instant and one axis when rebuilt. |
| **The drift check is now the only check** | `ledger_account_balances` and the recomputed sum over `ledger_entries` must always agree; a cheap periodic check finds divergence, and should recompute rather than only alarm, as Modern Treasury does. This used to compare the cache against `balance_after`, which was **not** an independent check — the writer computed both from the same locked row in the same transaction. Recomputing from the append-only entries is. |
| **Reporting code must name its axis, and the cursor lags the newest writes** | M5 must test the backdating case above. The lag is the longest in-flight transaction — the price of write concurrency — and it composes with [0005](/decisions/0005-event-log-and-write-path)'s deferred hash chain, which needs a total order. |

## The as-of cursor is not built, and it blocks M5

**`ledger_events` has no global sequence and no xid**, so the watermark has no substrate. Unverified:

1. That `pg_snapshot_xmin(pg_current_snapshot())` gives a usable watermark under our write pattern.
   The risk is a **batched posting run**, not [0001](/card/decisions/0001-authorization-holds)'s one-shot timers.
2. Its lag under such a run: one transaction open for minutes pins every report behind it.
3. ~~That the watermark advances past aborted transactions automatically.~~ **Verified** on PostgreSQL
   18.6: a session took xid8 5325039 and held it open, a concurrent snapshot read `5325039:5325039:`
   with xmin pinned at that id, and on `ROLLBACK` the next read `5325040:5325040:`. xmin tracks what
   is still *running*, and an aborted transaction is not, so it stops pinning the horizon unaided. The
   same transcript demonstrates risk 2, and on RDS the holders are not only our writers — `pg_dump`,
   an idle-in-transaction session, a logical replication slot, `hot_standby_feedback` from a replica,
   and any prepared transaction all pin xmin, so a report trailing the oldest can trail by hours.
