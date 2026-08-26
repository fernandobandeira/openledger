# 0005 — A reproducible as-of cursor

**Status:** proposed — blocks roadmap M5
**Date:** 2026-08-25

## Context

A report must be **reproducible**: re-running "as of June 30" next year must return the same
number it returned last year. That is the entire point of recording two time axes
([0003](./0003-bitemporal-balances.md)).

**`recorded_at` does not provide it.** It defaults to `now()`, which in Postgres is *transaction
start* time — not commit order:

| Transaction | starts | commits | writes `recorded_at` |
| --- | --- | --- | --- |
| A | T1 | **T3** | T1 |
| B | T2 (> T1) | T2.5 | T2 |

A report for "as of T2.6" run at T2.7 sees B but not A — A hasn't committed yet. The same report,
same as-of value, re-run at T4, sees both. **Different answer.** No amount of care with time zones
fixes this, because the problem is not the clock.

It needs only two concurrent writers and one slow transaction — a reporting run overlapping a
batched posting run is an ordinary Tuesday.

A bare `bigserial` doesn't help either: sequence values are handed out at *insert* time, so the
same interleaving leaves gaps that fill in afterwards. A reader taking `max(seq)` gets a value
that is not yet gap-free.

## The options

**(a) Serialize all ledger writes.** One lock at commit hands out a strictly commit-ordered
number. Trivially correct, and costs every concurrent write.

**(b) A gap-free watermark over a global sequence.** A reader does not use `max(seq)`; it uses the
highest **N such that every entry ≤ N has committed** — computable from
`pg_snapshot_xmin(pg_current_snapshot())`, since every transaction below the snapshot's xmin has
resolved. Standard CDC technique. Reports pin a watermark, not a timestamp. Preserves write
concurrency; the cursor lags the newest writes by the duration of the longest in-flight
transaction.

**(c) Push "as of entry #N" to the caller.** Honest, and fine internally — but a credit agreement
says "as of June 30", not "as of entry 4,183,992". Something still has to map a date to a cursor.

## Proposal

**(b)**, with the cursor on [`ledger_events`](./0004-event-log.md) — one monotonic sequence for
the whole system, assigned once per accepted event, rather than a second ordering concept per
table.

Reports resolve a business date to a watermark **once**, store the watermark alongside the report,
and re-run against the stored watermark forever after. The date picks a cursor; the cursor is what
the query uses.

This also composes with 0004's deferred hash chain, which needs a total order anyway.

## Why (a) is ruled out — measured

This ADR originally said "measure before choosing the clever option".
[Spike 003](../../spikes/003-throughput-ceiling/README.md) is that measurement, and it arrived
without being aimed at this question. Option (a) is structurally identical to the
single-contended-row case it characterised:

| | clearings/s |
| --- | --- |
| one contended row, unbatched | ~800, plateauing at concurrency 4 then **declining** |
| one contended row, batched (25) | 3,420 |
| no global contention, striped + single-call | 7,897 |

So (a) costs roughly 8× unbatched and 2× batched — and it is worse than those numbers look,
because the lock is **global**. Every lever [0007](./0007-open-source-positioning.md) rests on
works by reducing contention on *account* rows; none of them touch a lock taken by every writer
regardless of what it posts to. Adopting (a) would make 0007's throughput story inoperative.

**The concurrency-4 plateau is the specific danger.** Throughput on a contended row *declines*
past four concurrent writers, so a deployment that responded to a slow ledger by adding workers
would make it slower — the least debuggable failure mode available, and one that lands on users.

## Why this is still `proposed`

The watermark has to be built and tested against concurrent writers. Unverified:

1. That `pg_snapshot_xmin(pg_current_snapshot())` gives a usable watermark under our real write
   pattern. This originally assumed long-running workflow activities might hold transactions open;
   [0008](./0008-durable-timers.md) settles that they do not — timers are one-shot jobs, and a job
   handler's transaction is as short as any other write. **The risk that remains is a batched
   posting run**, not the scheduler.
2. The watermark's lag under a batched run — if one transaction stays open for minutes, every
   report in that window is pinned behind it.
3. That the watermark advances past aborted transactions automatically. It should; confirm.

**Do not build M5 on `recorded_at <= :as_of` meanwhile.** It is not reproducible, and code written
against it will change.
