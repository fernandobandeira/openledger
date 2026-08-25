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
