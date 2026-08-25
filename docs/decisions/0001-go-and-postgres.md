# 0001 — Go + Postgres, no ORM

**Status:** accepted
**Date:** 2026-08-25

## Context

Almost all the load-bearing logic in a ledger lives in SQL, not in application code:

- The authorization decision — the one request with a latency deadline — is a single
  transaction using `FOR UPDATE`, a filtered aggregate, and `ON CONFLICT ... DO NOTHING`.
- A balance is an index lookup on `(account_id, account_seq DESC)`.
- Immutability is `REVOKE UPDATE, DELETE` from the app role, not application discipline.
- Tenant isolation is row-level security.

That narrows the host language's job: run that SQL, drive durable timers, parse webhooks, serve
an API.

## Decision

**Go, on Postgres, with no ORM.**

**Go** because `int64` minor units are native, so no float ever comes near money; because
deployment is a static binary with no runtime to install; and because the Postgres tooling we
depend on — pgx and sqlc — is first-class there.

**Postgres** because one instance is enough — see the measured ceiling below.

**No ORM** because the hot queries are hand-tuned artifacts meant to be read and reviewed *as
SQL*, by us and plausibly by an auditor.

### Alternatives

| | Why not |
| --- | --- |
| **Kotlin/JVM** | Strongest runner-up — sealed classes give exhaustive state machines. Rejected on stack weight, not merit. |
| **TypeScript** | Default numeric type is a float. Every boundary would need `bigint` discipline forever. |
| **Rust** | Strong on correctness, but slower to iterate and a smaller pool of contributors for an OSS project. |
| **TigerBeetle** | See [0007](./0007-open-source-positioning.md#why-not-tigerbeetle), which makes the case properly. |

Go also remains the lowest-friction language for outside contributors, which matters more for an
open-source project than stack weight did for a small team.

## What changed since

**The sizing argument is superseded.** This ADR originally justified Postgres by *knowing* the
workload (under 1 TPS). [0007](./0007-open-source-positioning.md) removes that knowledge.
The conclusion holds on better grounds: [spike 003](../../spikes/003-throughput-ceiling/README.md)
measured **~800 clearings/s unsharded, ~7,900 striped**, with durability on. Postgres is now
chosen on measured headroom and a known bottleneck, not on an assumption.

**Formance reached the same "no procedural logic in the database" position, expensively.** Their
v1 put the ledger *in* plpgsql — triggers cascading from a log table into transactions, moves and
balances. Their migration 37 drops roughly 26 stored functions and moves all of it into Go. Note
what they *kept*: the constraints. It is procedural logic they reversed, not database-enforced
correctness.

**Constraints matter more for us than for them.** Formance's posting primitive is a
source/destination pair — balanced *by construction*, so no CHECK is needed anywhere. Our entries
are independent rows carrying a direction, so we *can* express an unbalanced transaction and
therefore *must* prevent it. We do both: the write API accepts balanced pairs only (making the
illegal state unrepresentable), and a deferred constraint trigger is the backstop. Spike 003 ran
its entire benchmark with that trigger active and never found it to be the bottleneck — up to
7,897 clearings/s the limit was row-lock contention.

## Resolved — Temporal is gone

Half this ADR's original case for Go was Temporal SDK quality. Temporal is not a library: it is a
server cluster with its own databases, which contradicts
[0007](./0007-open-source-positioning.md)'s promise of one binary and one database.

[**0008**](./0008-durable-timers.md) resolves it: durable timers run in-process on Postgres, and
the ledger core takes no scheduler dependency at all. **The case for Go now rests on `int64` money,
static binaries, and pgx/sqlc quality** — not on an SDK we no longer use.

## Consequences

- Correctness pressure moves into SQL, migrations, and tests.
- Go's lack of sum types makes state machines verbose. Mitigate with generated enum constants and
  exhaustiveness tests.
- The data-access layer is the next decision — [0002](./0002-data-access-layer.md).
