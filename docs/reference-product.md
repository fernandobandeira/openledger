# The reference product — an embedded card ledger

**This is the product openledger's reference implementation targets, not the project's
requirements.** openledger is a general double-entry ledger; see [`vision.md`](./vision.md) for why,
and [ADR-0007](./decisions/0007-open-source-positioning.md) for the decision that made this document
a product spec rather than a system spec.

**The system design lives in [`design-board.html`](./design-board.html)** — sizing, architecture,
the authorization hot path, the data model, state machines, and the lifecycle trace, in six
sections. Read that first. This document carries the two things the board cannot: **the chart of
accounts in detail**, and **the card lifecycle in text**, where each step can be diffed, grepped and
argued with.

Two things to hold while reading. Durable timers run **in-process on Postgres**
([ADR-0008](./decisions/0008-durable-timers.md)), not on an external workflow engine. And the hold
tables named in the trace below are the *shape* of the design, not what shipped: `card_holds`,
`credit_lines`, `spend_controls` and `card_transactions` do not exist. The hold model shipped as an
append-only trio — `card_auth_events`, `card_auth_event_group`, `card_hold_groups`
([ADR-0010](./decisions/0010-authorization-holds.md)) — and the credit-line and spend-control tables
are unbuilt (roadmap M7).

## The thesis

> The ledger is four systems wearing one name.

A v1 ledger built for one product — a charge card funded by a credit line — ends up the system of
record for **customer funds**, a **lender's collateral**, and the **financial statements**. Three
different masters, one table. Product surface assumed: charge card + wallet + AP/AR,
warehouse-funded receivables, we own the authorization decision, delegated KYB/KYC.

**An authorization moves no money and writes no ledger entry.** It records a hold and starts an
expiry timer; the ledger first hears about the purchase at **clearing**, which is also when
interchange is recognized. That is **our choice, not the field's** — Stripe, Adyen, Highnote,
Treasury Prime, Column, Galileo and Pismo all post a row at authorization time, while Increase,
Marqeta, Lithic and Unit keep it outside the ledger as we do
([spike 008](../spikes/008-processor-hold-semantics/README.md),
[ADR-0010](./decisions/0010-authorization-holds.md)).

## The chart of accounts

Nineteen account types, seeded by [`schema/chart.sql`](../schema/chart.sql) — **seed data, not
engine**: a marketplace or wallet deployment ships a different chart against the same core. Each
type declares its `category` (which rolls up the financial statements), its `normal_balance` (which
side it sits on), and the `fs_line` it maps to (the caption it appears under). Completeness comes
from enumerating this table rather than from listing whatever accounts have entries — see
[ADR-0009](./decisions/0009-chart-and-completeness.md).

| type | category | normal | fs_line | perimeter | counterparty |
| --- | --- | --- | --- | --- | --- |
| `customer_receivable` | asset | debit | receivables | | per_shard |
| `operating_cash` | asset | debit | cash | ✓ | shared |
| `fbo_cash` | asset | debit | restricted_cash | ✓ | shared |
| `allowance_for_credit_losses` | asset | **credit** | receivables | | none |
| `due_from_treasury` | asset | debit | other_assets | | shared |
| `customer_wallet` | liability | credit | customer_funds | | per_shard |
| `network_settlement_payable` | liability | credit | payables | ✓ | shared |
| `facility_borrowings` | liability | credit | borrowings | ✓ | shared |
| `accrued_interest_payable` | liability | credit | payables | | shared |
| `platform_rev_share_payable` | liability | credit | payables | | per_shard |
| `ach_pull_returnable` | liability | credit | payables | | per_shard |
| `due_to_tenants` | liability | credit | payables | | per_shard |
| `paid_in_capital` | equity | credit | equity | | none |
| `retained_earnings` | equity | credit | retained_earnings | | none |
| `interchange_revenue` | revenue | credit | revenue | | none |
| `fee_revenue` | revenue | credit | revenue | | none |
| `interest_expense` | expense | debit | interest | | none |
| `platform_rev_share_expense` | expense | debit | cost_of_revenue | | none |
| `credit_loss_expense` | expense | debit | credit_losses | | none |

Six things in that table are not obvious, and each of them is a way to get the books wrong:

- **`normal_balance` is not derivable from `category`.** `allowance_for_credit_losses` is an
  **asset** with a **credit** normal balance, because it subtracts from receivables. Store both.
- **Restricted cash is its own line.** Customer funds held FBO must not share a caption with the
  operator's own liquidity: Reg S-X 5-02.1 requires separate disclosure and ASC 230-10-45-4 (as
  amended by ASU 2016-18) requires restricted cash to be identified. Mapped to `cash`, unrestricted
  liquidity is overstated by the entire float — a number both a lender and a covenant read.
- **`ach_pull_returnable` is a liability, not an asset.** ACH-collected cash that can still come
  back R01 is *owed back* until the return window closes. Typed asset/debit it presents a negative
  asset for the length of the window.
- **Provision for credit losses is its own income-statement caption**, not a component of cost of
  revenue. Buried there, credit performance is invisible.
- **`due_to_tenants` is `per_shard`, not `shared`.** One operator-side account per scope collapses
  opposite-sign positions against *different* tenants into one number: owing t1 425.00 while t2 owes
  425.00 prints a payables line of zero. IAS 32.42 and ASC 210-20-45-1 permit offset only between
  the same two parties with an enforceable right of setoff.
- **`is_perimeter` and `counterparty_scope` are declarative.** No view, function or test reads
  either, so a wrong value is undetectable — mutation testing flips it and nothing fails.
  `is_perimeter` asserts "this account mirrors exactly one external balance and must reconcile
  against it", and nothing reconciles yet. A `CHECK` could not help: the column is a claim about the
  world, not about the row. Recorded as open in ADR-0009.

`retained_earnings` has nothing written to it — there is no closing process yet, so un-closed
earnings appear as the derived `current_year_earnings` line in the `balance_sheet` view.

## Reading a balance, and the trap in the as-of query

`posted` — what the customer owes — is read straight off the ledger, with no cache and no second
copy to drift. Every entry carries the running balance of its account at that moment.

```sql
-- current balance: one index lookup, no scan. tenant_id is not optional: it leads
-- every index, so without it this plans as a Seq Scan plus a Sort.
SELECT balance_after FROM ledger_entries
WHERE tenant_id = :tenant AND account_id = :acct
ORDER BY account_seq DESC LIMIT 1;

-- balance as of a past RECORDING instant. The ORDER BY must match
-- ix_entries__asof_recorded, NOT the balance index above.
SELECT balance_after FROM ledger_entries
WHERE tenant_id = :tenant AND account_id = :acct AND recorded_at <= :as_of
ORDER BY recorded_at DESC, account_seq DESC LIMIT 1;
```

**The as-of query is not "the same lookup with one more predicate".** Once `recorded_at` is a range
predicate, ordering by `account_seq` alone cannot be served by
`(tenant_id, account_id, recorded_at DESC, account_seq DESC)`, so the planner walks the balance
index backwards discarding rows. `ix_entries__asof_recorded` exists for exactly this query; the
ordering above is what reaches it.

Two limits on what that second query answers. It is a *recording*-axis question only: a business-date
balance must aggregate over `effective_at`, because a backdated entry lands with a later sequence
number ([ADR-0003](./decisions/0003-bitemporal-balances.md)). And it is **not yet reproducible** —
`recorded_at` defaults to transaction *start* time and is not monotonic with commit order, so the
same as-of query can re-run to a different answer ([ADR-0005](./decisions/0005-reproducible-as-of.md)).

## Edge cases that decide whether you've built this before

| Case | What breaks |
| --- | --- |
| **Hold expiry** | Holds must drop after ~5–7 days (longer for T&E). Never expiring them silently bleeds available credit and declines customers who have headroom. |
| **Forced post** | Clearing with no prior authorization — offline terminals, in-flight purchases, network stand-in. You must accept it, and it can exceed the limit. **Negative available credit is a valid state, not an assertion failure.** |
| **Clearing ≠ auth** | Tips, fuel pumps ($1 auth → $95 clearing), hotel incidentals. Partial captures, multiple captures per auth, incremental auths. |
| **Clearing before auth** | Happens. The state machine must be **order-tolerant**, not merely idempotent. |
| **Auth↔clearing matching** | No clean foreign key. Network IDs (ARN, RRN) don't reliably agree across messages. Needs exact match, then fuzzy fallback on card+merchant+amount±tolerance+window, then an **explicit unmatched queue** — never a silent guess. |

## The card lifecycle

One $500 purchase, row by row. **Available credit does not move during clearing** — the money only
changes buckets. It moves when they spend, and again when they pay.

| Account | open | 01 | 02 | 03 | 04 | 05 | 06 | 7.1 | 7.2 | 7.3 | 08 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| customer_receivable | 0 | 0 | 300.00 | 500.00 | 500.00 | 500.00 | 500.00 | 500.00 | 500.00 | 0 | 0 |
| operating_cash | 66.00 | 66.00 | 66.00 | 66.00 | 491.00 | 0 | 0 | 0 | 500.00 | 500.00 | 68.76 |
| network_settlement_pay | 0 | 0 | 294.60 | 491.00 | 491.00 | 0 | 0 | 0 | 0 | 0 | 0 |
| ach_pull_returnable | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 500.00 | 0 | 0 |
| facility_borrowings | 0 | 0 | 0 | 0 | 425.00 | 425.00 | 425.00 | 425.00 | 425.00 | 425.00 | 0 |
| accrued_interest_pay | 0 | 0 | 0 | 0 | 0 | → | → | 3.54 | 3.54 | 3.54 | 0 |
| platform_rev_share_pay | 0 | 0 | 1.62 | 2.70 | 2.70 | 2.70 | 2.70 | 2.70 | 2.70 | 2.70 | 0 |
| interchange_revenue | 0 | 0 | 5.40 | 9.00 | 9.00 | 9.00 | 9.00 | 9.00 | 9.00 | 9.00 | 9.00 |
| interest_expense | 0 | 0 | 0 | 0 | 0 | → | → | 3.54 | 3.54 | 3.54 | 3.54 |
| platform_rev_share_exp | 0 | 0 | 1.62 | 2.70 | 2.70 | 2.70 | 2.70 | 2.70 | 2.70 | 2.70 | 2.70 |
| **held** | 0 | 500 | 200 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| **available** | 10,000 | 9,500 | 9,500 | 9,500 | 9,500 | 9,500 | 9,500 | 9,500 | 9,500 | 10,000 | 10,000 |

Opening cash of 66 is equity — it fills the gap the 85% advance rate leaves on every transaction.
`→` = accruing daily from step 04, reaching 3.54 by step 07 (425 × 10% × 30/360). Check the
equation at any column: after 05, assets `500 + 0`, liabilities `0 + 425 + 2.70`, equity
`66 + 9.00 − 2.70`. Both sides 500. Untouched by a card trace but present in the chart:
`fbo_cash`, `customer_wallet`, `allowance_for_credit_losses`, `fee_revenue`, `credit_loss_expense`,
`due_from_treasury`, `due_to_tenants`, `paid_in_capital`, `retained_earnings`.

**01 · Authorization** — *processor, synchronous, ~1s deadline.* A hold row is written for 500,
unconsumed, approved. **The ledger records nothing**: an authorization creates no obligation.
Nothing is owed until it clears, and it may never clear. **available 9,500** = 10,000 − 0 posted −
500 held.

**02 · Partial clearing, $300** — *the merchant shipped half the order.* The hold's cleared amount
becomes 300; 200 is still reserved. Two ledger transactions, one per obligation:

```
evt_clear_1:posting    DR customer_receivable      300.00
                       CR network_settlement_pay   294.60
                       CR interchange_revenue        5.40
evt_clear_1:revshare   DR platform_rev_share_exp     1.62
                       CR platform_rev_share_pay     1.62
```

You never owed Visa 300 — at clearing the settlement obligation is *already net of interchange*, so
it is one event and one balanced transaction. The revenue share is the same event under a second
idempotency key, because it is a different obligation with its own lifecycle: you pay the platform
monthly, not per transaction. **available 9,500**, unchanged — 300 moved from held to posted.

**03 · Final clearing, $200** — the hold is fully consumed and contributes 0 to held from here.
`evt_clear_2:posting` posts `DR customer_receivable 200.00 / CR network_settlement_pay 196.40 /
CR interchange_revenue 3.60`, and `evt_clear_2:revshare` posts 1.08 each way. Settlement payable is
now 294.60 + 196.40 = 491.00 — exactly the wire in step 05. **available 9,500**, still unchanged.

**04 · Facility draw** — *treasury, batched daily, not per transaction.*
`DR operating_cash 425.00 / CR facility_borrowings 425.00`, an 85% advance rate on 500; the other 66
is equity, already there. **available 9,500** — your funding has nothing to do with their exposure.

**05 · Network settlement** — *Visa, net and batched: you wire 491, not 500.*
`DR network_settlement_pay 491.00 / CR operating_cash 491.00`, both to zero. The 9 you kept was
never a receipt — it is the gap between what they owe you and what you owed Visa.
**available 9,500**, unchanged.

**06 · Statement closes** — *cycle boundary, in the customer's timezone.* **No writes anywhere.** A
statement is a read over posted entries in a date window; not every business event is a ledger
event. (Fees are the exception; they post.) **available 9,500**, unchanged.

**7.1 · Repayment initiated** — *statement due date, ACH debit submitted.* The transfer row goes to
`submitted`; **the ledger records nothing.** Money *out* commits at initiation, money *in* commits
at settlement: a bill-pay debit posts pending immediately, because you have promised it and the
customer's wallet claim is gone, while a repayment posts nothing because they might not deliver.
Same rail, opposite direction, opposite treatment, because the risk runs the other way.
**available 9,500** — they still owe 500 until the money is actually ours.

**7.2 · Funds land** — *~2 banking days; the cash is in the account, and reversible.*
`evt_pull:settle` posts `DR operating_cash 500.00 / CR ach_pull_returnable 500.00`. The cash is real
and in your bank, and **the receivable is untouched**: corporate ACH (CCD/CTX) can still come back
R01 for ~2 banking days, so you hold a matching liability instead of extinguishing the debt.
**available 9,500** — cash in hand, credit still not released.

**7.3 · Return window closes** — *durable timer; the money is finally yours.* `evt_pull:final` posts
`DR ach_pull_returnable 500.00 / CR customer_receivable 500.00`. Only now is the debt extinguished.
Release credit at 7.1 and they spend money that never arrived; release at 7.2 and they spend money
that gets clawed back. The 2-day corporate window is short enough that risk-based instant release is
a viable **product** — but that is a decision, not a default. **available 10,000**.

**08 · Repay the facility** — *treasury: principal, accrued interest, platform share.*
`DR facility_borrowings 425.00`, `DR accrued_interest_payable 3.54` (425 × 10% × 30/360) and
`DR platform_rev_share_payable 2.70` (30% of the 9), all against `operating_cash`, which goes
66 → 68.76. Profit 2.76 = 9.00 − 3.54 − 2.70. **available 10,000**, all liabilities zero.

### Branches — the same trace when it doesn't go cleanly

**A · Clearing never arrives** *(durable timer, ~7 days after step 01)*. The hold expires and its
contribution to held goes to 0; the ledger records nothing, because nothing was ever owed.
Merchants are *supposed* to send an authorization reversal for what they don't capture, and many
don't — expiry is the backstop, not the exception. If a clearing turns up after expiry you still
accept it: that is a forced post, and it can push the company over its limit. **available 10,000**.

**B · Over-capture** *(a $1 fuel-pump auth clearing at $95)*. Held is
`GREATEST(1 − 95, 0) = 0`, not −94 — without the clamp this **silently raises** their available
credit. The ledger posts `DR customer_receivable 95 / CR network_settlement_pay 95`; 94 of that was
never reserved. Posted can jump past what was held, which is why exceeding the limit has to be a
**legal state**, not an assertion. **available drops 95**, on a hold that only ever reserved 1.

**C · Authorization reversal** *(the merchant voided the sale)*. The hold is voided and the full
amount released immediately. The ledger records nothing — unless a partial had already cleared, in
which case that part stays, because it is real debt. Only the unconsumed remainder is released.

### What the trace is showing

Available credit is flat at 9,500 through steps 02–06. Clearing, settlement and the facility draw
all move money, and none of them change what the customer can spend. **Held and posted are the same
money at two stages of its life**, so the handoff between them nets to zero — which is why closing
the hold and raising posted must happen in one transaction. Split them and the customer sees a
phantom limit change in one direction or the other.

And only four of these eight steps move cash. Interchange and interest — the entire P&L — live in
steps where no money moved anywhere on earth.

---

*Sources: docs.tigerbeetle.com · docs.moderntreasury.com · developer.squareup.com/blog/books*
