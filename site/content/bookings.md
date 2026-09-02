# Booking a payment — how money movement becomes bookkeeping

**For an engineer who reads SQL and HTTP and has never had to defend a balance sheet.** It takes one
real card payment — the 500.00 purchase the [card rail](/card) traces row by row — and uses it to
teach the general skill underneath: **find the obligations in a business event, and turn each one
into a balanced transaction.**

This is not the API reference — [that is generated from the spec](/api-reference/) — and not a
decision record; [those are here](/decisions), one per question, with their evidence. This page is
the layer in between: *what* to write down when a payment happens, and why that shape rather than a
simpler one. Every term it uses is defined in the [glossary](/glossary).

The worked example is the card rail's, and its detailed ledger-by-ledger table is
[on that page](/card#the-card-lifecycle). Nothing here restates it. What is here is the seven things
you have to understand to model your *own* flow against this ledger, in the order they bite.

## 1 · One number cannot say who owes what

A cardholder buys 500.00 of goods. The merchant ships half the order, and 300.00 clears. The
instinct of anyone who has kept a `balance` column is to add 300.00 to something. But four different
facts became true at that moment, and they are true of four different parties:

- the **cardholder owes you** 300.00;
- **you owe the network** 294.60, which is what you will actually wire;
- you **kept** 5.40 as interchange, which is revenue and not a receipt;
- of that 5.40, **1.62 is promised to the platform partner** whose customer this is.

A single balance holds exactly one of those, and there is no arithmetic that recovers the other
three from it. So the event is written as two transactions, each balanced on its own:

```
evt_clear_1:posting    DR customer_receivable      300.00
                       CR network_settlement_pay   294.60
                       CR interchange_revenue        5.40

evt_clear_1:revshare   DR platform_rev_share_exp     1.62
                       CR platform_rev_share_pay     1.62
```

**You never owed the network 300.00.** At clearing the settlement obligation arrives *already net of
interchange*, so the first transaction is one event and one balanced posting set — not a gross
liability followed by a fee that claws part of it back. Booking it gross and netting later invents a
liability that never existed and a receipt that never happened.

**The revenue share is a separate transaction under a separate idempotency key**, and that is the
more transferable lesson. It is the same business event, but a different obligation with a different
lifecycle: the network settles daily, the platform monthly. Fusing them into one transaction means
you can never retire one without touching the other.

The rest of the story is the same move, repeated. The remaining 200.00 clears as
`DR customer_receivable 200.00 / CR network_settlement_pay 196.40 / CR interchange_revenue 3.60`,
with 1.08 of revenue share beside it. Treasury draws 425.00 on the warehouse line — 85% of 500.00 —
and the other 66.00 was already there as equity, because an 85% advance rate leaves a gap on every
single purchase. You then wire 491.00 to the network, which is 294.60 + 196.40, and both sides go to
zero.

**The 9.00 you kept was never a receipt.** No wire carried it, no bank statement will ever show it
arriving. It is the gap between what the cardholder owes you and what you owed the network, and it
exists only because the two obligations were recorded separately. That is the whole argument for
double-entry in one number: **the P&L lives in the difference between obligations, and a system that
tracks one net balance cannot see it.**

## 2 · The primitive is a posting, not an entry

**The smallest thing a caller can hand this ledger is a `posting`: a source, a destination, an
amount and a currency.** Money leaves one place and arrives in another, so it always has two equal
sides. Direction is carried by the `source`/`destination` pair and never by a sign — `amount_minor`
is strictly positive, always.

```json
{ "source": "…network_settlement_payable…",
  "destination": "…customer_receivable…",
  "amount_minor": "29460",
  "currency": "USD" }
```

A transaction is a list of postings. The writer expands each into two `ledger_entries` rows, one
debit and one credit, and **there is no code path that writes an entry on its own**.

That is worth being precise about, because it is the design's load-bearing choice and it is easy to
mistake for a validation rule. **An unbalanced transaction here is not rejected — it is
unconstructible.** There is no shape a caller can build that expresses a dangling leg, so no check
is needed, no check can be forgotten, and no check can be disabled by a configuration flag. The
reasoning, and the one deliberate exception, are in
[ADR-0005](/decisions/0005-event-log-and-write-path): *"a check, not a shape"* is the phrase this
project uses when it catches itself about to do the weaker thing.

Two consequences you will meet in the first hour.

**Every write carries an idempotency key, and the key covers the bytes.** Same key with the same
body replays the stored answer, and the response says so in an `Idempotency-Replayed` header. Same
key with a *different* body is refused as `idempotency_key_reused` rather than silently replaying
someone else's result. Retries are a fact of payment rails; the contract for them is stated once, in
[ADR-0005](/decisions/0005-event-log-and-write-path), and every endpoint that accepts a write
inherits it — including the ones that move no money, like opening an account or defining a period.

**Every amount on the wire is an exact-integer decimal string in minor units.** `29460`, not
`294.60` and not the JSON number `29460`. The column is a `bigint`, which reaches far past 2⁵³, and
JSON has no integer type at all: a posting of `9007199254740993` was accepted and read back as
`9007199254740992` before this was fixed ([ADR-0022](/decisions/0022-amounts-are-strings)). If your
client touches `Number` anywhere in the path, it is already wrong and has not noticed yet.

## 3 · Reading a balance's sign

**This is the single thing newcomers most reliably misread, so read it twice.**

`GET /v1/accounts/{id}/balance` answers `posted_minor`, and that number is **debit-positive**. After
both captures and before the wire, `network_settlement_payable` reads **−49100**. Nothing is wrong.
It is a liability with a **credit** normal balance, and it is holding exactly what you expect: you
owe the network 491.00.

**Debit and credit are directions, not good and bad.** A debit increases an asset and decreases a
liability; a credit does the reverse. Which direction *increases* a given account is that account's
`normal_balance`, stored on its type in the chart. It is **not derivable from the category** — the
chart's own `allowance_for_credit_losses` is an **asset** with a **credit** normal balance, because
it subtracts from receivables — which is why the column exists rather than a `CASE` expression
([ADR-0007](/decisions/0007-schema-conventions-and-chart)).

**The API returns the arithmetic value and leaves the presentation flip to the reader**, on purpose.
The trial balance is explicit about it: `balance_debit_positive` is the value you roll up with, and
`normal_balance` never enters it, *"so a contra account carries its own sign instead of being
flipped twice"*. Flip once, at the edge, where a human reads it. Flip in the middle and you will
find the double flip in production, on the one account whose category and normal balance disagree.

Two further traps in the same neighbourhood.

**A balance is a `SUM` over the account's stripes, not a row.** The primary key of
`ledger_account_balances` is `(tenant_id, account_id, currency, stripe)`, so a hot account holds
several rows and a read that takes the first one gets a *fraction* of the balance. The HTTP endpoint
does the sum for you; a direct SQL reader has to remember. This page's ancestor got it wrong, and
[the card page carries the correction](/card#reading-a-balance-and-the-trap-in-the-as-of-query)
along with why a fraction of a debt is the expensive direction to be wrong in
([ADR-0018](/decisions/0018-batching-and-stripe-selection)).

**A position that swings to the wrong side is presented gross, not netted.** A `customer_wallet` in
a debit position routes to its declared `fs_line_contra` — `receivables` — so one customer in debit
cannot quietly cancel against another in credit and vanish from the balance sheet
([ADR-0012](/decisions/0012-chart-governance)). The reporting layer will show you that state
honestly. Section 5 is about why you should not be in it.

## 4 · A hold is not money moving

An authorization creates no obligation. Nothing is owed until it clears, and it may never clear. But
you still need it *sequenced* in the journal — it happened, it is evidence, and it has to be
inspectable.

**So a transaction can be posted with `status: "pending"`.** Its entries are written, its
`account_seq` counters advance, and **the posted balance does not move**: the balance cache
accumulates posted transactions only. Post the 500.00 authorization as pending and
`customer_receivable` reads zero with a 500.00 leg already visible in its entries.

**A pending transaction is never updated.** `ledger_transactions.status` does not mutate, and there
is no `PATCH`. The resolution is a **new posted transaction carrying `resolves_id`**, on the same
`POST /v1/transactions` endpoint — two optional fields, not a second route
([ADR-0016](/decisions/0016-pending-to-posted)). The amounts need not mirror the pending: retirement
is *by reference*, so a partial capture resolves with less and the cache moves by what actually
posted.

**And here is the constraint that will bite you if you map the card trace onto core primitives
naively.** `uq_txn__one_supersession` gives a pending transaction **exactly one fate**. Resolve it
once, or void it once, and that is all. A second resolution of the same pending is refused —
`target_already_superseded`, a 422 with nothing written — and the same index referees the race
between two concurrent attempts, so the loser is refused by name rather than reaching a 500.

The card rail's walkthrough tracks *partial consumption*: 500.00 held, 300.00 cleared, 200.00 still
reserved. **That is the card module's hold model, and it is parked and unbuilt** — the append-only
trio in `parked/card/schema.sql` that no migration applies, waiting on
[M7](/roadmap#m7--cards). Both models are correct for what they are: a network hold has its own
lifecycle with partial consumption in it, while a pending transaction is a claim about money that
resolves once. But they do not compose, and **steps 02 and 03 of that trace cannot both carry
`resolves_id`.** Mapped onto what is built today:

- `evt_clear_1:posting` — the 300.00 capture — **posts on its own**, an ordinary posted transaction.
- `evt_clear_2:posting` — the 200.00 capture — is the one that carries `resolves_id`, retiring the
  hold as it goes.

The first capture posts alone and the **last** one resolves the hold. If you take one sentence from
this section, take that one.

Two more things the core does and does not do here. **The void is built**: reversing a *pending*
transaction produces a posted transaction carrying `reverses_id` and no entries at all — a
zero-posting marker whose whole job is to retire the hold from the pending population by reference.
**Hold expiry is not built**: the timer that fires a void unprompted is [M8](/roadmap#m8--durable-timers),
so an abandoned pending waits for a caller to void it, and `recon_pending_bridge`'s
`oldest_pending_effective_at` is the aging alarm in the meantime.

And **the ledger will not compute "available" for you.** It does not know whether your pending
transaction is a card hold, a scheduled payout or an unsettled capture, so it declines to guess.
Available is the caller's composition of posted and pending; `recon_pending_bridge` exists to keep
the two numbers honest against each other.

## 5 · Booking a shortfall

Now the case every payments product hits and most model badly. **A chargeback lands against a wallet
the customer has already spent.**

The money has to go back. The wallet has nothing in it. The obvious thing is to let the wallet go
negative, and this ledger will let you: nothing refuses it, and the reporting layer presents it
correctly, gross, on the contra line. It is still the wrong shape, and
[ADR-0025](/decisions/0025-shortfalls-and-balance-floors) is the ruling.

**A liability in a debit position is not a liability.** `customer_wallet` is a liability with a
credit normal balance: a positive balance means *you owe them*. Swing it debit and the economics
invert — **they owe you** — which is an asset. The number is not wrong; it is filed under the wrong
kind of thing. And that filing error costs you two specific things:

1. **You cannot reserve against it.** Expected credit losses are booked against a financial
   **asset**. The chart's own `allowance_for_credit_losses` has nothing to attach to on a liability
   account that happens to be in a debit position. A book full of negative wallets cannot answer
   *"how much of what customers owe us do we expect to collect?"*
2. **It collapses two different events into one.** A customer owing you money, and your doubting you
   will collect it, are separate facts — different times, different evidence, different
   reversibility. One account carrying both loses the distinction permanently.

**So the wallet goes to zero, a receivable records what the customer owes, and your own operating
account funds the gap.** Two transactions, with an asset in between. Taking the trace's own 300.00
as the disputed amount:

```
evt_dispute:reversal   DR customer_wallet          300.00
                       CR operating_cash           300.00

evt_dispute:shortfall  DR customer_receivable      300.00
                       CR customer_wallet          300.00
```

The first is what any rail posts naturally: the funds go back, charged to the customer's wallet. The
second is the one that does the work — it returns the wallet to zero and **names the position**. Net
of both: `customer_wallet` at zero, `customer_receivable` at 300.00, `operating_cash` down 300.00.
You are out of pocket, and the books now say by whom.

What that second transaction buys is an entire vocabulary the chart was already built for. The
receivable can be **aged**. An **allowance** can be held against it —
`DR credit_loss_expense / CR allowance_for_credit_losses`, for whatever fraction of the book you
do not expect to collect, which is a judgement recorded separately from the debt itself. And when
you give up, the **write-off** is `DR allowance_for_credit_losses 300.00 /
CR customer_receivable 300.00`, which touches the P&L not at all because the loss was already
expensed when you doubted it. None of those three moves is expressible against a negative wallet.

**What it costs is stated plainly in the ADR and repeated here.** One more transaction on every
shortfall, and somebody has to actually run collections and write-offs against the receivables you
just made visible. The negative-balance version is genuinely cheaper right up until the first time
you are asked what you expect to collect.

**This is a convention, not an invariant.** Nothing in the schema refuses a book that lets wallets
go negative. A per-account **balance floor** is designed — and deliberately unbuilt, pending a
spike — and the modelling rule above is its precondition: book the shortfall as a receivable and the
wallet never *needs* to go below zero, so a floor on it never needs an exception.

## 6 · Closing the period

**A close is one ordinary balanced transaction.** No trigger, no `UPDATE`, no privileged path.

At the end of a month or a year, revenue and expense — the *temporary* accounts — are swept into
`retained_earnings`, so that next period's "earned and spent" counters start from zero rather than
silently including every previous period as well. One posting per temporary account, destination
`retained_earnings`, all in one transaction. **No Income Summary account**: the middle account is a
manual-bookkeeping checksum, and this transaction is balanced by construction
([ADR-0011](/decisions/0011-period-close-and-report-axes)).

Before the first close, earnings do not simply go missing. They appear as the derived
`current_year_earnings` line that `balance_sheet_at` synthesises, so the equation holds at every
instant whether or not anyone has run a close yet.

**It is now two HTTP calls** ([ADR-0024](/decisions/0024-closing-a-period)):

- `POST /v1/periods` defines a period — `code`, `starts_at`, `ends_at`, `tz`. The instants are
  **resolved by the caller** and the zone is stored as provenance and never re-resolved: a local
  midnight is not always a real instant, and the same local date resolves an hour apart across a
  tzdata update.
- `POST /v1/periods/{code}/close` closes one, **for one currency**. A book holding three currencies
  is three calls, because a close computes and stores a per-currency position and one call sweeping
  three would either succeed partially or need a transaction spanning three independent closes.

The closing transaction's `effective_at` is `ends_at` minus one microsecond — the last
*representable* instant inside a half-open period, exact rather than a `23:59:59` approximation.

**Then the checkpoint, and its order is load-bearing.** After the close's own entries exist, and not
before, the close writes `ledger_period_balances`: every account's balance as at the period end,
pinned at the cursor the close captured. It is derived, rebuildable, and off the write path — and it
exists so that a period once closed keeps saying the same thing. **An entry backdated into a closed
period after the fact arrives with a higher transaction id, so it lands in the tail rather than
invalidating the stored balance.** The restatement rule falls out of the cursor rather than being
bolted onto the close. Compute the checkpoint before the closing entries and identity admission is
inert; that failure was found and is why the order is written down
([ADR-0020](/decisions/0020-checkpoint-on-the-report-path)).

## 7 · Two clocks

**Every entry carries two dates and they routinely disagree.** `effective_at` is when it happened —
the card network's business date. `recorded_at` is when you found out, which for a late clearing or
a chargeback is days later. Backdating is not an edge case on a payment rail; it is Tuesday.

Because of that, *"what is the balance now"* and *"what was the balance on June 30"* are different
questions, and no single stored running total answers both. This ledger stores **no** running
balance ([ADR-0006](/decisions/0006-time-and-as-of)). The current balance is the cache; any as-of
balance is aggregated on whichever axis the question asked about.

**And "as of" is pinned to a commit cursor, not a clock.** Two things recorded seconds apart can
commit in the opposite order, so a timestamp cannot say which write landed first. Every report
answers a `pinned_cursor`; send it back and you get the same numbers forever, however much has
landed since. Re-running a report at a pin is the only way to reproduce a statement you have already
handed someone.

Two limits worth carrying. **The cursor is a horizon, not an instant** — it lags the newest writes
by the longest in-flight transaction, which is the price of committing without a global lock. And
**a report re-run at a pin returns that pin**, so a client that advances its horizon from every
answer drags it backwards; ask `GET /v1/cursor` when you want to move forward on purpose
([ADR-0019](/decisions/0019-read-path)).

`GET /v1/accounts/{id}/entries` makes the two axes concrete, and **requires you to name one — there
is no default** ([ADR-0023](/decisions/0023-account-statement)). `recorded` orders by commit
position; `effective` orders by business date and additionally takes a half-open range. A listing
that picks an axis silently is confidently wrong, so this one refuses to pick.

That toggle is where the whole idea stops being abstract, which is the hand-off to the next section.

## What this ledger will not do for you

A guide that overstates is worse than none, so:

- **There is no per-transaction overdraft rule, and there never will be.** *"Do not allow
  withdrawals below zero, but do allow this chargeback"* is a rule about the **operation**, and by
  the time the writer sees it both are a posting moving money out of a wallet. Saying it would take
  a transaction DSL, which this project refuses in any form
  ([ADR-0025](/decisions/0025-shortfalls-and-balance-floors)). The per-account floor is the shape
  that fits, and it is not built yet either.
- **There is no global transaction listing.** You can list one account's entries, and you can fetch
  a transaction whose id you already have. A listing across the whole book stays refused
  ([ADR-0019](/decisions/0019-read-path), [ADR-0023](/decisions/0023-account-statement)).
- **Reconciliation is not on HTTP.** The schema's ten checks run as `openledger reconcile`, in one
  snapshot, turned into an exit code — the daily sweep as a command, not a route.
- **There is no authentication.** `tenant_id` travels in the body as *data scoping*, never as an
  identity claim; the trust story is the deployment ([ADR-0017](/decisions/0017-no-authentication)).
- **Nothing has been run in production, and no number on this site is a benchmark.** The
  [vision](/vision) says why that is the honest framing rather than a disclaimer.

## Now go and click it

**Reading about a hold that moves no balance is not the same as watching one not move.** The
operator dashboard is a browser front end over this same API — accounts down the left, an account's
entries in the middle, and every route spelled out in the API's own field names underneath. Run it:

```sh
# 1. the database and the ledger
make up                                    # from the repository root
cargo build -p openledger
DATABASE_URL="postgres://openledger:openledger@localhost:5433/openledger?sslmode=disable" \
  ./target/debug/openledger serve          # binds 127.0.0.1:8080

# 2. the dashboard
cd dashboard && npm install && npm run dev # http://localhost:3000
```

Then, in order:

1. **Start a fresh book.** It switches `tenant_id` to a new one. The book is per tenant, so a fresh
   one costs a state update and destroys nothing.
2. **Click the ten scenario steps in order.** They are this page's story as data — the same amounts,
   and the card document's own event names as idempotency keys. Read each step's *teaches* line
   before you click it, and the balance it names after.
3. **Watch the hold move no balance.** After *Card authorized · 500.00*, `customer_receivable` reads
   zero with a 500.00 leg already sitting in the entries below it. That is section 4, on screen.
4. **Read a payable's sign.** After *Cleared · 200.00*, `network_settlement_payable` reads −491.00.
   That is section 3, and it is correct.
5. **Flip the entries table's axis toggle.** The chargeback step posts a transaction dated back to
   the day of the purchase and recorded today, so the row moves: at the end of the recorded order,
   in the middle of the effective one. It is tagged `dated back` on one axis and `recorded late` on
   the other, computed from the page in hand rather than asserted. That is section 7.
6. **Pin a cursor and re-run a report at it.** Post something, then run the report again at the pin.
   The numbers do not move. That is the whole of reproducibility, in two clicks.
7. **Send it twice.** The last step replays a key that was already claimed, byte for byte. You get
   `200` with the stored result and an `Idempotency-Replayed` header saying so.

Two things the walk deliberately does not hide. The customer's repayment is **not** on it, so
operating cash ends below zero when the facility is repaid — an overdrawn account is a legal state
here, and the step says so rather than papering over it. And the first capture posts on its own
while the **last** one resolves the hold, for the reason section 4 gives; the card document has both
captures resolving it, and that is not a thing this ledger will do.

Next: [the database](/database) for the thirteen tables underneath all of this,
[the service](/service) for the binary that answers, and [the decisions](/decisions) for why each
piece is what it is.
