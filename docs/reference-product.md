# v1 Vision — Embedded Card Ledger

> **This is the reference product specification, not the project's requirements.**
>
> openledger is a general open-source double-entry ledger — see [`vision.md`](./vision.md) for
> the project vision, and [ADR-0007](./decisions/0007-open-source-positioning.md) for the
> decision that made this document a product spec rather than a system spec.
>
> This document describes the embedded B2B charge card product that openledger's *reference
> implementation* targets. It remains the best description of the card domain we have, and its
> [lifecycle trace](#06--lifecycle-one-500-purchase-row-by-row) is still M0's acceptance test.
>
> Two corrections. The original specified **Temporal** for durable timers; that is superseded by
> [ADR-0008](./decisions/0008-durable-timers.md), which runs them in-process on Postgres — the
> design is otherwise unchanged, since every timer here is one-shot. And **§01's sizing is
> superseded** by
> [spike 003](../spikes/003-throughput-ceiling/README.md), which measured the design instead of
> reasoning about one known workload. Its "throughput is not the constraint" conclusion happens
> to survive, but the argument behind it does not transfer to a project that cannot know its
> users' volume.

> Source: extracted from the original design board. The three diagrams are in
> [`diagrams/`](./diagrams/) and embedded below.
>
> Status: **vision / v1 plan**. Not yet decomposed into work. See [`roadmap.md`](./roadmap.md).

## Thesis

> The ledger is four systems wearing one name.

A v1 ledger built for one product — a charge card funded by a credit line — ends up the
system of record for **customer funds**, a **lender's collateral**, and the **financial
statements**. Three different masters, one table.

Product surface assumed: charge card + wallet + AP/AR, warehouse-funded receivables, we own
the auth decision, delegated KYB/KYC. Small team, boring tech: **Postgres**.

---

## 01 — Size it before designing

> **Superseded** by [spike 003](../spikes/003-throughput-ceiling/README.md), which measured the
> ceiling rather than deriving it from one product's volume. The reasoning below is sound for
> *this* product and does not generalise. Kept for the product context.

Throughput is not the constraint.

- $30M facility ÷ ~35-day receivable turn ≈ **$100–300M/yr** of card spend at full utilization.
- At a $150–400 average B2B ticket: **30k–150k transactions/month**.
- Under **1 TPS** average, maybe **20–50 TPS** at Monday-morning peak.

A single Postgres instance handles this on a laptop. The real constraints are:

1. **Correctness** — every cent, no manual fixes.
2. **Auditability** — reproduce any number as of any date, forever.
3. **One latency-bound path** — the auth decision.
4. **Product surface area** — one engine serving six products without forking.

> Anyone who opens by sharding the ledger has misread the problem.

---

## 02 — Architecture: the hot path is not the ledger write

![Architecture: external systems, services, Postgres stores, and which path is inside the
authorization deadline](./diagrams/01-architecture.svg)

The only synchronous work inside the auth deadline is one short transaction against a single
company's row.

**An authorization moves no money and writes no ledger entry.** It records a hold and starts
an expiry timer. The ledger first hears about the purchase at the **clearing** event, which is
also when interchange is recognized — and that is what reaches back to close the hold. The
hold row carries its own `expires_at`, so nothing has to be handed forward at auth time.

Everything with a timer — hold expiry, clearing, settlement, ACH return windows, disputes,
statements — runs as a durable scheduled job calling **idempotent** ledger activities.

---

## 03 — The auth decision

> ⚠️ **This section is a specification, not a description of what exists.** `card_holds`,
> `credit_lines`, `spend_controls` and `card_transactions` are **not** in `migrations/`. The hold
> model shipped instead as `card_auth_events` + `card_auth_event_group` + `card_hold_groups`
> ([ADR-0010](./decisions/0010-authorization-holds.md)); the credit-line and spend-control tables
> are unbuilt (roadmap M7). The SQL below shows intended *shape* — none of it runs against the
> current schema, and its index comment is wrong for it besides: every shipped index leads with
> `tenant_id`, so a lookup that omits it plans as a Seq Scan plus a Sort.


![The authorization latency budget: ~1000ms before the processor applies your default, with a
p99 target around 300ms](./diagrams/02-auth-hot-path.svg)

The deadline (~1s) is generous relative to the work. The design goal is not speed — it is
**never being the reason the deadline is missed**, because the failure mode is the network
standing in and approving on your behalf.

### Before the transaction: pure config reads, no lock, fail fast

| Gate | Check |
| --- | --- |
| card active? | `spend_controls.active AND card.status = 'active'` |
| MCC allowed? | `mcc NOT IN blocked_mcc AND (allowed_mcc IS NULL OR mcc IN allowed_mcc)` |
| merchant allowed? | per-txn cap? |

Any failure → decline with a reason code, write the hold `closed`, return. **Never take the
lock for an auth you were always going to decline.** This same read yields `cap_minor` and
`period` → `period_start`, used in step 5. Racing a concurrent cap change is harmless; config
isn't worth locking.

### The transaction

```sql
BEGIN;

-- 1. lock the credit line. serializes ALL of this company's cards.
SELECT limit_minor, receivable_account_id
FROM credit_lines
WHERE company_id = :company
FOR UPDATE;

-- 2. POSTED = what they already owe. read straight off the ledger.
--    index lookup on (account_id, account_seq DESC). no cache anywhere.
SELECT balance_after AS posted_minor
FROM ledger_entries
WHERE account_id = :receivable_account
ORDER BY account_seq DESC
LIMIT 1;

-- 3. HELD = the UNCONSUMED part of open auths. derived, bounded.
--    both grains in ONE pass -- a card's holds are a subset of its company's.
SELECT
  COALESCE(SUM(GREATEST(amount_minor - cleared_minor, 0)), 0) AS company_held,
  COALESCE(SUM(GREATEST(amount_minor - cleared_minor, 0))
           FILTER (WHERE card_id = :card), 0)                 AS card_held
FROM card_holds
WHERE company_id = :company AND state = 'open';

-- 4. CARD periodic budget. same lock, same race -- two auths on one card
--    could otherwise both slip past a $2k monthly cap.
SELECT COALESCE(SUM(amount_minor), 0) AS card_spend
FROM card_transactions
WHERE card_id = :card AND posted_at >= :period_start;

-- 5. the decision. EVERY gate must pass; record WHICH one failed.
--      available   = limit_minor - posted_minor - company_held
--      credit ok?  available >= :amount
--      budget ok?  card_spend + card_held + :amount <= cap_minor

-- 6. THE INSERT IS THE REDUCTION. there is no counter to decrement --
--    the next auth's SUM simply sees one more open row.
INSERT INTO card_holds (auth_id, company_id, card_id, amount_minor,
                        state, decision, decline_reason)
VALUES (:auth, :company, :card, :amount,
        CASE WHEN :decision = 'approved' THEN 'open' ELSE 'closed' END,
        :decision, :reason)
ON CONFLICT (auth_id) DO NOTHING
RETURNING decision;
-- no row back => duplicate; return the STORED decision

COMMIT;
```

**One lock covers both gates.** Locking the company serializes every card under it, so the
per-card check is protected for free. Coarser than strictly necessary; at under 1 TPS that
costs nothing.

`decline_reason` is not logging. It picks the network response code — 51 insufficient funds
vs 57 not permitted vs 62 restricted — which is what the cardholder sees at the terminal, and
what support gets asked about.

**A declined auth still gets a row**, with `state = 'closed'` so it never counts toward held.
You need it for the retry path: a duplicate of a decline *must* also return the stored
decision, not be re-evaluated against a limit that may have moved.

### `posted` comes from the ledger — no cache, by construction

Rather than materialize the balance into a second table, carry a **running balance on the
entry itself**. Reading it is an index lookup; recomputing it from scratch verifies it; and
there is no second copy that can drift.

```sql
-- current balance: one index lookup, no scan, no cache.
-- tenant_id is not optional -- it leads every index, and without it this
-- plans as an index scan PLUS a sort.
SELECT balance_after FROM ledger_entries
WHERE tenant_id = :tenant AND account_id = :acct
ORDER BY account_seq DESC LIMIT 1;

-- balance as of a past RECORDING instant. Note the ORDER BY: it must match
-- ix_entries__asof_recorded, not the balance index.
SELECT balance_after FROM ledger_entries
WHERE tenant_id = :tenant AND account_id = :acct AND recorded_at <= :as_of
ORDER BY recorded_at DESC, account_seq DESC LIMIT 1;
```

**Two corrections. The shape below is asserted by `tests/query_plans.sql`; the millisecond figures
are not** — they came from a 2M-entry account whose harness is not in the repo. The shipped plan
test builds 200,000 rows and reports ~36,000 rows removed by filter: same shape, smaller numbers.

This block previously wrote the second query with `ORDER BY account_seq DESC` and called it *"the
same lookup, one more predicate"*. It is not. Once `recorded_at` is a range predicate, that ordering
cannot be served by `(tenant_id, account_id, recorded_at DESC, account_seq DESC)`, so the planner
walks the balance index backwards discarding rows: **253 ms and 1,439,915 rows removed by filter,
against 0.066 ms** for the version above. `ix_entries__asof_recorded` exists in `0001` and no query
in the docs could use it.

It also called this *"what makes lender reporting reproducible"*, which
[ADR-0005](./decisions/0005-reproducible-as-of.md) says in terms it is **not**: `recorded_at`
defaults to transaction *start* time and is not monotonic with commit order, so the same as-of query
re-runs to a different answer. And per [ADR-0003](./decisions/0003-bitemporal-balances.md) this
answers a *recording*-axis question only — a business-date balance must aggregate over
`effective_at`, because a backdated entry lands with a later sequence number.

### Edge cases that decide whether you've built this before

| Case | What breaks |
| --- | --- |
| **Hold expiry** | Holds must drop after ~5–7 days (longer for T&E). Never expiring them silently bleeds available credit and declines customers who have headroom. |
| **Forced post** | Clearing with no prior auth — offline terminals, in-flight purchases, network stand-in. You must accept it, and it can exceed the limit. **Negative available credit is a valid state, not an assertion failure.** |
| **Clearing ≠ auth** | Tips, fuel pumps ($1 auth → $95 clearing), hotel incidentals. Partial captures, multiple captures per auth, incremental auths. |
| **Clearing before auth** | Happens. The state machine must be **order-tolerant**, not merely idempotent. |
| **Auth↔clearing matching** | No clean foreign key. Network IDs (ARN, RRN) don't reliably agree across messages. Needs exact match, then fuzzy fallback on card+merchant+amount±tolerance+window, then an **explicit unmatched queue** — never a silent guess. |

---

## 04 — Data model

### `ledger_accounts`

```
id, tenant_id,   -- tenant_id is NOT NULL and leads every key, including on
                 -- house accounts. An earlier version of this block showed it
                 -- absent from the unique indexes and blank for house rows;
                 -- the roadmap calls tenant-leading keys "the one irreversible
                 -- decision on the list", and page 283 of this document already
                 -- said every key here leads with it.
owner_type, owner_id,
purpose         -- 'customer_receivable' | 'fbo_cash' | 'interchange_revenue'.
                --  finds the account, and groups it for reporting.
category        -- 'asset'|'liability'|'equity'|'revenue'|'expense'.
                --  rolls up the financial statements.
normal_balance  -- 'debit'|'credit'. NOT derivable from category.
                --  contra accounts diverge: allowance_for_credit_losses is
                --  category 'asset' with a CREDIT normal balance.
currency, metadata

UNIQUE (tenant_id, owner_type, owner_id, purpose, currency)
  -- covers company / platform / bank_account: owner_id is a real value.
UNIQUE (tenant_id, purpose, currency) WHERE owner_type = 'house'
  -- house rows have owner_id NULL, and NULL != NULL in Postgres, so the
  -- constraint above would happily allow a second interchange_revenue.
  -- the two cover disjoint sets.
```

`house` is for accounts there can only ever be ONE of. Anything that can legitimately have
siblings gets a real owner — which is why **cash is owned by its bank account**: a second
sponsor bank or a EUR FBO is a matter of time. That makes the reconciliation target
structural: every perimeter account has exactly one external balance that must agree with it.

`tenant_id` is the RLS scope. `owner_*` is the economic owner. They coincide sometimes — but
`tenant_id` is **never absent**. An earlier version of this table left it blank for the shared
accounts, which contradicted the shipped `NOT NULL` and the tenant-leading keys the roadmap calls
irreversible. Shared accounts belong to an operator scope (`_treasury` in the golden trace); that is
what makes a treasury movement an intercompany pair rather than a cross-tenant transaction.

| purpose | tenant_id | owner_type | owner_id |
| --- | --- | --- | --- |
| customer_receivable | platform_a | company | acme_property_mgmt |
| customer_wallet | platform_a | company | acme_property_mgmt |
| platform_rev_share_payable | platform_a | platform | platform_a |
| fbo_cash | _treasury | bank_account | bank_acct_a |
| operating_cash | _treasury | bank_account | bank_acct_b |
| network_settlement_payable | _treasury | house | — |
| facility_borrowings | _treasury | house | — |
| interchange_revenue | — | house | — |

### `ledger_transactions` — the unit of atomicity. **Status never mutates.**

```
tenant_id, id,              -- PRIMARY KEY (tenant_id, id)
event_id,                   -- the event that caused this
kind, status ('pending'|'posted'),
effective_at, recorded_at   -- both timestamptz
resolves_id, reverses_id,   -- a pending txn is resolved by a NEW txn
external_ref jsonb, metadata
```

**Idempotency is not here.** It lives on `ledger_events`, as
`UNIQUE (tenant_id, idempotency_key)` — because most of the lifecycle (authorizations, declines,
hold expiry, limit changes) writes no ledger transaction at all, so a key on this table could not
cover it. See [ADR-0004](./decisions/0004-event-log.md). Every key here leads with `tenant_id`.

Bitemporality is necessary, **not sufficient** — the bug is never in storage, it's at every
boundary that turns an instant into a bucket. Every `date_trunc`, every `BETWEEN`, every "as of".

1. `effective_at` comes from the **source's** clock, never `now()`. A clearing's is the network
   business date — Visa's cutoff, not your webhook's arrival. Use arrival and you disagree with
   their settlement report.
2. Every boundary names its zone, and they genuinely differ: statements → the customer's zone;
   facility reports → the zone in the credit agreement; close → the entity's book zone.
3. Reports pin an **instant**, not a date. Store `as_of` as timestamptz with the report, or
   "as of June 30" re-runs to a different number and you've lost the reproducibility
   bitemporality was for.

> The expensive one: payment settles 9pm local Aug 15 = 00:00 UTC Aug 16. DPD computed in UTC
> reads 1 day late → delinquency bucket → out of facility eligibility → available-to-draw
> drops. A tz bug turned treasury.

### `ledger_entries` — immutable. No UPDATE, no DELETE.

```
id, transaction_id, account_id,
direction ('debit'|'credit'),
amount_minor bigint CHECK (> 0),
currency,
account_seq  bigint  -- monotonic per account
balance_after bigint -- running balance, O(1) reads + as-of queries
UNIQUE (tenant_id, account_id, account_seq)
```

The idempotency key is scoped to the **event**, not the purchase. So pending → posted is a
NEW row, never an UPDATE:

| idempotency_key | status | resolves_id | |
| --- | --- | --- | --- |
| *(card auth writes NO ledger txn — nothing is owed until it clears)* | | | |
| `evt_clear_xyz:posting` | posted | — | txn A — receivable, payable, interchange |
| `evt_clear_xyz:revshare` | posted | — | txn B — same event, 2nd key |
| `evt_settle_88:payment` | posted | — | txn C |
| `evt_ach_init:transfer` | pending | — | txn D — ACH out: initiation IS an obligation change |
| `evt_ach_settle:transfer` | posted | D | txn E — resolves D |

### Working set — not the ledger. Bounded, mutable, indexed for the hot path.

**`credit_lines`** — lending, one per company, set by underwriting.
`company_id PK`, `tenant_id`, `limit_minor` (a **policy** attribute, never a balance, never an
account), `receivable_account_id` → ledger_accounts, `status`, `updated_at`.

**`spend_controls`** — policy, per card, set by the **customer**, not underwriting.
`card_id PK`, `company_id`, `cap_minor`, `period ('per_txn'|'day'|'month')`,
`allowed_mcc[]`, `blocked_mcc[]`, `allowed_merchants[]`, `active`.

- `period` values match `date_trunc()`'s field names **on purpose**. `'monthly'` throws at
  runtime. CHECK it.
- `per_txn` has no window: just `amount <= cap`, checked before the txn.
- `period_start = (date_trunc(period, now() AT TIME ZONE tz) AT TIME ZONE tz)` — `AT TIME ZONE`
  twice, and both are load-bearing. Drop the second and you compare a naive timestamp to
  `posted_at`.
- A monthly budget resets at the **customer's** midnight, not UTC's — otherwise it rolls over
  at 9pm on the 31st for a Florianópolis customer and declines a purchase they think is next
  month.
- Calendar-aligned (the 1st) vs statement-cycle-aligned (the 15th) is a **product** call — it
  turns `date_trunc` into a cycle lookup. Ask, don't assume.

Two tables because they are two different things:

- **credit line** = exposure cap. `limit - posted - held`. Frees up when they **pay**.
- **card cap** = periodic budget. `SUM(spend)` this period. Resets on the 1st.

The obligor is the **company**. Cards owe nothing, and the lender has never heard of them —
which is why the receivable never splits per card.

**`card_holds`**
```
id, auth_id UNIQUE      -- processor authorization id. the whole idempotency story.
company_id, card_id,
amount_minor  bigint    -- what was authorized
cleared_minor bigint    -- accumulated across N clearings. partial capture.
state    ('open'|'cleared'|'voided'|'expired'|'closed')
decision ('approved'|'declined')  -- declines land 'closed', never count
expires_at              -- durable timer target. ~7d, longer for T&E.
created_at
INDEX (company_id) WHERE state = 'open'   -- partial; makes SUM(held) an index scan
```

A hold is **partially consumed**, not open/closed:
`held = SUM(GREATEST(amount_minor - cleared_minor, 0)) WHERE company_id = ? AND state = 'open'`.

**Superseded.** This whole section describes a mutable `card_holds` row, which
[ADR-0010](./decisions/0010-authorization-holds.md) replaced with an append-only event log:
`card_auth_events` + `card_auth_event_group` + `card_hold_groups`, shipped in `migrations/0003` and
attested by [`tests/card_holds.sql`](../tests/card_holds.sql). It is kept because the *problems* it
enumerates are the real ones; the schema below is not what was built.
`GREATEST` clamps over-capture: a $1 fuel auth clearing at $95 goes to 0, not −94.

> ⚠️ **Superseded — this design was replaced.** `auth_id UNIQUE` assumes one authorization is one
> row, which the domain does not support. [ADR-0010](./decisions/0010-authorization-holds.md)
> replaced it with an append-only event log: `card_auth_events` (immutable facts),
> `card_auth_event_group` (revisable grouping, bitemporal), and `card_hold_groups` (the
> materialised per-group total). Shipped in `migrations/0003` and attested by
> [`tests/card_holds.sql`](../tests/card_holds.sql). The table below is kept because the problems
> it lists are real; the schema is not what was built.

Other rails get the same shape: `ach_transfers`, `disputes`, `statements`. The ledger is the
permanent record; these are what's still in flight.

> Append-only is **enforced, not documented** — by triggers that refuse `UPDATE`, `DELETE` and
> `TRUNCATE` outright. The narrow grant matters too, but a `REVOKE` is undone by one `GRANT ALL`,
> so it is not the mechanism.

---

## 05 — Domain state machines vs. the ledger

![Domain state machines beside the ledger: which transitions are financial events and which are
not](./diagrams/03-state-machines.svg)

Deciding **which** transitions are financial events is the actual modelling work, and it
differs per rail. Push status onto the ledger row so it can be updated and you've traded away
immutability; emit a transaction per transition and you fill the ledger with non-financial noise.

---

## 06 — Lifecycle: one $500 purchase, row by row

**Available credit does not move during clearing** — the money only changes buckets. It moves
when they spend, and again when they pay.

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

Opening cash of 66 is equity — it fills the gap the 85% advance rate leaves on every
transaction. `→` = accruing daily from step 04, reaching 3.54 by step 07 (425 × 10% × 30/360).

Check the equation at any column — after 05: assets `500 + 0`, liabilities `0 + 425 + 2.70`,
equity `66 + 9.00 − 2.70`. Both sides 500.

Also in the chart, untouched by a card trace: `fbo_cash`, `customer_wallet`,
`allowance_for_credit_losses`, `fee_revenue`, `credit_loss_expense`, `due_from_treasury`,
`due_to_tenants`, `retained_earnings`.

`outbound_transfer_in_transit` and `unapplied_receipts` were listed here too and are **not in the
chart** — they belong to a payouts flow that has not been designed.

### 01 — Authorization
*Processor · `card_authorization` · SYNCHRONOUS, ~1s deadline*

- `card_holds` **INSERT**: `auth_id=auth_abc  card=card_7  amount_minor=500  cleared_minor=0  state=open  decision=approved`
- ledger: **— nothing —**. An authorization creates no obligation. Nothing is owed until it
  clears, and it may never clear. The hold lives only in `card_holds`.
- **available 9,500** = 10,000 − 0 posted − 500 held

### 02 — Partial clearing · $300
*Processor · `card_transaction` · merchant shipped half the order*

- `card_holds` **UPDATE**: `cleared_minor = 300`, state stays `open` — 200 is still reserved
- `card_transactions` **INSERT**: merchant, mcc, 300 (expense product + card budget)
- ledger `evt_clear_1:posting`:
  `DR customer_receivable 300.00` / `CR network_settlement_pay 294.60` / `CR interchange_revenue 5.40`
  — you never owed Visa 300. At clearing the settlement obligation is **already net of
  interchange** — one event, one balanced transaction.
- ledger `evt_clear_1:revshare`:
  `DR platform_rev_share_exp 1.62` / `CR platform_rev_share_pay 1.62`
  — same event, second key. A different obligation with its own lifecycle: you pay the
  platform monthly, not per transaction.
- **available 9,500** = 10,000 − 300 posted − 200 held · *unchanged* — 300 moved from held to posted

### 03 — Final clearing · $200

*Processor · `card_transaction` · rest of the order*

- `card_holds` **UPDATE**: `cleared_minor = 500` → state = `cleared`. Fully consumed, contributes 0 to held.
- ledger `evt_clear_2:posting`: `DR customer_receivable 200.00` / `CR network_settlement_pay 196.40` / `CR interchange_revenue 3.60`
- ledger `evt_clear_2:revshare`: `DR platform_rev_share_exp 1.08` / `CR platform_rev_share_pay 1.08`
- `network_settlement_pay` now 294.60 + 196.40 = 491.00 — exactly the wire in step 05.
- **available 9,500** · *still unchanged*

### 04 — Facility draw
*Treasury · batched daily, not per transaction*

- ledger: `DR operating_cash 425.00` (85% advance rate on 500) / `CR facility_borrowings 425.00`
  — the other 66 is equity, already there.
- **available 9,500** · your funding has nothing to do with their exposure

### 05 — Network settlement
*Visa · net, batched · you wire 491, not 500*

- ledger: `DR network_settlement_pay 491.00` (→ 0, discharged) / `CR operating_cash 491.00` (→ 0, passed straight through)
- The 9 you kept was never a receipt. It's the gap between what they owe you (500) and what
  you owed Visa (491).
- **available 9,500** · unchanged

### 06 — Statement closes
*Cycle boundary · customer's timezone*

- **— no writes anywhere —**. A statement is a READ over posted entries in a date window. Not
  every business event is a ledger event. (Fees are the exception; they post.)
- **available 9,500** · unchanged

### 7.1 — Repayment initiated
*Statement due date · ACH debit submitted*

- `ach_transfers` **INSERT**: `state=submitted, 500`
- ledger: **— nothing —**
- **MONEY OUT commits at initiation. MONEY IN commits at settlement.** A bill-pay debit posts
  pending immediately — you've promised it and the customer's wallet claim is gone. A repayment
  posts nothing: they might not deliver. Same rail, opposite direction, opposite treatment,
  because the risk runs the other way.
- **available 9,500** · they still owe 500 until the money is actually ours

### 7.2 — Funds land
*~2 banking days · cash is in the account, and reversible*

- `ach_transfers` **UPDATE**: `state=settled`
- ledger `evt_pull:settle`: `DR operating_cash 500.00` / `CR ach_pull_returnable 500.00`
- The cash is real and in your bank. **The receivable is untouched** — corporate ACH (CCD/CTX)
  can still come back R01 for ~2 banking days, so you hold a matching liability instead of
  extinguishing the debt.
- **available 9,500** · cash in hand, credit still not released

### 7.3 — Return window closes
*durable timer · the money is finally yours*

- ledger `evt_pull:final`: `DR ach_pull_returnable 500.00` / `CR customer_receivable 500.00`
- Only now is the debt extinguished. Release credit at 7.1 and they spend money that never
  arrived; release at 7.2 and they spend money that gets clawed back. The 2-day corporate
  window is short enough that risk-based instant release is a viable **product** — but that's
  a decision, not a default.
- **available 10,000** · receivable zero, window closed

### 08 — Repay the facility
*Treasury · principal, accrued interest, platform share*

- `DR facility_borrowings 425.00` / `CR operating_cash`
- `DR accrued_interest_payable 3.54` / `CR operating_cash` — 425 × 10% × 30/360
- `DR platform_rev_share_payable 2.70` / `CR operating_cash` — 30% of the 9
- `operating_cash` 66 → 68.76. Profit 2.76 = 9.00 − 3.54 − 2.70.
- **available 10,000** · all liabilities zero, receivable zero

### Branches — the same trace when it doesn't go cleanly

**A · Clearing never arrives** *(durable timer fires, ~7 days after step 01)*
- `card_holds` **UPDATE**: `state = expired`, held contribution → 0
- ledger: **— nothing. nothing was ever owed. —**
- Merchants are *supposed* to send an auth reversal for what they don't capture. Many don't.
  Expiry is the backstop, not the exception. And if clearing turns up after expiry you still
  accept it — that's a forced post, and it can push the company over its limit.
- **available 10,000** · returns without the customer ever owing anything

**B · Over-capture** *($1 fuel-pump auth, $95 clearing)*
- `card_holds`: `amount_minor=1`, `cleared_minor=95` → `held = GREATEST(1 − 95, 0) = 0`, not −94.
  Without `GREATEST` this **silently raises** their available credit.
- ledger: `DR customer_receivable 95` / `CR network_settlement_pay 95`
- 94 of that was never reserved. Posted can jump past what was held — which is why exceeding
  the limit has to be a **legal state**, not an assert.
- **available drops 95** · on a hold that only ever reserved 1

**C · Authorization reversal** *(acquirer · merchant voided the sale)*
- `card_holds` **UPDATE**: `state = voided`, full amount released immediately
- ledger: **— nothing, if no clearing had posted yet —**. If a partial had already cleared,
  that part stays: it's real debt. Only the unconsumed remainder is released.
- **available 10,000** · minus anything already cleared

### What the trace is actually showing

Available credit is flat at 9,500 through steps 02–06. Clearing, settlement, and the facility
draw all move money — and none of them change what the customer can spend. **Held and posted
are the same money at two stages of its life**, so the handoff between them nets to zero. That
is why closing the hold and raising posted must happen in one transaction: split them and the
customer sees a phantom limit change in one direction or the other.

And only four of these eight steps move cash. Interchange and interest — the entire P&L — live
in steps where no money moved anywhere on earth.

---

*Sources: docs.tigerbeetle.com · docs.moderntreasury.com · developer.squareup.com/blog/books*
