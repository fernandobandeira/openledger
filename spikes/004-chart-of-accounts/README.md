# Spike 004 — The chart of accounts as a capability, and the math as a theorem

**The question.** Accounts like `platform_rev_share_payable` and `facility_borrowings` are
business-specific — a card program funded by a warehouse line has them, a marketplace wallet does
not. A general ledger cannot ship a fixed chart of accounts. So what *does* it ship, and how does
it guarantee the math is right when it doesn't know what the accounts are?

**Status:** closed. Feeds [ADR-0007](../../docs/decisions/0007-open-source-positioning.md) and
M0/M1.

---

## The answer

**Ship the capability to declare a chart, plus constraints that make the accounting identity a
theorem rather than a test.**

> **If** every transaction balances (debits = credits) per currency, **and** every account's
> category and normal balance are correct, **then** `A = L + E + (R − X)` holds — at every
> instant, on either time axis, for any subset of whole transactions.

*Category* is one of asset / liability / equity / revenue / expense. *Normal balance* is whether
an account naturally grows on the debit or the credit side — and it is **not** derivable from
category (a loss allowance is an asset that behaves like a credit). The identity says assets equal
liabilities plus equity plus profit.

It follows because *every individual transaction balances*, so **any union of whole transactions
balances** — every prefix, every as-of cut, every per-tenant slice. So we don't *check* the math;
we make the two premises structurally impossible to violate.

**Proven:** the [the reference product spec §06](../../docs/reference-product.md) golden trace — one $500 purchase, 13
transactions — reproduces the vision doc's hand-computed figures to the cent, with the equation
verified after **every** transaction. That is M0's acceptance test, passing.

## But the theorem does not prove *completeness* — and that is the real risk

`A = L + E + (R − X)` proves the **ledger** is internally consistent. It says nothing about
whether a **report** enumerated every account. Demonstrated:

```
TRUE global interchange revenue (3 tenant accounts)   30.00
reported by a mapping that misses one tenant          20.00
accounting equation                                   BALANCED
```

**Revenue understated by a third, equation perfectly happy** — but *not* for the reason this line
gave for several rounds. It said omitting an account "removes it from both sides", which
[ADR-0009](../../docs/decisions/0009-chart-and-completeness.md) shows is false and checkably so:
drop `interchange_revenue` from the shipped trace and assets read 276 against L+E+R-X of -624. What
happens here is narrower — the demo omits a whole *tenant*, and a tenant's sub-book balances on its
own, so both sides move together. The numbers stand; the stated mechanism was wrong. This is the audit finding to engineer against: a tenant is onboarded, its
account row is created, the reporting mapping misses it, and nothing imbalances.

Fixed by [`completeness.sql`](./completeness.sql): every account type carries a `NOT NULL`
financial-statement line, and the reporting view joins **chart → types → all instances**, so there
is no parameter in which to pass an incomplete account list. Verified: a 4th tenant added
afterwards appeared automatically with no mapping change.

## What it cost

- Two extra tables (`account_types`, `fs_lines`) and a trigger, in exchange for making a whole
  class of silent misstatement impossible.
- Splitting an account per tenant is **standard practice** (see [Prior art](#prior-art)) but it
  moves all the risk onto completeness of the roll-up, which is why the fix above is mandatory
  rather than nice-to-have.
- Row-level security turns tenant-locality from an optimisation into a **correctness
  requirement** — and conflicts with our batching design. See [RLS](#rls).

---

# The evidence

## Making the premises unbreakable

**Premise (a) — every transaction balances** was already enforced by `ck_entries__balances`, the
deferred constraint trigger from [spike 002](../002-sqlc-vs-jet/README.md). It fires at `COMMIT`,
per transaction, per currency.

**Premise (b) — every account is correctly typed** was *not*. `purpose` was free text and
category/normal-balance were per-account columns, so nothing stopped `interchange_revenue` being
created as an **asset with a debit normal balance** — which silently breaks every statement that
rolls up by category and produces an equation failure nobody can locate.

[`chart.sql`](./chart.sql) adds a real chart of accounts as data:

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
| `interchange_revenue` declared as `asset`/`debit` | ❌ *"declares asset/debit but type is revenue/credit"* |
| a `purpose` not in the chart | ❌ foreign key violation |
| `allowance_for_credit_losses` as `asset` with **credit** normal balance | ✅ allowed |

That third row is why normal balance can't be computed from category. *Contra accounts* are assets
that behave like credits, and any design that derives one from the other is wrong the first time
someone books a loss allowance.

## What is engine and what is configuration

| | Fixed by the engine | Declared per deployment |
| --- | --- | --- |
| Categories, normal balances | yes | — |
| The identity `A = L + E + (R − X)` | always enforced | — |
| Per-transaction balancing | always enforced | — |
| **Account types** (the chart) | — | **yours** |
| Which accounts exist, and who owns them | — | **yours** |
| How a business event maps to entries | — | **yours** ([still open](#still-open)) |

The card chart in [`chart.sql`](./chart.sql) is **seed data for the reference product**, not part
of the engine. A marketplace ships a different one against the same core.

## Proof: the golden trace

[`golden_trace.sql`](./golden_trace.sql) posts the full the reference product spec lifecycle;
[`verify.sql`](./verify.sql) evaluates the equation after each transaction.

```
 step | after_txn             | assets | liabs  | equity | revenue | expense | equation
------+-----------------------+--------+--------+--------+---------+---------+----------
    1 | open                  |  66.00 |   0.00 |  66.00 |    0.00 |    0.00 | BALANCED
    2 | evt_clear_1:posting   | 366.00 | 294.60 |  66.00 |    5.40 |    0.00 | BALANCED
    7 | evt_settle            | 500.00 | 427.70 |  66.00 |    9.00 |    2.70 | BALANCED
   13 | evt_repay:revshare    |  68.76 |   0.00 |  66.00 |    9.00 |    6.24 | BALANCED
```

Step 7 is the one the vision doc checks by hand: *"assets 500 + 0, liabilities 0 + 425 + 2.70,
equity 66 + 9.00 − 2.70. Both sides 500."* Liabilities 427.70, equity plus revenue minus expense
72.30, total 500.00. **Exact match**, and the final trial balance matches to the cent.

### An accident worth keeping

The first run ordered steps *alphabetically*. All 13 transactions posted in one `COMMIT`, so
`now()` — transaction-**start** time — gave every one an identical `recorded_at` and the sort fell
through to the idempotency key. That is
[ADR-0005](../../docs/decisions/0005-reproducible-as-of.md) demonstrating itself by accident, on a
13-row table, with no concurrency involved.

**And the equation held under the wrong order anyway** — which is the theorem doing its job. Order
independence is exactly what "any union of whole transactions balances" buys.

## The accounting view

### The vocabulary is "control account + subsidiary ledger", and our version is safer

Splitting one reported figure across many physical accounts is the centuries-old bookkeeping norm:
a **control account** in the general ledger carries the total, a **subsidiary ledger** holds the
individual accounts, and the two are reconciled monthly. Accounts receivable ↔ one account per
customer is the canonical case.

**Our version is strictly stronger.** Classically the control balance is *separately maintained*
and can drift from the subledger — which is why control-account reconciliation is a SOX key
control. In our design the total is **defined as** `SUM(instances)` over the same rows. Drift is
not detected; it is impossible. That moves the entire risk onto one question — *is the set summed
the complete set?* — which is what [`completeness.sql`](./completeness.sql) answers.

### The framing that dissolves most of the objection

An accountant sees **`account_types` = the chart of accounts (16 entries)** and
**`ledger_accounts` = dimensioned instances**. `interchange_revenue` is *one* account in the chart
no matter how many rows carry that `purpose`.

ERP practice is blunt: put the **"what"** in the account and the **"why/where"** in a dimension.
*"One `interchange_revenue` account per tenant"* is the textbook **anti-pattern**. *"One
`interchange_revenue` account type, with tenant as a dimension"* is the textbook **correct
answer**. Our schema already does the latter.

Say **"we partitioned the postings of one account"**, never "we split the account". Avoid "shard"
in accountant-facing documents. Never name a staging account "suspense" — that word carries
regulatory weight (FFIEC lists suspense/omnibus/settlement accounts as an examination focus);
"clearing" is the word for designed staging.

### Economic vs mechanical splits

The standards register is **unit of account** (IFRS Conceptual Framework ¶4.48ff). An *economic*
split means the pieces genuinely are separate units of account; a *mechanical* split is one unit of
account physically partitioned, with no accounting consequence.

| Account | Split is… | Why |
| --- | --- | --- |
| `customer_receivable` per customer | **economic** | separate legal right, external confirmation, aged individually |
| `interchange_revenue` per tenant | **mechanical** | our own income, no counterparty, no separate settlement |
| `network_settlement_payable` per tenant | **mechanical — but questionable** | see below |

### Two corrections to the chart

**`network_settlement_payable` is a perimeter account.** We marked it `is_perimeter = false`. It is
the archetype — an external party (the card network) holds the authoritative balance and will
confirm it. Fixed.

**Summing shards is arithmetic netting, and netting has rules.** IAS 1.32 and ASC 210-20-45-1
permit offsetting only for amounts due to and from the **same party**. A set may be summed only if
all members share one counterparty. If the split key *is* the counterparty — a receivable per
customer — sign-flipped members must be presented **gross**, not netted. (Customer accounts in
credit may not be netted against other customers' debits; they are reclassified to liabilities.)
Added `counterparty_scope: none | shared | per_shard` so the reporting layer can enforce it.

### Where the design is genuinely weakest

**Reconciliation granularity should mirror the counterparty's statement, not our contention
profile.** The card network settles per BIN/ICA/settlement cycle — *not* per tenant. Splitting
`network_settlement_payable` per tenant introduces a partition axis **orthogonal to the only axis
that can ever be externally confirmed**, so every reconciliation must re-aggregate before it can
start. Unless tenant maps 1:1 to BIN, **split perimeter accounts on the counterparty's axis, or
not at all.**

## RLS

Row-level security scopes what a database role can see. Per-tenant accounts make it possible —
today `tenant_id` is NULL on house accounts, so a tenant policy makes every house account
invisible to everyone. But three things follow.

### 1. `ledger_entries` needs a denormalized `tenant_id`

It has none; tenant is reachable only by joining `ledger_accounts`, and an RLS policy containing a
subquery runs **per row** — a well-known planner trap. Denormalize it, as
[ADR-0003](../../docs/decisions/0003-bitemporal-balances.md) did for `effective_at`. It is also the
column a future `PARTITION BY HASH (tenant_id)` would need.

### 2. Every transaction must be tenant-local, or tenants see an UNBALANCED ledger

Perimeter accounts genuinely cannot be per-tenant — `operating_cash` mirrors one real bank account
— so a treasury transaction spans scopes: `DR operating_cash (__house__) / CR customer_receivable
(t1)`. With RLS scoped to `t1`:

| viewer | sees | net |
| --- | --- | --- |
| operator | both legs | 0.00 ✅ |
| **tenant t1** | the credit leg only | **−500.00** ❌ |

**The tenant's trial balance is off by the entire amount, and their accounting equation fails.**
RLS silently turns a valid ledger into an invalid one, because it filters *within* a transaction.

That is Beancount's fund-accounting rule exactly: *"it is required that any transaction be balanced
in every fund that it uses."* A tenant scope is a fund.

**The fix: intercompany clearing accounts.** Split the cross-scope transaction into two
transactions, each balanced within one scope, joined by a due-from/due-to pair:

```
-- inside tenant t1                    -- inside the house scope
DR due_from_treasury (t1)   500        DR operating_cash (__house__)  500
CR customer_receivable (t1) 500        CR due_to_tenants (__house__)  500
```

Verified side by side in the same tenant's RLS view:

| transaction | t1 sees | verdict |
| --- | --- | --- |
| cross-scope, single transaction | −500.00 | **UNBALANCED** |
| intercompany pair | 0.00 | **BALANCED** |

Consequences: **RLS is a correctness constraint here, not just security.** It tightens the theorem
— "any union of *whole* transactions" is violated when a tenant sees a filtered subset. And it
gives "no cross-tenant transactions" a reason to exist beyond sharding: it is required for
per-tenant reporting to be correct at all, on a single database. It needs *enforcement* — a CI
check that no transaction's entry set spans more than one `tenant_id`, in M1.

### 3. Three constraints measured on our own stack

**`COPY FROM` is not supported on RLS tables** — `ERROR: COPY FROM not supported with row-level
security`, on PG 18.6. [Spike 002](../002-sqlc-vs-jet/README.md) found `CopyFrom` load-bearing, and
[spike 003](../003-throughput-ceiling/README.md) uses it for the coalesced batch worth 4.4×.
**RLS on `ledger_entries` and bulk `COPY` batching are mutually exclusive.** Options: post as a
`BYPASSRLS` role (RLS then guards only reads — arguably all we wanted), fall back to multi-row
`INSERT`, or scope RLS to reads via views. **Needs deciding, not discovering.**

**The policy must be written one specific way.** `current_setting()` is `STABLE`, not `IMMUTABLE`,
so inside a policy it can be re-evaluated **per row**. Wrapping it in a scalar subquery forces a
once-per-statement InitPlan — Supabase measured 178,000 ms → 12 ms on exactly this fix:

```sql
-- WRONG: evaluated per row
USING (tenant_id = current_setting('app.tenant_id'))
-- RIGHT: InitPlan-cached, and fails CLOSED when the GUC is unset
USING (tenant_id = (SELECT current_setting('app.tenant_id', true)))
```

The two-argument form matters: one-arg *errors* when unset, two-arg returns NULL and
`tenant_id = NULL` matches nothing.

**Enums are not leakproof.** Non-leakproof operators can't be reordered ahead of the RLS security
barrier, which routinely costs an index scan. Measured: `enum_eq` **NOT leakproof**; `uuid_eq`,
`int8eq`, `texteq`, `timestamptz_le` all leakproof. Our hot-path indexes lead with `account_id`
(uuid), `account_seq` (int8) and `recorded_at` (timestamptz), so they're unaffected — the exposure
is reporting queries filtering by `direction`, `state` or `status`.

**Also worth banking:** the app role must not own the tables (owners bypass RLS — add `FORCE ROW
LEVEL SECURITY`); use `SET LOCAL` per transaction, never `SET ROLE` per tenant (both recent RLS
plan-cache CVEs, CVE-2024-10978 and CVE-2026-14666, were triggered by role switching); only
`pg_advisory_xact_lock` survives transaction pooling; and **RDS Proxy may pin the session on `SET`**
for PostgreSQL, which would defeat the GUC pattern on AWS's own proxy — unverified, needs testing
against `DatabaseConnectionsCurrentlySessionPinned`.

## Prior art

Splitting one logical account into N physical rows is **standard practice**, attested under six
names:

| Name | Source | Split key |
| --- | --- | --- |
| **Balance sharding** | Blnk, *"Handling Hot Balances"* | hashed |
| **Scoped accounts** | Envato `double_entry` (Rails, ~2012) | a business entity |
| **Account pooling** | Formance, *Architecting for scale* | random (`@world:<random_id>`) |
| **Template accounts** | Fragment (`template: true`) | the entity |
| **Ledger Account Categories** | Modern Treasury (aggregation half only) | arbitrary grouping |
| **Fund accounting / balanced segment** | Beancount, django-ledger, Oracle & SAP GL | the fund / unit |

`double_entry`'s README states our exact justification: *"Scoping accounts is recommended. Unscoped
accounts may perform more slowly than scoped accounts due to lock contention."* Shipped in a
production marketplace since 2012.

**Our key choice is the better one, and AWS names why.** Everyone else splits on a random or hashed
key; we propose a semantically meaningful one. AWS's DynamoDB write-sharding guidance draws the
line: *random suffixes* give great writes but *"to read all the items for a given day, you would
have to query the items for all the suffixes and then merge the results"*; *calculated suffixes*
*"use a number that you can calculate based upon something that you want to query on."* A tenant
key is a calculated suffix — per-tenant reads become point reads, and only the global roll-up
scatters.

**This refines spike 003's "batching and striping are antagonistic".** Blnk pairs balance sharding
*with* coalescing deliberately: *"each shard still batches transactions that share the same source,
destination, and currency, but with far less contention per pair than a single overloaded
balance."* **The affinity key should be the tenant, not the worker** — a batch of one tenant's
clearings naturally coalesces onto that tenant's rows, and a business key survives a restart and
needs no sweep process.

### THE design rule: put the invariant on the rollup, not the shard

Found in the wild (`dineshsuthar123/Nexus`, `008_account_sharding.sql`): an
`account_shard(account_id, shard_id, balance)` table with `CHECK (balance >= 0)` **per shard**. A
debit then fails on one shard while the aggregate has funds, forcing rebalancing.

Every mature system avoids it the same way — Modern Treasury's
`ledger_account_category_balance_locks` lock the **category** balance; Fragment's entry conditions
apply to `totalBalance`, *"which includes both the account's own lines and its children's lines"*;
hledger, in accounting terms: *"you should avoid writing balance assertions on individual lots… you
can usually write it on the parent account instead."*

**Directly relevant to the reference product: a credit limit must be checked against the logical
account, never one split of it.**

### Two more shapes worth copying

**Fragment's three balances** — `ownBalance` (this account's own lines), `childBalance` (its
children's), `balance` (both), with matching `*BalanceChange(period:)`. Don't leave "balance = SUM
across splits" as an implicit query convention; name it in the schema.

**Beancount: the tenant belongs ABOVE the account roots, not below.** From their fund-accounting
design doc — *"An Accounting Fund is a self-balancing Chart of Accounts"*, with the rule that any
transaction must balance in every fund it uses, therefore any combination of funds balances. And:

> *"funds belong **above** the five root accounts (Assets, Liabilities, Equity, Income and
> Expenses), not below them."*

Our theorem says every per-tenant slice balances — but only **if every transaction is
tenant-local**. Making the tenant a first-class scope *above* the account type keeps
`A = L + E + (R − X)` provable per tenant, which is what makes a future database split safe.

### Nobody does global reporting inside the OLTP engine

| System | Global reporting |
| --- | --- |
| Formance | per-ledger only; CDC to ClickHouse, `GROUP BY ledger` |
| TigerBeetle | no server-side aggregation at all; CDC to a warehouse |
| `double_entry` | materialized aggregate cache table |
| Modern Treasury / Fragment | precomputed rollups on write |
| **Blnk** | **left to the user — and its own docs flag that as the reason not to shard** |

Blnk's caveat is the one to design against: don't split when *"you need a single balance identity
for external reconciliation or regulatory reporting **without aggregation**."* That is the
`network_settlement_payable` case exactly.

## Still open

**Posting rules.** A deployment declares its chart; it must also declare **how a business event
becomes entries** — given a clearing of amount X with interchange rate r and rev-share s, produce
the balanced set. Today that lives in application code, so each integrator re-derives it and can
get it wrong silently. Formance uses a DSL (Numscript); that is a large surface to own.

**Adyen has shipped the better first step** — their ledger accepts entries *only* via a template,
and templates are **mathematically verified**: they *"prove that every combination of amounts will
result in a net sum of 0. This verification is fully automated and runs on every change to the
templates."* That is a different correctness posture: we check a transaction balances **at
runtime**, forever; they prove the *rule* balances **once, at design time**, making an unbalanced
transaction unconstructable rather than rejected. Complementary — keep the runtime constraint as a
backstop. Needs its own spike before M3.

**Global rollups should be named, not ad-hoc.** Reporting across per-tenant accounts is a `SUM`
(measured: 11.5 ms across 1,000 tenants), but Modern Treasury's **Ledger Account Categories** are
the better shape — nested, first-class groups where *"the balance of a Ledger Category is equal to
the sum of the balances of all contained accounts."* An ad-hoc `SUM` has no identity, gets
rewritten differently in three services, and has nowhere to cache.

**A reserved `unallocated` instance per account type.** Accruals, FX revaluation, corrections and
cut-off adjustments have no natural tenant. Without a designated home the accountant will either
invent one (breaking the "mechanical" story) or post to an arbitrary tenant (corrupting the
analytics that motivated the split).

**Principal vs agent** (ASC 606-10-55-36 / IFRS 15.B34–B38). If a deployment is an *agent*, the
tenant's interchange is not revenue at all — it is a payable. Then the per-tenant rows are not
splits of one account; some are a *different account with a different classification*. That is an
accounting error, not a modelling preference, and it is invisible to a design that treats "one
account, N splits" as axiomatic. Gross-vs-net is a deployment decision, not an engine decision.

**Multi-entity.** If tenants are separate legal entities, the theorem gains a precondition: any
union of whole transactions gives a balanced *consolidated* set, **not** a balanced *per-entity*
set. The fix is the same intercompany due-to/due-from primitive as the RLS fix above.

**Segment reporting is a non-issue for most adopters.** IFRS 8 / ASC 280 apply only to public
entities, and the trigger is review by the chief operating decision maker for resource allocation
— *not* data availability. Building per-tenant revenue in the ledger does not create a segment.
