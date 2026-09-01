# The reference product — an embedded card ledger

**This is the product OpenLedger's reference implementation targets, not the project's
requirements.** OpenLedger is a general double-entry ledger; see [`vision.md`](/vision) for why,
and [ADR-0002](/decisions/0002-scaling) for the decision that made this document
a product spec rather than a system spec.

**The reasoning behind the system lives in [`decisions/`](/decisions)** — the stack, the scaling
model, the write path, the two time axes, and the hold model, one file each. This document carries
the two things an ADR cannot: **the chart of accounts in detail**, and **the card lifecycle in
text**, where each step can be diffed, grepped and argued with.

Two things to hold while reading. Durable timers run **in-process on Postgres**
([card 0001 · authorization holds](/card/decisions/0001-authorization-holds)), not on an external workflow engine. And the hold
tables named in the trace below are the *shape* of the design, not what shipped: `card_holds`,
`credit_lines`, `spend_controls` and `card_transactions` do not exist. The hold model is **written and parked** as an
append-only trio — `card_auth_events`, `card_auth_event_group`, `card_hold_groups`
([card 0001 · authorization holds](/card/decisions/0001-authorization-holds)) — in
`parked/card/schema.sql`, which **no migration applies**. The
credit-line and spend-control tables were never written at all (roadmap M7).

## The thesis

> The ledger is four systems wearing one name.

A v1 ledger built for one product — a charge card funded by a credit line — ends up the system of
record for **customer funds**, a **lender's collateral**, and the **financial statements**. Three
different masters, one table. Product surface assumed: charge card + wallet + AP/AR,
warehouse-funded receivables, we own the authorization decision, delegated KYB/KYC.

**An authorization moves no money and writes no *posted* ledger entry.** It records a hold and starts
an expiry timer; the ledger first hears about the purchase at **clearing**, which is also when
interchange is recognized. That is **our choice, not the field's** — about half the systems surveyed
write a durable, balance-affecting row at authorization time and about half keep it outside the
ledger as we do. [Spike 002](/card/spikes/002-processor-hold-semantics) has the split per
vendor; it is not repeated here, because a list in two places drifts out of step with itself.
See also [card 0001 · authorization holds](/card/decisions/0001-authorization-holds).

## The chart of accounts

Twenty account types, seeded by `schema/chart.sql` — **seed data, not
engine**: a marketplace or wallet deployment ships a different chart against the same core. Each
type declares its `category` (which rolls up the financial statements), its `normal_balance` (which
side it sits on), and the `fs_line` it maps to (the caption it appears under). Completeness comes
from enumerating this table rather than from listing whatever accounts have entries — see
[ADR-0007](/decisions/0007-schema-conventions-and-chart).

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
| `outbound_transfer_in_transit` | liability | credit | customer_funds | | per_shard |
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
- **`is_perimeter` and `counterparty_scope` are now read, not merely declared.**
  `counterparty_scope` is held by a composite foreign key onto `account_types` and linted by
  `chart_lint`: a `per_shard` type in a house account, a `shared` type keyed to many owners, or a
  `none` type on an owner-keyed account each raise an error
  ([ADR-0012](/decisions/0012-chart-governance)). `is_perimeter` asserts "this account mirrors
  exactly one external balance and must reconcile against it", and now something does — `perimeter_drift`
  compares that balance against a third party's attestation in `perimeter_attestations`, `chart_lint`
  flags a perimeter account carrying entries with no attestation (and an attestation against a
  non-perimeter type), and mirrored pairs net out through the `cross_scope_mirror` reconciliation
  check ([ADR-0010](/decisions/0010-reconciliation)). A plain `CHECK` still can't settle whether the
  external claim is right — that is what the attestation is for.

`retained_earnings` receives its balance only at period close, swept there by a `period_close`
transaction ([ADR-0011](/decisions/0011-period-close-and-report-axes)); until then, earnings posted
since the last close appear as the derived `current_year_earnings` line that the `balance_sheet_at`
function synthesises.

## Reading a balance, and the trap in the as-of query

`posted` — what the customer owes — is the ledger's own current balance, so it is a small aggregate
over that account's stripe rows. There is no running balance on the entries to read instead:
[spike 009](/spikes/009-where-the-balance-lives) dropped it, because a running balance is only
correct on the order rows were inserted in.

> **Correction, 2026-09-01 — and this one had teeth.** This section used to present the query below
> without its `SUM`, as *"one row, by primary key"*. The primary key of
> `ledger_account_balances` is **four** columns — `(tenant_id, account_id, currency, stripe)` — so on
> a striped account that predicate matches **N rows, one per stripe**, and a client reading the
> first row gets a fraction of the debt. **A fraction of the debt is more available credit**, in the
> authorization path, which is the one place on this page where being wrong low costs money.
> [ADR-0002](/decisions/0002-scaling) has always said *"every read SUMs the stripes"*; this query
> contradicted it. The defect was latent while the writer bound a literal stripe `0` and every
> account had exactly one row. **[ADR-0018](/decisions/0018-batching-and-stripe-selection) made it
> live on 2026-09-01**, and the committed e2e test
> `an_accounts_total_across_its_stripes_is_everything_that_was_posted_to_it` is what holds the
> corrected shape.

```sql
-- current balance: SUM the account's stripes. The primary key is
-- (tenant_id, account_id, currency, stripe) -- one account can hold many
-- rows, and a read that omits the SUM under-reports the balance.
SELECT sum(input - output) FROM ledger_account_balances
WHERE tenant_id = :tenant AND account_id = :acct AND currency = :ccy;

-- balance as of a pinned COMMIT cursor: an aggregate, not a lookup. The predicate
-- must match ix_entries__asof_commit (tenant_id, account_id, xact_id). tenant_id is
-- not optional -- it leads every index, and without it this plans as a Seq Scan.
SELECT sum(CASE WHEN direction = 'debit' THEN amount_minor ELSE -amount_minor END)
FROM ledger_entries
WHERE tenant_id = :tenant AND account_id = :acct AND xact_id < :cursor;
```

> **The current-balance read is the one the ~1s authorization deadline depends on**, and dropping
> the running balance made it slightly worse, not better: `ledger_account_balances` is rewritten on
> every posting to that account, so a hot account's rows never get their visibility-map bit set and
> the read always visits the heap. It is one heap fetch per stripe — one row on an unstriped
> account, and up to `stripe_count` on a hot one, which is the cost striping trades for write
> throughput. Spike 009 took that trade deliberately, and the card rail is where it is felt first.

**The as-of query is not "the current balance with one more predicate".** It cannot be, now: the
current balance is a different table. `ix_entries__asof_commit` exists for exactly the second
query, and the predicate above is what reaches it — written any other way the planner scans and
discards.

Two limits on what that second query answers. It is a *commit*-axis question only: a business-date
balance must aggregate over `effective_at` instead — on `ix_entries__effective` — because a backdated
entry lands with a later `xact_id` than the business date it belongs to
([ADR-0006](/decisions/0006-time-and-as-of)). And the cursor is a **horizon, not an instant**:
pinning `pg_snapshot_xmin(pg_current_snapshot())` makes an issued statement reproducible, but it also
lags the newest writes by the longest in-flight transaction — the price of committing without a
global lock ([ADR-0006](/decisions/0006-time-and-as-of)).

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

*(**A note added 2026-09-01, after someone tried to replay this trace against the shipped core.**
The hold in this walkthrough is the **card module's** hold — `parked/card/schema.sql`, unbuilt, M7 —
and it tracks *partial consumption*: 500 held, then 300 cleared with 200 still reserved. The core's
own `pending` transaction does not work that way. `uq_txn__one_supersession` gives a pending
transaction **exactly one fate** ([ADR-0016](/decisions/0016-pending-to-posted)), so a second
resolution of the same pending is refused with `target_already_superseded` — measured against the
running binary. Both models are correct for what they are, and neither is a defect: a hold is a
card-network construct with its own lifecycle, while a pending transaction is a claim about money
that resolves once. But steps 02 and 03 below **cannot be posted as two resolutions of one pending
transaction**, and anyone mapping this trace onto core primitives has to decide which capture
carries the `resolves_id`.)*

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
