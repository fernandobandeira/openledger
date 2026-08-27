# Vision — why this exists

An open-source **double-entry ledger**. Postgres for storage, Rust for the service.

**The whole project is about correctness**, not throughput: every cent accounted for, the books
balanced at every instant, any number reproducible as of any date, and no manual fixes ever. All
four are cheap to design in and painful to retrofit.

## If you have never built a ledger

Every money movement is written twice — once as a **debit**, once as a **credit** — and the two
sides of one transaction must sum to the same amount. That is *double-entry*, and the
[README](/) shows one $500 card purchase in full. The part that surprises everyone is
that **the authorization writes nothing at all**: when the terminal beeps nothing is owed, so the
system records a *hold* and starts a timer. The ledger first hears of the purchase at **clearing** —
days later, possibly for a different amount, possibly never. The [glossary](/glossary) has the
rest of the vocabulary these documents assume.

## Why this exists when Formance already does

[Formance](https://github.com/formancehq/ledger) is the closest open-source equivalent, it is
mature, and it has been run against real money. [Spike 001](/spikes/001-formance) read
its source and all 54 of its migrations. **Take it seriously before building anything.**

**What it does better, and it is not close:** production scar tissue. Fifty-four migrations with
names like `27-fix-invalid-pcv` record failures we have not had yet. It ships Numscript, a real DSL
for posting rules — a problem we have open — plus ClickHouse replication, import/export by
replaying its log, and a multi-ledger deployment model. **If you need a ledger in production this
quarter, use Formance.** Three things it structurally does not do, each verified in its source:

**1. No accounting semantics.** No normal balance anywhere in the schema and no accounting
equation; a balance is `input - output`, so a liability reads negative. It does have a chart —
since v2.3 a versioned `schemas(chart jsonb)` table, v3 typed account patterns — but that chart is
an address *naming grammar*, and the rules type is literally `struct{}`. **You cannot get a trial
balance or a balance sheet out of Formance without a mapping layer beside it.** Here accounts carry
category *and* normal balance, and `A = L + E + (R − X)` held at every step of a card lifecycle when
[spike 004](/spikes/004-chart-of-accounts) measured it. **Read that as "was measured
once, against something else":** the spike defines its own `account_types`, has no `fs_lines` layer
at all, and names three accounts differently from the shipped chart. **No object in `migrations/` computes
the equation today** — that view went with [ADR-0004](/decisions/0004-where-logic-lives), and
rebuilding it in the writer is on the roadmap.

**2. Its effective-date balance is mutable, and that cost it.** Formance keeps running balances on
both time axes, and the effective-axis one is not immutable: a backdated transaction triggers an
unbounded `UPDATE` of every later row for that account. Their `moves` table carries
`fillfactor = 80` (verified at their pinned commit; that this is *why* is our inference, not their
stated reason), and **three migrations repair volume data** — 19, 20 and 28 — with two more
replacing the aggregation functions and a sixth that is a no-op stub.
[ADR-0006](/decisions/0006-time-and-as-of) declines to build that: our running balance is
immutable and lives on the insertion axis only; business-date balances aggregate on read.

**3. No pending state.** No holds, no authorizations, no status — users model a hold by moving
money to a hold account. For anything card-shaped that is the core of the domain, not a detail.

**It also does not enforce that transactions balance**, which is a legitimate design rather than an
oversight: its primitive is a `Posting{Source, Destination, Amount, Asset}`, balanced by
construction, so `Postings.Validate()` has no balance check — nothing is left to check. The cost is
that the guarantee lives only in the write path: verified against their applied schema, a single
unbalanced row inserted straight into `moves` commits silently.
[0005](/decisions/0005-event-log-and-write-path) takes the same bet — make the illegal state
unrepresentable in the writer. **The invariant they do enforce is the interesting one:** Formance
refuses a negative account balance by default (`ErrInsufficientFunds`, per source account per
asset, `@world` the only hardcoded exemption), but their own docs say it checks the *final* state
only — *"the ledger does not validate the intermediate states of the ledger, only the final state"*
*(quoted without a URL)*. For a card product that is exactly the gap that matters: a backdated
authorization can drive a credit limit negative mid-history and still be accepted.

**And the honest part:** this is a personal project, and building a ledger is how you find out what
a ledger actually is. That is a sufficient reason; dressing it up as a market gap would be worse.

## The core, and the product built on it

**The core is the project:** accounts typed by category and normal balance, multi-tenant and
multi-currency; transactions as the unit of atomicity, whose status never mutates; immutable
append-only entries balanced per currency; a current balance in one index lookup and as-of reads on
two time axes; and an event log that is both idempotency spine and audit trail. **The reference
product** — the embedded B2B charge card, with spend controls, credit lines, holds and the
authorization path — exists to prove the core carries a real product without forking, and to give
it a demanding acceptance test. **It is not the project.** That line decides what is configurable:
the product layer is meant to be replaced, the core is not.

## What it guarantees

Four properties. None is a setting.

- **Append-only.** Triggers refuse `UPDATE`, `DELETE` and `TRUNCATE` on the journal outright, for
  *every* role including the owner. The narrow grant matters too but is not the mechanism: a
  `REVOKE` is undone by one later `GRANT ALL` ([0004](/decisions/0004-where-logic-lives)).
- **Balanced per currency**, by construction in the writer rather than by the database
  ([0005](/decisions/0005-event-log-and-write-path)). **The writer does not exist yet**, and entries are
  independent rows carrying a direction — so an unbalanced transaction is expressible today and
  nothing refuses it. That is the next thing to build.
- **Bitemporal.** Every transaction carries when it happened and when it was learned about. These
  differ constantly: a clearing's business date belongs to the network, not to the webhook.
- **Event-logged.** Every accepted external event is recorded, including the many that write no
  ledger transaction — authorizations, declines, hold expiry, limit changes. But
  `ledger_transactions.event_id` is nullable, so a transaction *can* be written with no causing
  event; until it is `NOT NULL` this one is a convention, not a guarantee.

**Correctness is never configurable** — a ledger that makes historization optional returns empty
results to point-in-time queries, a wrong answer that looks like an answer. Two consequences are
counter-intuitive. **Balanced books do not mean correct reports:** drop a whole *balanced* slice —
a tenant, a currency, a range of whole transactions — and the accounting equation still holds while
revenue is understated, so the balance sheet is built by enumerating the chart of accounts, never
by listing whatever accounts have entries ([0007](/decisions/0007-schema-conventions-and-chart)). And
**each tenant's slice must balance on its own**, so no transaction may span tenants: cross-scope
movements split into two, joined by clearing accounts. Tenant-locality is correctness, not
optimization.

## Performance

**No number in this repository is a benchmark.** Everything measured so far ran on localhost, where
a round trip costs 0.05 ms against roughly ten times that on managed Postgres — which *reorders*
the tuning levers rather than scaling the result down. No throughput figure is published until one
is measured over a real network. What a balance read costs at a million entries is **unmeasured**;
what is structural is that it is a *lookup* — every entry carries its account's running balance, so
the current balance is one index hit, not a scan.

The ceiling is set by **contention, not hardware**. A *hot account* is one nearly every transaction
touches — `network_settlement_payable` is hot because every clearing writes that same row, and
updating a row takes a lock. [Spike 003](/spikes/003-throughput-ceiling) measured that
row at 872 clearings/s and, **striped** 64 ways, at 6,970 — but its own banner records the
contended configuration re-measuring at 833 and then 482 purely from machine load, so the ratio is
the finding, not the number. **Striping is not built** — no stripe column exists.

## Why Postgres, and not TigerBeetle

TigerBeetle deserves a straight answer, because it is excellent: its two-phase transfer model maps
onto card authorization almost exactly — a pending transfer with a timeout *is* a hold with an
expiry, posting it for less *is* a partial clearing, voiding it *is* a reversal. It loses on two
counts unrelated to the ledger core. **It cannot be the only datastore** — its schema is
deliberately fixed, with no ad-hoc queries, joins, aggregation or JSON, so reporting, statements,
spend controls and multi-tenancy still need Postgres, which is two systems and a consistency
boundary between them. And **it defeats the deployment goal**: [TigerBeetle
Cloud](https://tigerbeetle.com/cloud) is managed hosting on AWS/Azure/GCP, but there is no
AWS-*native* service, and self-hosting wants a six-replica cluster on local NVMe operated by you.
[ADR-0002](/decisions/0002-scaling) has the full comparison.

Next: [`decisions/`](/decisions) for why
each piece is what it is, [`reference-product.md`](/reference-product) for the chart of
accounts and the card lifecycle, and [`roadmap.md`](/roadmap) for the build order.
