# 0001 — Go + Postgres, no ORM

**Status:** accepted
**Date:** 2026-08-25

## Context

[The v1 vision](../v1-vision.md) sizes the workload before designing it: under 1 TPS average,
20–50 TPS at peak. Throughput is not the constraint. The stated constraints are correctness,
auditability, one latency-bound path (the auth decision), and product surface area.

That inverts the usual language calculus. Almost all the load-bearing logic lives in SQL:

- The auth decision is **one transaction** — `FOR UPDATE`, a two-grain `FILTER` aggregate,
  `GREATEST` clamping, `ON CONFLICT ... DO NOTHING RETURNING`.
- Balances are an index lookup on `(account_id, account_seq DESC)`.
- Immutability is `REVOKE UPDATE, DELETE` on the app role, not application discipline.
- Tenant isolation is RLS.

The host language's job is narrower than usual: run that SQL, drive durable workflows, parse
processor webhooks, serve an API.

## Decision

**Go**, on **Postgres**, with **no ORM**.

Go because:

- Temporal is written in Go and the Go SDK is its reference implementation. Every timer in the
  design — hold expiry, clearing, settlement, ACH return windows, disputes, statements — is a
  Temporal workflow, so SDK quality is a primary axis, not a secondary one.
- `int64` minor units are native and boring. No float anywhere near money by construction.
- Deployment is a static binary. Small team, boring tech.

Postgres because the vision argues for it directly and the sizing supports it: one instance,
no sharding, no cache. `posted` is read straight off the ledger precisely so there is no second
copy that can drift.

No ORM because the queries in the vision doc are hand-tuned artifacts. They are meant to be
read and reviewed as SQL — by us, and plausibly by an auditor.

## Alternatives considered

**Kotlin/JVM** — the strongest runner-up. Sealed classes give exhaustive `when` over state
machine transitions, which the vision calls "the actual modelling work," and the finance
ecosystem is mature. Rejected on stack weight for a small team, not on merit. Revisit if the
domain state machines get genuinely hard.

**TypeScript** — best if one person is doing full-stack. Rejected because the default numeric
type is a float; every boundary would need `bigint` discipline forever, and the one place we
cannot afford a silent rounding bug is this one.

**Rust** — attractive for the ledger core's invariants. Rejected because Temporal's Rust SDK
is not ready, and at under 1 TPS we would be paying iteration speed for performance we have
explicitly declined to need.

**TigerBeetle** (cited in the vision's sources) — purpose-built double-entry, but it solves the
throughput problem we do not have, and does not help with bitemporal reporting, RLS
multi-tenancy, or the working-set tables. Worth reading for its invariants; not worth adopting.
See [spike 001](../../spikes/001-formance/README.md) for the "learn from, don't adopt" pattern.

## Corroboration from [spike 001](../../spikes/001-formance/README.md)

Two parts of this ADR were later tested against Formance's production history, and both held —
one of them for a reason we had not thought of.

**"No ORM, logic in Go, the DB does constraints and locks" is the position Formance arrived at
the expensive way.** Their v1 put the ledger *in the database*: insert a row into `logs`, and
plpgsql triggers cascaded into transactions, moves, accounts, and volumes. Migration 37 is the
demolition — it drops roughly 26 stored functions including `handle_log()`,
`insert_transaction()`, `insert_move()`, and every volume-computation function, moving all of it
into Go. We should not read that as "the database is the wrong place for correctness" — their
*constraints* stayed. It is specifically **procedural logic** in the database that they reversed.

**Constraints doing the work is load-bearing for us in a way it is not for them.** Formance's
posting primitive is `Posting{Source, Destination, Asset, Amount}` — a balanced pair *by
construction*, so there is no CHECK and no trigger enforcing that debits equal credits anywhere
in their schema. Our `ledger_entries` are independent rows carrying a `direction`, which means
we **can** express an unbalanced transaction and therefore **must** enforce that we don't.
Formance offers us no help here, and their marketing line about debits always equalling credits
has no runtime check behind it.

The lesson taken: do both layers. Make the write API accept balanced pairs only — make the
illegal state unrepresentable, which is the actual Formance insight — **and** keep the deferred
constraint trigger as a backstop. At our volume the trigger is free, and it converts a class of
silent corruption into a failed insert.

## Amendment — the sizing argument is superseded

This ADR's opening move is "size it before designing," justified by *knowing* the workload.
[ADR-0007](./0007-open-source-positioning.md) proposes reframing the project as a general
open-source ledger, which removes that knowledge.

The conclusion holds; the reasoning is replaced. [Spike 003](../../spikes/003-throughput-ceiling/README.md)
measured the design at **~800 clearings/s unsharded, ~6,850/s striped**, on stock Postgres with
durability on — 17–40× the peak this ADR sized for. Postgres remains correct, but on measured
headroom and a known bottleneck (one contended row), not on an assumption about volume.

## Amendment — what else the pivot touches

Beyond the sizing argument above, three things in this ADR need restating under
[ADR-0007](./0007-open-source-positioning.md).

**The "Alternatives considered" rationale leans on the superseded sizing.** The Rust rejection
("at under 1 TPS we would be paying iteration speed for performance we have explicitly declined
to need") and the Kotlin rejection ("stack weight for a small team") were both arguments from a
known, small workload. The conclusions survive on other grounds — Temporal's Rust SDK is still
not ready, and Go remains the lowest-friction language for outside contributors, which matters
*more* for an open-source project than stack weight did for a small team. But the arguments as
written no longer carry themselves.

**The TigerBeetle dismissal here is superseded.** This ADR rejects it in three lines as solving
a throughput problem we do not have. [ADR-0007](./0007-open-source-positioning.md#why-not-tigerbeetle)
now makes the case properly, and reaches the same conclusion for a better reason: TigerBeetle
cannot be the only datastore, so it *adds* a system rather than replacing one, and it has no
managed AWS offering — which defeats the deployment goal outright. Read 0007's version, not this
one.

**The deferred balance trigger is no longer an assumption.** This ADR claims "at our volume the
trigger is free." [Spike 003](../../spikes/003-throughput-ceiling/README.md) ran the entire
benchmark with `ck_entries__balances` active, and the measured bottleneck was row-lock contention
on shared accounts — not the trigger, not I/O, not WAL flush. The claim is now measured rather
than assumed, and it holds up to at least 7,897 clearings/s.

## Amendment — Temporal is an unexamined dependency for the open-source goal

This is the largest unresolved tension the pivot creates, and no ADR currently owns it.

Half this ADR's case for Go is Temporal: *"Every timer in the design — hold expiry, clearing,
settlement, ACH return windows, disputes, statements — is a Temporal workflow, so SDK quality is
a primary axis, not a secondary one."* That reasoning is sound for a team building one product
who have already decided to run Temporal.

[ADR-0007](./0007-open-source-positioning.md) states the goal as **"a small team can drop into
AWS and run."** Temporal is not a library — it is a server cluster with its own persistence store
and worker fleet, or a paid cloud subscription. Requiring it means the "drop into AWS" story is
Postgres **plus** a Temporal deployment, which is materially harder than the one-managed-database
pitch 0007 rests on, and harder than the thing it is arguing against on exactly those grounds.

Three positions are available and this ADR does not choose between them:

1. **Temporal in the reference product only.** The ledger core needs no durable timers — hold
   expiry and ACH return windows belong to the *card* layer, which ADR-0007 already demotes to a
   reference implementation. This is the most likely answer and would resolve the tension
   cleanly.
2. **A pluggable timer interface**, with a Postgres-backed default and Temporal as an option.
   Costs an abstraction over something notoriously easy to get subtly wrong.
3. **Accept Temporal as a hard dependency** and drop the "drop into AWS" claim to match.

Note this interacts with [ADR-0005](./0005-reproducible-as-of.md), whose open question 1 assumes
"long-running Temporal activities holding transactions open" as part of the write pattern.

**Recommendation: this needs its own ADR before M6**, which is where Temporal was scheduled to
enter. Flagged here rather than decided, because it is a positioning call that belongs with
whoever accepts or rejects 0007.

## Consequences

- Correctness pressure moves into SQL, migrations, and tests. Constraints do the work that
  application code would otherwise be trusted to do.
- Go's lack of sum types makes state machines more verbose. Mitigate with generated enum
  constants and exhaustiveness tests, not comments.
- The data-access layer becomes the next real decision — see [0002](./0002-data-access-layer.md).
