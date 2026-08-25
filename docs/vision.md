# Vision

> Status: current. The *project* vision. [`v1-vision.md`](./v1-vision.md) is now the
> **reference product** spec. Positioning: [ADR-0007](./decisions/0007-open-source-positioning.md).

## What this is

An open-source **double-entry ledger**. Postgres for storage, Go for the service — a single
binary and a database you already know how to run.

The bet is narrow: **most teams that need a real ledger do not need a fast one, but every one of
them needs a correct one.** Correct means testable things — every cent accounted for, no manual
fixes, and any number reproducible as of any date, forever. Cheap to build in, painful to
retrofit. That is the whole argument for using something instead of rolling your own `balances`
table.

## If you have never built a ledger

A ledger records money movements as **entries**. Every entry is a **debit** or a **credit**, and
within one transaction the debits and the credits must sum to the same amount. That is what
*double-entry* means, and it is the only thing standing between you and a balance sheet that does
not add up.

A customer spends $500 on their card. Days later the card network sends a **clearing** message —
the message that says the purchase is real and money is owed. We record:

```
DR  customer_receivable         500.00    the customer now owes us $500
CR  network_settlement_payable  491.00    we owe the card network $491
CR  interchange_revenue           9.00    we keep $9 as interchange
                                -------
              debits 500.00  =  credits 500.00
```

Three things to take from that:

- **It balances**, and the database enforces it rather than the application.
- **Interchange** is the fee the network hands back to the card issuer on every purchase. It is
  most of how a card program makes money.
- **The $9 was never cash.** No bank account moved. It is the gap between what the customer owes
  us and what we owe the network — and it is revenue the moment we record it.

And the part that surprises everyone: **the authorization writes nothing at all.** When the
terminal beeps, no money has moved and nothing is owed. We record a *hold* against the customer's
credit limit and start a timer. The ledger first hears about the purchase at clearing — which may
be days later, may be for a different amount (tips, fuel pumps), and may never arrive.

A few more terms, because the rest of these docs assume them:

| Term | Meaning |
| --- | --- |
| **Bitemporal** | Recording *two* times per transaction: when it happened in the business (`effective_at`) and when we learned about it (`recorded_at`). They differ constantly, and conflating them is how reports become irreproducible. |
| **Idempotency key** | A caller-supplied key that makes a retry safe: replaying it returns the stored result instead of posting twice. Non-negotiable when a payment processor retries a webhook. |
| **Normal balance** | Whether an account grows on debits or on credits. Assets and expenses grow on debits; liabilities, equity and revenue grow on credits. **Not derivable from the category** — an *allowance for credit losses* is an asset that grows on credits. |
| **Chart of accounts** | The list of account *types* a deployment uses. Ours is data, not code, because every business has different ones. |
| **Trial balance** | Every account's balance, listed. It must satisfy `assets = liabilities + equity + (revenue − expenses)`. |
| **Settlement** | Actually wiring the money. Here: paying the network its $491. Distinct from clearing, which only records the obligation. |

## Who it is for

A small team that needs a ledger and does not want to operate a new class of infrastructure to get
one. Put it behind RDS or Aurora, get managed backups and point-in-time restore for free, stop
thinking about it. That constraint drives more of the design than performance does — see
[Why Postgres, and not TigerBeetle](#why-postgres-and-not-tigerbeetle).

## The core, and the product built on it

**The core is the project:**

| | |
| --- | --- |
| Accounts | typed by category and normal balance, multi-tenant, multi-currency |
| Transactions | the unit of atomicity; status never mutates |
| Entries | immutable, append-only, balanced per currency |
| Balances | O(1) current balance, plus as-of reads on two time axes |
| Bitemporal reads | recorded axis and effective axis, never conflated ([ADR-0003](./decisions/0003-bitemporal-balances.md)) |
| Event log | the idempotency spine and audit trail ([ADR-0004](./decisions/0004-event-log.md)) |

**The reference product** is the embedded B2B charge card sketched above — spend controls, credit
lines, holds, the authorization path. [`v1-vision.md`](./v1-vision.md) describes it in full. It
exists to prove the core carries a real product without forking, and to give the core a demanding
acceptance test. **It is not the project.**

The line matters because it decides what is configurable. The product layer is meant to be
replaced. The core is not.

## Non-negotiables

Four properties. None is a setting.

- **Append-only.** Entries are never updated or deleted, enforced by revoking `UPDATE` and
  `DELETE` from the application role.
- **Balanced per currency**, enforced by the database as a deferred constraint trigger.
- **Bitemporal.** Every transaction carries when it happened (`effective_at`, from the source's
  clock) and when we learned about it (`recorded_at`). These differ constantly — a clearing's
  business date is the network's, not our webhook's arrival time.
- **Event-logged.** Every accepted external event is recorded, including the many that produce no
  ledger transaction (authorizations, declines, hold expiry, limit changes).

**Correctness is never configurable**, and that is a lesson rather than a preference.
[Spike 001](../spikes/001-formance/README.md) found a ledger that made historization a feature
flag; the result was point-in-time queries silently returning empty — what one reporter called
*"a green check that didn't actually execute."* A wrong answer that looks like an answer is worse
than an error.

Make the product pluggable. Never the invariants.

## Four measurements that shaped the design

All from this session; the spikes have the method.

**Reading a balance is a lookup, not a recomputation.** Every entry carries its account's running
balance at that moment, so a current balance is one index hit. Summing history instead, on an
account with 1,000,000 entries: **0.018 ms vs 105.91 ms.**

**That running balance answers only one of two questions.** It is ordered by *insertion*, so on
backdated history a *business-date* balance read from it is simply wrong — **32,000.00 where the
truth was 16,000.00.** Hence two axes, never conflated
([ADR-0003](./decisions/0003-bitemporal-balances.md)).

**Balanced books do not mean correct reports.** A report enumerating only some accounts understated
interchange revenue as **20.00 against a true 30.00** — and the accounting equation still passed,
because the missing account drops out of *both* sides. Balancing is not completeness.

**A tenant's slice of the books must balance on its own.** Under row-level security a transaction
touching both a tenant account and a shared one shows the tenant only their half: **net −500.00,
unbalanced**, where the operator sees 0.00. The fix is that no transaction may span tenants —
which turns "tenant-local" from an optimization into a correctness rule.

## Performance, and why there is no number here

[Spike 003](../spikes/003-throughput-ceiling/README.md) measured the design rather than assuming
it, with durability on throughout (`fsync`, `synchronous_commit`, `full_page_writes`).

A **hot account** is one nearly every transaction touches — above, `network_settlement_payable`
and `interchange_revenue` are hot, because every clearing in the system writes those same two
rows. Updating a row takes a lock, so every writer queues behind them.

| | clearings/s |
| --- | --- |
| one shared row | ~800 |
| that row **striped** 64 ways | ~6,970 |

**Striping** splits one logical account's balance across N physical rows; writers pick one, and
reading the balance sums them. It is worth ~8× and it is the mechanism that actually works,
because it splits *within* whatever account is hot regardless of who is causing the load.

Splitting per *tenant* instead only pays when traffic is evenly spread. **Skew** — how unevenly
traffic is distributed across tenants — destroys it: with one tenant generating 90% of volume,
per-tenant splitting gave 1.07× while striping still gave 7.8×. Per-tenant accounts earn their
place for [other reasons](../spikes/004-chart-of-accounts/README.md), not for throughput.

**No headline number here, on purpose.** Everything above ran on localhost, where a round trip
costs 0.05 ms. On RDS it costs roughly 0.5 ms, and the clearing path takes six of them against
1.3 ms of real work — which *reorders* the tuning levers rather than merely scaling the result.
Nothing has been measured over a network, so nothing is published. That is M4.

Two results that do transfer: the bottleneck is **contention on one row, not hardware** (adding
workers past concurrency 4 makes it slower), and throughput is **close to insensitive to table
size** — unchanged at 5M entries and 2 GB against 128 MB of cache, because the workload is
append-only.

## Why Postgres, and not TigerBeetle

TigerBeetle deserves a straight answer, because it is excellent. Its two-phase transfer model maps
onto card authorization almost exactly: a pending transfer with a timeout *is* a hold with an
expiry, posting it for a lesser amount *is* a partial clearing, voiding it *is* an authorization
reversal. If the ledger core were the whole problem it would be a strong candidate. Three reasons
it is the wrong fit:

1. **It solves a throughput problem we measured ourselves not to have.**
2. **It cannot be the only datastore.** Its schema is deliberately fixed — no ad-hoc queries, no
   joins, no aggregation, no JSON. Reporting, statements, spend controls, and multi-tenancy all
   still need Postgres. You operate two systems and a consistency boundary between them.
3. **It defeats the deployment goal.** No managed AWS offering; it wants a replica cluster on
   instances with fast local disk, operated by you. For a small team that *increases* operational
   burden at exactly the moment we claim to reduce it.

What we take anyway: the two-phase transfer with timeout is a better-factored version of our
`card_holds` table, and worth reading before that table is finalized. Revisit the decision when a
real user sustains thousands of clearings per second *after* applying the levers above — that
problem will announce itself.

## Where to go next

| | |
| --- | --- |
| [`roadmap.md`](./roadmap.md) | What gets built, in what order, and why that order |
| [`decisions/`](./decisions/) | ADRs — every architectural decision and its reasoning |
| [`v1-vision.md`](./v1-vision.md) | The reference product: the embedded card ledger in full |
| [`../spikes/`](../spikes/) | Timeboxed investigations — brief, findings, and code together |
