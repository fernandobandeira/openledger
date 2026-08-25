# Spike 006 — Holds as an append-only event log

## The question

A *hold* is the amount an authorization reserves against a card's credit limit. Today it is one
mutable row per authorization: `amount_minor` set at auth, `cleared_minor` UPDATEd as clearings
arrive, `state` UPDATEd on expiry — with `auth_id text NOT NULL UNIQUE`.

Two problems. It contradicts the append-only discipline used everywhere else in this ledger, and
**`auth_id UNIQUE` rejects an incremental authorization outright** — the hotel or fuel-pump case
where a merchant tops up an existing authorization. The
[reference spec](../../docs/reference-product.md) lists "incremental auths" in its edge-case table
while the schema makes them impossible.

## The answer

**Record every authorization event as an immutable signed row; derive the hold by summing.**

```sql
card_auth_events (
    event_id     -- idempotency: one row per processor message
    group_key    -- ties an auth to its increments, reversals and clearings
    kind         -- authorization | incremental | reversal | clearing | expiry
    amount_delta -- SIGNED: auth/incremental add, reversal/clearing/expiry subtract
)

group_total = SUM(amount_delta)
held        = SUM(GREATEST(group_total, 0))
```

`GREATEST` is what makes over-capture safe: a $1 fuel authorization cleared at $95 totals −94, and
must contribute **0** rather than silently *raising* available credit.

**One formula covers every case in the spec's edge-case table.** Measured:

| case | scenario | group total | still held | |
| --- | --- | --- | --- | --- |
| A | auth 500, partial clears 300 + 200 | 0.00 | 0.00 | fully consumed |
| B | **incremental** — 200, +150, +150, cleared 400 | 100.00 | 100.00 | ✅ *impossible under the old schema* |
| C | **over-capture** — $1 auth, $95 clearing | **−94.00** | **0.00** | clamped, credit not raised |
| D | reversal — merchant voided | 0.00 | 0.00 | released |
| E | expiry — clearing never came | 0.00 | 0.00 | released |
| F | authorized, nothing cleared | 330.00 | 330.00 | still reserved |
| G | **clearing arrives before the auth** | 200.00 | 200.00 | see below |
| H | **forced post** — clearing, no auth ever | −250.00 | 0.00 | contributes nothing to held |

### Order-tolerance is free

The spec requires the state machine be *"order-tolerant, not merely idempotent."* **`SUM` is
commutative, so this design is order-tolerant by construction** rather than by careful coding.

Case G, in order: the clearing lands first and the group reads `0.00` held — correct, nothing was
ever reserved. The authorization catches up and it reads `200.00` — 500 authorized less the 300
already cleared. No state machine had to anticipate the sequence.

### Idempotency and sign are database constraints

- A redelivered webhook is refused by `UNIQUE (tenant_id, event_id)` — not by application logic.
- A clearing carrying a *positive* delta is refused by a `CHECK`. The sign is a property of the
  event kind, so it cannot be got wrong.

Both verified by attempting them.

## What it costs

**Reads become an aggregate.** `held` was a single-row lookup; it is now a `GROUP BY` over a
group's events. Groups are small — an authorization plus a handful of increments and clearings —
so the scan is bounded by *events per authorization*, not by history. But it is on the
authorization hot path, which has a ~1s deadline, and it has **not been benchmarked here**. If it
proves too slow the standard answer applies: a materialised per-group total maintained on write,
with the event log staying the source of truth — the same relationship
[ADR-0003](../../docs/decisions/0003-bitemporal-balances.md) sets up between `balance_after` and
recomputation.

**More rows.** Five to ten per authorization instead of one. At this volume, irrelevant.

## The open question this does not answer

**What is `group_key`, really?** The design assumes some identifier is stable across an original
authorization, its increments, its reversals and its clearings. Candidates differ in stability:
Visa's Transaction Identifier, Mastercard's Banknet reference, the RRN, the ARN, the approval
code, or a processor's own transaction object id.

The spec already warns that this is not clean: *"No clean foreign key. Network IDs (ARN, RRN)
don't reliably agree across messages. Needs exact match, then fuzzy fallback on
card+merchant+amount±tolerance+window, then an explicit unmatched queue — never a silent guess."*

So `group_key` may not always be knowable at write time, and the table must tolerate a row
arriving before its group is resolved. **Under research; the schema here assumes the optimistic
case.** That question, and whether each major issuer-processor exposes a webhook id stable across
redeliveries (needed for `event_id`), is what decides whether this design is deployable as written.

## Reproduce

```sh
psql "$DSN" -f holds.sql    # schema + the derived view
psql "$DSN" -f cases.sql    # all eight cases, plus idempotency and sign guards
```
