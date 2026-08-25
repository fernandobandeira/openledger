# Vision

> Status: current. Supersedes [`v1-vision.md`](./v1-vision.md) as the *project* vision —
> that document is now the **reference product** specification.
> Positioning decision: [ADR-0007](./decisions/0007-open-source-positioning.md) (proposed).

## What this is

An open-source double-entry ledger. Postgres for storage, Go for the service, a single binary
plus a database you already know how to run.

The bet is narrow: **most teams that need a real ledger do not need a fast one, but every one of
them needs a correct one.** Correctness here means specific, testable things — every cent
accounted for, no manual fixes, and any number reproducible as of any date, forever. Those are
hard to retrofit and cheap to build in from the start, which is the whole argument for using
something rather than rolling your own `balances` table.

## Who it is for

A small team that needs a ledger and does not want to operate a new class of infrastructure to
get one. Concretely: you can put this behind RDS or Aurora, get managed backups and
point-in-time restore for free, and not think about it again.

That constraint drives more of the design than performance does. See
[Why Postgres, and not TigerBeetle](#why-postgres-and-not-tigerbeetle).

## The core, and the product built on it

Two layers, deliberately separated.

**The core** is the ledger, and it is the project:

| | |
| --- | --- |
| Accounts | typed by category and normal balance, multi-tenant, multi-currency |
| Transactions | the unit of atomicity; status never mutates |
| Entries | immutable, append-only, balanced per currency |
| Balances | O(1) current balance, plus as-of reads on two time axes |
| Bitemporal reads | recorded axis and effective axis, never conflated ([ADR-0003](./decisions/0003-bitemporal-balances.md)) |
| Event log | the idempotency spine and audit trail ([ADR-0004](./decisions/0004-event-log.md)) |

**The reference product** is an embedded B2B charge card funded by a credit line — spend
controls, credit lines, card holds, the authorization hot path. It is described in full by
[`v1-vision.md`](./v1-vision.md), and it exists for two reasons: to prove the core can carry a
real product without forking, and to give the core a demanding acceptance test. It is not the
project.

The dividing line matters because it decides what is configurable. The product layer is meant to
be replaced. The core is not.

## Non-negotiables

Four properties of the core. None of them is a setting.

- **Append-only.** Entries are never updated or deleted. Enforced by revoking `UPDATE` and
  `DELETE` from the application role, not by convention.
- **Balanced per currency.** Enforced by the database, as a deferred constraint trigger, not by
  application code.
- **Bitemporal.** Every transaction carries both when it happened (`effective_at`, from the
  source's clock) and when we learned about it (`recorded_at`).
- **Event-logged.** Every accepted external event is recorded, including the ones that produce no
  ledger transaction.

**Correctness is never configurable, and this is a lesson rather than a preference.**
[Spike 001](../spikes/001-formance/README.md) found Formance made historization a feature flag;
the result is point-in-time queries that silently return `{}` when the flag is off — what one
reporter called *"a green check that didn't actually execute."* A wrong answer that looks like an
answer is worse than an error. The temptation for a general engine is to let users trade
historization, hashing, or balance tracking for throughput. We will not offer that trade.

Make the product pluggable. Never the invariants.

## Performance

[Spike 003](../spikes/003-throughput-ceiling/README.md) measured the design rather than assuming
it. Durable settings throughout — `fsync`, `synchronous_commit`, and `full_page_writes` all on.

| Configuration | clearings/s | entries/s |
| --- | --- | --- |
| baseline (unsharded, unbatched) | ~800 | ~2,400 |
| + coalesced batching (25 per transaction) | 3,420 | 10,260 |
| + hot-account striping (64) | 6,850 | 20,550 |
| random striping **+** batching | 2,356 | 7,069 |
| + worker-affinity striping + batching | 4,790 | 14,370 |
| + single-call posting, striped | 7,897 | 23,692 |

**These numbers are not a claim, and none of them belongs in marketing copy yet.** They were
measured on localhost on one 16-core laptop with stock Postgres. On localhost a round trip costs
**0.05ms**; on RDS it costs roughly **0.5ms**, and our clearing path takes six of them against
1.3ms of actual work. That does not merely scale the numbers down — it *reorders the levers*,
making batching and single-call posting matter more and striping matter less. Nothing has been
measured over a network. Until it is, we publish no throughput figure.

What the measurements do support:

- **The bottleneck is one row, not the hardware.** Routing every clearing through a single
  *company* account costs 12%. The shared *house* accounts are the entire ceiling, and throughput
  plateaus at concurrency 4 and then declines — so adding workers to a struggling ledger makes it
  slower.
- **Table size barely matters.** Retested at 5 million entries and 2 GB against 128 MB of cache,
  essentially unchanged. The workload is append-only, so the hot set is bounded by account count,
  not entry count.
- **There are two levers and they cancel** unless you pick correctly. Batching suits streams you
  control; striping suits independent arrivals. Random striping combined with batching is worse
  than either alone; worker-affinity striping makes them compose.

Both levers become first-class features rather than folklore, and house accounts become
per-tenant — a shared ledger whose tenants contend with each other gets slower as it succeeds.

## Why Postgres, and not TigerBeetle

TigerBeetle deserves a straight answer, because it is excellent and the comparison is real. Its
two-phase transfer model maps onto card authorization almost exactly: a pending transfer with a
timeout is a hold with an expiry, posting a pending transfer for a lesser amount is a partial
clearing, voiding one is an authorization reversal, and its pending/posted balance split is
precisely the held/posted distinction the card product needs. If the ledger core were the whole
problem, it would be a strong candidate.

Three reasons it is the wrong fit here:

1. **It solves a throughput problem we measured ourselves not to have.** It targets orders of
   magnitude beyond what spike 003 found, and almost no user will reach even that ceiling.
2. **It cannot be the only datastore.** Its schema is deliberately fixed — no ad-hoc queries, no
   joins, no aggregation, no JSON, user data limited to fixed-width integers. Reporting,
   statements, spend controls, state machines, multi-tenancy, and row-level security all still
   need Postgres. You end up operating two systems and a consistency boundary between them.
3. **It defeats the deployment goal.** There is no managed AWS offering; it wants a replica
   cluster on instances with fast local disk, operated by you, including upgrades and failure
   recovery. For a small team, adopting it *increases* operational burden at exactly the moment
   we claim to reduce it.

What we take from it anyway: the two-phase transfer with timeout is a better-factored version of
our `card_holds` table, and worth reading before that table is finalized.

When to revisit: when a real user sustains thousands of clearings per second *after* applying the
levers above. That is a good problem, it will announce itself, and the ledger core is a narrow
enough interface to put behind an abstraction then — against a real workload rather than a
hypothetical one.

## What we are deliberately not building

- Sharding, read replicas for writes, or a cache in front of balances. The sizing does not call
  for any of it, and a cache in front of a ledger is a second copy that can drift.
- Configurable correctness, in any form.
- A general-purpose scripting language for transactions.
- Multi-currency FX conversion. The schema carries currency and balances per currency;
  conversion is a separate problem with its own decision to make.

## Where to go next

| | |
| --- | --- |
| [`roadmap.md`](./roadmap.md) | What gets built, in what order, and why that order |
| [`decisions/`](./decisions/) | ADRs — every architectural decision and its reasoning |
| [`v1-vision.md`](./v1-vision.md) | The reference product: the embedded card ledger in full |
| [`../spikes/`](../spikes/) | Timeboxed investigations — brief, findings, and code together |
