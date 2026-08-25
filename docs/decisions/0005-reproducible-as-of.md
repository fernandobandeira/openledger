# 0005 — A reproducible as-of cursor

**Status:** proposed — blocks roadmap M4
**Date:** 2026-08-25

## Context

[ADR-0003](./0003-bitemporal-balances.md) split balances onto two time axes and left one
question open. This is it.

[v1-vision §04](../v1-vision.md) requires that reports pin an **instant**, not a date, "or 'as
of June 30' re-runs to a different number and you've lost the reproducibility bitemporality was
for." The recorded axis exists to provide exactly that guarantee.

**It doesn't, as specified.** `recorded_at` defaults to `now()`, which in Postgres is the
*transaction start* time. It is not monotonic with **commit** order:

| Transaction | starts | commits | writes `recorded_at` |
| --- | --- | --- | --- |
| A | T1 | **T3** | T1 |
| B | T2 (> T1) | T2.5 | T2 |

A report for "as of T2.6" run at T2.7 sees B but not A — A hasn't committed. The same report for
the same instant, re-run at T4, sees both. **Same query, same as-of value, different answer.**
That is precisely the failure the requirement exists to prevent, and no amount of care with time
zones or `date_trunc` fixes it, because the problem is not the clock.

This is not hypothetical at our volume — it needs only two concurrent writers and one slow
transaction. A facility report and a batched clearing run overlapping is an ordinary Tuesday.

Formance pins one timestamp per SQL transaction via a temp table with `ON COMMIT DELETE ROWS`,
so rows *within* a transaction agree. That fixes intra-transaction consistency. It does not fix
this.

## The shape of the answer

A reproducible cursor must be **commit-ordered**. A wall clock cannot be, and neither can a bare
`bigserial` — sequence values are handed out at *insert* time, so the same interleaving produces
gaps that fill in later. A reader who takes `max(seq)` at T2.6 gets a value that is not yet
gap-free, and A's lower sequence number appears afterwards.

Three candidates:

**(a) Serialize all ledger writes.** A single advisory lock at commit hands out a strictly
commit-ordered number. Correct, trivially. Costs us every concurrent write — and the vision doc
already accepts serializing per company, not globally. At 20–50 TPS peak this is the option most
likely to be *fine* and most likely to be regretted; note Formance's SYNC hash mode does exactly
this and it is the reason their async path exists.

**(b) A gap-free watermark over a global sequence.** Entries get a global `bigserial`. A reader
does not use `max(seq)`; it uses the highest **N such that every entry ≤ N is committed**.
Standard CDC technique, computable from `pg_snapshot_xmin(pg_current_snapshot())` — every
transaction below the snapshot's xmin has resolved. Reports pin a watermark value, not a
timestamp. Preserves write concurrency; the cost is that a report's cursor lags the newest
writes by the duration of the longest in-flight transaction, which for us is milliseconds.

**(c) Accept "as of entry #N" and push the problem to the caller.** Honest, and viable for
internal reporting, but a lender's credit agreement says "as of June 30", not "as of entry
4,183,992". Something has to map a date to a cursor, and that mapping is (a) or (b) wearing a
hat.

## Proposal

**(b)**, with the cursor living on [`ledger_events`](./0004-event-log.md) rather than on
entries — one monotonic sequence for the whole system, assigned once per accepted event, rather
than a second ordering concept per table.

Reports resolve a business date to a watermark **once**, store the watermark alongside the
report, and re-run against the stored watermark. That is what makes "as of June 30" reproduce:
the date picks a cursor, and the cursor — not the date — is what the query uses forever after.

This also composes with the deferred hash-chain in
[ADR-0004](./0004-event-log.md#deferred-deliberately): a chain needs a total order, and this is
that order.

## Why this is still `proposed`

The watermark mechanism needs to be **built and tested against concurrent writers** before it is
accepted. Specifically unverified:

1. That `pg_snapshot_xmin(pg_current_snapshot())` gives a usable watermark under our actual
   write pattern, including long-running Temporal activities holding transactions open.
2. What the watermark's lag actually is under a batched clearing run — if a nightly batch holds
   one transaction open for minutes, every report during that window is pinned behind it.
3. Whether the watermark should advance past aborted transactions automatically (it should, but
   confirm).
4. ~~Whether (a) is honestly good enough. At under 1 TPS average, global write serialization may
   cost nothing measurable, and it is far simpler.~~ **Measured — see the amendment below.**

Do not build M4 on the vision doc's `recorded_at <= :as_of` in the meantime. It is not
reproducible, and code written against it will need to change.

## Amendment — open question 4 is now answered, and it favours (b)

This ADR said **"Measure before choosing the clever option."**
[Spike 003](../../spikes/003-throughput-ceiling/README.md) is that measurement, and it arrived
without being aimed at this question.

Option (a) — a single advisory lock handing out a commit-ordered number — is structurally
identical to the single-contended-row case spike 003 characterised in detail:

| | clearings/s |
| --- | --- |
| one contended row, unbatched | ~800, plateauing at concurrency 4 then **declining** |
| one contended row, coalesced batching (25) | 3,420 |
| no global contention, striped | 6,850 |
| no global contention, striped + single-call | **7,897** |

Two consequences the original analysis could not have known:

**(a) costs roughly 8× unbatched and 2× batched — and it is worse than those numbers look**,
because the lock is *global*. Every lever [ADR-0007](./0007-open-source-positioning.md) rests on
— striping, worker-affinity striping, per-tenant house accounts — works by reducing contention on
**account** rows. None of them touch a lock that every writer takes regardless of which account
it is posting to. Adopting (a) does not merely lower the ceiling; it makes 0007's entire
throughput story inoperative.

**The concurrency-4 plateau is the specific danger.** Spike 003 found that throughput on a
contended row *declines* past concurrency 4. A deployment that adds workers to a slow ledger
would make it slower — the least debuggable failure mode available, and one that would land on
users rather than on us.

**This settles the proposal at (b)** on evidence rather than taste. It also raises the value of
(b)'s specific shape: because the cursor lives on `ledger_events` and is assigned once per
accepted event, batching amortises it exactly as it amortises everything else.

Open questions 1–3 stand unchanged; the watermark still has to be built and tested against
concurrent writers. Question 1's premise — "long-running Temporal activities holding transactions
open" — should be re-examined in light of
[ADR-0001's Temporal amendment](./0001-go-and-postgres.md#amendment--temporal-is-an-unexamined-dependency-for-the-open-source-goal),
since it is no longer settled that Temporal is in the write path at all.
