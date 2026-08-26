# 0002 — One Postgres, striped: the hot account is the ceiling

**Status:** accepted
**Evidence:** [spike 003](../../spikes/003-throughput-ceiling/README.md).

## The decision

**Stay on one PostgreSQL instance, and treat the hot account — not the hardware — as the thing that
runs out.** Four things follow:

1. **Hot-account striping is a first-class feature.** One logical account is stored as N physical
   balance rows, summed to read it, so N writers take N row locks instead of queueing on one. An
   account declares a stripe count; writes pick a stripe; reads `SUM`.
2. **House accounts are per tenant.** `uq_accounts__house` is `(tenant_id, purpose, currency) WHERE
   owner_type = 'house'` — a modelling fix and a prerequisite for tenant isolation, **not** a
   throughput mechanism.
3. **Say which lever applies where.** Batching and *randomly* chosen stripes cancel each other —
   worse together than either alone, because random selection scatters a batch and defeats
   coalescing. Give a writer its own stripe, or key the stripe on the tenant.
4. **Publish no throughput number until it is measured on RDS.** A round trip costs ~0.05 ms on
   localhost and ~0.5 ms on managed Postgres, which changes the *ranking* of the levers, not just
   their size.

## Why

**Size it before designing it, because throughput is not the constraint here.** A $30M facility
divided by a ~35-day receivable turn is **$100–300M/yr of card spend** at full utilization. At a
$150–400 average B2B ticket that is **30k–150k transactions per month** — under **1 TPS average**,
and maybe **20–50 TPS at a Monday-morning peak**. One Postgres instance handles that on a laptop.

The real constraints are correctness (every cent, no manual fixes), auditability (reproduce any
number as of any date, forever), **one latency-bound path** (the authorization decision — see
[0008](./0008-authorization-holds.md)), and product surface area (one engine serving several
products without forking). *Anyone who opens by sharding the ledger has misread the problem.* Every
multiple quoted below is against this figure, so the derivation is the number that matters.

Spike 003, durable settings, stock Postgres, one 16-core machine:

| Configuration | clearings/s |
| --- | --- |
| baseline (one shared account row, no batching) | ~800 |
| + coalesced batching | 3,420 |
| + **striping** 64 ways **and** single-call posting, *instead of* batching | **7,897** (2 GB table; 7,816 at 43 MB) |

- **The baseline is already 17–40× the volume the reference product needs**, untuned.
- **The bottleneck is one row, not the machine.** A single *customer* account costs 12%; the shared
  **hot account** — settlement, fee revenue, the one nearly every transaction touches — is the whole
  ceiling, plateauing at four concurrent writers and then *declining*. pgledger's published numbers
  agree: **10,636.8 transfers/s across 50 accounts against 7,558.9 across 10**, same worker count.
- **Striping works however load is distributed:** 872 → 6,970 clearings/s with one tenant; 948 →
  7,405 with 32 tenants where one generates 90% of traffic.
- **Per-tenant accounts are not the mechanism.** A uniform benchmark shows 9.1× from splitting per
  tenant; with a dominant tenant — what real payment volume looks like — it collapses to **1.07×**,
  because that tenant's own house accounts become the new hot row. Splitting *relocates* the
  bottleneck; striping removes it. Per-tenant accounts stay anyway, for the data model, per-tenant
  reconciliation, and as the prerequisite for RLS.

**The layering, because it decides what needs a scheduler.**

| layer | what it is | needs a scheduler? | writes the ledger? |
| --- | --- | --- | --- |
| **1. Ledger core** | accounts, transactions, entries, balances, event log | **no** | it *is* the ledger |
| **2. Rails** | card, ACH, wallet — each with its own state machine and deadlines | yes ([0008](./0008-authorization-holds.md)) | yes, on the events it decides are financial |
| **3. Product** | authorization decisions, spend controls, credit lines | no | **no** |

**The core needs no scheduler, ever** — every timer belongs to a rail. And a clearing is recorded as
an event and posted by a job *in one transaction*, outside the authorization deadline, so the
**outbox and the job queue are one component, not two**.

**The authorization path writes no ledger entry** — only the hold tables
([0008](./0008-authorization-holds.md)) — and **reads one number**, the `customer_receivable`
balance. That single read is the product layer's entire coupling to the core, which is what makes the
product a plug-in rather than a fork. **Keep the interface exactly that narrow; it is the seam to
protect in M1.**

## Alternatives

| | Why not |
| --- | --- |
| **Shard by tenant** | Only if you outgrow one instance — treasury accounts cannot be split, so shards would span them. |
| **A second datastore for the hot path** | Adds a consistency boundary to remove a bottleneck that striping removes without one. |
| **TigerBeetle** | Excellent, and still wrong here — below. |

## Why not TigerBeetle

Three reasons, none of them that it is bad. It solves a throughput problem **we measured ourselves
not to have**. Its fixed schema — no ad-hoc queries, joins or aggregation — leaves reporting,
statements, multi-tenancy and RLS on Postgres anyway, so it *adds* a datastore and a consistency
boundary rather than replacing one. And [TigerBeetle Cloud](https://tigerbeetle.com/cloud) exists on
AWS/Azure/GCP, but with no AWS-*native* service, self-hosting means operating a six-replica NVMe
cluster. **Take from it anyway:** its two-phase transfer with timeout is a better-factored hold than
ours. **Revisit if** a user sustains thousands of clearings/s after striping.

## What it costs

- **Striping is not built.** There is no stripe column in `schema/`, and `uq_accounts__house` would
  currently prevent one on exactly the accounts that need it. Every figure above that says "striped"
  describes a configuration this repository cannot currently express.
- **The ceiling is global** — shared by every tenant on a database, not granted to each.
- **Cross-tenant transactions exist and must be modelled.** `operating_cash` mirrors *one* real bank
  account and the facility is one line from one lender, so neither splits per tenant: **7 of the
  reference trace's 24 transactions touch `operating_cash`**, none of them clearings. Clearings are
  tenant-local; treasury is not. Splitting the book in two, joined by intercompany due-from/due-to
  accounts, restores locality — and [0007](./0007-schema-conventions-and-chart.md) records that
  nothing currently reconciles the two sides.
- **The striped balance read grows with the stripe count**, the authorization path's one read
  included. See [0006](./0006-time-and-as-of.md) for the as-of version, which is worse.
- **Three things are unmeasured**: the authorization path (a latency deadline, not a throughput
  target — it needs its own spike), anything over a network (the largest caveat, and why nothing is
  published until M4 measures on RDS), and replication (one node; synchronous replication costs every
  commit).
