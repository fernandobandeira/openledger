# 0001 — Go on one Postgres, no ORM

**Status:** accepted

## The decision

**Go, on a single Postgres instance, with no ORM.** Queries are hand-written SQL compiled to typed
Go by sqlc ([0002](./0002-data-access-layer.md)). The ledger's procedural logic lives in Go;
Postgres holds the shape ([0012](./0012-where-logic-lives.md)).

## Why

**Go** because `int64` minor units are native, so no float ever comes near money; because
deployment is a static binary with no runtime to install; and because pgx and sqlc are
first-class there. Go is also the lowest-friction language for outside contributors, which matters
for an open-source project.

**Postgres** because the headroom is measured, not assumed.
[Spike 003](../../spikes/003-throughput-ceiling/README.md) recorded **~800 clearings/s unsharded
and 6,212–7,405 striped at 64**, with durability on, on one 16-core machine — 17–40× the volume the
reference product needs. (The ~7,900 figure quoted elsewhere is striping *plus* single-call
posting: a different configuration, not a better measurement of the same one.) At the top of the
ladder the spike is explicit that the curve "plateaus **because the machine ran out of cores rather
than because of a lock**. The ceiling moved from the design to the hardware."

**No ORM** because the hot queries are hand-tuned artifacts meant to be read and reviewed *as SQL*,
by us and plausibly by an auditor. The authorization decision is one transaction using
`FOR UPDATE`, a filtered aggregate and `ON CONFLICT ... DO NOTHING`; a balance is an index lookup on
`(account_id, account_seq DESC)`; immutability is a trigger that refuses `UPDATE` and `DELETE` on
the immutable logs ([0011](./0011-what-the-database-enforces.md)), not application discipline.

**Formance reached the same "no procedural logic in the database" position, expensively.** Their v1
put the ledger *in* plpgsql — triggers cascading from a log table into transactions, moves and
balances; their migration 37 drops 27 stored functions and moves it all into Go
([spike 001](../../spikes/001-formance/README.md)). Note what they *kept*: the constraints. It is
procedural logic they reversed, not database-enforced correctness.

**The trap that follows from that, and it is ours alone.** Formance's posting primitive is a
source/destination pair — balanced *by construction*, so no CHECK is needed anywhere. Our entries
are independent rows carrying a direction, so we *can* express an unbalanced transaction and
therefore *must* prevent it. [0013](./0013-the-write-path.md) makes it unconstructible in the write
API rather than refusing it in SQL, and that writer is not built, so today nothing enforces balance
at all.

## Alternatives

| | Why not |
| --- | --- |
| **Kotlin/JVM** | Strongest runner-up — sealed classes give exhaustive state machines. Rejected on stack weight, not merit. |
| **TypeScript** | Default numeric type is a float. Every boundary would need `bigint` discipline forever. |
| **Rust** | Strong on correctness, slower to iterate, smaller contributor pool for an OSS project. |
| **TigerBeetle** | See [0007](./0007-open-source-positioning.md#why-not-tigerbeetle), which makes the case properly. |
| **Temporal for durable timers** | A server cluster with its own databases, against one binary and one database. [0008](./0008-durable-timers.md) runs timers in-process on Postgres instead. |

## What it costs

- Correctness pressure moves into Go, SQL, migrations and tests rather than into a framework.
- Go has no sum types, so state machines are verbose. Mitigate with generated enum constants and
  exhaustiveness tests.
- **Tenant isolation is meant to be row-level security and is not built.** `tenant_id` leading
  every key is the prerequisite and it exists; the policies do not — `schema/` contains no
  `CREATE POLICY` and no `ENABLE ROW LEVEL SECURITY`.
- The data-access layer is the next decision — [0002](./0002-data-access-layer.md).
