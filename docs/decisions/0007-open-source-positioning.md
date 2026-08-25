# 0007 — Positioning: a general open-source ledger

**Status:** proposed
**Date:** 2026-08-25

## Context

[ADR-0001](./0001-go-and-postgres.md) chose the stack on the strength of *knowing* the workload:
"throughput is not the constraint… under 1 TPS average, maybe 20–50 TPS at peak." Every
subsequent decision leans on that, and several deliberately hardcode what a general engine would
have to make configurable.

The question is whether this becomes **a general open-source ledger a small team can drop into
AWS and run** — which invalidates the premise, because we would no longer know our users' volume.

[Spike 003](../../spikes/003-throughput-ceiling/README.md) measured the ceiling so this can be
decided on numbers.

## What the measurements say

| Configuration | clearings/s | entries/s |
| --- | --- | --- |
| baseline (unsharded, unbatched) | ~800 | ~2,400 |
| + coalesced batching (25 per txn) | 3,420 | 10,260 |
| + hot-account striping (64) | **6,850** | **20,550** |
| both | 2,356 | 7,069 |

Durable settings throughout (`fsync`, `synchronous_commit`, `full_page_writes` all on), stock
Postgres on a 16-core laptop.

Three findings shape the decision:

1. **The baseline is ~17–40× the volume v1-vision sized for**, with no tuning. One unremarkable
   Postgres covers the overwhelming majority of fintech startups.
2. **The bottleneck is one row, not the hardware.** Routing every clearing through a single
   *company* account costs 12%; the two shared *house* accounts are the entire ceiling.
   Throughput plateaus at concurrency 4 and then declines.
3. **Two levers, and they cancel each other.** Batching and striping each give 4–8×; applied
   together they give 3× *less* than either alone.

## Decision

**Reframe as a general ledger. Keep Postgres. Change the argument, not the stack.**

ADR-0001's conclusion survives; its *reasoning* does not. "Throughput is not the constraint" was
an argument from known volume and cannot be made by a project that does not know its users. The
defensible version is: **here is the measured ceiling, here is the single thing that limits it,
and here are the two levers — pick the one matching your write pattern.**

### What changes

**1. Hot-account striping becomes a first-class feature.** It is the difference between 800/s and
6,850/s and currently exists only as folklore. Design it in: an account declares a stripe count,
writes pick a stripe, balance reads `SUM` across stripes. One integer on the account row.

**2. House accounts become per-tenant.** `uq_accounts__house` currently guarantees exactly one
`interchange_revenue` per *deployment*. Correct for one product; wrong for a shared ledger, where
it makes every tenant contend with every other and **the system slows down as it succeeds**.
Measured: 16 tenants with their own house accounts scale like 16 stripes (790 → 4,319/s).

**3. The product layer becomes optional.** Cards, spend controls, credit lines, and the auth hot
path are a *reference implementation built on* the ledger, not the ledger. The core is accounts,
transactions, entries, balances, bitemporal reads, and the event log.

**4. Documentation must state which lever applies where** — batching for streams we control (a
processor webhook queue drained by a workflow), striping for independent arrivals (the auth
path). Recommending both lands users at 2,356/s wondering why tuning made it slower.

### What must NOT change

**Do not make correctness configurable.** [Spike 001](../../spikes/001-formance/README.md) found
Formance's feature flags produce point-in-time queries that silently return `{}` when a
historization flag is off — a reviewer's *"green check that didn't actually execute."* The
temptation for a general engine is to make historization, hashing, and balance tracking
optional. **Configurable historization means as-of queries that are wrong rather than loud.**

Keep the core rigid: append-only, balanced-per-currency, bitemporal, event-logged. Make the
*product* pluggable, never the invariants.

## Why not TigerBeetle

The obvious alternative, and worth taking seriously — it is a genuinely excellent piece of
engineering and its **two-phase transfer model maps onto card authorization almost exactly**:
a pending transfer with a timeout is a hold with an expiry, `post_pending_transfer` with a lesser
amount is a partial clearing, `void_pending_transfer` is an auth reversal, and pending/posted
balances are precisely our `held`/`posted` split. If the ledger core were the whole problem, it
would be a strong candidate.

Three reasons it is the wrong choice here:

**1. It solves a throughput problem we have measured ourselves not to have.** TigerBeetle targets
orders of magnitude beyond 6,850/s. Adopting it to cross a ceiling almost no user will reach is
paying a large fixed cost for headroom.

**2. It cannot be the only datastore, so it *adds* a system rather than replacing one.**
TigerBeetle has a deliberately fixed schema — no ad-hoc queries, no joins, no aggregation, no
jsonb, and user data limited to fixed-width integer fields. Statements, reporting, spend
controls, ACH state machines, multi-tenancy, and RLS all still need Postgres. The result is two
datastores to operate and a consistency boundary between them, in exchange for throughput we do
not need.

**3. It defeats the deployment goal outright.** The target is "a small startup drops this into
AWS." Postgres means RDS or Aurora: managed, backed up, point-in-time restore, one click.
TigerBeetle has no managed AWS offering — it wants a replica cluster on instances with fast local
disk, operated by you, including upgrades and failure recovery. For the audience we are aiming
at, choosing TigerBeetle *increases* operational burden at exactly the moment we are claiming to
reduce it. The user's instinct that it "would give some maintenance" is correct, and it is the
deciding factor rather than a footnote.

**What to take from it anyway:** the two-phase transfer with timeout is a better-factored version
of `card_holds`, and worth reading before M5 finalizes that table.

**When to revisit:** if a real user is sustaining thousands of clearings per second *after*
striping or batching. That is a good problem, it will announce itself, and the ledger core is a
narrow enough interface to put behind an abstraction *then* — with a real workload to design
against instead of a hypothetical one.

## Consequences

- ADR-0001 needs an amendment recording that its sizing argument is superseded here, and that the
  conclusion now rests on measurement rather than on a known workload.
- The roadmap gains striping and per-tenant house accounts; M1's schema changes.
- v1-vision becomes what it always was — a *reference product* spec — and should be labelled as
  such rather than read as the system's requirements.
- The README's framing changes from "embedded B2B spend management" to a ledger with that as its
  reference implementation.

## Open

- **The auth path was not measured.** It writes no ledger entry and serializes per company, so it
  should scale far better — but it has a latency deadline rather than a throughput target and
  deserves its own spike before any claim is made about it.
- **All numbers are from a small, fully-cached table.** The contention finding is structural and
  will hold; the absolute numbers will fall at 100M+ entries. Needs re-measuring at size before
  going in a README where users will hold us to it.
- **Single node.** No replication or failover. Synchronous replication will cost on every commit
  and is not in these numbers.
