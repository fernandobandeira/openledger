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

## Open — posting rules

The remaining piece of "how they tie together." A deployment declares its chart; it must also
declare **how a business event becomes entries** — given a clearing of amount X with interchange
rate r and rev-share share s, produce the balanced set. Today that mapping lives in application
code, which means each integrator re-derives it and can get it wrong silently.

Formance solves this with Numscript, a DSL. That is a large surface to own. A declarative
template validated **at definition time** — proving the rule balances for all inputs, not just
the ones that were tried — is probably the right first step. Needs its own spike before M3.
