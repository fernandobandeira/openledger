# 0007 — A general open-source ledger, on one Postgres

**Status:** accepted

## The decision

**A general ledger with a card product as its reference implementation, not a card ledger — and
Postgres stays.** The core is accounts, transactions, entries, balances, bitemporal reads and the
event log; cards, spend controls and credit lines are built *on* it, and a marketplace wallet simply
doesn't install them. **Its purpose is correctness** — provably balanced books, reproducible as-of
numbers, invariants enforced by the database rather than by discipline — and where easy deployment
and correctness point different ways, correctness wins ([`vision.md`](../vision.md#why-this-exists-when-formance-already-does)
has why this exists at all). Four things follow:

1. **Hot-account striping is a first-class feature** — one logical account stored as N physical
   balance rows summed to read it, so N writers take N row locks instead of queueing on one. An
   account declares a stripe count; writes pick a stripe; reads `SUM`.
2. **House accounts are per tenant**: `uq_accounts__house` is
   `(tenant_id, purpose, currency) WHERE owner_type = 'house'` — a modelling fix and a prerequisite
   for tenant isolation, **not** a throughput mechanism.
3. **Documentation says which lever applies where.** Batching and *randomly* chosen stripes cancel
   each other — worse together than either alone, because random selection scatters a batch and
   defeats coalescing. Give a writer its own stripe, or key the stripe on the tenant.
4. **Publish no throughput number until it is measured on RDS**: a round trip costs ~0.05 ms on
   localhost and ~0.5 ms on managed Postgres, which changes the *ranking* of the levers.

**Correctness is never configurable.** Formance's feature flags produce point-in-time queries that
silently return empty when historization is off — wrong rather than loud. The core stays rigid
(append-only, balanced-per-currency, bitemporal, event-logged); the *product* is the pluggable part.

## Why

[Spike 003](../../spikes/003-throughput-ceiling/README.md), durable settings, stock Postgres, one 16-core machine:

| Configuration | clearings/s |
| --- | --- |
| baseline (one shared account row, no batching) | ~800 |
| + coalesced batching | 3,420 |
| + **striping** 64 ways **and** single-call posting, *instead of* batching | **7,897** (2 GB table; 7,816 at 43 MB) |

- **The baseline is 17–40× the volume the reference product needs**, untuned.
- **The bottleneck is one row, not the hardware.** A single *customer* account costs 12%; the shared
  **hot account** — settlement, fee revenue, the one nearly every transaction touches — is the whole
  ceiling, plateauing at four concurrent writers then *declining*. pgledger's published numbers agree:
  **10,636.8 transfers/s across 50 accounts against 7,558.9 across 10**, same worker count.
- **Striping works however load is distributed:** 872 → 6,970 clearings/s with one tenant, 948 →
  7,405 with 32 tenants where one generates 90% of traffic.
- **Per-tenant accounts are not the mechanism.** A uniform benchmark shows 9.1× from splitting per
  tenant; with a dominant tenant — what real payment volume looks like — it collapses to **1.07×**,
  because that tenant's own house accounts become the new hot row. Splitting *relocates* the
  bottleneck; striping removes it. They stay anyway: correct data model, per-tenant reconciliation,
  prerequisite for RLS.

## The layering, stated precisely

| | what it is | needs a scheduler? | writes the ledger? |
| --- | --- | --- | --- |
| **1. Ledger core** | accounts, transactions, entries, balances, event log | **no** | it *is* the ledger |
| **2. Rails** | card, ACH, wallet — each with its own state machine and deadlines | yes ([0008](./0008-durable-timers.md)) | yes, on the events it decides are financial |
| **3. Product** | authorization decisions, spend controls, credit lines | no | **no** |

**The core needs no scheduler, ever** — every timer belongs to a rail ([0008](./0008-durable-timers.md)).
And a clearing is recorded as an event and posted by a job in one transaction, outside the auth
deadline, so the *outbox* and the *job queue* are one component, not two.

**The auth path writes no ledger entry** — only the hold tables
([0010](./0010-authorization-holds.md)) — and **reads one number**: the `customer_receivable`
balance. That one read is the product layer's whole coupling, which makes it a plug-in rather than a
fork, so keep the interface exactly that narrow. **The seam to protect in M1.**

## Alternatives

| | Why not |
| --- | --- |
| **Shard by tenant** | Only if you outgrow one instance — treasury accounts cannot be split, so shards span them. |
| **Stay a card ledger** | Same engine either way; forking one per product is the cost we avoid. |
| **TigerBeetle** | Excellent, and still wrong here — its own section, below. |

## Why not TigerBeetle

Three reasons, none of them that it is bad: it solves a throughput problem we measured ourselves not
to have; its fixed schema — no ad-hoc queries, joins or aggregation — leaves reporting, statements,
multi-tenancy and RLS on Postgres anyway, so it *adds* a datastore and a consistency boundary rather
than replacing one; and [TigerBeetle Cloud](https://tigerbeetle.com/cloud) exists on AWS/Azure/GCP,
but with no AWS-*native* service self-hosting means operating a six-replica NVMe cluster. **Take from
it anyway:** its two-phase transfer with timeout is a better-factored hold. **Revisit if** a user
sustains thousands of clearings/s after striping.

## What it costs

- **The ceiling is global** — shared by every tenant on a database, not granted to each.
- **Cross-tenant transactions exist and must be modelled.** `operating_cash` mirrors *one* real bank
  account and the facility is one line from one lender, so neither splits per tenant: **7 of the
  reference trace's 24 transactions touch `operating_cash`**, none of them clearings. Clearings are
  tenant-local, treasury is not; splitting one in two, joined by intercompany due-from/due-to
  accounts, restores locality.
- **The striped balance read grows with the stripe count**, the auth path's one read included; see
  [0003](./0003-bitemporal-balances.md) for the as-of version. The roadmap gains striping, M1's
  schema with it.
- **Three things are unmeasured**: the auth path (a latency deadline, not a throughput target — it
  needs its own spike), anything over a network (the largest caveat, and why nothing is published
  until M4 measures on RDS), and replication (single node; sync replication will cost every commit).
