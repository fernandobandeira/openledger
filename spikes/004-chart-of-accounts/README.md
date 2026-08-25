# Spike 004 — The chart of accounts as a capability, and the math as a theorem

**Question:** Accounts like `platform_rev_share_payable`, `fee_revenue`, and
`facility_borrowings` are business-specific. A card program funded by a warehouse line has them;
a marketplace wallet does not; a neobank has different ones again. A general ledger cannot ship
a fixed chart of accounts. So what *does* it ship — and how does it guarantee the math is right
when it does not know what the accounts are?

**Status:** closed. Feeds [ADR-0007](../../docs/decisions/0007-open-source-positioning.md) and M0/M1.

## The answer in one line

**Ship the capability to declare a chart, plus constraints that make the accounting identity a
theorem rather than a test.**

## The theorem

> **If** every transaction balances (debits = credits) per currency,
> **and** every account's `category` and `normal_balance` are correct,
> **then** the trial balance always balances and the accounting equation
> `A = L + E + (R − X)` holds — at every instant, on either time axis, for any subset of whole
> transactions.

It follows from the second premise doing real work: because *every individual transaction* is
balanced, **any union of whole transactions is balanced**. Every prefix, every as-of cut, every
per-tenant slice. The equation is not a report we compute and hope about; it is a property of
the data that cannot be false while the constraints hold.

Which reframes the engineering problem. We do not need to *check* the math. We need to make the
two premises **structurally impossible to violate** — then the math cannot be wrong.

### Premise (a) was already enforced

`ck_entries__balances`, the deferred constraint trigger from
[spike 002](../002-sqlc-vs-jet/README.md). Fires at `COMMIT`, per transaction, per currency.

### Premise (b) was NOT enforced — this spike fixes that

`purpose` was free text and `category`/`normal_balance` were per-account columns. Nothing stopped
`interchange_revenue` being created as an **asset with a debit normal balance** — which silently
breaks every statement that rolls up by category, and produces an equation that fails for a
reason nobody can find.

[`chart.sql`](./chart.sql) adds:

```sql
CREATE TABLE account_types (
    code           text PRIMARY KEY,
    category       ledger_category       NOT NULL,
    normal_balance ledger_normal_balance NOT NULL,
    description    text NOT NULL,
    is_perimeter   boolean NOT NULL DEFAULT false  -- mirrors an external balance 1:1
);
ALTER TABLE ledger_accounts
    ADD CONSTRAINT fk_accounts__type FOREIGN KEY (purpose) REFERENCES account_types(code);
-- plus a trigger asserting the account's category/normal_balance match its type
```

Verified to bite:

| Test | Result |
| --- | --- |
| `interchange_revenue` declared as `asset`/`debit` | ❌ *"declares asset/debit but type interchange_revenue is revenue/credit"* |
| a `purpose` not in the chart | ❌ foreign key violation |
| `allowance_for_credit_losses` as `asset` with **credit** normal balance | ✅ allowed |

That third row is why `normal_balance` cannot be derived from `category`. Contra accounts are
assets that behave like credits, and any design that computes one from the other is wrong the
first time someone books a loss allowance.

## What is engine and what is configuration

| | Fixed by the engine | Declared per deployment |
| --- | --- | --- |
| Categories | `asset`/`liability`/`equity`/`revenue`/`expense` — accounting is accounting | — |
| Normal balances | `debit`/`credit` | — |
| The identity `A = L + E + (R − X)` | always enforced | — |
| Per-transaction balancing | always enforced | — |
| **Account types** (the chart) | — | **yours** |
| Which accounts exist, and who owns them | — | **yours** |
| How a business event maps to entries | — | **yours** (see Open) |

The card chart in [`chart.sql`](./chart.sql) is **seed data for the reference product**, not part
of the engine. A marketplace would ship a different one against the same core.

## Proof: the golden trace reproduces the vision doc exactly

[`golden_trace.sql`](./golden_trace.sql) posts the full
[v1-vision §06](../../docs/v1-vision.md) lifecycle — one $500 purchase, thirteen transactions —
and [`verify.sql`](./verify.sql) evaluates the equation after **each** one.

```
 step | after_txn             | assets | liabs  | equity | revenue | expense | equation
------+-----------------------+--------+--------+--------+---------+---------+----------
    1 | open                  |  66.00 |   0.00 |  66.00 |    0.00 |    0.00 | BALANCED
    2 | evt_clear_1:posting   | 366.00 | 294.60 |  66.00 |    5.40 |    0.00 | BALANCED
    4 | evt_clear_2:posting   | 566.00 | 492.62 |  66.00 |    9.00 |    1.62 | BALANCED
    6 | evt_draw              | 991.00 | 918.70 |  66.00 |    9.00 |    2.70 | BALANCED
    7 | evt_settle            | 500.00 | 427.70 |  66.00 |    9.00 |    2.70 | BALANCED
   13 | evt_repay:revshare    |  68.76 |   0.00 |  66.00 |    9.00 |    6.24 | BALANCED
```

Step 7 is the one the vision doc checks by hand: *"after 05: assets 500 + 0, liabilities
0 + 425 + 2.70, equity 66 + 9.00 − 2.70. Both sides 500."* Liabilities 427.70, equity plus
revenue minus expense 72.30, total 500.00. **Exact match.**

The final trial balance also matches the doc to the cent — `operating_cash` 68.76,
`interchange_revenue` 9.00, `interest_expense` 3.54, `platform_rev_share_expense` 2.70, profit
2.76. **This is M0's acceptance test, passing.**

## An accident worth keeping

The first run ordered steps *alphabetically*. All thirteen transactions were posted in one
`COMMIT`, so `now()` — which is transaction-**start** time — gave every one an identical
`recorded_at`, and the sort fell through to the idempotency key.

That is [ADR-0005](../../docs/decisions/0005-reproducible-as-of.md) demonstrating itself by
accident, on a thirteen-row table, before any concurrency was involved. The ordering had to be
recovered from `uuidv7` primary keys instead.

**And the equation held under the wrong order anyway** — which is the theorem doing its job. Order
independence is exactly what "any union of whole transactions is balanced" buys.

## The accounting view — researched, and it changed the design

### The vocabulary is "control account + subsidiary ledger", and our version is safer

Splitting one reported figure across many physical accounts is the **centuries-old** bookkeeping
norm: a **control account** in the general ledger carries the total, a **subsidiary ledger** holds
the individual accounts, and the two are reconciled. Accounts receivable ↔ one account per
customer is the canonical case. We are not proposing anything exotic; we are proposing a
subsidiary ledger.

**And our version is strictly stronger than the classical one.** In classical bookkeeping the
control balance is *separately maintained* and can therefore drift from the subledger — which is
why monthly control-account reconciliation is a SOX key control. In our design the total is
**defined as** `SUM(instances)` over the same rows. Drift is not detected; it is impossible.

That moves the entire risk onto one question: **is the set summed the complete set?**

### The framing that dissolves most of the objection

An accountant looking at our schema sees **`account_types` = the chart of accounts (16 entries)**
and **`ledger_accounts` = dimensioned instances**. `interchange_revenue` is *one* account in the
chart no matter how many rows carry that `purpose`.

This matters because ERP practice is blunt about it: put the **"what"** in the account and the
**"why/where"** in a dimension. *"One `interchange_revenue` account per tenant"* is the textbook
**anti-pattern**. *"One `interchange_revenue` account type, with tenant as a dimension on the
instances"* is the textbook **correct answer**. Our schema already does the latter.

**Say "we partitioned the postings of one account", never "we split the account."** Avoid "shard"
in accountant-facing documents. Never name a staging account "suspense" — that word has
regulatory weight (FFIEC lists suspense/omnibus/settlement accounts as an examination focus);
"clearing" is the word for designed staging.

The standards register for the same distinction is **unit of account** (IFRS Conceptual Framework
¶4.48ff): an *economic* split means the pieces genuinely are separate units of account
(a receivable per customer — distinct enforceable right, distinct counterparty, aged and impaired
individually); a *mechanical* split is one unit of account physically partitioned, with no
accounting consequence.

| Account | Split is… | Why |
| --- | --- | --- |
| `customer_receivable` per customer | **economic** | separate legal right, external confirmation, aged individually |
| `interchange_revenue` per tenant | **mechanical** | our own income, no counterparty, no separate settlement |
| `network_settlement_payable` per tenant | **mechanical — but see below** | one counterparty (the network) |

### THE HOLE — the accounting equation does not prove completeness

Removing `uq_accounts__house` removes a machine-checked guarantee that exactly one
`interchange_revenue` exists per deployment. **The theorem does not replace it.** Demonstrated:

```
TRUE global interchange revenue (3 tenant shards)   30.00
reported by a mapping that misses tenant t3         20.00
accounting equation                                 BALANCED
```

**Revenue understated by a third, equation perfectly happy.** Because omitting a shard removes it
from *both* sides, `A = L + E + (R − X)` still holds. The theorem proves the **ledger** is
internally consistent; it says nothing about whether a **report** enumerated every account.

This is precisely the audit finding to engineer against: a tenant is onboarded, its account row is
created, and the reporting mapping misses it. Nothing imbalances, because the entry balanced.

### The fix — enumerate from the chart outward

[`completeness.sql`](./completeness.sql) adds an `fs_lines` table, a **`NOT NULL`** `fs_line` on
every account type, and a `financial_statements` view that joins **chart → types → all instances**.
There is no parameter in which to pass an incomplete list of accounts.

Verified: adding a 4th tenant after the fact moved `instances` from 3 to 4 **with no mapping
change**, and `unmapped_accounts` (the loud exception view, which must always be empty) stayed at
zero.

This is also the artifact an auditor actually asks for — a controlled, versioned mapping from
trial balance to statement line, rather than a `SUM` someone wrote in a report.

### Two corrections to the chart

**`network_settlement_payable` is a perimeter account.** We marked it `is_perimeter = false`. It is
the archetype: an external party (the card network) holds the authoritative balance and will
confirm it. Fixed.

**Summing shards is arithmetic netting, and netting has rules.** IAS 1.32 and ASC 210-20-45-1
permit offsetting only for amounts due to and from the **same party**. A shard set may be summed
only if all shards share one counterparty. If the shard key *is* the counterparty — a receivable
per customer — then sign-flipped shards must be presented **gross**, not netted. (The classic case:
customer accounts in credit may not be netted against other customers' debits; they are
reclassified to liabilities.) Added `counterparty_scope: none | shared | per_shard` so the
reporting layer can enforce it.

### Where the design is genuinely weakest

**Reconciliation granularity should mirror the counterparty's statement, not our contention
profile.** The card network settles per BIN/ICA/settlement cycle — *not* per tenant. Sharding
`network_settlement_payable` per tenant introduces a partition axis **orthogonal to the only axis
that can ever be externally confirmed**, so every reconciliation must re-aggregate before it can
start. Unless tenant maps 1:1 to BIN, **shard perimeter accounts on the counterparty's axis, or
not at all.**

### Still open, from the accounting side

- **A reserved `unallocated` instance per account type.** Accruals, FX revaluation, corrections,
  and cut-off adjustments have no natural tenant. Without a designated home the accountant will
  either invent a shard (breaking the "mechanical" story) or post to an arbitrary tenant
  (corrupting the analytics that motivated the split).
- **Principal vs agent (ASC 606-10-55-36 / IFRS 15.B34–B38).** If a deployment is an *agent*, the
  tenant's interchange is not revenue at all — it is a payable. Then the per-tenant rows are not
  shards of one account; some are a *different account with a different classification*. That is
  an accounting error, not a modelling preference, and it is invisible to a design that treats
  "one account, N shards" as axiomatic. The gross-vs-net decision is a deployment decision, not an
  engine decision, and the docs must say so.
- **Multi-entity.** If tenants are separate legal entities, the theorem acquires a precondition:
  "any union of whole transactions is balanced" gives a balanced *consolidated* set, **not** a
  balanced *per-entity* set. One transaction touching two entities balances globally while leaving
  each entity's trial balance out of balance. The fix is intercompany due-to/due-from clearing
  accounts — a legitimate clearing-account use, and the primitive to add if we serve multi-entity.
- **Segment reporting is a non-issue for most adopters.** IFRS 8 / ASC 280 apply only to public
  entities, and the trigger is CODM review for resource allocation — *not* data availability.
  Building per-tenant revenue in the ledger does not create a segment. Worth a docs note so nobody
  panics.

## Prior art — the pattern has six names and we are not inventing it

Surveyed across open-source and commercial ledgers. Splitting one logical account into N physical
rows is **standard practice**, attested under six names:

| Name | Source | Shard key |
| --- | --- | --- |
| **Balance sharding** | Blnk, docs page *"Handling Hot Balances"* | hashed |
| **Scoped accounts** | Envato `double_entry` (Rails, ~2012) | a business entity |
| **Account pooling** | Formance, *Architecting for scale* | random (`@world:<random_id>`) |
| **Template accounts** | Fragment (`template: true`) | the entity |
| **Ledger Account Categories** | Modern Treasury (aggregation half only) | arbitrary grouping |
| **Fund accounting / balanced segment** | Beancount, django-ledger, Oracle & SAP GL | the fund / unit |

`double_entry`'s README states our exact justification: *"Scoping accounts is recommended.
Unscoped accounts may perform more slowly than scoped accounts due to lock contention."* Shipped
in a production marketplace since 2012.

### Our key choice is the better one, and AWS names why

Everyone sharding a hot ledger account in OSS shards on a **random or hashed** key. We propose a
**semantically meaningful** one. AWS's DynamoDB write-sharding guidance draws exactly this line:

- **Random suffixes** — great writes, but *"to read all the items for a given day, you would have
  to query the items for all the suffixes and then merge the results."*
- **Calculated suffixes** — *"use a number that you can calculate based upon something that you
  want to query on."*

A tenant key is a calculated suffix. Per-tenant reads become point reads on a known row; only the
*global* roll-up scatters. Random stripes make every read a scatter.

### This refines our "batching and striping are antagonistic" finding

[Spike 003 Result 6](../003-throughput-ceiling/README.md) measured random striping and coalesced
batching cancelling (2,356/s vs 6,850 or 3,420 alone), and
[Result 8](../003-throughput-ceiling/README.md) found worker-affinity striping makes them compose
(4,790/s, flat across concurrency).

Blnk pairs balance sharding *with* coalescing deliberately, and explains why: *"Coalescing stays
effective. With the queue enabled, each shard still batches transactions that share the same
source, destination, and currency, **but with far less contention per pair** than a single
overloaded balance."*

**The affinity key should be the tenant, not the worker.** A batch of one tenant's clearings
naturally coalesces onto that tenant's house rows — same mechanism as Result 8, but keyed on a
business fact, so it survives a restart and needs no sweep process.

### THE design rule: put the invariant on the rollup, not the shard

The failure mode, found in the wild (`dineshsuthar123/Nexus`, `008_account_sharding.sql`): an
`account_shard(account_id, shard_id, balance)` table with `CHECK (balance >= 0)` **per shard**. A
debit then fails on one shard while the aggregate has funds, forcing shard rebalancing.

Every mature system avoids it the same way:

- **Modern Treasury**: `ledger_account_category_balance_locks` lock the **category** balance.
- **Fragment**: entry conditions apply to `totalBalance`, *"which includes both the account's own
  lines and its children's lines."*
- **hledger**, in accounting terms: *"generally you should avoid writing balance assertions on
  individual lots… you can usually write it on the parent account instead."*

Directly relevant to the reference product: a **credit limit must be checked against the logical
account**, never a stripe.

### Fragment's three balances are the API shape to copy

`ownBalance` (this account's own lines), `childBalance` (its children's), `balance` (both) — with
matching `ownBalanceChange` / `childBalanceChange` / `balanceChange(period:)`. Don't leave
"balance = SUM across stripes" as an implicit query convention; name it in the schema.

### Beancount: the tenant belongs ABOVE the account roots, not below

The sharpest accounting-theory statement of our theorem, from Beancount's fund-accounting design
doc — *"An Accounting Fund is a self-balancing Chart of Accounts"*, with the rule *"it is required
that any transaction be balanced in every fund that it uses"*, therefore any combination of funds
balances. And the design guidance:

> *"I don't see how this can be so easily or neatly achieved by pushing the idea of the 'funds'
> down into the account hierarchy: **funds belong above the five root accounts** (Assets,
> Liabilities, Equity, Income and Expenses), not below them."*

Our theorem already says every per-tenant slice balances — but that only holds **if every
transaction is tenant-local**, which is exactly what per-tenant house accounts buy. Making the
tenant a first-class scope *above* the account type (rather than a suffix below
`interchange_revenue`) is what keeps `A = L + E + (R − X)` provable per tenant, and that is what
makes a future database split safe.

### Nobody does global reporting inside the OLTP engine

| System | Global reporting |
| --- | --- |
| Formance | per-ledger only; CDC to ClickHouse, `GROUP BY ledger` |
| TigerBeetle | no server-side aggregation at all; CDC to a warehouse |
| `double_entry` | materialized `double_entry_line_aggregates` cache table |
| Modern Treasury / Fragment | precomputed rollups on write |
| **Blnk** | **left to the user — and its own docs flag that as the reason not to shard** |

Blnk's stated caveat is the one to design against: don't shard when *"you need a single balance
identity for external reconciliation or regulatory reporting **without aggregation**."* That is
the `network_settlement_payable` case exactly.

### Two independent corroborations of our own numbers

- **pgledger** (pure-SQL Postgres ledger, same running-balance + sorted-`FOR UPDATE` design as
  ours) publishes 10,637 transfers/s local, 7,559 hot, and **1,631 over a network (36.8ms per
  transfer)** — an ~85% collapse. Independent confirmation of
  [Result 9](../003-throughput-ceiling/README.md) and of the decision not to publish a localhost
  figure.
- **Formance self-reports** being *"optimized for 1K writes per second on an underlying commodity
  storage instance."* Our unsharded ~840 clearings/s with durability on is in the same league as
  the closest comparable system.

### A correction to how we read TigerBeetle

Their objection — *"most accounts cannot be neatly partitioned between shards"*, *"row locks on hot
accounts worsen when the transactions must execute across shards"* — is an argument against
**distributed** sharding, where cross-shard transactions get expensive. **It does not apply to N
rows in one Postgres.** [ADR-0007](../../docs/decisions/0007-open-source-positioning.md) leaned on
it slightly too heavily.

## RLS — per-tenant accounts make it possible, and make it a CORRECTNESS constraint

### Today RLS cannot work at all

`ledger_accounts.tenant_id` is NULL for house accounts, so a policy like
`USING (tenant_id = current_setting('app.tenant_id'))` makes every house account **invisible to
every tenant**. Per-tenant house accounts fix that — every account row gets a real tenant.

But two more things are required, and the second is not a security issue at all.

### 1. `ledger_entries` needs a denormalized `tenant_id`

It currently has none — tenant is reachable only by joining `ledger_accounts`. An RLS policy with
a subquery runs **per row** and is a well-known planner trap. Denormalize it, the same way
[ADR-0003](../../docs/decisions/0003-bitemporal-balances.md) denormalized `effective_at`. It is
also the column a future `PARTITION BY HASH (tenant_id)` would need.

### 2. Every transaction must be tenant-local, or tenants see an UNBALANCED ledger

This is the finding that matters, and it is demonstrated rather than argued.

Perimeter accounts genuinely **cannot** be per-tenant — `operating_cash` mirrors one real bank
account. So a treasury transaction spans scopes: `DR operating_cash (__house__) / CR
customer_receivable (t1)`.

With RLS scoped to `t1`:

| viewer | sees | net |
| --- | --- | --- |
| operator | both legs | 0.00 ✅ |
| **tenant t1** | the credit leg only | **−500.00** ❌ |

**The tenant's trial balance is off by the entire amount, and their accounting equation fails.**
RLS silently turns a valid ledger into an invalid one, because it filters *within* a transaction.

This is precisely Beancount's rule from the fund-accounting prior art: *"it is required that any
transaction be balanced in every fund that it uses."* A tenant scope is a fund.

### The fix: intercompany clearing accounts

Split the cross-scope transaction into **two transactions, each balanced within one scope**,
joined by a due-from/due-to pair:

```
-- inside tenant t1
DR due_from_treasury (t1)        500
CR customer_receivable (t1)      500

-- inside the house scope
DR operating_cash (__house__)    500
CR due_to_tenants (__house__)    500
```

Verified in the same tenant's RLS view, side by side:

| transaction | t1 sees | verdict |
| --- | --- | --- |
| `treasury2` (cross-scope, single transaction) | −500.00 | **UNBALANCED** |
| `fixed:tenant` (intercompany pair) | 0.00 | **BALANCED** |

This is the same primitive the accounting review identified for **multi-entity** deployments, and
it generalizes: `due_from_*` / `due_to_*` clearing accounts are what make any scoped view of a
ledger a valid ledger in its own right.

### Consequences

- **RLS is not merely a security feature here — it is a correctness constraint.** If RLS is on,
  the tenant's view must itself satisfy `A = L + E + (R − X)`. That is only true if no transaction
  crosses scopes.
- **This tightens the theorem.** [The theorem above](#the-theorem) says any union of *whole*
  transactions balances. Under RLS a tenant does not see whole transactions — they see a filtered
  subset — so the theorem's precondition is violated unless transactions are tenant-local by
  construction.
- **It gives "no cross-tenant transactions" a reason to exist beyond sharding.** ADR-0007 wanted
  that property for tenant→database routing. It turns out to be required for per-tenant reporting
  to be correct at all, on a single database, with no sharding involved.
- **It needs enforcement, not intention.** Shopify runs CI verifiers named "Cross Shard
  Transaction". The equivalent here: assert no transaction's entry set spans more than one
  `tenant_id`. That check is cheap and belongs in M1.

## RLS — three constraints measured on our own stack

### `COPY FROM` is not supported on RLS tables. This conflicts with our batching design.

```
ERROR:  COPY FROM not supported with row-level security
```

Measured on PG 18.6. [Spike 002](../002-sqlc-vs-jet/README.md) found `CopyFrom` load-bearing —
it is what made sqlc's native pgx mode worth choosing — and
[spike 003 Result 5](../003-throughput-ceiling/README.md) uses `tx.CopyFrom` to insert a
coalesced batch of entries, the lever worth 4.4×.

**RLS on `ledger_entries` and bulk `COPY` batching are mutually exclusive.** Options: run the
posting path as a `BYPASSRLS` role (RLS then protects only the read path — which is arguably all
we wanted it for), fall back to multi-row `INSERT` for batches, or scope RLS to reads via views.
This needs deciding, not discovering.

### The policy must be written one specific way

`current_setting()` is `STABLE`, not `IMMUTABLE`, so inside a policy it can be re-evaluated
**per row**. Wrapping it in a scalar subquery forces an InitPlan evaluated once per statement.
Supabase measured 178,000 ms → 12 ms on exactly this fix.

```sql
-- WRONG: evaluated per row
USING (tenant_id = current_setting('app.tenant_id'))
-- RIGHT: InitPlan-cached, and fails CLOSED when the GUC is unset
USING (tenant_id = (SELECT current_setting('app.tenant_id', true)))
```

The two-argument form matters: one-arg *errors* when unset, two-arg returns NULL and
`tenant_id = NULL` matches nothing.

### Enums are not leakproof — but our hot path is safe

Non-leakproof operators cannot be reordered ahead of the RLS security barrier, which routinely
costs an index scan. Measured on our types:

| operator | |
| --- | --- |
| `enum_eq` | **NOT leakproof** |
| `uuid_eq`, `int8eq`, `texteq`, `timestamptz_le` | leakproof |

Our hot-path indexes lead with `account_id` (uuid), `account_seq` (int8), and `recorded_at`
(timestamptz) — all leakproof, so `ix_entries__balance_lookup` is unaffected. The exposure is on
reporting queries filtering by `direction`, `state`, or `status`. Worth knowing before someone
adds an enum to the leading column of an index.

### Also worth banking

- **The app role must not own the tables** — owners bypass RLS. Add `FORCE ROW LEVEL SECURITY`.
- Use `SET LOCAL` per transaction, never `SET ROLE` per tenant. Two RLS plan-cache CVEs in two
  years (CVE-2024-10978, CVE-2026-14666) were both triggered by role switching.
- Only `pg_advisory_xact_lock` survives transaction pooling; session-level `pg_advisory_lock`
  leaks onto the next client's connection.
- **RDS Proxy may pin the session on `SET`** for PostgreSQL — which would defeat the
  `SET LOCAL` GUC pattern on AWS's own proxy. Unverified; needs testing against
  `DatabaseConnectionsCurrentlySessionPinned` before we recommend the combination.

## Open — posting rules

The remaining piece of "how they tie together." A deployment declares its chart; it must also
declare **how a business event becomes entries** — given a clearing of amount X with interchange
rate r and rev-share share s, produce the balanced set. Today that mapping lives in application
code, which means each integrator re-derives it and can get it wrong silently.

Formance solves this with Numscript, a DSL. That is a large surface to own. A declarative
template validated **at definition time** — proving the rule balances for all inputs, not just
the ones that were tried — is probably the right first step.

**Adyen has shipped exactly that**, and it is the strongest external validation of this direction.
Their ledger accepts entries *only* via a template, and templates are **mathematically verified**:
they *"represent amounts that serve as inputs by logical entities and prove that every combination
of amounts will result in a net sum of 0. This verification is fully automated and runs on every
change to the templates."*

That is a genuinely different correctness posture from ours. We check that a transaction balances
**at runtime**, per transaction, forever. Adyen proves the *rule* balances **once, at design
time** — so an unbalanced transaction becomes unconstructable rather than rejected. The two are
complementary: keep the runtime constraint as a backstop, add design-time proof as the primary
guarantee. Needs its own spike before M3.

## Open — global rollups should be named, not ad-hoc

Reporting across per-tenant accounts is a `SUM` (measured: 11.5ms across 1,000 tenants). But
Modern Treasury's **Ledger Account Categories** are the better shape: *"free-form account groups
that can be used to create account hierarchies"* where *"the balance of a Ledger Category is equal
to the sum of the balances of all contained accounts"*, and categories nest.

The difference matters. An ad-hoc `SUM` scattered through reporting code has no identity, gets
rewritten slightly differently in three services, and has nowhere to cache. A **named, nested,
first-class rollup** gives "global interchange revenue" an identity, one place to later
materialize or push to a warehouse, and it generalizes to the sharded case (per-shard rollup, then
sum of rollups) in a way a raw `SUM(*)` does not.
