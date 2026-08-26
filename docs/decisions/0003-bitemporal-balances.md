# 0003 — Balances on two time axes

**Status:** accepted
**Date:** 2026-08-25

## Context

Every entry carries two dates, and they routinely disagree:

- **recorded** (`recorded_at`, ordered by `account_seq`) — when we learned about it.
- **effective** (`effective_at`) — the business date it belongs to, taken from the source's
  clock. A card network's business date, not our webhook's arrival time.

An entry that arrives late is **backdated**: recorded today, effective last week. This is normal,
not exceptional — late clearings and chargebacks are inherently backdated.

`balance_after` is a running balance stamped on each entry as it is written. It answers "what was
this account's balance after this entry was *recorded*", and it is correct for that question. It
is **wrong for business-date questions**, and by a lot:

| account_seq | effective | amount | balance_after |
| --- | --- | --- | --- |
| 1 | Jan 10 | +100 | 100 |
| 2 | Jan 30 | +50 | 150 |
| 3 | Jan 20 | +30 | **180** |

Balance as of Jan 25 by running-balance lookup: **180**. The truth: **130**. The backdated Jan 20
entry has a *higher* sequence number than the Jan 30 entry, so `ORDER BY account_seq DESC LIMIT 1`
lands on a balance that already includes Jan 30. Re-measured at scale with every entry backdated,
the lookup was off — 180 against a true 130, i.e. **1.38x**, on a three-row example.
(An earlier draft called this "re-measured at scale, off by 2x". There is no such measurement; the
three-row example above is the only one. The *direction* of the error is the point and does not
depend on the magnitude, but the magnitude was invented and is struck.)

That matters because every stated purpose for as-of balances — statements, lender reporting, "as
of June 30" — is a business-date question.

## Decision

**Two axes, two mechanisms. Do not serve both with one running balance.**

| Question | Mechanism |
| --- | --- |
| Current balance (the hot path) | `balance_after`, `ORDER BY account_seq DESC LIMIT 1` — O(1) |
| Balance as *recorded* at instant T | `ORDER BY recorded_at DESC, account_seq DESC LIMIT 1` |
| **Balance as of business date T** | **aggregate over `effective_at <= T`** |

**The recorded-axis row used to read "same lookup, plus `recorded_at <= T`", and that shape is
wrong.** It plans on the current-balance index — which is ordered by `account_seq` — and then
filters, discarding tens of thousands of rows to find one. The read has to be ordered by the axis
it is asking about, which is what `ix_entries__asof_recorded` exists for. Measured before the SQL
harness was deleted: the naive shape removed ~36,000 rows by filter; the corrected one removed
none. Two different questions, two different indexes — which is the whole point of this ADR, and
the table stated it wrongly for the axis it was about.

`effective_at` is denormalized onto `ledger_entries` so the aggregate is a single-table index scan
rather than a join.

**Why not maintain a second running balance on the effective axis?** Because a backdated insert
would have to `UPDATE` every later row for that account — unbounded write amplification on a table
whose whole value is immutability. Formance built exactly that and needed six volume/pcv migrations
afterwards — of which **three actually repair data** (19, 20, 28), two only replace the aggregation
functions, and one is a no-op stub whose entire body is `raise notice 'Migration superseded by next
migration'`. Six was this document's number, and it was too generous to itself. **Why not forbid backdating?** It breaks on late clearing and
chargebacks.

So: aggregate-on-read is chosen **because immutability is worth more than read latency**.

### Measured, on their code: 740×

[Spike 001](../../spikes/001-formance/README.md) copied Formance's effective-volume trigger pair
verbatim into a fresh schema — the `BEFORE INSERT` that computes a move's business-date running
balance and the `AFTER INSERT` that rewrites every later move's — and inserted N moves into one
account, once in effective-date order and once fully backdated.

| moves | in insertion order | fully backdated |
| --- | --- | --- |
| 200 | — | 679 ms |
| 400 | — | 5,162 ms |
| 1,000 | **114 ms** | **84,342 ms** |

**740× on a thousand rows, and worse than quadratic** — 200→400 is 7.6×, 400→1,000 is 16× — because
each `UPDATE` rewrites an ever-larger set and the HOT-update budget from `fillfactor = 80` runs out.
That fill factor is migration 10 in their history; this is what it was paying for.

This ADR previously argued the shape from their migration list. Now it has the number, and the
number is the argument.

**And their own best point-in-time path does not use the stored column.** `/volumes?pit=`
re-aggregates `sum(case when not is_source then amount else 0 end)` from `moves`; only
`/aggregate/balances?pit=` reads `post_commit_effective_volumes`. So Formance ships **two
implementations of the same number with different failure modes** — and their better one is
aggregate-on-read, which is what this ADR chose. We are not merely avoiding their mistake; we
converged on their own fallback.

### This is not a contradiction of Formance's finding

Spike 001 found Formance demoting their running balance because of backdating, which reads as
incompatible with keeping ours. It isn't. They kept **two** running balances and their own code
comments separate them: `post_commit_volumes` (insertion axis) *"will never change"*;
`post_commit_effective_volumes` (effective axis) *"can be updated if a transaction is inserted in
the past"*. Only the **mutable** one cost them anything. Ours is the immutable one.

The lesson is not "running balances are bad" — it is **"a running balance on a mutable axis is
bad"**, and we keep only the immutable one.

### Free corruption alarm

`balance_after` and the recorded-axis aggregate must always agree. Any divergence is a bug,
detectable by a cheap periodic check. Worth strengthening from *alarm* to *fall back to
recomputation*, which is what Modern Treasury does when a cached balance drifts.

## Consequences

- **The effective-axis aggregate is linear and currently unbounded** — roughly 0.10 µs per entry
  in range, and observed at **105.91 ms** for a 1M-entry account in a one-off run whose harness is not in this repo. An earlier draft extrapolated ~220 ms from the per-entry rate while that direct measurement already existed; prefer the measurement. We have traded Formance's
  unbounded `UPDATE` on backdating for an unbounded `SCAN` on business-date reporting. Ours is at
  least on the read path, off the latency deadline, and does not mutate history.
- **It must be bounded, and accounting already knows how: period close.** Materialize each
  account's balance at each period end; a business-date query becomes *"prior period's closing
  balance + entries in the open period"*. This is an **effective-axis checkpoint**, distinct from
  `balance_after`. A backdated entry landing in a closed period needs explicit handling —
  restatement, or a prior-period adjustment in the open period — which accounting practice
  already requires. **Prerequisite for M5.**
- **The STRIPED read cost is unmeasured, and the assumption behind it is now unsafe.** The
  unstriped read *was* observed -- 105.91 ms at 1M entries, four points, above, with no harness in the repo. What has not been
  measured is that same read summed across N stripes. This decision was
  originally justified by "thousands of rows, not millions". Spike 003 measured the *write* path
  only, and found that the accounts touched by every transaction are the shared ones — which are
  therefore also the accounts accumulating the most entries. The account most likely to be queried
  "as of last quarter" is precisely the one with the largest scan. **Needs a spike before M5**,
  measuring the aggregate over an account with millions of entries, striped and unstriped.
- **Reporting code must name its axis explicitly.** An unqualified "as of" in a function signature
  is a support ticket waiting to happen.
- **Roadmap M5 must test the backdating case above**, not merely the happy path.

## Blocked on 0005

`recorded_at` is assigned `now()` by a trigger (it is no longer accepted from a caller — see
[0011](./0011-what-the-database-enforces.md)), and `now()` is *transaction start* time, so it is not monotonic with
commit order — an "as of T" report can return different numbers when re-run.
[0005](./0005-reproducible-as-of.md) takes that up, and it blocks M5.
