# Glossary

Every term this project uses that you'd only know if you'd built a ledger before. Examples come
from the [reference product](/card), the [decisions](/decisions), or something we measured.

## Accounting

**Double-entry** — every transaction moves money *between* accounts, so it always has at least
two sides that cancel out. A $500 sale is 500 out and 500 in: the customer owes us 500, we owe the
seller 491, we keep 9 as fee ([worked through](/database)). A transaction that doesn't balance is
meant to be *unrepresentable* rather than rejected — the writer never builds one
([ADR-0005](/decisions/0005-event-log-and-write-path)).

**Debit / credit** — the two sides. Not "money in / money out": which one *increases* an account
depends on the account. Debits increase assets and expenses; credits increase liabilities, equity
and revenue. Above, a debit increases what the customer owes us (an asset) and a credit increases
what we owe the seller (a liability). Both are "more".

**Normal balance** — which side an account normally sits on. `customer_receivable` is
debit-normal; `interchange_revenue` is credit-normal.

**Contra account** — an account that sits on the *opposite* side from its category.
`allowance_for_credit_losses` is an **asset** with a **credit** normal balance, because it
subtracts from receivables. This is the reason normal balance cannot be computed from category —
you have to store both.

**Category** — one of exactly five: asset, liability, equity, revenue, expense. This is what rolls
up into financial statements.

**Chart of accounts** — the list of account *types* a business uses (`customer_receivable`,
`interchange_revenue`, …). Not the same as the accounts themselves: one type can have thousands of
instances, one per customer.

**Trial balance** — every account and its balance, listed. Should always balance.

**Accounting equation** — `assets = liabilities + equity + (revenue − expense)`. If every
transaction balances and every account is categorised correctly, this holds automatically, at
every instant. See [spike 004](/spikes/004-chart-of-accounts).

**Control account / subsidiary ledger** — the centuries-old pattern for "one reported number, many
underlying accounts": the control account carries the total, the subsidiary ledger holds the
detail, and the two must reconcile. Accounts receivable ↔ one account per customer is the classic
case.

**Clearing account** — a designed staging account money passes *through* on its way somewhere,
expected to return to zero. Legitimate. **Suspense account** — a holding pen for entries you
couldn't classify. A recognised control risk, and a word that makes auditors nervous. Don't name
things "suspense".

**Period close** — freezing a period's books and carrying forward the closing balances. Relevant
to us because it's what bounds an otherwise unbounded scan when computing historical balances.

## This ledger

**Entry** — one line: this account, this direction, this amount. **Transaction** — a balanced set
of entries. **Account** — the thing entries attach to.

**Balance cache** (`ledger_account_balances`) — one row per account holding what it is worth *now*,
so reading a current balance is a primary-key lookup instead of summing history. It is also the row
a writer locks, which is what serializes two people spending the same money.

**Running balance** — a balance stored on *each entry*, giving the account's total immediately after
that entry. This ledger has **no such column**: it had one and
[spike 009](/spikes/009-where-the-balance-lives) dropped it, because a running balance is only
correct on the order rows were *inserted*, and every question anyone asks is about the date the money
*moved*.

**Recorded date vs effective date** — *when we learned about it* vs *when it happened*. A card
clearing arrives Tuesday for a purchase Visa dates to Monday. Recorded = Tuesday, effective =
Monday. Keeping both is called **bitemporal**.

**Backdating** — an entry arriving with an effective date earlier than entries already recorded.
Normal in payments: late clearings and chargebacks are inherently backdated. It is why a running
balance cannot answer "balance as of business date T", and why this ledger stores none — see
[ADR-0006](/decisions/0006-time-and-as-of).

**Idempotency key** — a key on an incoming event so a retry doesn't post it twice. The network
*will* send the same clearing more than once.

**Perimeter account** — an account mirroring exactly one real external balance, like a bank
account. `operating_cash` is one. The money is physically in one place, so this kind of account
**cannot be split** — which is why not every transaction can be made tenant-local.

**House account** — an account belonging to the operator rather than a customer:
`interchange_revenue`, `network_settlement_payable`.

**Tenant-local** — a transaction whose every entry belongs to one tenant. Matters because a
transaction spanning tenants makes each tenant's own books not balance ([measured: a tenant sees
−500.00](/spikes/004-chart-of-accounts)), and blocks ever splitting tenants across
databases.

## Card processing

**Authorization** — the merchant asks "is this card good for $500?" and you answer in about a
second. **It writes no ledger entry**, because nothing is owed yet — you record a *hold* and start
a timer.

**Hold** — the reservation an authorization creates. Reduces available credit; may never become a
real charge.

**Clearing** — the merchant actually claims the money, usually days later. *This* is when the
ledger first records anything.

**Settlement** — money physically moves between banks. Net and batched: you wire Visa 491, not 500.

**Interchange** — the cut the card issuer keeps, ~1.8% here. It's revenue that appears at clearing
without any money moving.

**Partial capture** — a $500 authorization clearing as $300 then $200. **Over-capture** — a $1 fuel
pump authorization clearing at $95. **Forced post** — a clearing with no authorization at all
(offline terminal). All three are normal, and all three break naive designs.

**MCC** — merchant category code. Used for spend controls ("no gambling").

## The hold model

An authorization is not one message. A purchase can produce an authorization, several increments, a
reversal and several clearings, arriving in any order and sometimes twice. The designed model
([ADR-0001](/card/decisions/0001-authorization-holds)) keeps every message as an immutable row in
`card_auth_events` and derives the hold from them. That DDL is written and **parked** in
[`parked/card/`](/card/parked); no migration applies it.

**`group_key`** — the identifier that ties those messages together as *one* authorization. It is not
something the processor reliably tells you: network IDs (ARN, RRN) don't agree across messages, so
grouping is an *inference* — exact match, then a fuzzy fallback, then an unmatched queue. Because an
inference is revisable, `group_key` lives on `card_auth_event_group`, a bitemporal membership table,
and never on the event itself. Re-grouping a mis-matched clearing is then a new membership row, not
an `UPDATE` to a row we call immutable.

**`total_minor`** — the group's running net total: increases minus clearings and reversals. It can
go negative, and that is information, not a bug (see over-capture).

**`held_minor`** — what actually reduces available credit. A generated column: zero once the group
has expired, otherwise `GREATEST(total_minor, 0)`. The clamp is what stops a $1 fuel authorization
clearing at $95 from *raising* the customer's credit by 94.

**`authorized_minor`** — the running sum of the *increase-side* deltas only, ignoring clearings and
reversals. A processor restating a cumulative total is restating this number, not the net total.
Derive the delta from the net total instead and the answer depends on arrival order — the same three
messages produce different holds in different orders, with no error raised.

**`total_convention`** — whether a group's increase-side messages carry **deltas** ("add 20.00") or
cumulative **totals** ("the authorization is now 120.00"). Fixed by the first message in the group.
Mixing the two is irreconcilable and must be refused rather than guessed: a total arriving *before*
the delta it restates carries no information saying it already includes it, so `{+100.00 delta,
120.00 total}` yields 120.00 in one order and 220.00 in the other. Within one convention, order
tolerance holds — deltas commute, and totals resolve to the highest total seen.

## Performance

**Hot account** — an account touched by nearly every transaction, so every writer queues on the same
row. `network_settlement_payable` is ours. [Spike 003](/spikes/003-throughput-ceiling) put a single
shared row in the high hundreds of clearings per second on one machine — a shape, not a number, and
[the vision](/vision#performance) says how far it moved on a re-audit. This is a named,
forty-year-old problem: it is the branch record in the 1985 DebitCredit benchmark.

**Contention** — writers waiting on the same row. The ceiling above is contention, not CPU or
disk, which is why a bigger instance doesn't help.

**Striping** — storing one logical account as N physical rows so writers spread across them;
balance = sum of the stripes. **Not built** ([roadmap](/roadmap)). Measured in [spike
003](/spikes/003-throughput-ceiling) only, on the same single machine as the figure above:
872 → 6,970 clearings/s at 64 stripes.

**Skew** — how unevenly traffic is spread across customers. Uniform = everyone equal; skewed = one
customer is most of your volume, which is what real platforms look like. It matters because giving
each tenant its own accounts gives 9.1× under uniform load but only 1.07× at 90/10 skew — the big
tenant's own account just becomes the new hot row. Striping is immune to this.

**Coalescing / batching** — combining many postings to one account into a single write. Worth
~4.4× on its own.

**Round trip** — one request to the database and back. Cheap on localhost, ~10× more on managed
Postgres — which is why our local numbers are not publishable figures.
