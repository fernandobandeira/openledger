# 0004 — An append-only event log

**Status:** accepted
**Date:** 2026-08-25

## Context

**Idempotency** — making a retried request produce the stored result rather than a second effect
— currently lives on `ledger_transactions`. So we can only deduplicate events that *produce a
ledger transaction*. But most of a ledger's accepted operations deliberately produce none:

| Event | Writes a ledger transaction? |
| --- | --- |
| Authorization, approved | **No** — it records a hold; nothing is owed until it clears |
| Authorization, declined | **No** |
| Hold expiry | **No** — nothing was ever owed |
| Authorization reversal | **No**, if nothing had cleared |
| Statement close | **No** — a statement is a read |
| Repayment initiated | **No** — money in commits at settlement |
| Credit limit change, account opening | **No** |

That is most of the lifecycle. Every one arrives from an external system that will retry, and
**none can currently be made idempotent**, because idempotency is a column on a table they never
touch. Today the only thing making a duplicate *declined* authorization safe is a unique key on
one rail's table. Every other rail needs its own, and each is a chance to get it wrong.

This generalizes past the card product: any ledger has accepted operations that produce no
transaction — an account opened, a limit changed, a rejected posting, a metadata edit. For a
general engine this table is the difference between having a retry contract and not having one.

## Decision

Add **`ledger_events`**: an append-only record of every accepted external event, written in the
same transaction as whatever it causes.

- `idempotency_key` + `idempotency_hash`, tenant-scoped with `NULLS NOT DISTINCT`.
- `kind`, `source`, `payload jsonb`, `effective_at`, `recorded_at`.
- Every `ledger_transactions` row *should* reference the event that caused it — but `event_id` is
**nullable and unenforced**, and an event-less transaction inserts without complaint. Making it
`NOT NULL` is the obvious fix and is not yet done. So do rails that write no
  transaction — holds, transfers, disputes.

**The retry contract, stated once:** same key + same hash → replay the stored outcome. Same key +
*different* hash → reject. A caller bug that silently returns the wrong stored result is worse
than a failure.

**This is not event sourcing.** The ledger stays the system of record; we do not rebuild it by
replay. But `payload` must be **complete enough to replay from**, not merely complete enough to
audit — an open-source ledger needs logical export, migration between deployments, and the
ability to rebuild derived state after a bug. That is a constraint on the payload schema, and it
is far cheaper to honour from the first migration than to retrofit.

## Consequences

- **Idempotency becomes uniform.** One mechanism instead of a different natural key per rail.
- **Keep the per-rail unique keys anyway.** A caller-supplied idempotency key and a
  business-object natural key catch different failures and deserve different responses: hash
  mismatch is a `400`, duplicate business object is a `409`.
- **Declined authorizations get a home.** Today they exist only as a closed hold row.
- Write amplification is one insert per event into an uncontended append-only table. Not measured,
  but not the shape of thing that caused any bottleneck spike 003 found.

## Deferred — hash chaining, and why the cost is now known

Chaining each log row's hash to the previous gives tamper evidence, which is valuable to a lender.
This ADR originally said the serialization was free at our volume. **That is measurably false.**

A per-write lock on the chain head is structurally the single-contended-row case
[spike 003](../../spikes/003-throughput-ceiling/README.md) measured: ~800 clearings/s, plateauing
at concurrency 4 and *declining* after. Worse, it is a **global** contention point, so it defeats
every throughput lever [0007](./0007-open-source-positioning.md) depends on — striping and
per-tenant accounts all reduce contention on *account* rows and do nothing about a lock every
writer takes.

The one lever that survives is **batching**, because the chain lock is taken once per transaction
rather than once per event.

> **Synchronous hash chaining costs roughly 2× throughput when batched, and roughly 8× when not.**

Affordable for a lender-facing deployment; unaffordable as a default. It should be **opt-in per
deployment** — a durability/audit setting, not a correctness setting, so it does not violate
0007's rule against configurable correctness. Decide it alongside
[0005](./0005-reproducible-as-of.md), since a chain needs a total order.

When we do build it, copy Formance's **payload/memento split**: `payload` is the full event;
`memento` is a separate canonical byte form used *only* as hash input, deliberately excluding
derived fields. The chain then covers the *decision*, not the derived state — so recomputing a
balance never invalidates tamper evidence.

**Also deferred: metadata history.** Our `metadata jsonb` is mutable with no history, which cannot
answer "what did we believe at time T". If any of it feeds reporting, the cheapest fix is to make
metadata changes *be* events in this log rather than adding revision tables.
