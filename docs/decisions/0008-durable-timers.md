# 0008 — Durable timers live in Postgres, not Temporal

**Status:** accepted
**Date:** 2026-08-25

## The decision

**No Temporal.** Durable timers run inside the application binary, backed by the same Postgres the
ledger writes to. The product layer gets a narrow interface, and the **`tx` parameter is the point**:

```go
type Scheduler interface {
    At(ctx context.Context, tx pgx.Tx, kind, key string, at time.Time, payload []byte) error
    Cancel(ctx context.Context, tx pgx.Tx, kind, key string) error
}
```

Exactly **one** driver ships: [River](https://github.com/riverqueue/river), verified in
[spike 005](../../spikes/005-durable-timers/README.md). The ledger core takes no scheduler
dependency at all.

The reference product needs timers that survive restarts: a card authorization hold expires after
~7 days, an ACH return window closes ~2 banking days after funds land, statements close monthly,
disputes have deadlines. [ADR-0001](./0001-go-and-postgres.md) had planned on Temporal, and half its
case for Go was Temporal SDK quality; [ADR-0007](./0007-open-source-positioning.md) promises a small
team can drop this into AWS, which is a claim about *one* managed database. This ADR resolves that
tension in favour of the one database.

## Why

> Every Temporal, Rails and pricing figure in this section is **unverified** — no fetchable source
> sits next to it. Treat them as the reasoning that was persuasive at the time, not as evidence.

**The requirement is durable *scheduling*, not workflow *orchestration*.** The longest chain in the
design is two steps (ACH settles → wait → post). Nothing uses Temporal's distinguishing features:
workflow-as-code with replay, signals into running workflows, child workflows, or versioning.

**The exactly-once guarantee is already ours.** Temporal delivers exactly-once *effects* as
at-least-once execution plus idempotent handlers. [ADR-0004](./0004-event-log.md) already requires
every handler to be idempotent — that is what the event log is for. Temporal would be a second
implementation of a guarantee the ledger already provides.

**Temporal cannot enqueue transactionally, and here that decides it.** River inserts the job in the
*same Postgres transaction* as the ledger write, so "the hold row and its expiry timer both exist,
or neither" is a database guarantee. `StartWorkflow` is a gRPC call to another service and cannot
join our transaction — using it means building an outbox, i.e. building a Postgres queue *and then*
putting Temporal behind it.

**Long timers are harder under Temporal, not easier.** Its own documentation uses our exact shape —
sleep on a timer, then run an activity — as the worked example of what breaks: reordering those
commands between deploys makes replay non-deterministic. Every deploy during a 7-day hold window
becomes a versioning exercise. A job row is inert JSON handed to whatever code is current.

**The footprint is disproportionate to 0.05 jobs per second.** Temporal Server is four services
(frontend, history, matching, worker) with its own persistence database and migrations, plus a
separate visibility store; `numHistoryShards` is fixed at deploy time and changing it requires a
cluster rebuild; minor versions must be upgraded sequentially with a schema migration each; RBAC
ships **off by default** (four roles behind a `ClaimMapper` and `NewDefaultAuthorizer`, but the
default is `noopAuthorizer`) and there is no audit logging — notable for the component driving
money-movement timers. Its tested Postgres matrix stops at 16.6; we target 18.

**Precedent.** Rails 8 made Solid Queue — a database-backed queue — its default, moving *away* from
Redis, and runs 20M jobs/day for HEY at 37signals. Removing the accessory service was worth more
than the specialised backend.

### The reframe that lowers the bar — and why the scheduler is not correctness-critical

Available credit is computed from `card_hold_groups.held_minor`, **not** from a timer. A hold past
its deadline that has not yet been swept still counts against available credit. So every timer here
**fails conservatively when it fires late**: a late expiry under-reports available credit, a late
ACH finalization keeps a receivable open longer. Nothing produces a wrong ledger, only a temporarily
pessimistic one. The scheduler is an *actuator*, not a correctness-critical component.

A reconciliation sweep makes a lost job recoverable rather than silent — groups past their deadline
and still holding:

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

`ix_hold_groups__held` is what earns this — it is `(tenant_id, company_id) WHERE held_minor > 0`,
and the sweep filters on the partial predicate with no tenant or company equality, so the `WHERE`
clause is the useful half of the index, not the key columns.

**The sweep is inert today, and executing it will not tell you that.** It parses and runs; it
matches zero rows on every database this API can build, because nothing writes
`card_auth_events.hold_expires_at` — the column exists, the ingest path has no parameter for it, so
the predicate is NULL for every row. Making it live means modelling the deadline a processor
actually sends. Until then the recovery this section describes does not exist, which matters less
than it sounds (an unswept hold over-reserves) and more than nothing (the sweep was load-bearing in
the argument for not needing a durable scheduler).

## Alternatives

| | Why not |
| --- | --- |
| **Temporal Cloud** | Not an option for an open-source project: the plan floor is $100/month against an actual consumption cost here of about $14. An OSS user should not have to buy a SaaS subscription to get hold expiry. *(Unverified — no source.)* |
| **Self-hosted Temporal** | The four reasons above. The one thing it would buy — a real multi-month workflow engine — is the bet named below. |
| **`gue` instead of River** | MIT rather than MPL-2.0, and it has delayed jobs, `SKIP LOCKED`, backoff and transactional enqueue. Kept as the fallback if MPL ever becomes unacceptable; uniqueness would be hand-rolled on the event log's idempotency keys, which exist anyway. *(Feature list unverified — no source.)* |
| **A scheduler abstraction with two drivers** | An abstraction with one implementation is a seam; with two speculative ones it is a tax. A Temporal driver is *possible* via an outbox — document it, and let the first user who actually runs Temporal contribute it. |

## What it costs

- **ADR-0001's Go argument no longer rests on Temporal SDK quality.** It rests on `int64` money,
  static binaries, and pgx/sqlc.
- **Statement close is a self-rescheduling one-shot job**, not a periodic job — per-customer
  timezones make it one anyway, and it avoids River's commercial tier, which gates durable periodic
  jobs. *(Unverified — no source; `spikes/005` says only that River supports periodic jobs and did
  not exercise them.)*
- **River is MPL-2.0**, which is *file-level* copyleft and does not constrain this MIT project. Two
  obligations survive: shipping a static binary means telling recipients how to obtain River's
  source (§3.2), and any River file we *modify* stays MPL. *(Unverified — no source.)*
- **The dispute bet.** Four of the five timers are genuinely one-shot. **Disputes are not** — a real
  chargeback lifecycle is a multi-month state machine (filed, representment, pre-arbitration,
  arbitration, ruling) with external events arriving early, late, or never, and human steps between.
  That is exactly the shape Temporal exists for. If dispute handling grows into it, migrating means
  moving live in-flight state across a 120-day window during which both systems are authoritative.

  We take the bet for two reasons. A hand-rolled state machine over a `disputes` table with
  deadline-driven jobs is boring, well-understood, and **auditable** — a reviewer or an actual
  auditor can read a table and a transition function, where reconstructing a dispute from a Temporal
  event history is strictly harder. And the risk is confined to the reference product layer, which
  [ADR-0007](./0007-open-source-positioning.md) already declares replaceable. The ledger core — the
  actual project — touches a scheduler either way: never.
