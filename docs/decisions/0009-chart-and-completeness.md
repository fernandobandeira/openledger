# 0009 — The chart of accounts, and what the accounting equation does not prove

**Status:** accepted
**Date:** 2026-08-25

## Context

This project's stated purpose is correctness, and its headline claim is that the books are
provably balanced. That claim needs two things the ledger core does not supply on its own: a way
to know what *kind* of account each account is, and a guarantee that a report has not quietly
left one out.

Both were designed and demonstrated in [spike 004](../../spikes/004-chart-of-accounts/README.md)
and shipped in [`migrations/0002`](../../migrations/0002_chart_of_accounts.sql). Neither was
recorded as a decision — an omission found by adversarial review of this log, which claims on its
front page to hold *"everything we've decided."*

## Decision

### 1. The chart of accounts is data, not code

Account *types* live in a table. Each declares a category, a normal balance, and the
financial-statement line it rolls up to. `ledger_accounts.purpose` is a foreign key to it.

Purposes like `platform_rev_share_payable` are business-specific — a card program funded by a
warehouse line has them, a marketplace wallet does not. So the engine ships the *capability*; the
card chart is seed data.

### 2. `normal_balance` is stored, never derived from `category`

A loss allowance is an **asset** with a **credit** normal balance. Any design that computes one
from the other is wrong the first time someone books one.

### 3. The accounting equation does NOT prove completeness

This is the finding that justifies the whole layer, and it is not obvious.

A report that enumerates only *some* accounts still satisfies `A = L + E + (R − X)`, because the
missing account drops out of **both** sides. Demonstrated: three tenants holding 10.00 of
interchange each, a report that misses one shows **20.00 against a true 30.00**, and every check
reads `BALANCED`.

So completeness is a **separate invariant**, and it is enforced structurally: every account type
has a `NOT NULL` financial-statement line, and reports enumerate from the chart outward, so there
is no parameter in which to pass an incomplete list of accounts.

### 4. The equation is evaluated per currency

Not a refinement — a correction. `A = L + E + (R − X)` follows from total debits equalling total
credits, which holds for **any** union of per-currency-balanced transactions *regardless of
denomination*. A currency-blind check therefore returns `true` for arbitrary currency mixing and
**can never detect it**. Measured before the fix: 100.00 USD plus 100.00 EUR reported
*"assets 200.00, balanced."*

The theorem is true and **vacuous** the moment a second currency exists. It is now stated per
currency, and the docs' "any union of whole transactions" is narrowed accordingly.

### 5. Summing a split account is netting, and netting has rules

Where one logical account is split across rows, `SUM` over them is arithmetic offsetting. IAS 1.32
and ASC 210-20-45-1 permit that only for amounts due to and from the **same party**. So each
account type declares a `counterparty_scope`; where the split key *is* the counterparty,
opposite-sign members must be presented gross rather than netted.

## Prior art, checked rather than assumed

Xero's published [OpenAPI spec](https://raw.githubusercontent.com/XeroAPI/Xero-OpenAPI/master/xero_accounting.yaml)
carries **three** separate fields on one account, which is the same split as ours:

```yaml
- Code: "610"
  Name: Accounts Receivable
  Type: CURRENT                 # business meaning
  SystemAccount: DEBTORS        # reserved role
  ReportingCode: ASS.CUR.REC.TRA  # financial-statement line
```

`Class` (their five-way category, `ASSET|EQUITY|EXPENSE|LIABILITY|REVENUE`) is marked `readOnly` —
derived from `Type`, never set directly. That is our arrangement too: category lives on the *type*
row, and an account may not disagree with it.

The instructive difference: their reporting axis is **hierarchical** (`ASS.CUR.REC.TRA` — asset,
current, receivable, trade) where our `fs_line` is flat. Flat is enough for a balance sheet and an
income statement; it is not enough for a nested statement with subtotals.

*(A broader survey of QuickBooks, NetSuite and SAP was attempted and returned nothing usable —
those docs are unreachable as fetchable content. Absence of evidence is recorded as such, not
converted into a claim.)*

## Consequences

- **Reclassification is blocked while accounts exist.** Changing a type's category silently
  rewrote the income statement — revenue 9.00 → 0.00 on the golden trace with every check green,
  because reports join through the type while the guard only fired on the account. Both directions
  are now guarded.
- **A mis-typed reporting axis raises** rather than returning an empty, balanced report.
- The vocabulary is **control account + subsidiary ledger**, and our version is stronger than the
  classical one: the control balance is *defined as* the sum rather than separately maintained, so
  it cannot drift — which is why completeness, not reconciliation, is the risk that needed
  engineering.

## Not decided here

- **Posting rules** — how a business event becomes entries. Adyen proves its templates balance at
  design time; we have not designed ours.
- **A reserved `unallocated` instance** per type, for accruals and corrections that have no tenant.
  Xero's `SystemAccount` enum (`RETAINEDEARNINGS`, `ROUNDING`, `UNREALISEDCURRENCYGAIN`, …) is the
  shape this should take: a reserved role, distinct from the type.
- **A hierarchical reporting axis.** `fs_line` is flat; nested subtotals need a tree.
- **Multi-entity.** The theorem gives a balanced *consolidated* set, not a balanced *per-entity*
  one. Intercompany due-from/due-to accounts are the primitive, and they are seeded but unused.
- Several accounting-practice claims consulted during this work **could not be verified** against
  primary sources with the tooling available. They are omitted rather than softened.
