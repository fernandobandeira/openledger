# 0002 — One Postgres, striped: the hot account is the ceiling

**Status:** accepted
**Evidence:** [spike 003](/spikes/003-throughput-ceiling).

## The decision

**This is a general ledger with a card product as its reference implementation, not a card ledger** —
and it stays on one PostgreSQL instance, treating the hot account rather than the hardware as the
thing that runs out.

The core is accounts, transactions, entries, balances, the two time axes and the event log. Cards,
spend controls and credit lines are built *on* it; a marketplace wallet simply does not install them.
**The core ships first and the card rail comes after it** — [0001](/card/decisions/0001-authorization-holds) is
scoped as future work on that basis. That line is what decides what is configurable: the product
layer is meant to be replaceable, the core is not.

Four things follow from the scaling half:

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
[0001](/card/decisions/0001-authorization-holds)), and product surface area (one engine serving several
products without forking). *Anyone who opens by sharding the ledger has misread the problem.* Every
multiple quoted below is against this figure, so the derivation is the number that matters.

Spike 003, durable settings, stock Postgres, one 16-core machine:

| Configuration | clearings/s |
| --- | --- |
| baseline (one shared account row, no batching) | ~800 |
| + coalesced batching | 3,420 |
| + **striping** 64 ways **and** single-call posting, *instead of* batching | **7,897** (2 GB table; 7,816 at 43 MB) |

- **The baseline is already 16–40× the volume the reference product needs**, untuned — that is
  ~800/s against the 20–50 TPS peak derived above, and it is the only multiplier in this repository
  you can check without leaving the page.
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
| **2. Rails** | card, ACH, wallet — each with its own state machine and deadlines | yes ([0001](/card/decisions/0001-authorization-holds)) | yes, on the events it decides are financial |
| **3. Product** | authorization decisions, spend controls, credit lines | no | **no** |

![Architecture: the authorization decision runs synchronously against a store of holds, while the ledger write happens on a job outside that deadline](/diagrams/01-architecture.svg)

*Drawn before the hold model was decided, and it shows.* The Postgres store it labels
*"availability + holds — one row per hold group"*, fed by `SELECT … FOR UPDATE` and `INSERT hold`,
**is not deployed** — that DDL is parked in [`parked/card/`](/card/parked) and applied by no
migration. And the mutable row it draws is the shape
[0001](/card/decisions/0001-authorization-holds) went on to **reject**: a hold is a `SUM` over an
append-only log, never an amount anyone updates. What it still gets right is the split this section
is about — the decision is synchronous, the ledger write is not.

**The core needs no scheduler, ever** — every timer belongs to a rail. And a clearing is recorded as
an event and posted by a job *in one transaction*, outside the authorization deadline, so the
**outbox and the job queue are one component, not two**.

**The authorization path writes no ledger entry** — only the hold tables
([0001](/card/decisions/0001-authorization-holds)) — and **reads one number**, the `customer_receivable`
balance. That single read is the product layer's entire coupling to the core, which is what makes the
product a plug-in rather than a fork. **Keep the interface exactly that narrow; it is the seam to
protect in M1.**

**That is true of the code and was false of the schema**, and [0008](/decisions/0008-module-boundaries)
closes the gap. Measured: not one foreign key crosses the card/core boundary in either direction, and
a Cargo-feature build with the card crate out of the graph **compiles clean against a database that
has never seen the card DDL**. The schema half is now true as well, though **not** by the route 0009 gave: rather
than moving into a `card` schema, the card DDL was lifted out of the baseline entirely and parked in
[`parked/card/`](/card/parked), applied by no migration. A wallet-only user gets seven
core tables and nothing else. What is still missing is what 0009 wanted and parking does not give —
**removability**: there is no `DROP SCHEMA card CASCADE` to run, because there is nothing installed
to drop. See [0008](/decisions/0008-module-boundaries).

## Alternatives

| | Why not |
| --- | --- |
| **Stay a card ledger** | Same engine either way. Forking one ledger per product is the cost this avoids, and the card rail's entire coupling to the core is one read. |
| **Shard by tenant** | Only if you outgrow one instance — treasury accounts cannot be split, so shards would span them. |
| **A second datastore for the hot path** | Adds a consistency boundary to remove a bottleneck that striping removes without one. |
| **TigerBeetle** | Excellent, and still wrong here — below. |

## Why not TigerBeetle

Three reasons, none of them that it is bad — and it deserves a straight answer, because the fit is
real: its two-phase transfer maps onto card authorization almost exactly. A pending transfer with a
timeout *is* a hold with an expiry, posting it for less *is* a partial clearing, voiding it *is* a
reversal.

It still loses, on grounds unrelated to the ledger core. It solves a throughput problem **we measured
ourselves not to have**. Its fixed schema — no ad-hoc queries, joins or aggregation — leaves reporting,
statements, multi-tenancy and RLS on Postgres anyway, so it *adds* a datastore and a consistency
boundary rather than replacing one. And [TigerBeetle Cloud](https://tigerbeetle.com/cloud) exists on
AWS/Azure/GCP, but with no AWS-*native* service, self-hosting means operating a six-replica NVMe
cluster. **Take from it anyway:** its two-phase transfer with timeout is a better-factored hold than
ours. **Revisit if** a user sustains thousands of clearings/s after striping.

## What it costs

- **Striping is not built.** There is no stripe column in `migrations/`, and `uq_accounts__house` would
  currently prevent one on exactly the accounts that need it. Every figure above that says "striped"
  describes a configuration this repository cannot currently express.
- **The ceiling is global** — shared by every tenant on a database, not granted to each.
- **Cross-tenant transactions exist and must be modelled.** `operating_cash` mirrors *one* real bank
  account and the facility is one line from one lender, so neither splits per tenant: **7 of the
  reference trace's 24 transactions touch `operating_cash`**, none of them clearings. Clearings are
  tenant-local; treasury is not. Splitting the book in two, joined by intercompany due-from/due-to
  accounts, restores locality — and [0007](/decisions/0007-schema-conventions-and-chart) records that
  nothing currently reconciles the two sides.
- **The striped balance read grows with the stripe count**, the authorization path's one read
  included. See [0006](/decisions/0006-time-and-as-of) for the as-of version, which is worse.
- **Three things are unmeasured**: the authorization path (a latency deadline, not a throughput
  target — it needs its own spike), anything over a network (the largest caveat, and why nothing is
  published until M4 measures on RDS), and replication (one node; synchronous replication costs every
  commit).
