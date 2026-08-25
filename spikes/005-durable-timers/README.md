# Spike 005 — Can Postgres replace Temporal for durable timers?

## The question

The project needs timers that survive restarts: a card authorization *hold* must expire after
~7 days, an ACH return window closes ~2 banking days after funds land, statements close monthly.
[ADR-0001](../../docs/decisions/0001-go-and-postgres.md) planned to use **Temporal** for these —
but Temporal is a server cluster with its own datastore, which contradicts
[ADR-0007](../../docs/decisions/0007-open-source-positioning.md)'s pitch of *one binary and a
database you already run*.

## The answer

**Postgres is sufficient, and Temporal is not needed.** Verified end to end with
[River](https://github.com/riverqueue/river) v0.45.0 against a real database.

The requirement is **durable scheduling**, not **workflow orchestration** — and those are very
different things:

| what we need | longest chain |
| --- | --- |
| hold expiry (~7 days) | 1 step |
| ACH return window (~2 days) | 2 steps |
| statement close (monthly) | 1 step |
| dispute deadlines | 1 step |

Nothing here uses Temporal's distinguishing features — workflow-as-code with replay, signals into
running workflows, child workflows, or workflow versioning.

**And the decisive point:** Temporal's headline guarantee is exactly-once *effects*, delivered as
at-least-once execution plus idempotent activities. But
[ADR-0004](../../docs/decisions/0004-event-log.md) already requires every handler to be idempotent
— that is the entire purpose of the event log. **Temporal would be a second implementation of a
guarantee the ledger already provides**, bought with a cluster's worth of operations.

## Measured

Real jobs, real database, process killed between scheduling and working:

```
STEP 1  schedule 3 timers, then EXIT — no worker ever runs
        unique insert #1 -> job 3, skipped_as_duplicate=false
        unique insert #2 -> job 3, skipped_as_duplicate=true

STEP 2  process gone. Postgres still holds:
        auth_due     scheduled  2026-08-25 19:18
        auth_unique  scheduled  2026-08-25 19:18
        auth_7day    scheduled  2026-09-01 19:18   <- seven days out

STEP 3  start a worker, 8 concurrent, 6 seconds
        fired: auth_unique (attempt 1)
        fired: auth_due    (attempt 1)

STEP 4  auth_due     completed  attempt 1
        auth_unique  completed  attempt 1
        auth_7day    scheduled  attempt 0   <- correctly untouched
```

Every property the ledger needs, confirmed:

| requirement | result |
| --- | --- |
| Survives process death | ✅ jobs persisted with no worker ever having run |
| Schedules days ahead | ✅ 7-day job stored and left alone |
| Does not fire early | ✅ `attempt 0` after a worker ran for 6s |
| Fires exactly once under concurrency | ✅ `attempt 1`, 8 workers competing |
| Idempotent enqueue | ✅ two inserts of one hold's expiry returned the **same job id** |
| Standard Postgres queue pattern | ✅ `FOR UPDATE … SKIP LOCKED` in the driver SQL |

## What it costs

**Operationally, nothing.** River is a library, not a server — no `cmd/`, it runs inside our
binary. It adds 5 tables and 7 migrations to the same database. It is built on **pgx v5**, already
our driver under [ADR-0002](../../docs/decisions/0002-data-access-layer.md), and generates its own
SQL with **sqlc**, already our codegen.

**What we give up**, honestly: workflow-as-code (a multi-step process reads as sequential Go with
state persisted automatically), signals and queries into running workflows, versioning of
long-running workflows, and Temporal's operational UI. For a two-step maximum chain none of these
apply — but they are real capabilities and a future rail with a genuinely long saga could want
them.

**License:** MPL-2.0 — file-level copyleft, weaker than AGPL, linking is unencumbered. Worth
knowing but not a blocker for an open-source project.

## What this does not settle

- Only River was tested hands-on. `gue`, `neoq` and others were not benchmarked here.
- Load was trivial. At a few thousand ledger transactions a day the pending-timer set is small,
  but that is reasoning, not measurement.
- The **statement close** case is a scheduled *cron*, not a one-shot timer. River supports
  periodic jobs; not exercised here.
- Whether to keep a **pluggable timer interface** so teams already running Temporal can use it is
  a design question, not a capability question.

## Reproduce

```sh
createdb ol_timers
export OL_DSN="postgres://openledger:openledger@localhost:5433/ol_timers"
go run . schedule   # schedules, then exits without working
go run . work       # starts a worker for 6s
```
