# The database, drawn and explained

Seven tables that record money movement so that it cannot quietly go wrong. This page is the
guided tour: what each table is for, why it has the shape it has, and — just as carefully —
**what it does not protect you from**. No prior experience with ledgers assumed.

Two things to know before you start. **There is no application on top of this schema yet**: the
service is not built, so where a guarantee depends on code that does not exist, this page says so
rather than implying otherwise. And the schema is one file,
[`migrations/00001_baseline.sql`](/source/baseline), applied by one command; the
reasoning is in comments beside each object, and the decisions behind it are in
[`decisions/`](/decisions), one file each.

## Start here if you have never built a ledger

A ledger answers one question — *who is owed what* — in a way that cannot silently drift. Five
ideas carry almost the whole design, and they are all quite small. If a word here is new, the
[glossary](/glossary) defines every term this project uses.

**Every movement is written twice.** Once as a **debit**, once as a **credit**, and the two sides
of one transaction sum to the same amount. That is *double-entry*. It is not bureaucracy: it means
an error has to be made twice, consistently, to survive. Here is one $500 card purchase, in full —
`DR` marks a debit and `CR` a credit:

```
DR  customer_receivable         500.00    the customer owes us $500
CR  network_settlement_payable  491.00    we owe the card network $491
CR  interchange_revenue           9.00    we keep $9 as our fee
    ------------------------------------
    debits 500.00  =  credits 500.00      balanced
```

**Debit and credit are directions, not good and bad.** A debit increases an asset and decreases a
liability; a credit does the reverse. Which direction *increases* a particular account is that
account's **normal balance**, and it is a property of the account rather than something you can
compute. Most assets are debit-normal — but a loss allowance is an asset that grows with credits.
That one exception is why the database stores the normal balance instead of deriving it.

**Balances have to add up in a particular way.** Everything a business owns equals everything it
owes plus what the owners have put in, adjusted by what it has earned and spent:
**assets = liabilities + equity + (revenue − expenses)**. That identity is the *accounting
equation*, and it falls straight out of writing every movement twice. Two sections below turn on
it.

**Nothing is ever edited.** A correction that rewrites history is indistinguishable from a lie, so
a mistake is fixed by posting a new, opposite entry beside it. Every table that records what
happened is append-only, enforced rather than agreed.

**Balances are derived from entries, never the other way round.** If a stored balance and the
entries behind it ever disagree, the entries are right. Any stored balance is a cache and has to
be able to say so.

**Two dates, always.** When something happened, and when we found out. They differ constantly — a
card clearing carries the network's business date, days before the webhook that told us about it.
Confusing them is the single most common way a correct ledger produces a wrong report.

## The map

Seven tables in three layers. **The journal** records what happened, in order. **The register**
says whose money it is — and holds the one cached number the fast path reads. **The chart** says
what any of it means. Arrows point from a table to the table it depends on.

![The core ledger: seven tables in three layers, with the journal on top, the register in the middle and the chart of accounts at the bottom](/diagrams/04-database-erd.svg)

Every arrow is a *composite* key — it carries more than an id. That is the recurring trick of this
schema, and it is worth holding on to: **when a value is copied into a second table for speed, the
copy is made part of a key, so it cannot disagree with the original.** Three report views (not
drawn) read the chart at the bottom and the journal at the top.

Two words that recur. A **tenant** is one customer of this ledger — one business whose books are
kept separately inside a shared database. **PK** marks the columns that identify a row uniquely.

## Four ideas that explain the schema

These four decide most of the column choices below. Read them first and the seven tables stop
being a list.

### 1 · The tenant leads every key

*Free now, extremely expensive later.*

Every ledger table starts with `tenant_id`, every ledger table's primary key **begins** with it,
and every index and foreign key on those tables carries the prefix. It costs nothing today and it
is the prerequisite for row-level security, for partitioning, and for ever splitting across
database instances — all painful to retrofit and trivial to design in.

It also makes one correctness property *expressible*. Because the foreign key from an entry to its
transaction includes the tenant, a transaction spanning two tenants is structurally impossible
rather than merely discouraged. That matters because each tenant's books have to balance on their
own: a movement between tenants is modelled as two transactions joined by clearing accounts, never
one transaction that leaves one side short.

The chart tables deliberately *lack* the prefix — they are deployment-global. So per-tenant charts
are not representable and a tenant cannot add an account type without a migration. A real
limitation, recorded rather than glossed
([ADR-0007](/decisions/0007-schema-conventions-and-chart)).

### 2 · Reports are built from the chart outward

*Because balanced books do not mean correct reports.*

Drop a single account from a report and the accounting equation catches it — the two sides differ
by exactly that account's balance. But drop a whole *balanced* slice — one tenant, one currency, a
date range containing only whole transactions — and the equation still holds perfectly while
revenue is understated. That is the failure a filter bug actually produces, and no amount of
balance-checking can see it.

So completeness is treated as a separate invariant from balance, and the fix is structural:

![Two ways to build a report: from the entries, where a line with no activity is never enumerated and silently absent; and from the chart, where every line is listed first and prints as zero](/diagrams/05-report-direction.svg)

`balance_sheet` and `income_statement` enumerate outward. `trial_balance` still enumerates
inward, and is the wrong thing to build a completeness claim on — it is kept because it is the
right tool for a different job: showing what actually moved.

### 3 · Two time axes, two mechanisms — never one

*The single most common way a correct ledger produces a wrong number.*

An entry recorded today with a business date of last week is *backdated*, and it is completely
normal: late clearings and chargebacks arrive that way. Which means the order entries were
*recorded* in is not the order they *happened* in — and a running balance follows the recording
order:

| account_seq | effective (business date) | amount | balance_after |
| --- | --- | --- | --- |
| 1 | Jan 10 | +100 | 100 |
| 2 | Jan 30 | +50 | 150 |
| 3 | Jan 20 — **backdated** | +30 | **180** |

Ask for the balance *as of Jan 25* by reading the latest `balance_after` and you get **180**. The
truth is **130**. The Jan 20 entry has a higher sequence number than Jan 30's, so the newest
running balance already includes January 30.

So there are two mechanisms and each read names its axis. "What is this balance now" is one index
lookup on `balance_after`. "What was it as of a business date" aggregates over `effective_at`,
which is linear in history — and the accountants' answer to that is a **period close**, which
stores each period's closing balance so the query becomes *prior close plus entries since*. That
close is designed and not built.

The tempting alternative — a second running balance on the business-date axis — is the one thing
this design refuses outright, because a backdated insert then has to rewrite every later row for
that account. Measured on Formance, the closest comparable open-source ledger: 114 ms for a
thousand entries inserted in order, **84 seconds** for the same thousand backdated. A running
balance on a mutable axis is a trap ([ADR-0006](/decisions/0006-time-and-as-of) has the
numbers).

### 4 · Two triggers, and a written case for each

*The default is none.*

Business logic in the database is a road other ledgers have walked and reversed — Formance built a
full stored-procedure write engine and then spent two migrations demolishing it, dropping five
triggers and twenty-seven functions. So the rule here is that a trigger must state, in the schema
beside it, the invariant it holds, why nothing declarative holds it, and *what it does not protect
against*. Two clear that bar, as six trigger objects over two functions
([ADR-0004](/decisions/0004-where-logic-lives)):

- **The journal is append-only.** No row in `ledger_entries`, `ledger_transactions` or
  `ledger_events` may be updated or deleted. There is no `CHECK` for "this row may not change" and
  no key that expresses it. The only non-trigger option is to withhold the privilege — and
  revoking a privilege binds the application's database user only, while migrations, repair
  scripts and a human at a database prompt all run as the owner, which is exactly the population
  that historically does the damage.
- **And `TRUNCATE` is not a `DELETE`.** PostgreSQL fires no delete trigger for it, so the guard
  above sees nothing. It needs its own trigger per table — a single database-wide event trigger
  would be the natural one object for the job, and PostgreSQL refuses that for `TRUNCATE`
  outright.

Both are set to fire even on the replication apply path and under a restore that disables
triggers. A replica that does not enforce its publisher's invariants is a laundering channel for
corrupt rows.

> **What they do not protect against.** An owner who disables or drops a trigger, which is one
> statement. Nobody in this field holds append-only with a database mechanism: the two published
> answers are Monzo's reviewed service allowlist, which took their ledger from callable-by-1,500
> to callable-by-six, and Uber's cryptographic signatures over each record. Both live outside the
> database. This is the cheap 80%, and it binds accidents rather than intent.

## The seven tables

In the order the diagram reads: the journal first, because it is the point; then the register; then
the chart that gives it meaning.

### `ledger_entries` — one leg of one movement

The row everything else exists to protect. An entry is one side of one movement: this account, this
direction, this amount, this currency. The $500 purchase above is three entry rows. They are never
updated and never deleted.

> **CAUGHT — without the effective-date key.** A transaction dated 2026-06-15 accepted a thousand
> entries dated 1999-01-01. Every business-date report in the system reads that column.

**The direction carries the sign, never the amount.** `amount_minor` is always positive, and it is
an integer of *minor units* — cents, not dollars, and never a floating-point number, which cannot
represent 0.10 exactly. Storing a negative amount *and* a direction gives you two ways to say the
same thing, and eventually they disagree.

**Two columns are copied here on purpose.** `effective_at` is copied from the transaction so a
business-date report is a single-table index scan rather than a join, and `currency` is copied from
the account. Both copies sit inside composite foreign keys, so neither can drift from its source —
that is what makes the copying safe rather than merely fast.

`account_seq` is a per-account counter that orders one account's history, and `balance_after` is
that account's running balance at that point. Together they turn "what is this account's balance
right now" into a single index lookup instead of a sum over all its history.

The keys that carry a rule: `uq_entries__account_seq` (one row per account per sequence number —
arguably the journal's most important key); `fk_entries__account` on `(tenant, account, currency)`,
so an entry cannot carry a currency its account does not hold; `fk_entries__txn_effective`, so the
copied business date must equal the transaction's; and `ck_entries__amount_positive`.

### `ledger_transactions` — the unit of atomicity

A transaction groups the entries that must be true together, and carries both dates:
`effective_at` from whatever actually happened, `recorded_at` from when we heard about it.

**Its status never mutates.** A `pending` transaction that later settles does not become `posted` —
a *new* row is written pointing back at it through `resolves_id`. A reversal is the same shape
through `reverses_id`. Both are unique, so nothing can be resolved twice or reversed twice, and a
transaction may do one or the other but not both.

This is why the table can be append-only at all. The usual design updates a status column in place,
and then the answer to "what did this look like last Tuesday" is gone.

> **CAUGHT — `uq_txn__one_per_event`.** Without it, two transactions were produced from one event
> row, so the idempotency spine did not by itself prevent double-posting.

> **STILL OPEN — `event_id` is nullable.** A transaction *can* be written with no causing event, so
> "every transaction references the event that caused it" is a convention here, not yet an
> invariant. That is why that one arrow is drawn dashed. `NOT NULL` is the fix and it is not done.

### `ledger_events` — every accepted operation, including the ones that move no money

External systems retry. A webhook arrives twice; a client resends after a timeout. Something has to
make the second attempt harmless, and it cannot be a key on the transactions table — because
**most of what a ledger accepts writes no transaction at all**.

An account being opened writes none. Neither does a credit-limit change, a rejected posting, or a
metadata edit. In the card product that ratio is starker still: an authorization reserves money
without moving it, and so do a decline, a hold expiring and a reversal. Put the retry key on the
transaction and every one of those operations has nowhere to live
([ADR-0005](/decisions/0005-event-log-and-write-path)).

**The retry contract:** same idempotency key and the same request body → replay the stored outcome.
Same key, *different* body → refuse. Silently returning the wrong stored result is worse than
failing.

`payload` is deliberately complete enough to *replay* from, not merely to audit — a rebuild after a
bug, or an export to another deployment, both need that, and it is far cheaper to honour in the
first migration than to retrofit.

> **STILL OPEN — the replay path does not exist.** `idempotency_hash` is written and read by
> nothing. The unique index makes a second attempt *fail*; it does not yet make the first attempt's
> answer come back. And an `INSERT … ON CONFLICT DO NOTHING` — exactly what a retry loop reaches
> for — swallows a same-key-different-body replay in silence, which no index can distinguish from a
> deliberate one.

### `ledger_accounts` — whose money, in what currency

One row per (owner, purpose, currency). A company's receivable in USD is one account; the same
company's receivable in EUR is another. Currency is part of an account's identity, not a label on
it.

An account also has an **owner type**: a company, the platform, a bank account, or *house* — the
operator's own accounts, which have no owner id. Two partial unique indexes keep those two worlds
disjoint, because a plain unique index would not constrain house rows at all: their `owner_id` is
`NULL`, and in SQL one null never equals another.

**House accounts are per tenant**, not per deployment. A single global house account makes every
tenant contend on one row, and it makes a tenant's books incomplete on their own
([ADR-0002](/decisions/0002-scaling)).

The account carries a copy of its type's `category` and `normal_balance`, so a report never has to
join the chart just to learn the sign of a number — and that copy is a foreign key into the row it
was copied from.

> **CAUGHT — without the currency in the key.** USD entries sat happily inside EUR accounts and the
> declared currency was decorative.

### `account_types` — the chart of accounts, as data

A *type* is a kind of account: `customer_receivable`, `fbo_cash` (money held *for benefit of* a
customer), `interchange_revenue`. Each declares its category — asset, liability, equity, revenue or
expense — its normal balance, and the line of the financial statements it rolls up to.

**The chart lives in a table because every business needs a different one.** A card programme has a
`platform_rev_share_payable`; a marketplace wallet does not. It also has to *store* each type's
normal balance rather than compute it, because some accounts break the pattern — a loss allowance
is an asset that grows with credits — and code that derives the balance from the category gets
those wrong.

`fs_statement` and `fs_side` are **derived by the database** from the category and can never be
supplied, then carried into the foreign key below. That turns "a revenue type may not report under
an expense caption" from a trigger into a key.

> **CAUGHT — two silent failures, by the same key.** Pointing a revenue type at a cost-of-revenue
> line put 6,000.00 of revenue on the expense side of the income statement — with net income still
> correct, so every aggregate check stayed green. And a rebate typed expense-with-a-credit-balance
> inflated revenue directly: the same signature, in the opposite direction.

### `fs_lines` — the lines of the balance sheet and income statement

The smallest table here, and the one that makes a whole class of bug impossible. Every account type
maps to exactly one statement line, so a report can be built by enumerating from the chart outward
— which is idea 2 above.

`side` is declared, not inferred. It used to be derived from whatever had been posted, which meant
a line with no activity evaluated to null and quietly landed on the wrong half of the balance sheet
— in the report whose entire purpose is the opposite of inferring the chart from the data.

> **CAUGHT — `ck_fs_lines__side_matches_statement`.** A balance-sheet line carrying an
> income-statement side was counted on *neither* side and vanished: 90% of a balance sheet missing,
> reporting balanced.

> **A LIMIT, NOT A GAP — captions are constrained and still not trusted.** Two lines sharing a
> caption are indistinguishable to a reader, so a unique index trims and lowercases before
> comparing. It is *not* a guarantee: one Cyrillic `ѕ` in place of a Latin `s` passes every check,
> prints identically, and misreports earnings. Unicode look-alikes are unbounded, so the rule is
> stated rather than pretended — consumers key on the *code*, and the balance sheet emits it for
> exactly that reason.

### `ledger_account_balances` — the write-side lock, and the fast read, in one row

One row per (account, currency), holding total money in, total money out, and the last sequence
number issued. It is the only table in the schema that is *supposed* to be updated, and it is
rebuildable from the journal at any time.

**Its real job is serialization.** A single statement adds this posting's amounts and returns both
the new balance and the next sequence number — so the row lock *is* the serialization point. No
`SELECT max()`, no advisory lock, no retry loop, and no gap for two concurrent writers to race
through:

```sql
INSERT INTO ledger_account_balances AS b (…)
VALUES (…)
ON CONFLICT (tenant_id, account_id, currency) DO UPDATE
   SET input    = b.input  + excluded.input,
       output   = b.output + excluded.output,
       last_seq = b.last_seq + 1
RETURNING b.last_seq, b.input - b.output;
```

**Why a separate table:** balances change on every posting, account identity almost never. Folding
them together would mean every posting updating a wide row carrying JSON and several indexes. A
narrow row is cheap to lock and stays in memory — and "cheap to lock" is the most
performance-critical property in this schema. Keeping `input` and `output` apart rather than one
signed number keeps the update commutative and makes gross turnover free.

> **STILL OPEN — a hard deployment constraint.** This works under PostgreSQL's default `READ
> COMMITTED` isolation. Raise the isolation level and, under contention, the same statement fails
> with *could not serialize access* — it fails closed, so nothing corrupts, but a retry loop does
> not rescue it. No document owns this constraint yet.

## What the database does not enforce

Some of these are deliberate — the invariant lives somewhere better. Some are simply not done. The
point of listing them together is that a reader should never have to guess which kind they are
looking at. This is a shortened list: the full one, with the counterexample for each, is the
[*Still open*](/decisions#still-open) section of the decision log, and it is longer.

| Not enforced | Kind | Why, and what it means for you |
| --- | --- | --- |
| **Debits equal credits** | **not yet** | The write API will accept a *posting* — a source account, a destination, an amount — so a single leg is unconstructible in the type system rather than refused in SQL. That is what every comparable system relies on. **Until that writer exists nothing enforces balance at all**, and nothing reports it either: `ledger_entries` stores independent rows carrying a direction, so an unbalanced transaction is fully expressible today. |
| `recorded_at`, `account_seq`, `balance_after` | **not yet** | Assigned by the writer, with no parameter for a caller to supply — stronger than a database default, because a default is overridable. Today they are defaults or caller-supplied, and forgeable by an ordinary `INSERT`. *A column with a default is not a constraint.* |
| **The cache and the journal have no relationship** | not done | Zero views compare `ledger_account_balances` to the entries behind it, and no constraint references one from the other. Using only the application's granted privileges the cache was moved from 1,000.00 to 100.00 with the sequence forged, and every report stayed green. |
| `event_id` | not done | Nullable, so "every transaction references its causing event" is a convention. `NOT NULL` is the fix. |
| **Foreign keys on the replication apply path** | not done | Foreign keys are implemented as triggers, and all 36 of the internal ones are left in the default state, which the logical-replication apply path skips. Verified: a two-tenant entry in a currency its account does not hold, dated 1999, committed cleanly on that path. |
| **Table inheritance** | not done | A child table of `ledger_entries` inherits the checks and none of the keys, indexes or triggers — and stays visible through the parent to every view. One `INSERT … SELECT` doubles every number in every report; one `DELETE` on the child removes rows from the parent's view of history. |
| **Schema changes** | not done | The append-only guard covers data statements only. An `ALTER TABLE … TYPE … USING` rewrote posted history with both triggers still armed and neither firing. |
| **Reclassifying a statement line** | not done | The chart key blocks a move that *contradicts* a type's category. It does not block a move to a different line of the same statement and side — so customer float can be moved from restricted cash to unrestricted on an already-issued balance sheet, in one statement, with every check green. |
| **One transaction, two currencies** | not done | Each leg satisfies its own account's currency, so 100.00 USD became 100.00 EUR at an implicit rate of 1.0. There is no FX gain/loss line in the chart, so even a correct writer would have nowhere to book the difference. |
| `counterparty_scope`, `is_perimeter` | not done | Two columns on `account_types` stating real accounting rules — which accounts may be summed together, and which mirror an external balance that must reconcile. **No view, function or test reads either**, so a wrong value is undetectable, and a `CHECK` could not help: they are claims about the world, not about the row. Documentation stored in a column. |
| **Row-level security** | not done | There is no policy anywhere. Tenant-leading keys are the prerequisite and they exist; the policies do not. Note the tension to resolve first: PostgreSQL refuses bulk `COPY` into a table with row-level security enabled, and bulk copy is what makes batched posting fast. |

## Applying it

The schema is one flat file — readability is worth more than a change history nobody reads — and
every later change is a new numbered migration beside it. There are **no down migrations**: on a
ledger, a down migration is either a lie or data loss. Dropping a column destroys real state,
dropping an index restores one the data may no longer satisfy, and neither brings rows back. The
honest operation is to roll forward.

```sh
make up        # PostgreSQL 18 in Docker -- uuidv7() is a floor, not a preference
make migrate   # openledger migrate: applies the baseline, then exits
make chart     # seed an EXAMPLE chart of accounts -- yours will differ
```

`openledger migrate` is a subcommand of the same binary the ledger will be, so a deployment runs
the same image with a different command. It runs as a pre-deploy job that must succeed before new
pods roll: **a bad migration should stop a deploy, not crash-loop a ledger**, and a pre-deploy job
is also the only ordering in which a schema change reaching old and new code at once is safe.

It takes its own lock rather than the one the library ships, because the library's lock *waits* —
and two waiting migrators plus one index being built in the background deadlock against each other.
Ours asks, gives up, and asks again, which never joins that cycle. It waits for a budget an
operator chooses, then gives up loudly, which under a re-runnable job is the right failure.
[ADR-0003](/decisions/0003-migrations) has the reasoning and
[`src/migrate.rs`](/source/migrate-rs) has the code.

## What is deliberately not here

The card product — authorizations, holds, clearing — has a full design and a written schema, and
**no migration applies it**. It is parked in [`parked/card/`](/parked-card) until the
ledger core underneath it is proven. Not one foreign key crosses that boundary in either direction,
which is what made parking it a move rather than a rewrite.

Also absent, and on the [roadmap](/roadmap) rather than forgotten: **hot-account striping**
(splitting one contended balance row into several, the throughput lever that matters here), the
**period close** that bounds business-date reads, the **as-of cursor** that makes an issued report
reproducible, and the **schema snapshot test** — apply to an empty database, dump every index and
constraint, diff against a committed file. That last one is the highest-leverage thing on the list
and it does not exist yet.

---

*Every count on this page was measured against a fresh load, not asserted; the canonical inventory
is [what the schema enforces today](/decisions#what-the-schema-enforces-today). Figures
attributed to other systems are shapes rather than benchmarks, and nothing in this repository has
been measured over a real network.*
