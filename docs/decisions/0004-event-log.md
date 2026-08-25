# 0004 — An append-only event log

**Status:** accepted
**Date:** 2026-08-25

## Context

[Spike 001](../spikes/001-formance.md) identified this as the one table from Formance's schema
we are genuinely missing. Their `logs` is the real source of truth — every other table is a
projection, and they rebuild an entire ledger by replaying it.

The concrete problem for us is narrower and sharper than "they have one, so should we."

**Our idempotency key lives on `ledger_transactions`.** That means we can only deduplicate
events that *produce a ledger transaction*. But [v1-vision](../v1-vision.md) is explicit that
many events deliberately produce none:

| Event | Writes a ledger transaction? |
| --- | --- |
| Card authorization (approved) | **No** — a hold, nothing is owed until it clears |
| Card authorization (declined) | **No** — a `closed` hold row |
| Hold expiry | **No** — nothing was ever owed |
| Authorization reversal | **No**, if nothing had cleared |
| Statement close | **No** — a statement is a read |
| Repayment initiated (7.1) | **No** — money in commits at settlement |
| Credit limit change | **No** |
| Account opening | **No** |

That is most of the lifecycle. Every one of those arrives from an external system that will
retry, and **none of them can currently be made idempotent**, because idempotency is a column
on a table they never touch.

The vision doc's own §03 requires that a duplicate of a *declined* authorization return the
stored decision rather than re-evaluate against a limit that may have moved. Today the only
thing making that work is `card_holds.auth_id UNIQUE` — a per-rail solution. `ach_transfers`,
`disputes`, and `statements` each need their own, and each is a chance to get it wrong.

## Decision

Add **`ledger_events`**: an append-only record of every accepted external event, written in the
same transaction as whatever it causes.

- `idempotency_key` + `idempotency_hash`, scoped to the tenant, `NULLS NOT DISTINCT` — the
  same shape [ADR-0003's schema work](../spikes/001-formance.md) applied to
  `ledger_transactions`, now in one place instead of per-rail.
- `kind`, `source` (processor / treasury / customer / internal), `payload jsonb`,
  `effective_at`, `recorded_at`.
- Every `ledger_transactions` row references the event that caused it. Rails that write no
  transaction — holds, ACH transfers, disputes — reference it too.

**This is not event sourcing.** The ledger remains the system of record; we do not rebuild it
by replay. The log is the **idempotency spine and the audit trail**, and it answers "what did
we hear, when, and what did we do about it" for events that leave no ledger footprint. Formance
replays because they need import/export across deployments; we don't have that requirement and
should not pay for it.

## Consequences

- **Idempotency becomes universal and uniform.** One mechanism, one place to get right, instead
  of `auth_id UNIQUE` here and something else there. Per-rail natural keys stay as *additional*
  constraints — see below — but they stop being the only line of defence.
- **Keep the per-rail unique keys too.** `card_holds.auth_id UNIQUE` guards against double-posting
  the same network authorization *regardless of what the caller does with idempotency keys*.
  Formance keeps both: an idempotency key (caller-supplied, `400` on hash mismatch) and
  `transactions.reference` (business-object natural key, `409` on conflict). Two different
  failures, two different responses.
- **The retry contract gets stated once.** Same key + same hash → replay the stored outcome.
  Same key + different hash → reject; a caller bug that silently returns the wrong stored result
  is worse than a failure.
- **Declined authorizations get a home.** Today they exist only as a `closed` hold row.
- Write amplification is one extra insert per event. At under 1 TPS this is not a consideration.

## Deferred, deliberately

**Per-row hash chaining** for tamper evidence — cheap here and valuable to a lender. Formance's
`logs.hash` chains each row to the previous, which under their SYNC mode takes an advisory lock
and serializes every write; that is the entire reason their async block-hashing layer exists. At
our volume the serialization is free. **Take the chain, never build the blocks** — but not in
this ADR, because it interacts with the ordering question in
[ADR-0005](./0005-reproducible-as-of.md) and should be decided alongside it.

When we do take it, **copy their `data` / `memento` split**, which the
[table-design pass](../spikes/001-formance.md#logs--the-ddl-we-are-designing-adr-0004-from)
identified as the best idea in their schema:

- `payload jsonb` — the full event, for reads and replay.
- `memento bytea` — a *separate canonical byte form used only as hash input*, deliberately
  **excluding derived fields**. Their comment: *"We don't want those fields to be part of the
  hash as they are not part of the decision-making process."*

The chain then covers **the decision, not the derived state**, so recomputing a balance never
invalidates tamper evidence. Get this wrong and every backfill breaks the chain. Their hash input
also pins the row's own id and hash to fixed values so the digest is position-independent.

**Metadata history.** Formance maintains `transactions_metadata` / `accounts_metadata` revision
tables precisely because a mutable jsonb blob cannot answer "what did we believe at time T". Our
`metadata jsonb` is mutable with no history. If any of it feeds collateral reporting — obligor,
risk grade, account purpose — it needs history. The cheapest path is to make metadata changes
*be* events in this log rather than adding revision tables. Revisit once we know what metadata
the lender actually reads.
