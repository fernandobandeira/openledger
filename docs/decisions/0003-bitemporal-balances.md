# 0003 — Balances on two time axes: running balance for now, aggregate-on-read for as-of

**Status:** accepted

## The decision

Every entry carries two dates that routinely disagree: **recorded** (`recorded_at`, ordered by
`account_seq`) is when we learned about it, **effective** (`effective_at`) is the business date it
belongs to, taken from the source's clock — a card network's business date, not our webhook's arrival
time. An entry recorded today and effective last week is **backdated**, which is normal: late
clearings and chargebacks are inherently backdated.

**Two axes, two mechanisms — never both from one running balance.**

| Question | Mechanism |
| --- | --- |
| Current balance (the hot path) | `balance_after`, `ORDER BY account_seq DESC LIMIT 1` — O(1) |
| Balance as *recorded* at instant T | `ORDER BY recorded_at DESC, account_seq DESC LIMIT 1`, on `ix_entries__asof_recorded` |
| **Balance as of business date T** | **aggregate over `effective_at <= T`** |

`effective_at` is denormalized onto `ledger_entries` so the aggregate is a single-table index scan,
not a join. There is no running balance on the effective axis.

## Why

**A running balance answers business-date questions wrongly.**

| account_seq | effective | amount | balance_after |
| --- | --- | --- | --- |
| 1 | Jan 10 | +100 | 100 |
| 2 | Jan 30 | +50 | 150 |
| 3 | Jan 20 | +30 | **180** |

Balance as of Jan 25 by running-balance lookup: **180**. The truth: **130**. The backdated Jan 20
entry has a *higher* sequence number than the Jan 30 entry, so `ORDER BY account_seq DESC LIMIT 1`
lands on a balance that already includes Jan 30. And every stated purpose for as-of balances —
statements, lender reporting, "as of June 30" — is a business-date question.

**Each read must be ordered by the axis it asks about.** A recorded-axis read written as
"current-balance lookup plus `recorded_at <= T`" plans on the `account_seq` index and then filters,
discarding tens of thousands of rows to find one — measured at ~36,000 rows removed by filter
against zero for the correctly-ordered shape (harness since deleted). Hence `ix_entries__asof_recorded`.

**Why not a second running balance on the effective axis?** A backdated insert would have to `UPDATE`
every later row for that account — unbounded write amplification on a table whose whole value is
immutability. [Spike 001](../../spikes/001-formance/README.md) copied Formance's effective-volume
trigger pair verbatim into a fresh schema, then inserted N moves into one account in effective-date
order and again fully backdated:

| moves | in insertion order | fully backdated |
| --- | --- | --- |
| 200 | — | 679 ms |
| 400 | — | 5,162 ms |
| 1,000 | **114 ms** | **84,342 ms** |

**740× on a thousand rows, and worse than quadratic** — 200→400 is 7.6×, 400→1,000 is 16× — because
each `UPDATE` rewrites an ever-larger set and the HOT-update budget from `fillfactor = 80` runs out.
That fill factor is migration 10 in their history; three later migrations (19, 20, 28) repair data.
Their own best point-in-time path ignores the stored column anyway: `/volumes?pit=` re-aggregates
from `moves`, and only `/aggregate/balances?pit=` reads `post_commit_effective_volumes`.

**None of that argues against our running balance.** Formance kept **two**, and their code comments
separate them: `post_commit_volumes` (insertion axis) *"will never change"*;
`post_commit_effective_volumes` (effective axis) *"can be updated if a transaction is inserted in
the past"*. Only the **mutable** one cost them anything: the rule is not "running balances are bad",
it is **"a running balance on a mutable axis is bad"**.

**Free corruption alarm.** `balance_after` and the recorded-axis aggregate must always agree; a cheap
periodic check finds divergence, and should recompute rather than only alarm, as Modern Treasury does.

## Alternatives

| | Why not |
| --- | --- |
| One running balance for both axes | Wrong by construction — the table above. |
| A second running balance on the effective axis | 740× on backdated insert, measured on their code. |
| Forbid backdating | Breaks on late clearing and chargebacks, which are the normal case. |

## What it costs

- **The effective-axis aggregate is linear and currently unbounded** — roughly 0.10 µs per entry in
  range, and **105.91 ms** for a 1M-entry account (one-off run, no harness in repo). We traded
  Formance's unbounded `UPDATE` for an unbounded `SCAN`, but ours is on the read path and mutates
  nothing.
- **It must be bounded, and accounting already knows how: period close.** Materialize each account's
  balance at each period end, so a business-date query becomes *"prior period's closing balance +
  entries in the open period"* — an **effective-axis checkpoint**, distinct from `balance_after`. A
  backdated entry in a closed period needs restatement or a prior-period adjustment, as accounting
  practice already requires. **Prerequisite for M5.**
- **The striped read cost is unmeasured.** The accounts every transaction touches are the shared ones,
  also the accounts accumulating the most entries — so the account most likely to be queried "as of
  last quarter" has the largest scan, summed across N stripes. **Spike before M5.**
- **Reporting code must name its axis explicitly**, and M5 must test the backdating case above.
- **The recorded axis is not yet trustworthy, which blocks M5.** `recorded_at` should be assigned by
  the writer; today it is a bare `DEFAULT` and forgeable — verified, an `INSERT` supplying
  `1999-01-01` was accepted — and `now()` is *transaction start* time, so it is not monotonic with
  commit order and an "as of T" report can re-run to a different number.
  See [0005](./0005-reproducible-as-of.md).
