# openledger

An open-source **double-entry ledger**. Postgres for storage, Go for the service.

**The whole project is about correctness.** Not throughput, not deployment convenience — those are
solved problems and the measurements say so. Correctness here means specific, testable claims:
every cent accounted for, the books provably balanced at every instant, any number reproducible as
of any date, and no manual fixes ever. Those properties are cheap to design in and painful to
retrofit.

## If you have never built a ledger

A ledger records money movements as **entries**. Every entry is a **debit** or a **credit**, and
within one transaction the debits and credits must sum to the same amount. That is what
*double-entry* means, and it is the only thing standing between you and a balance sheet that does
not add up.

A customer spends $500 on their card. Days later the card network sends a **clearing** message —
the message that says the purchase is real and money is owed:

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
  us and what we owe the network — and it is revenue the moment it is recorded.

And the part that surprises everyone: **the authorization writes nothing at all.** When the
terminal beeps, no money has moved and nothing is owed. The ledger records a *hold* against the
customer's credit limit and starts a timer. It first hears about the purchase at clearing — which
may be days later, may be for a different amount (tips, fuel pumps), and may never arrive.

The [glossary](./glossary.md) defines the rest of the vocabulary these docs assume.

## Why this exists when Formance already does

[Formance](https://github.com/formancehq/ledger) is the closest open-source equivalent, it is
mature, and it has been run against real money. [Spike 001](../spikes/001-formance/README.md) read
its source and all 54 of its migrations. **Take it seriously before building anything.**

**What Formance does better, and it is not close:** production scar tissue. Fifty-four migrations
with names like `27-fix-invalid-pcv` are a record of failures we have not had yet. It ships
Numscript, a real DSL for posting rules — a problem we have open. It has replication to ClickHouse,
import/export by replaying its log, and a multi-ledger deployment model. If you need a ledger in
production this quarter, use Formance.

**Three things it structurally does not do**, each verified in its source rather than inferred:

**1. It has no accounting semantics.** There is no account category and no normal balance anywhere
in the schema. A balance is `input - output`, so a liability reads negative. Its "chart of
accounts" is an address *naming grammar*, and the rules type is literally `struct{}`. **You cannot
get a trial balance or a balance sheet out of Formance without building a mapping layer beside
it.** Here, accounts are typed, and the accounting equation `A = L + E + (R − X)` is
[proven to hold at every step](../spikes/004-chart-of-accounts/README.md) of a full card lifecycle.

**2. Its effective-date balance is mutable, and that cost it.** Formance keeps running balances on
both time axes. The effective-axis one is *not* immutable — a backdated transaction triggers an
unbounded `UPDATE` of every later row for that account. Their `moves` table carries
`fillfactor = 80` (the fill factor is verified at their pinned commit; the *reason* is our
inference, not their stated one), and **three migrations repair volume data** -- 19, 20 and 28 --
with two more replacing the aggregation functions and a sixth that is a no-op stub. An earlier
version of this line said four and six; [ADR-0003](./decisions/0003-bitemporal-balances.md) carried
that correction and this file did not.
[ADR-0003](./decisions/0003-bitemporal-balances.md) declines to build that: the running balance is
immutable and lives on the insertion axis only; business-date balances aggregate on read.

**3. It has no pending state.** No holds, no authorizations, no status — users model a hold by
moving money to a hold account. For anything card-shaped that is the core of the domain, not a
detail.

One more worth knowing: **Formance does not enforce that transactions balance.** Its primitive is
a source→destination posting, balanced by construction, so there is no constraint and no trigger.
That is a legitimate design — make the illegal state unrepresentable — but it means the claim
"debits always equal credits" has no runtime check behind it. Here, entries are independent rows
carrying a direction, so an unbalanced transaction *is* expressible and is therefore
[refused by the database](../tests/negative_controls.sql).

**And the honest part:** this is a personal project. Building a ledger is how you find out what a
ledger actually is — every correction in these docs came from measuring something we had asserted.
That is a sufficient reason on its own, and dressing it up as a market gap would be worse.

## The core, and the product built on it

**The core is the project:**

| | |
| --- | --- |
| Accounts | typed by category and normal balance, multi-tenant, multi-currency |
| Transactions | the unit of atomicity; status never mutates |
| Entries | immutable, append-only, balanced per currency |
| Balances | current balance in one index lookup, plus as-of reads on two time axes |
| Bitemporal reads | when it happened and when it was recorded, never conflated |
| Event log | the idempotency spine and audit trail |

**The reference product** is the embedded B2B charge card sketched above — spend controls, credit
lines, holds, the authorization path. It exists to prove the core carries a real product without
forking, and to give the core a demanding acceptance test. **It is not the project.**
[`reference-product.md`](./reference-product.md) describes it in full.

That line decides what is configurable. The product layer is meant to be replaced. The core is not.

## What it guarantees

Four properties. None is a setting.

- **Append-only.** Entries are never updated or deleted — enforced by a trigger that refuses both
  outright, for *every* role including the owner. The grant model matters too, but it is not the
  mechanism: a `REVOKE` is a point-in-time change to a privilege, and a later `GRANT ALL` undoes
  it ([0011](./decisions/0011-what-the-database-enforces.md)).
- **Balanced per currency**, enforced by the database on every transaction.
- **Bitemporal.** Every transaction carries when it happened in the business and when it was
  learned about. These differ constantly: a clearing's business date belongs to the network, not
  to the webhook's arrival.
- **Event-logged.** Every accepted external event is recorded, including the many that produce no
  ledger transaction at all — authorizations, declines, hold expiry, limit changes. **Caveat, and
  it belongs here rather than buried:** `ledger_transactions.event_id` is still nullable, so a
  transaction *can* be written with no causing event. Making it `NOT NULL` is the obvious fix and
  is not done — until it is, this is a convention, not the guarantee the other three are.

**Correctness is never configurable.** Ledgers that make historization optional produce
point-in-time queries that silently return empty results — a wrong answer that looks like an
answer, which is worse than an error. Make the product pluggable; never the invariants.

Two consequences follow, and both are counter-intuitive:

**Balanced books do not mean correct reports.** A report that drops a whole *balanced slice* — a
tenant, a currency, a date range of whole transactions — still satisfies the accounting equation,
because what went missing was itself balanced. Revenue can be understated while every check passes.
Completeness is a separate invariant: the balance sheet is built by enumerating the chart of
accounts and joining numbers onto it, rather than by listing whatever accounts happen to have
entries.

**Each tenant's slice of the books must balance on its own.** A transaction touching one tenant's
account and a shared one leaves that tenant's view unbalanced. So no transaction may span tenants;
cross-scope movements are split into two transactions joined by clearing accounts. Tenant-locality
is a correctness rule, not an optimization.

## Performance

The design is measured rather than assumed — see
[spike 003](../spikes/003-throughput-ceiling/README.md) for method and full results.

Reading a balance is a **lookup, not a recomputation**: every entry carries its account's running
balance at that moment, so the current balance is one index hit rather than a scan over history.
On an account with a million entries that is the difference between 0.018 ms and 105.91 ms.

The ceiling is set by **contention, not hardware**. A *hot account* is one nearly every transaction
touches — `network_settlement_payable` above is hot, because every clearing in the system writes
that same row. Updating a row takes a lock, so writers queue:

| | clearings/s |
| --- | --- |
| one shared row | ~800 |
| that row **striped** 64 ways | ~6,970 |

**Striping** splits one logical account's balance across N physical rows; writers pick one, and
reading the balance sums them. It works regardless of *who* is generating the load, because it
splits within whatever account is hot. Throughput is also close to insensitive to table size — the
workload is append-only, so a 2 GB table behaves like a small one.

**Treat those figures as shape, not as a benchmark.** They come from a local machine, where a
database round trip costs 0.05 ms. On managed Postgres it costs roughly ten times that, and the
clearing path spends six round trips against 1.3 ms of actual work — so network latency reorders
which optimisations matter rather than simply scaling the result down. openledger publishes no
throughput figure until one has been measured over a real network.

## Why Postgres, and not TigerBeetle

TigerBeetle deserves a straight answer, because it is excellent. Its two-phase transfer model maps
onto card authorization almost exactly: a pending transfer with a timeout *is* a hold with an
expiry, posting it for a lesser amount *is* a partial clearing, voiding it *is* an authorization
reversal. If the ledger core were the whole problem it would be a strong candidate. Three reasons
it is the wrong fit here:

1. **It solves a throughput problem this workload does not have.**
2. **It cannot be the only datastore.** Its schema is deliberately fixed — no ad-hoc queries, no
   joins, no aggregation, no JSON. Reporting, statements, spend controls and multi-tenancy still
   need Postgres. That means operating two systems and a consistency boundary between them.
3. **It defeats the deployment goal.** **Correction:** an earlier version of this said "there is no managed AWS offering."
   [TigerBeetle Cloud](https://tigerbeetle.com/cloud) exists, on AWS/Azure/GCP. The accurate
   narrower claim is that there is no AWS-*native* service, and that self-hosting wants a
   six-replica cluster on local NVMe, operated by you. For a small team that *increases*
   operational burden at exactly the point this project claims to reduce it.

None of that makes TigerBeetle wrong — it makes it a different tool. If your ledger genuinely is
the whole problem and you are willing to operate a cluster for it, it is the better engine.

## Where to go next

| | |
| --- | --- |
| [`decisions/`](./decisions/) | Every architectural decision, on one page, with links to the reasoning |
| [`roadmap.md`](./roadmap.md) | What gets built, in what order, and why that order |
| [`glossary.md`](./glossary.md) | Every domain term, with a real example |
| [`reference-product.md`](./reference-product.md) | The embedded card ledger, in full |
| [`../tests/`](../tests/) | The acceptance suites — the lifecycle they replay, and the breakages they refuse |
| [`../spikes/`](../spikes/) | Timeboxed investigations — question, answer, and the code that proved it |
