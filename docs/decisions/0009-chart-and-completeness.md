# 0009 — The chart of accounts is data, and completeness is a separate invariant

**Status:** accepted
**Date:** 2026-08-25

## The decision

**1. The chart of accounts is data, not code.** Account *types* live in a table. Each declares a
category, a normal balance, and the financial-statement line it rolls up to.
`ledger_accounts.purpose` is a foreign key to it. Purposes like `platform_rev_share_payable` are
business-specific — a card program funded by a warehouse line has them, a marketplace wallet does
not — so the engine ships the *capability* and the card chart is seed data.

**2. `normal_balance` is stored, never derived from `category`.** A loss allowance is an **asset**
with a **credit** normal balance. Any design that computes one from the other is wrong the first
time someone books one.

**3. Completeness is a separate invariant from balance.** The accounting equation does not prove a
report enumerated everything, so reports enumerate **from the chart outward**:
[`balance_sheet`](../../schema/schema.sql) starts `FROM fs_lines` and left-joins the numbers on, so
a line with no activity appears as a zero instead of vanishing. Every account type carries a
`NOT NULL` financial-statement line so there is always something to enumerate.

**4. The equation is evaluated per currency.**

**5. Where one logical account is split across rows, summing them is netting, and netting has
rules.** Each account type declares a `counterparty_scope`; where the split key *is* the
counterparty, opposite-sign members must be presented gross rather than netted.

Both mechanisms were designed in [spike 004](../../spikes/004-chart-of-accounts/README.md) and ship
in [`schema/schema.sql`](../../schema/schema.sql).

## Why

**A dropped balanced sub-book is invisible; a dropped account is not.** This is the finding the
whole layer exists for, and the distinction is the load-bearing part. Omit a single account and it
drops out of exactly *one* side of the equation — dropping `interchange_revenue` from the golden
trace leaves the two sides differing by exactly that account's balance, which the equation catches
and quantifies. What it cannot catch is omitting a whole **balanced** sub-book: an entire tenant, an
entire currency, an entire entity, any date range containing only whole transactions. Three tenants
holding 10.00 of interchange each, and a report that misses one shows **20.00 against a true
30.00**, with every check reading `BALANCED`, because what was dropped was itself balanced.

That reframes the threat. The risk is not a stray missing account; it is a **dropped sub-book** — an
RLS predicate, a tenant filter, a `date_trunc` boundary, a timezone. The reference product already
says it: *"the bug is never in storage, it's at every boundary that turns an instant into a
bucket."*

**A currency-blind equation is vacuous the moment a second currency exists.** `A = L + E + (R − X)`
follows from total debits equalling total credits, which holds for **any** union of
per-currency-balanced transactions *regardless of denomination* — so a currency-blind check returns
`true` for arbitrary currency mixing and can never detect it. Measured before the fix: 100.00 USD
plus 100.00 EUR reported *"assets 200.00, balanced."*

**Netting is a presentation rule with a standard behind it.** IAS 1.32 and ASC 210-20-45-1 permit
offsetting only for amounts due to and from the **same party**, which is why the scope has to be
declared on the type rather than inferred from the split.

**Prior art, checked rather than assumed.** Xero's published
[OpenAPI spec](https://raw.githubusercontent.com/XeroAPI/Xero-OpenAPI/master/xero_accounting.yaml)
carries **three** separate fields on one account — the same split as ours:

```yaml
- Code: "610"
  Name: Accounts Receivable
  Type: CURRENT                   # business meaning
  SystemAccount: DEBTORS          # reserved role
  ReportingCode: ASS.CUR.REC.TRA  # financial-statement line
```

Their `Class` (the five-way category `ASSET|EQUITY|EXPENSE|LIABILITY|REVENUE`) is marked `readOnly`,
derived from `Type` and never set directly — our arrangement too. The instructive difference: their
reporting axis is **hierarchical** (`ASS.CUR.REC.TRA` — asset, current, receivable, trade) where our
`fs_line` is flat. Flat is enough for a balance sheet and an income statement; it is not enough for
a nested statement with subtotals.

*(A broader survey of QuickBooks, NetSuite and SAP returned nothing usable — those docs are
unreachable as fetchable content. Absence of evidence recorded as such, not converted into a
claim.)*

## Alternatives

- **Derive `category` from `purpose` in code.** Ships the chart as a Go `switch`, which makes every
  new deployment's chart a code change and puts a contra account permanently out of reach. Rejected
  by point 2 above.
- **Trust the accounting equation as the completeness check.** It is the check that already exists
  and costs nothing, which is exactly why it was tempting. It cannot see a balanced omission, and
  balanced omissions are the ones a filter bug produces.
- **A hierarchical reporting axis, like Xero's.** Strictly more expressive, and it needs a tree
  where a flat code needs a column. Deferred, not rejected — see below.
- **Enumerate reports inward from `ledger_entries`.** Simpler and it is what `trial_balance` still
  does. An account with no entries is then simply absent, which is the failure this ADR names.

## What it costs

- **Reclassification is blocked while accounts exist — in one direction only.**
  `fk_accounts__type` refuses a change to a type's `category` or `normal_balance` while accounts
  reference it. It does **not** refuse a move of `fs_line` to another line of the same statement and
  side: verified, `fbo_cash` moved from `restricted_cash` to `cash` and 440.00 of customer float
  silently became unrestricted liquidity on an already-issued balance sheet — the exact harm
  `schema/chart.sql` cites Reg S-X 5-02.1 and ASC 230-10-45-4 for. Open. The blocked direction was
  worth blocking: changing a type's category silently rewrote the income statement, revenue 9.00 →
  0.00 on the golden trace with every check green, because reports join through the type while the
  guard only fired on the account.
- **`trial_balance` still enumerates inward** and is the wrong thing to build a completeness claim
  on. the accounting equation was rebuilt, in the SQL implementation 0012 deleted, to enumerate `FROM ledger_accounts` with the entry
  aggregate left-joined on, like `balance_sheet`; `trial_balance` has not.
- **A mis-typed reporting axis raises** rather than returning an empty, balanced report — which is
  the right failure, but it is a failure at read time rather than an unrepresentable state.
- The vocabulary is **control account + subsidiary ledger**, and our version is stronger than the
  classical one: the control balance is *defined as* the sum rather than separately maintained, so
  it cannot drift. That is why completeness, not reconciliation, is the risk that needed
  engineering.

## Not decided here

- **Posting rules** — how a business event becomes entries. Adyen proves its templates balance at
  design time; we have not designed ours.
- **A reserved `unallocated` instance** per type, for accruals and corrections with no tenant.
  Xero's `SystemAccount` enum (`RETAINEDEARNINGS`, `ROUNDING`, `UNREALISEDCURRENCYGAIN`, …) is the
  shape: a reserved role, distinct from the type.
- **A hierarchical reporting axis.** `fs_line` is flat; nested subtotals need a tree.
- **Multi-entity elimination in a report.** The theorem gives a balanced *consolidated* set, not a
  balanced *per-entity* one. Intercompany due-from/due-to accounts are the primitive and the golden
  trace runs on them — the facility draw, the network settlement and the ACH collection are all
  cross-scope, and the two sides are asserted to eliminate exactly at every step. Nothing *nets*
  them in a report, so a consolidated balance sheet presents intercompany balances gross.
- Several accounting-practice claims consulted during this work could not be verified against
  primary sources with the tooling available. They are omitted rather than softened.
