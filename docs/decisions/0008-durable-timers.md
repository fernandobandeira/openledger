# 0008 — Durable timers in Postgres, not Temporal

**Status:** accepted
**Date:** 2026-08-25

## Context

The reference product needs timers that survive restarts: a card authorization *hold* expires
after ~7 days, an ACH return window closes ~2 banking days after funds land, statements close
monthly, disputes have deadlines.

[ADR-0001](./0001-go-and-postgres.md) planned to use **Temporal**, and half its case for Go was
Temporal SDK quality. [ADR-0007](./0007-open-source-positioning.md) promises a small team can drop
this into AWS — a claim about *one* managed database. Temporal is a server cluster with its own
datastore. Those two positions were in tension and no decision owned it.

## Decision

**No Temporal.** Durable timers live in the application binary, backed by the same Postgres.

The product layer gets a narrow interface, and the **`tx` parameter is the point**:

```go
type Scheduler interface {
    At(ctx context.Context, tx pgx.Tx, kind, key string, at time.Time, payload []byte) error
    Cancel(ctx context.Context, tx pgx.Tx, kind, key string) error
}
```

Exactly **one** driver ships: [River](https://github.com/riverqueue/river), verified in
[spike 005](../../spikes/005-durable-timers/README.md). The ledger core takes no scheduler
dependency at all.

## Why

**The requirement is durable *scheduling*, not workflow *orchestration*.** The longest chain in
the design is two steps (ACH settles → wait → post). Nothing uses Temporal's distinguishing
features: workflow-as-code with replay, signals into running workflows, child workflows, or
versioning.

**The guarantee is already ours.** Temporal delivers exactly-once *effects* as at-least-once
execution plus idempotent handlers. [ADR-0004](./0004-event-log.md) already requires every handler
to be idempotent — that is what the event log is for. Temporal would be a second implementation of
a guarantee the ledger already provides.

**Temporal cannot enqueue transactionally, and that matters here.** River inserts the job in the
*same Postgres transaction* as the ledger write, so "the hold row and its expiry timer both exist,
or neither" is a database guarantee. Temporal's `StartWorkflow` is a gRPC call to another service
and cannot join our transaction — using it means building an outbox, i.e. building a Postgres
queue *and then* putting Temporal behind it.

**Long timers are harder under Temporal, not easier.** Temporal's own documentation uses our exact
shape — sleep on a timer, then run an activity — as its worked example of what breaks: reordering
those commands between deploys makes replay non-deterministic. Every deploy during a 7-day hold
window becomes a versioning exercise. A job row is inert JSON handed to whatever code is current.

**The footprint is disproportionate.** Temporal Server is four services (frontend, history, matching, worker); it needs its own
persistence database with its own migrations, plus a separate visibility store (**contested:** one
reviewer reported Temporal's docs call this recommended-for-production, another reported it
required — and the second later retracted its external verification as fabricated, so neither
reading is confirmed here. Treat as unverified); `numHistoryShards`
is fixed at deploy time and changing it requires a cluster rebuild; minor versions must be upgraded
sequentially with a schema migration each; and self-hosted Temporal ships no RBAC or audit logging
— notable for the component driving money-movement timers. Its tested Postgres matrix also stops at
16.6, while we target 18. All of this to service roughly **0.05 jobs per second**.

Temporal Cloud is not an option for an open-source project: the plan floor is $100/month, against
an actual consumption cost here of about $14 — an OSS user should not have to buy a SaaS
subscription to get hold expiry.

**Precedent.** Rails 8 made Solid Queue — a database-backed queue — its default, moving *away*
from Redis, and runs 20M jobs/day for HEY at 37signals. Removing the accessory service was worth more than
the specialised backend.

## The reframe that lowers the bar

The deadline is already stored on the event (`card_auth_events.hold_expires_at`), and available
credit is computed from `card_hold_groups.held_minor` — **not** from a timer. So a hold that has
passed its deadline but has not yet been swept still counts against available credit.

Every timer here **fails conservatively when it fires late**: a late expiry under-reports available
credit, a late ACH finalization keeps a receivable open longer. Nothing produces a wrong ledger,
only a temporarily pessimistic one. The deadline is durable in our own table regardless; the
scheduler is an *actuator*, not a correctness-critical component.

So we also add a **reconciliation sweep** — groups that are past their deadline and still holding:

```sql
SELECT g.tenant_id, g.company_id, g.group_key
FROM card_hold_groups g
WHERE g.expired_at IS NULL AND g.held_minor > 0
  AND EXISTS (
      SELECT 1 FROM card_auth_event_group m
      JOIN card_auth_events e ON e.tenant_id = m.tenant_id AND e.id = m.event_id
      WHERE m.tenant_id = g.tenant_id AND m.group_key = g.group_key
        AND m.superseded_at IS NULL
        AND e.hold_expires_at < now());
```

`ix_hold_groups__held` already covers the outer predicate. It costs almost nothing and makes a lost
job recoverable rather than silent.

## Amendment — the schema moved, twice

This ADR was written against `card_holds`, which had a `state` column. Migration 0003 replaced it
with `card_auth_events` + `card_hold_groups`, so the prescribed sweep predicate no longer existed.

The first repair was **also wrong**: it moved the predicate to `card_hold_groups` but kept
`hold_expires_at`, a column that lives on `card_auth_events`. `ERROR: column "hold_expires_at" does
not exist`. So this ADR contained two successive dead queries, in the section whose own conclusion
is that dead queries are the problem.

The *conclusion* survives, and for the same reason: an unswept expired hold still counts toward
`held_minor` until the flag is set, so a lost timer job leaves the ledger temporarily
**pessimistic**, never wrong. But the reframe rested on a specific predicate, and that predicate was
dead — twice, and the second time in the very amendment that fixed the first. The query above was
executed against `migrations/0001`–`0003` before being written down, which is now the standard: the
schema snapshot test in [0006](./0006-schema-conventions.md) must cover ADR-quoted SQL, because
review demonstrably does not.

## Consequences

- The ledger core has no scheduler dependency. ADR-0001's Go argument no longer rests on Temporal
  SDK quality; it rests on `int64` money, static binaries, and pgx/sqlc.
- One driver ships. A Temporal driver is *possible* via an outbox — document it, and let the first
  user who actually runs Temporal contribute it. An abstraction with one implementation is a seam;
  with two speculative ones it is a tax.
- **Statement close is a self-rescheduling one-shot job**, not a periodic job — per-customer
  timezones make it one anyway, and it avoids River's commercial tier, which gates durable periodic
  jobs.
- **River is MPL-2.0**, which is *file-level* copyleft and so does not constrain this project's
  licence (the repo is MIT). Two obligations do survive: shipping a static binary means telling
  recipients how to obtain River's source (§3.2), and any River file we *modify* stays MPL. If MPL
  ever becomes unacceptable, `gue` (MIT) is the fallback — delayed jobs, `SKIP LOCKED`, backoff,
  transactional enqueue; uniqueness would be hand-rolled on the event log's idempotency keys, which
  exist anyway.
- Documentation and the architecture diagram still say "Postgres · Temporal" and need updating.

## The bet, named

Four of the five timers are genuinely one-shot. **Disputes are not.** A real chargeback lifecycle
is a multi-month state machine — filed, representment, pre-arbitration, arbitration, ruling — with
external events arriving early, late, or never, and human steps in between. That is exactly the
shape Temporal exists for, and it is already on our list.

If dispute handling grows into that, migrating means moving **live in-flight state across a 120-day
window** during which both systems are authoritative. That is a genuinely painful retrofit.

We take the bet for two reasons. A hand-rolled state machine over a `disputes` table with
deadline-driven jobs is boring, well-understood, and **auditable** — a reviewer or an actual auditor
can read a table and a transition function, where reconstructing a dispute from a Temporal event
history is strictly harder. And the risk is confined to the reference product layer, which
[ADR-0007](./0007-open-source-positioning.md) already declares replaceable. The ledger core — the
actual project — touches a scheduler either way: never.
