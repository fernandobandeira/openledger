# 0004 — Idempotency lives on an append-only event log, not on transactions

**Status:** accepted

## The decision

**`ledger_events`**: an append-only record of every accepted external event, written in the same
transaction as whatever it causes.

- `idempotency_key` + `idempotency_hash`, tenant-scoped, under `uq_events__idempotency`.
- `kind`, `source`, `payload jsonb`, `effective_at`, `recorded_at`.
- Every `ledger_transactions` row references the event that caused it — and so do the rails that
  write no transaction at all: holds, transfers, disputes.

**The retry contract, stated once:** same key + same hash → replay the stored outcome. Same key +
*different* hash → reject. A caller bug that silently returns the wrong stored result is worse than
a failure.

**This is not event sourcing.** The ledger stays the system of record; we do not rebuild it by
replay. But `payload` must be **complete enough to replay from**, not merely complete enough to
audit — an open-source ledger needs logical export, migration between deployments, and the ability
to rebuild derived state after a bug. That is a constraint on the payload schema, and it is far
cheaper to honour from the first migration than to retrofit.

## Why

Idempotency on `ledger_transactions` can only deduplicate events that *produce* a ledger
transaction. Most of a ledger's accepted operations deliberately produce none:

| Event | Writes a ledger transaction? |
| --- | --- |
| Authorization, approved | **No** — it records a hold; nothing is owed until it clears |
| Authorization, declined | **No** |
| Hold expiry | **No** — nothing was ever owed |
| Authorization reversal | **No**, if nothing had cleared |
| Statement close | **No** — a statement is a read |
| Repayment initiated | **No** — money in commits at settlement |
| Credit limit change, account opening | **No** |

That is most of the lifecycle, all of it arriving from external systems that retry. One mechanism
replaces a different natural key per rail, and declined authorizations — which otherwise exist only
as a closed hold row — get a home. It also generalizes past cards: any ledger has accepted
operations that produce no transaction (an account opened, a limit changed, a rejected posting, a
metadata edit), so for a general engine this table is the difference between having a retry contract
and not having one.

## Alternatives

| | Why not |
| --- | --- |
| Idempotency key on `ledger_transactions` | Covers only the minority of events that post. |
| A natural key per rail | Each rail is a separate chance to get it wrong. **Keep them anyway** as a second check: a hash mismatch is a `400`, a duplicate business object is a `409` — different failures deserving different responses. |
| Event sourcing | The ledger stays the system of record; we do not rebuild balances by replay. |

## What it costs

- Write amplification is one insert per event into an uncontended append-only table. Unmeasured,
  but not the shape of thing that caused any bottleneck
  [spike 003](../../spikes/003-throughput-ceiling/README.md) found.
- **`ledger_transactions.event_id` is nullable and unenforced**, so an event-less transaction
  inserts without complaint. `NOT NULL` is the obvious fix and is not yet done.
- **The `NULLS NOT DISTINCT` on the idempotency index is inert** — both `tenant_id` and
  `idempotency_key` are `NOT NULL`. It is kept as documentation of a real hazard: in the spike
  schema `tenant_id` *was* nullable, and without that clause a unique index does not constrain
  house-scoped rows at all. Costs nothing; silently wrong if either column is made nullable again.

## Deferred: hash chaining

Chaining each log row's hash to the previous gives tamper evidence, which is valuable to a lender.
A per-write lock on the chain head is structurally the single-contended-row case spike 003
measured: ~800 clearings/s, plateauing at concurrency 4 and *declining* after. Worse, it is a
**global** contention point, so it defeats every throughput lever
[0007](./0007-open-source-positioning.md) depends on — striping and per-tenant accounts reduce
contention on *account* rows and do nothing about a lock every writer takes. The one lever that
survives is **batching**, because the chain lock is taken once per transaction rather than once per
event.

> **Synchronous hash chaining costs roughly 2× throughput when batched, and roughly 8× when not.**

Affordable for a lender-facing deployment; unaffordable as a default. So it is **opt-in per
deployment** — a durability/audit setting, not a correctness setting, which keeps it clear of
0007's rule against configurable correctness. Decide it alongside
[0005](./0005-reproducible-as-of.md), since a chain needs a total order.

When we build it, copy Formance's **payload/memento split**: `payload` is the full event, `memento`
a separate canonical byte form used *only* as hash input, deliberately excluding derived fields.
The chain then covers the *decision*, not the derived state, so recomputing a balance never
invalidates tamper evidence.

**Also deferred: metadata history.** `metadata jsonb` is mutable with no history, so it cannot
answer "what did we believe at time T". If any of it feeds reporting, the cheapest fix is to make
metadata changes *be* events in this log rather than adding revision tables.
