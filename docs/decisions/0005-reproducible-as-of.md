# 0005 — "As of" means a commit-ordered cursor, not a timestamp

**Status:** proposed — blocks roadmap M5

## The decision

A report resolves a business date to a **gap-free watermark over a global sequence** on
[`ledger_events`](./0004-event-log.md) — one monotonic sequence for the whole system, assigned once
per accepted event — stores the watermark alongside the report, and re-runs against the stored
watermark forever after. The date picks a cursor; the cursor is what the query uses.

The watermark is not `max(seq)`. It is the highest **N such that every entry ≤ N has committed**,
computable from `pg_snapshot_xmin(pg_current_snapshot())`, since every transaction below the
snapshot's xmin has resolved. Standard CDC technique.

With it, a rule: **an as-of query must name the column it filters, and a resource must have exactly
one such column.** Naming the axis on the *parameter* is not enough.

## Why

**`recorded_at` is not reproducible.** It is `now()` — *transaction start* time, not commit order:

| Transaction | starts | commits | writes `recorded_at` |
| --- | --- | --- | --- |
| A | T1 | **T3** | T1 |
| B | T2 (> T1) | T2.5 | T2 |

A report for "as of T2.6" run at T2.7 sees B but not A — A hasn't committed yet. The same report,
same as-of value, re-run at T4, sees both. **Different answer.** No care with time zones fixes this;
the problem is not the clock. It needs two concurrent writers and one slow transaction, and a
reporting run overlapping a batched posting run is an ordinary Tuesday.

**It has been reproduced** with nothing but the app role's ordinary INSERT grants: one recorded-axis
report, run either side of one concurrent commit, gave revenue **110,000.00 then 160,000.00** —
`balanced` both times, both drift views empty.

**A bare `bigserial` doesn't help.** Sequence values are handed out at *insert* time, so the same
interleaving leaves gaps that fill in afterwards — `max(seq)` is not yet gap-free. Hence a watermark.

**The closest prior art has the same hole and knows it.** Formance's `transaction_date()` seeds from
`statement_timestamp()` into a session temp table: intra-transaction consistency, nothing about
commit order. Their per-ledger sequence carries this comment, three times over
([spike 001](../../spikes/001-formance/README.md)):

```sql
-- create a sequence for transactions by ledger instead of a sequence of the table as we want to
-- have contiguous ids
-- notes: we can still have "holes" on ids since a sql transaction can be reverted after a usage
-- of the sequence
```

They wanted a gapless total order, built a sequence for it, wrote down that it does not deliver one,
and did nothing further — while their `logs (ledger, id)` primary key *is* the cursor this ADR wants.
The naming rule above is theirs too, learned expensively: they *do* name the axis (`pit` plus a
`useInsertionDate` selector) and `pit` still resolves to **six different columns across seven
endpoints**, the selector spelled three ways, undocumented in their OpenAPI.

## Alternatives

| | Why not |
| --- | --- |
| **`recorded_at <= :as_of`** | Not reproducible — the table above. Do not build M5 on it; code written against it will change. |
| **Serialize all ledger writes** behind one commit-ordered lock | Trivially correct, and measured expensive. See below. |
| **Push "as of entry #N" to the caller** | Honest, and fine internally — but a credit agreement says "as of June 30", not "as of entry 4,183,992". Something still has to map a date to a cursor. |

**Why serializing is ruled out — measured.** [Spike
003](../../spikes/003-throughput-ceiling/README.md) characterised exactly this shape:

| | clearings/s |
| --- | --- |
| one contended row, unbatched | ~800, plateauing at concurrency 4 then **declining** |
| one contended row, batched (25) | 3,420 |
| no global contention, striped + single-call | 7,897 |

Roughly 10× unbatched and 2.3× batched — and worse than it looks, because the lock is **global**:
every lever [0007](./0007-open-source-positioning.md) rests on reduces contention on *account* rows,
and none of them touch a lock taken by every writer. **The concurrency-4 plateau is the specific
danger** — throughput *declines* past four concurrent writers, so a deployment that answered a slow
ledger by adding workers would make it slower, which is the least debuggable failure mode available.

## What it costs

- The cursor **lags the newest writes** by the duration of the longest in-flight transaction — the
  price of keeping write concurrency.
- **The query layer is not bitemporal yet, though storage is.** `accounting_equation` takes one
  instant and one axis, so *the effective-axis February close as known on 1 March* cannot be
  expressed; `balance_sheet`, `income_statement` and `balance_sheet_balances` have no date predicate.
- It composes with [0004](./0004-event-log.md)'s deferred hash chain, which needs a total order.

## Why this is still `proposed`

The watermark has to be built and tested against concurrent writers. Unverified:
1. That `pg_snapshot_xmin(pg_current_snapshot())` gives a usable watermark under our real write
   pattern. The risk is a **batched posting run**, not the scheduler —
   [0008](./0008-durable-timers.md)'s timers are one-shot jobs with short transactions.
2. The watermark's lag under such a run: one transaction open for minutes pins every report in that
   window behind it.
3. That the watermark advances past aborted transactions automatically. It should; confirm.
