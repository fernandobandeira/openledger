# 0005 — Every write enters through an append-only event log, and the primitive it writes is a posting

**Status:** accepted
**Evidence:** [spike 001](/spikes/001-formance),
[spike 006](/spikes/006-how-other-ledgers-enforce).

## The decision

**Every change to the ledger arrives as a message from the outside** — a card was approved, a payment
cleared, a credit limit changed — **and we write every one of those messages down, in order, before we
act on it.** That ordered list is the **event log**, the table `ledger_events`, and it is
*append-only*: rows are only ever added, never edited or deleted. Writing the message down first, in
the same database transaction as whatever it causes, is what lets us recognise a repeat — external
systems retry, so the same message often arrives twice, and because the first copy was recorded under a
caller-supplied **idempotency key** (a unique id for *this* request), the second is spotted and not
acted on a second time.

**When a message does move money, the only thing a caller can hand us is a balanced *posting*.** A
posting names a source account, a destination account and an amount — money leaving one place and
arriving in another — so it always has two equal sides. There is no way to express a single dangling
leg, so an unbalanced transaction is not something the code rejects; it is something no caller can
express in the first place. Most of what a ledger accepts moves no money at all — an approval, a
declined charge, a limit change — which is exactly why every event goes in one log rather than being
keyed off the money-moving transactions: the log is the only place a retry can be recognised whatever
the message does.

**One log doing two jobs a reader may know by name.** From the outside in, `ledger_events` is an
**inbox**: every incoming message recorded once on arrival and deduplicated on its key plus a hash of
its body, so a duplicate is recognised and ignored — the *idempotent consumer* pattern. From the inside
out, it is also an **outbox**: when an event has to trigger follow-on work — per
[0002](/decisions/0002-scaling), a clearing is recorded and then posted by a background job in one
transaction — that same log is the queue the job reads from. One table, both roles.

- `idempotency_key` + `idempotency_hash`, tenant-scoped, under `uq_events__idempotency`.
- `kind`, `source`, `payload jsonb`, `effective_at`, `recorded_at`.
- Every `ledger_transactions` row references the event that caused it — and so do the rails that
  write no transaction at all: holds, transfers, disputes.
- **One event, at most one transaction** — `uq_txn__one_per_event`, partial on
  `event_id IS NOT NULL` because most events cause none. **The idempotency spine does not by itself
  prevent double-posting**: `uq_events__idempotency` deduplicates the *event*, and without this
  second index two transactions were produced from one event row. Reproduced.

**The retry contract, stated once:** same key + same hash → replay the stored outcome. Same key +
*different* hash → reject. The `idempotency_key` under `uq_events__idempotency` **deduplicates the
event** — a second attempt with the same key cannot insert. The `idempotency_hash` — a hash of the
request body — is what makes the replay-vs-reject decision *correct*: a genuine retry carries the same
body and replays the stored outcome; a different request that reused the key carries a different body
and is rejected loudly. Without the hash, the `INSERT … ON CONFLICT DO NOTHING` a naive retry loop
reaches for silently swallows a same-key/different-body call as a fake success. The key gives dedup;
the hash gives a correct replay-vs-reject decision. A caller bug that silently returns the wrong stored
result is worse than a failure.

**This is not event sourcing.** The ledger stays the system of record; we do not rebuild it by
replay. But `payload` must be **complete enough to replay from**, not merely complete enough to
audit — an open-source ledger needs logical export, migration between deployments, and the ability
to rebuild derived state after a bug. That is a constraint on the payload schema, and it is far
cheaper to honour from the first migration than to retrofit.

**The write API accepts postings, not entries.** A posting names a source account, a destination
account, an amount and a currency — so it cannot express one leg. A transaction is a list of
postings. The writer expands each into two `ledger_entries` rows, one debit and one credit, and there
is no code path that writes an entry on its own.

**An unbalanced transaction is therefore unconstructible, not refused** — a compiler guarantee, with
no zero value and no implicit `Default` to fabricate one from
([0001](/decisions/0001-rust-and-postgres)).

`ledger_entries` keeps its present shape — independent rows carrying a `direction` and an
`account_seq`. That is deliberate, and it is what Formance does too: `Posting` in
the type, two `moves` rows in storage. **The row is a leg; the primitive you can call is a pair.**

## Why an event log rather than a key on the transaction

Idempotency on `ledger_transactions` can only deduplicate events that *produce* a ledger
transaction. Most of a ledger's accepted operations deliberately produce none:

| Event | Writes a ledger transaction? |
| --- | --- |
| Authorization, approved | **No** — it records a hold; nothing is owed until it clears |
| Authorization, declined | **No** |
| Hold expiry | **No** — nothing was ever owed |
| Authorization reversal | **No**, if nothing had cleared |
| Statement close | **No** — a statement is a read |
| Repayment initiated | **No** — money in commits at settlement |
| Credit limit change, account opening | **No** |

That is most of the lifecycle, all of it arriving from external systems that retry. One mechanism
replaces a different natural key per rail, and declined authorizations — which otherwise exist only
as a closed hold row — get a home. It also generalizes past cards: any ledger has accepted
operations that produce no transaction (an account opened, a limit changed, a rejected posting, a
metadata edit), so for a general engine this table is the difference between having a retry contract
and not having one.

## Why a posting rather than a check

A check lives in one handler and the next handler has to remember it. A type is remembered by the
compiler, for every caller in the language, forever, with no coordination. The survey shows that is
what the field actually relies on:

- **Formance** ships **zero `GRANT` and zero `REVOKE` in its entire repository** — they are not
  betting on one writer either. Their guarantee is `Posting{Source, Destination, Amount, Asset}`, and
  `Postings.Validate()` contains **no balance check at all**, because there is nothing left to check.
  Measured against their applied schema: a single unbalanced row inserted straight into `moves`
  commits silently, 500 USD leaving `world` and arriving nowhere. The type is the whole defence.
- **TigerBeetle** puts both account ids on one `Transfer` row. Same idea, one level lower.
- **pgledger** puts it in the *table*: `pgledger_transfers (from_account_id, to_account_id, amount,
  CHECK (amount > 0 AND from_account_id != to_account_id))`, with the per-account legs generated,
  never authored. The strongest version of "make the illegal state unrepresentable" in the survey.
- **Beancount, hledger and `ledger`** make the point most elegantly: you may **elide the amount on
  exactly one posting**, and it is inferred from the requirement that the transaction balance. The
  invariant is not a validation bolted onto the model — it is the thing that *completes* it.

And the negative result, which is what makes this a decision rather than a preference: **no
established open-source ledger enforces debits-equal-credits in the database.** Not one of the nine
systems surveyed — six of them SQL or ORM-backed. Modern Treasury asserts it at the API with a 422;
Fragment makes it a schema-compile-time error; everyone else checks it in application code or makes
it structural. Formance *did* once enforce a different invariant with a
`CREATE CONSTRAINT TRIGGER … DEFERRABLE INITIALLY DEFERRED` — and **deleted it in migration 15 in
favour of a partial unique index.**

## What we considered

| | Why not |
| --- | --- |
| **Idempotency key on `ledger_transactions`** | Covers only the minority of events that post. |
| **A natural key per rail** | Each rail is a separate chance to get it wrong. **Keep them anyway** as a second check: a hash mismatch is a `400`, a duplicate business object is a `409` — different failures deserving different responses. |
| **Event sourcing** | The ledger stays the system of record; we do not rebuild balances by replay. |
| **Keep the deferred constraint trigger** | It worked, and it was the thing this tree was proudest of. But PostgreSQL's own manual opens its consistency chapter with *"It is very difficult to enforce business rules regarding data integrity using Read Committed transactions because the view of the data is shifting with each statement"* — and a constraint trigger that reads sibling rows to decide whether to raise is exactly that pattern. Ours was safe only because it read rows in its own transaction; the sequence-assignment trigger next to it was *not*, and became sound only once it took the balance row's lock itself. We found that by counterexample. |
| **Check it at the API boundary**, as Modern Treasury does | That is a check, not a shape. |
| **Fragment's approach** — declare entry *templates* in a schema and validate the accounting equation when the schema compiles, so callers pass parameters and never lines | Genuinely stronger, and it presumes a template language we do not have. Revisit if a posting-rules DSL lands. |

## What it costs

- Write amplification is one insert per event into an uncontended append-only table. Unmeasured,
  but not the shape of thing that caused any bottleneck
  [spike 003](/spikes/003-throughput-ceiling) found.
- **`ledger_transactions.event_id` is `NOT NULL`** — decided and applied by
  [0013](/decisions/0013-write-path-contract) §3, which also records the deadline this fix had:
  once one event-less row commits, append-only makes the repair a choice between `DISABLE TRIGGER`
  and fabricating history. It landed while the journal was empty.
- **The `NULLS NOT DISTINCT` on the idempotency index is inert** — both `tenant_id` and
  `idempotency_key` are `NOT NULL`. It is kept as documentation of a real hazard: in the spike
  schema `tenant_id` *was* nullable, and without that clause a unique index does not constrain
  house-scoped rows at all. Costs nothing; silently wrong if either column is made nullable again.
- **The decomposition of a transaction into pairs is not unique.** "Debit A 100, credit B 60, credit
  C 40" is expressible as `A→B 60, A→C 40`, and so is every other balanced set — but where the
  pairing carries no meaning, we are inventing one and then storing it as though it did.
  TigerBeetle's answer is to route through a **control account** and chain the transfers so they
  succeed or fail together; they recommend doing that first and optimising later. Ours should say
  which account plays that role before the first multi-leg posting is written.
- **Cross-currency is two postings through a clearing account**, and the rate lives nowhere.
  pgledger refuses a cross-currency transfer outright and its own example shows the consequence: the
  FX rate is implicit in the difference between two amounts and is not stored. We should store it.
- **None of this binds direct DML.** A posting type is a guarantee about our code, and says nothing
  about a psql session, a backfill, `pg_restore --disable-triggers`, or the replication apply path.
  That is what the append-only and no-truncate triggers in `migrations/00001_baseline.sql` are for, and why
  [0004](/decisions/0004-where-logic-lives) keeps them: they are the outer layer, and they bind accidents,
  not intent.
- **Nothing enforces balance at the database level.** `ck_entries__balances` is gone, and
  `ledger_entries` stores independent rows carrying a `direction`, so an unbalanced transaction is
  expressible through direct DML. The guarantee is the posting type on our write path, not a database
  check — which is where every system in the survey that made this move puts it too.

## Deferred: hash chaining

Chaining each log row's hash to the previous gives tamper evidence, which is valuable to a lender.
A per-write lock on the chain head is structurally the single-contended-row case spike 003
measured: ~800 clearings/s, plateauing at concurrency 4 and *declining* after. Worse, it is a
**global** contention point, so it defeats every throughput lever [0002](/decisions/0002-scaling) depends
on — striping and per-tenant accounts reduce contention on *account* rows and do nothing about a
lock every writer takes. The one lever that survives is **batching**, because the chain lock is
taken once per transaction rather than once per event.

> **Synchronous hash chaining costs roughly 2× throughput when batched, and roughly 8× when not — *extrapolated from spike 003's contended-row numbers, not measured*.**

Affordable for a lender-facing deployment; unaffordable as a default. So it is **opt-in per
deployment** — a durability/audit setting, not a correctness setting, which keeps it clear of the
rule against configurable correctness. Decide it alongside [0006](/decisions/0006-time-and-as-of), since a
chain needs a total order.

When we build it, copy Formance's **payload/memento split**: `payload` is the full event, `memento`
a separate canonical byte form used *only* as hash input, deliberately excluding derived fields.
The chain then covers the *decision*, not the derived state, so recomputing a balance never
invalidates tamper evidence.

**Also deferred: metadata history.** `metadata jsonb` is mutable with no history, so it cannot
answer "what did we believe at time T". If any of it feeds reporting, the cheapest fix is to make
metadata changes *be* events in this log rather than adding revision tables.
