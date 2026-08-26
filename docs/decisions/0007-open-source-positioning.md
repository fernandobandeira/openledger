# 0007 — Positioning: a general open-source ledger

**Status:** accepted

*Was `proposed` long after it stopped being open.* Every consequence it lists has shipped — the
README leads with the ledger, `reference-product.md` is labelled a product spec, house accounts are
per tenant (`uq_accounts__house`), and the tenant-leading composite keys cite this ADR by name in
`migrations/0001`. Four other documents treat it as settled authority. What remains open is
**measurement** (nothing on RDS, striping unbuilt), not a question of direction — and open
measurements belong in "Still open", not in a status field.
**Date:** 2026-08-25

## Context

[0001](./0001-go-and-postgres.md) chose the stack on the strength of *knowing* the workload —
"under 1 TPS average, maybe 20–50 TPS at peak". Several later decisions deliberately hardcode
things a general engine would have to make configurable.

The question is whether this becomes **a general open-source ledger a small team can drop into AWS
and run**, which removes that knowledge.
[Spike 003](../../spikes/003-throughput-ceiling/README.md) measured the ceiling so the question
can be answered with numbers. Durable settings throughout, stock Postgres, one 16-core machine:

| Configuration | clearings/s |
| --- | --- |
| baseline (one shared account row, no batching) | ~800 |
| + coalesced batching | 3,420 |
| + **striping** 64 ways **and** single-call posting, *instead of* batching | **7,897** |

Three findings shape the decision:

1. **The baseline is already 17–40× the volume 0001 sized for**, untuned. One unremarkable
   Postgres covers the overwhelming majority of adopters.
2. **The bottleneck is one row, not the hardware.** Routing every posting through a single
   *customer* account costs 12%; the shared **hot account** — the one nearly every transaction
   touches, like settlement or fee revenue — is the entire ceiling. Throughput plateaus at four
   concurrent writers and then *declines*.
3. **The levers interact, and one of them was mismeasured.** See "Scaling shape".

## Amendment — correctness is the point, not the deployment pitch

This ADR was originally framed around "a small team can drop this into AWS." That framing has been
demoted. It is a real property and worth keeping, but it is not why the project exists and it
should not drive design arguments.

**The project's purpose is correctness**: provably balanced books, reproducible as-of numbers, and
invariants enforced by the database rather than by discipline. Where a deployment argument and a
correctness argument point in different directions, correctness wins. Nothing below changes as a
*decision* — Postgres, striping, per-tenant house accounts and the TigerBeetle rejection all stand
on their own evidence — but several of them were *argued* on deployment grounds, and those
arguments are the weaker half.

See [`vision.md`](../vision.md#why-this-exists-when-formance-already-does) for why this exists
alongside Formance, which is the comparison that actually matters.

## Decision

**Reframe as a general ledger. Keep Postgres. Change the argument, not the stack.**

0001's conclusion survives; its reasoning does not. "Throughput is not the constraint" was an
argument from known volume. The defensible version is: *here is the measured ceiling, here is the
single thing that limits it, and here is the lever.*

**1. Hot-account striping becomes a first-class feature.** **Striping** means storing one logical
account as N physical balance rows and summing them to read the balance — so N writers take N
different row locks instead of queueing on one. It is the difference between ~800/s and ~7,000/s striped (7,897 with single-call posting on top) and
currently exists only as folklore. Design it in: an account declares a stripe count, writes pick a
stripe, balance reads `SUM`.

**2. House accounts become per-tenant.** A unique index currently guarantees exactly one shared
revenue account per *deployment*. Correct for one product; wrong for a shared ledger, where it
makes every tenant contend with every other. (See the correction below — this is a modelling fix
and a prerequisite for tenant isolation, **not** the throughput mechanism it was first claimed to
be.)

**3. The product layer becomes optional.** Cards, spend controls, and credit lines are a
*reference implementation built on* the ledger. The core is accounts, transactions, entries,
balances, bitemporal reads, and the event log.

**4. Documentation must state which lever applies where.** Batching and *randomly* chosen stripes
cancel each other — together they measured worse than either alone, because random stripe
selection scatters a batch across rows and defeats coalescing. Two ways out: give each writer its
own stripe so a batch lands on one row, or key the stripe on the tenant so a tenant's batch
coalesces naturally.

**5. Publish no throughput number until it is measured on RDS.** A round trip costs ~0.05 ms on
localhost and ~0.5 ms on managed Postgres, which changes the *ranking* of the levers, not just the
magnitudes.

**Correction.** An earlier version of this ADR cited pgledger as "publishing 10,637 transfers/s
locally collapsing to 1,631 over a network." **The second figure does not exist** — pgledger has
never published a network benchmark, and `1,631` appears nowhere in its history. It was
fabricated, and it was the only external support this argument had. Struck.

What pgledger *does* publish corroborates the other half of this ADR, and does so cleanly: the
same local machine gives **10,636.8 transfers/s across 50 accounts and 7,558.9 across 10**, with
worker count unchanged. That is a 1.41× swing produced purely by account contention — the lever
this ADR argues is the real one. The network claim remains **unsupported by anything outside this
repository**, which is precisely why no number gets published until M4 measures one.

### What must NOT change

**Correctness is never configurable.** Formance's feature flags produce point-in-time queries that
silently return empty when a historization flag is off — a reviewer called it *"a green check that
didn't actually execute."* The temptation for a general engine is to make historization, hashing,
and balance tracking optional. **Configurable historization means as-of queries that are wrong
rather than loud.** Keep the core rigid: append-only, balanced-per-currency, bitemporal,
event-logged. Make the *product* pluggable, never the invariants.

## The layering, stated precisely

"Core versus reference product" is too coarse. Three layers, and the boundaries are load-bearing:

| | what it is | needs a scheduler? | writes the ledger? |
| --- | --- | --- | --- |
| **1. Ledger core** | accounts, transactions, entries, balances, event log | **no** | it *is* the ledger |
| **2. Rails** | card, ACH, wallet — each with its own state machine and deadlines | yes ([0008](./0008-durable-timers.md)) | yes, on the events it decides are financial |
| **3. Product** | authorization decisions, spend controls, credit lines | no | **no** |

Two consequences that are easy to miss:

**The ledger core needs no scheduler, ever.** Every timer belongs to a rail — hold expiry, ACH
return windows, statement cycles. The core is synchronous and transactional: it is called, it
writes, it returns. That is why [0008](./0008-durable-timers.md) can put the scheduler in the
product layer without the core noticing.

**The authorization path is an optional module, not part of the ledger.** It is worth being exact
about what it does, because the naming misleads:

- It **writes** only the hold event log (`card_auth_events`, per
  [ADR-0010](./0010-authorization-holds.md)) — never a ledger entry. Nothing is owed until
  clearing.
- It **reads** one number from the ledger: the `customer_receivable` balance. Unstriped that is a
  single index lookup (0.018 ms). **Striped, it is a sum over the stripes**, so it grows with the
  stripe count — the same knob this ADR recommends turning up. *The specific per-stripe timings
  previously quoted here are struck: they appear nowhere else in the repository and no method was
  recorded. Striping is not implemented, so there is nothing to measure yet.* Still trivial against a ~1s deadline, but the read
  grows with the tuning knob this same ADR recommends, so "one cheap read" is the wrong shape of
  claim. The coupling is one *logical* read whose cost is a configuration choice.

So the product layer's entire coupling to the ledger is *one read*. A deployment with no cards —
a marketplace wallet, say — simply does not install layer 3, and nothing in layers 1 or 2 changes.
This makes the auth path a genuine plug-in rather than a fork, which is what
"[the reference product] is not the project" has to mean concretely.

It also means the read interface must stay narrow — *give me this account's current balance* —
rather than the product reaching into ledger internals. That is the seam to protect in M1.

**And the money movement is already async.** A clearing arrives as an external event, is recorded,
and is posted to the ledger by a job — outside the authorization deadline entirely. This is
v1-vision's central claim ("the hot path is not the ledger write"), and
[0008](./0008-durable-timers.md) makes the mechanism concrete: the event and its job commit in one
transaction.

**A simplification falls out.** The architecture diagram shows an *outbox* and a *job queue* as
separate components. With transactional enqueue they are the same thing — the classic outbox
pattern exists to bridge "commit to the database" and "publish to a broker that is not the
database." When the consumer reads from the same database, the outbox *is* the queue. One
component, not two.

## Scaling shape — what an adopter can expect

**The ceiling is global, not per-tenant.** It is shared across every tenant on a database, not
granted to each.

**Striping is the throughput mechanism, and it works regardless of how load is distributed.**
Measured: 872 → 6,970 clearings/s with a *single* tenant, and 948 → 7,405 with 32 tenants where
one tenant generates 90% of traffic.

**Per-tenant accounts are not.** An earlier draft claimed 8× from splitting per tenant, from a
**uniformly distributed** benchmark. Real payment volume is heavily **skewed** — a few tenants are
most of the traffic — and re-measured with a dominant tenant the gain collapses from 9.1× to
**1.07×**, because that tenant's own house accounts become the new hot row. **Per-tenant splitting
relocates the bottleneck; striping removes it.**

They still earn their place for other reasons: they are the correct data model (a revenue figure
merged across tenants is an aggregate nobody's accounting asks for), they are better for
reconciliation (1,000 accounts tell you *which* tenant caused a 3-cent break), and they are a
prerequisite for correct per-tenant row-level security.

**"No cross-tenant transactions, ever" was wrong.** Some accounts are physically singular:
`operating_cash` mirrors *one* real bank account, and the facility is one line from one lender.
Neither can be split per tenant. **7 of the reference trace's 13 transactions touch
`operating_cash`.** The four *clearing* transactions do not — so the honest claim is **clearings
are tenant-local; treasury is not.** Clearings are the volume and treasury is a daily batch, so
that may be an acceptable trade, but it has to be stated rather than claimed away. Splitting a
cross-scope transaction into two, joined by intercompany due-from/due-to accounts, restores
tenant-locality where it matters.

**The corrected story:** one Postgres for almost everyone; stripe the hot accounts when you reach
the per-row ceiling; shard by tenant only if you outgrow one instance, accepting that treasury
spans shards.

## Why not TigerBeetle

Worth taking seriously — it is excellent, and its two-phase transfer model maps onto card
authorization almost exactly (a pending transfer with a timeout *is* a hold with an expiry). Three
reasons it is still wrong here:

1. **It solves a throughput problem we measured ourselves not to have.**
2. **It cannot be the only datastore, so it *adds* a system rather than replacing one.** Fixed
   schema, no ad-hoc queries, no joins, no aggregation. Reporting, statements, multi-tenancy and
   RLS all still need Postgres — two datastores and a consistency boundary between them.
3. **It defeats the deployment goal.** Postgres means RDS: managed, backed up, one click.
   ([0008](./0008-durable-timers.md) removed the last thing that undercut this claim — durable
   timers were going to require a Temporal cluster, and now run in-process on the same database.)
   **Correction:** an earlier version said TigerBeetle "has no managed AWS offering."
   [TigerBeetle Cloud](https://tigerbeetle.com/cloud) exists, on AWS/Azure/GCP. The accurate,
   narrower claim: there is no AWS-*native* service, and self-hosting wants a six-replica cluster
   on local NVMe that you operate. It *increases* operational burden precisely where we claim to
   reduce it — but by less than this ADR originally asserted.

One correction: TigerBeetle argues against sharding because hot accounts make shards bottlenecks.
That is an argument against **distributed** sharding, where cross-shard transactions get
expensive. It does not apply to N rows in one Postgres, and an earlier draft leaned on it too
heavily.

**Take from it anyway:** the two-phase transfer with timeout is a better-factored hold.
**Revisit if** a real user sustains thousands of clearings per second *after* striping — a good
problem that will announce itself, and the core is a narrow enough interface to abstract then.

## Consequences

- The roadmap gains striping; M1's schema changes.
- The reference product spec is labelled as such: it describes the card product this ledger was designed against, not the project's own requirements.
- The README leads with the ledger, not the card product.

## Open

- **The auth path was never measured.** It writes no ledger entry and serializes per customer, so
  it should scale better — but it has a latency deadline rather than a throughput target and
  deserves its own spike.
- **Nothing has been measured over a network.** Now the largest caveat.
- **Single node.** No replication or failover; synchronous replication will cost on every commit.
