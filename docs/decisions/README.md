# Decisions

Everything we've decided, on one page. Read this to know where the project stands; follow a link
only when you want the reasoning behind a particular call.

New to ledgers? Start with the [glossary](../glossary.md) — it defines every domain term used
here, so the ADRs don't each stop to re-explain them.

## The stack

- **Go** — because the interesting logic is SQL, and Go stays out of the way.
- **Postgres**, one instance — measured at ~800 **clearings**/s untuned (a clearing is one card
  transaction = 3 ledger entries), rising to ~6,970/s with the hot account striped 64 ways and
  7,897/s striping *and* posting in a single call. Spike 003's own banner applies: re-auditing the
  same configurations moved the baseline from 833 to 482, so **treat these as shape, not as a
  benchmark**. Nothing has been measured over a network.
- **sqlc**, no ORM — we write the SQL; it generates typed Go. The hot queries stay reviewable *as
  SQL*.
- **Postgres for durable timers too** — an in-process job queue, no scheduler cluster to run.

## The decisions

| # | We decided | Because | Status |
| --- | --- | --- | --- |
| [0001](./0001-go-and-postgres.md) | Go + Postgres, no ORM | The load-bearing logic is SQL, so the host language's job is narrow; Postgres has measured headroom of 17–40× what we sized for | accepted |
| [0002](./0002-data-access-layer.md) | Native pgx + sqlc, over go-jet | go-jet can silently scan a money column as zero with no error, and its codegen needs a live database | accepted |
| [0003](./0003-bitemporal-balances.md) | Running balance for "now", aggregate-on-read for "as of a business date" | A backdated entry lands with a *later* sequence number, so a running balance answers business-date questions wrongly | accepted |
| [0004](./0004-event-log.md) | Add an append-only `ledger_events` table | Most accepted operations write no ledger transaction, so idempotency can't live on the transactions table | accepted |
| [0005](./0005-reproducible-as-of.md) | Pin reports to a commit-ordered cursor, not a timestamp | `recorded_at` is transaction-*start* time, so the same "as of" query re-runs to a different answer | **proposed** |
| [0006](./0006-schema-conventions.md) | Naming rules, a CI schema-snapshot test, keep FKs and enums | Dropping a column silently drops its indexes — Formance lost two that way, unnoticed for sixteen migrations | accepted |
| [0007](./0007-open-source-positioning.md) | Reframe as a general open-source ledger; keep Postgres | The bottleneck is one contended row, not the hardware — and striping fixes it | accepted |
| [0008](./0008-durable-timers.md) | Durable timers in Postgres, not Temporal | The need is durable *scheduling*, not workflow orchestration — and a job row commits in the same transaction as the ledger write, which Temporal cannot do | accepted |
| [0009](./0009-chart-and-completeness.md) | Chart of accounts as data; completeness is a separate invariant | A report missing one account still satisfies the accounting equation — the missing account drops out of both sides | accepted |
| [0010](./0010-authorization-holds.md) | A hold is a SUM over an append-only event log, not a mutable amount | Grouping a clearing to its authorization is a revisable inference, and processors disagree on whether an increment carries a delta or a cumulative total | accepted |
| [0011](./0011-what-the-database-enforces.md) | The dozen guards added under adversarial review, and what the database still cannot enforce | A column with a DEFAULT is not a constraint — `recorded_at`, `account_seq` and `xact_id` all had one, and each turned out forgeable by an INSERT | accepted |

## Non-negotiable

No decision may trade these away. They are what makes the numbers trustworthy:

- **Append-only.** No `UPDATE`, no `DELETE`, no `TRUNCATE` on entries — enforced by triggers that
  refuse the statement outright, not by discipline and **not by the grants**. A `REVOKE` is a
  point-in-time change to a privilege; one `GRANT ALL` undoes it. This line said "enforced by
  revoking the grants" while the two documents that own the claim
  ([vision](../vision.md), [0011](./0011-what-the-database-enforces.md)) both said the opposite.
- **Balanced per currency**, enforced by the database on every transaction.
- **Bitemporal.** Every entry records both when it happened and when we learned about it.
- **Event-logged.** Every accepted operation is recorded, whether or not it moves money.
  *Not yet enforced:* `ledger_transactions.event_id` is nullable — see "Still open".
- **Correctness is never configurable.** Formance made historization a feature flag and got
  point-in-time queries that silently return empty — *"a green check that didn't actually
  execute."* Make the product pluggable; never the invariants.

## Still open

Undecided, listed plainly rather than buried:

- **[0005](./0005-reproducible-as-of.md) is `proposed`**, not accepted. The as-of cursor blocks
  **M5**, not M4 — M4 is the RDS benchmark and is unblocked. Both time axes are now asserted
  ([`tests/bitemporal.sql`](../../tests/bitemporal.sql)); what 0005 still owes is *reproducibility
  under concurrent writes*, which needs a commit-ordered cursor.
- **`counterparty_scope` and `is_perimeter` are declarative.** Both are documented at length, both
  carry CHECK constraints, and no view or function reads either. The offsetting rule ADR-0009 §5
  states as a mechanism is not implemented. A consequence worth stating: because nothing reads
  them, **a wrong value in either is undetectable by any test** — mutation testing flips them and
  nothing fails, and no test we could write would change that without first building the mechanism.
  They are documentation stored in a column.
- **Row-level security does not exist yet.** `migrations/` contains no `CREATE POLICY` and no
  `ENABLE ROW LEVEL SECURITY`, while [0001](./0001-go-and-postgres.md) asserts "tenant isolation
  *is* row-level security" and spike 004 calls it a correctness constraint. `tenant_id` leading
  every key is the *prerequisite*, and it is built; the policies are not. The bullet below
  described only a design conflict, as though the feature were otherwise in place.
- **Row-level security conflicts with bulk loading.** Postgres refuses `COPY FROM` on a table with
  RLS enabled — and `COPY` is what makes batched posting fast. Likely resolution: post through a
  role that bypasses RLS, so RLS guards reads only. Not yet decided.
- **Historical balances get slower as history grows, and nothing bounds it yet.** Reading "the
  balance right now" is a single index lookup (0.018 ms). Reading "the balance as of last June"
  has to add up entries, which is linear — ~0.10 µs each, so ~3 ms at 30k entries and a measured 105.91 ms at 1M. The fix is the accountants' one: close each period and store its closing balance, so a
  query only has to add up the current period. Designed but not built —
  [0003](./0003-bitemporal-balances.md) has the numbers.
- **`event_id` is nullable**, so "every transaction references its causing event" is a convention
  rather than an invariant. `NOT NULL` is the fix; it is not done.
- **There is no idempotency replay path.** `idempotency_hash` is written and never read, so
  "same key + same body replays the stored result; a different body is refused" is designed and
  unbuilt. The unique index only makes the second attempt fail.
- **The write path requires READ COMMITTED.** Measured: REPEATABLE READ and SERIALIZABLE lose
  most writes to serialization failures on the balance upsert, and a retry loop does not rescue
  it. A hard deployment constraint, recorded in no ADR.
- **Striping is not built.** The stack summary above quotes striped figures; there is no stripe
  column in `migrations/`, and `uq_accounts__house` would currently prevent one on the accounts
  that need it.
- **There is no CI, and the schema snapshot test is not wired to anything.**
  `expected_schema.sql` exists and runs; nothing invokes it. [0006](./0006-schema-conventions.md)
  calls it "the highest-leverage item here" and [0008](./0008-durable-timers.md) says it must cover
  ADR-quoted SQL — which, twice, it would have caught.
- **Hash chaining for tamper evidence is deferred, not decided.**
  [0004](./0004-event-log.md) leaves it explicitly open: it needs a total order, so it is entangled
  with [0005](./0005-reproducible-as-of.md). The cost figures quoted there are extrapolated from
  spike 003's contended-row numbers, not measured.
- **The chart of accounts is not versioned**, so changing which statement line an account reports
  under would silently restate issued statements. Currently blocked outright, which is a stopgap:
  IAS 1.41 *requires* reclassifying comparatives. See [0009](./0009-chart-and-completeness.md).
- **There is no period close and no retained earnings posting.** Un-closed earnings are presented
  as a derived `current_year_earnings` line, which is correct interim presentation but means
  nothing bounds how far back a backdated entry can restate a reported period.
- **No number has been measured on RDS.** Everything so far is localhost, where a round trip is
  ten times cheaper. Nothing gets published until that is fixed.
- **Three hold-flow findings are recorded rather than closed**, in
  [0010](./0010-authorization-holds.md), and **one of them under-reserves credit** — the failure
  this project calls the cardinal sin. This entry previously said "two", and said both "fail
  closed — availability, not correctness". Both halves were wrong, and the omitted one was the
  serious one:
  - **A cumulative restatement that DECREASES is refused, and the refusal is sticky.**
    `authorized_minor` only rises, so a processor restating a *lower* subtotal after a partial
    reversal is read as out-of-order, and the group can never accept a total below its high-water
    mark again. Measured at 60.00 held against 90.00 real, with `card_hold_drift` silent — the
    materialised total and the log agree, on the wrong number. Representing a *decreasing*
    authorized subtotal is the missing design piece, which is why this is recorded and not
    guarded.
  - **A refused convention mix leaves an order-dependent number in service** — the same two
    messages leave 50.00 or 100.00 held depending on arrival order, because only the second is
    refused and the first is already applied. Quarantining the *group* rather than the message is
    the likely answer.
  - **A regroup can deadlock against an unsorted multi-group caller.** This one, and only this
    one, costs availability rather than correctness: it aborts cleanly and leaves no drift.
- **Completeness is guaranteed WITHIN a scope, not across them**, and that limit is recorded only
  in `migrations/0002`. A scope with no accounts at all is invisible to every report, and
  `balance_sheet`'s `p_tenant` is exactly the "parameter in which to pass an incomplete list" that
  [0009](./0009-chart-and-completeness.md) says should not exist. `vision.md` states the
  completeness guarantee without that qualification.
- **Shipped surface nothing reads.** `webhook_deliveries`, `hold_expires_at` and `clearing_deadline`
  exist in `migrations/0003`, carry rationale in comments, and are referenced by no view, no
  function and no test. They are either the next milestone's work or dead weight; recorded here
  rather than left to be discovered as "untested".
- **Posting rules.** A deployment declares its own accounts; it must also declare how a business
  event becomes entries. Adyen proves those templates balance at design time. We have not designed
  ours.

## Decided, but recorded only in the migrations

These are real decisions with real reasoning; none has an ADR, which makes the header above
("everything we've decided, on one page") an overstatement. Listed here until they get one:

- **All four reports filter `status = 'posted'`.** Without it a pending authorization was
  recognised as revenue and its posted resolution counted it again — 500.00 of interchange twice.
  The reasoning is in `migrations/0002`.
- **Balances are stored debit-positive**, and `trial_balance` splits `balance_minor`
  (presentation, normal-balance-signed) from `balance_debit_positive` (arithmetic). Every report
  does its addition in the second and its display in the first.
- **`webhook_deliveries` is a separate table** from `ledger_events`: HTTP-layer redelivery is a
  different concern from ledger identity, and collapsing them makes a retried webhook look like a
  business event.
- **PostgreSQL 18 is a floor, not a preference.** `uuidv7()` is the default on **six** tables and
  does not exist before 18. The roadmap targets RDS for M4/M6, which must therefore run 18.
- **Two chart constraints have no ADR**: `uq_fs_lines__caption` (two lines sharing a caption are
  indistinguishable on the face of the statement, which is the restricted-cash harm arrived at from
  the other side — and nothing in the suite reads a caption, so it had to be a constraint rather
  than a test) and `ck_fs_lines__code_reserved` (a real chart line may not shadow the
  `current_year_earnings` plug the balance sheet synthesises).

## On sourcing

Claims about third-party systems are the weakest evidence in this repository, and twice now a
number attributed to a named project turned out never to have existed. Once it was written by us;
once a reviewer commissioned to check such claims **fabricated an entire verification section** —
URLs, quoted text, commit counts, price tables — after its own sub-agents died without reporting.

Two rules follow, and they are cheap:

- **A third-party figure needs a fetchable source next to it**, or it is marked unverified. Not
  softened — marked. "I could not check this" is a finding, not an embarrassment.
- **Corrections get applied to the document that carries the claim**, not only to the ADR that
  discovered it. Three struck numbers stayed live in the migrations and spikes they came from,
  while the ADRs said "fabricated — struck". *This rule was itself violated the day it was
  written*: the invented processor survey survived in `spikes/006/holds.sql`, the one file that
  actually carries it, for a further round. `grep` the struck phrase across the whole tree, not
  just `docs/`.
- **A spike's own verification can be dead.** `spikes/006/cases.sql` claimed eight measured cases
  and contained six, none of which run against the schema in the same directory. Nothing in
  `spikes/` is executed by CI, so "measured" there means "was measured once, against something".
  The live attestation is `tests/`.

## On mutation testing

Four rounds of adversarial review have used the same measure: change the schema so it is wrong, and
see whether the suite notices. It is the only measure that distinguishes a test suite from a
transcript. Two things learned the hard way:

**An "equivalent mutant" is a claim, and it needs an argument.** Reviewers have reported real gaps
as equivalent and equivalent mutants as real gaps, and both cost a round. The ones now recorded as
genuinely equivalent each have a one-line reason: `SUM(held_minor)` vs `SUM(total_minor)` under
`held_minor > 0` (`held_minor` is `GREATEST(total_minor,0)`, so under that predicate they are the
same number); dropping `tenant_id` from a partition key (ids are `uuidv7`, globally unique); and —
found by us, not by a reviewer — **swapping the `assets` and `liabilities_and_equity` output
columns of `balance_sheet_balances`**, which a reviewer reported as a gap. On a balanced sheet
those two numbers are equal by construction, so no assertion about a balanced book can tell them
apart. The mutant is only distinguishable on books that are already broken.

**A control has to fail for its own reason.** The post-expiry drift control raised
`authorized_minor`, which also makes the stored total disagree with the log — so it fired on the
stored-vs-log branch and the branch it named could be deleted with the test still green. Lowering
the *snapshot* instead isolates it. The same lesson as the `must_fail` reason strings, one level up.

## How this log works

One file per decision, numbered, never deleted. A decision that turns out wrong gets a new ADR
superseding it; the old one stays, with its status changed, so the reasoning trail survives.

Where measurement later corrected a decision, the ADR states the current position **first** and
summarises what it superseded — you should never have to read a change history to learn what we
think now.
