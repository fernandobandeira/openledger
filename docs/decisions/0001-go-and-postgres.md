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

**Go** because Temporal is written in Go and its Go SDK is the reference implementation (every
timer in the design is a Temporal workflow); because `int64` minor units are native, so no float
ever comes near money; and because deployment is a static binary.

**Postgres** because one instance is enough — see the measured ceiling below.

**No ORM** because the hot queries are hand-tuned artifacts meant to be read and reviewed *as
SQL*, by us and plausibly by an auditor.

### Alternatives

| | Why not |
| --- | --- |
| **Kotlin/JVM** | Strongest runner-up — sealed classes give exhaustive state machines. Rejected on stack weight, not merit. |
| **TypeScript** | Default numeric type is a float. Every boundary would need `bigint` discipline forever. |
| **Rust** | Temporal's Rust SDK is not ready. |
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

## Open — Temporal is an unexamined dependency

Half this ADR's case for Go is Temporal SDK quality. But Temporal is not a library: it is a
server cluster with its own database and worker fleet, or a paid cloud subscription.
[0007](./0007-open-source-positioning.md) promises "a small team can drop this into AWS", which
is a claim about *one* managed database. Those two things are in tension and no ADR owns it.

Three positions, unchosen:

1. **Temporal in the reference product only.** The ledger core needs no durable timers — hold
   expiry and settlement windows belong to the card layer, which 0007 already demotes. Most
   likely answer.
2. **A pluggable timer interface**, Postgres-backed by default. Costs an abstraction over
   something easy to get subtly wrong.
3. **Accept the dependency** and drop the "drop into AWS" claim.

**Needs its own ADR before M6**, where Temporal was scheduled to enter.

## Consequences

- Correctness pressure moves into SQL, migrations, and tests.
- Go's lack of sum types makes state machines verbose. Mitigate with generated enum constants and
  exhaustiveness tests.
- The data-access layer is the next decision — [0002](./0002-data-access-layer.md).
