# Decisions

Everything we've decided, on one page. Read this to know where the project stands; follow a link
only when you want the reasoning behind a particular call.

New to ledgers? Start with the [glossary](../glossary.md) — it defines every domain term used
here, so the ADRs don't each stop to re-explain them.

## The stack

- **Go** — because the interesting logic is SQL, and Go stays out of the way.
- **Postgres**, one instance — measured at ~800 **clearings**/s untuned (a clearing is one card
  transaction = 3 ledger entries), rising to ~6,970/s with the hot account striped 64 ways and
  7,897/s striping *and* posting in a single call — on a 2 GB table; the comparable
  43 MB figure is 7,816, and quoting only the higher one was cherry-picking. Spike 003's own banner applies: re-auditing the
  same configurations moved the baseline from 833 to 482, so **treat these as shape, not as a
  benchmark**. Nothing has been measured over a network.
- **sqlc**, no ORM — we write the SQL; it generates typed Go. The hot queries stay reviewable *as
  SQL*.
- **Postgres for durable timers too** — an in-process job queue, no scheduler cluster to run.

> **The SQL implementation and its test suites are gone.** Several entries below refer to
> `tests/…` files, adversarial rounds and mutation runs. Those existed, they found the defects
> recorded here, and [0012](./0012-no-triggers.md) deleted them along with the 27 triggers and 26
> PL/pgSQL functions they were written to attest. The **findings** are the output of this project
> and they stand; the code that produced them does not. What remains is
> [`schema/schema.sql`](../../schema/schema.sql) — declarative only, and it loads.

## The decisions

| # | We decided | Because | Status |
| --- | --- | --- | --- |
| [0001](./0001-go-and-postgres.md) | Go + Postgres, no ORM | Postgres has measured headroom of 17–40× what we sized for. (This cell used to open "the load-bearing logic is SQL, so the host language's job is narrow" — [0012](./0012-no-triggers.md) reverses that: the logic goes in Go, and Postgres keeps only what is declarative.) | accepted |
| [0002](./0002-data-access-layer.md) | Native pgx + sqlc, over go-jet | go-jet can silently scan a money column as zero with no error, and its codegen needs a live database | accepted |
| [0003](./0003-bitemporal-balances.md) | Running balance for "now", aggregate-on-read for "as of a business date" | A backdated entry lands with a *later* sequence number, so a running balance answers business-date questions wrongly | accepted |
| [0004](./0004-event-log.md) | Add an append-only `ledger_events` table | Most accepted operations write no ledger transaction, so idempotency can't live on the transactions table | accepted |
| [0005](./0005-reproducible-as-of.md) | Pin reports to a commit-ordered cursor, not a timestamp | `recorded_at` is transaction-*start* time, so the same "as of" query re-runs to a different answer | **proposed** |
| [0006](./0006-schema-conventions.md) | Naming rules, a CI schema-snapshot test, keep FKs and enums | Dropping a column silently drops its indexes — Formance lost two that way, unnoticed for sixteen migrations | accepted |
| [0007](./0007-open-source-positioning.md) | Reframe as a general open-source ledger; keep Postgres | The bottleneck is one contended row, not the hardware — and striping fixes it | accepted |
| [0008](./0008-durable-timers.md) | Durable timers in Postgres, not Temporal | The need is durable *scheduling*, not workflow orchestration — and a job row commits in the same transaction as the ledger write, which Temporal cannot do | accepted |
| [0009](./0009-chart-and-completeness.md) | Chart of accounts as data; completeness is a separate invariant | A dropped *balanced sub-book* satisfies the accounting equation while the report is incomplete. (This cell used to say a missing account "drops out of both sides" — [0009](./0009-chart-and-completeness.md) strikes that as false: one account drops out of exactly ONE side, and the equation catches it loudly.) | accepted |
| [0010](./0010-authorization-holds.md) | A hold is a SUM over an append-only event log, not a mutable amount | Grouping a clearing to its authorization is a revisable inference, and processors disagree on whether an increment carries a delta or a cumulative total | accepted |
| [0011](./0011-what-the-database-enforces.md) | The dozen guards added under adversarial review, and what the database still cannot enforce | A column with a DEFAULT is not a constraint — `recorded_at`, `account_seq` and `xact_id` all had one, and each turned out forgeable by an INSERT | **enforcement half superseded by [0012](./0012-no-triggers.md)** |
| [0012](./0012-no-triggers.md) | **Zero triggers, zero PL/pgSQL. The ledger goes in Go; Postgres keeps only what is declarative** | The schema had quietly become the ledger — 27 triggers and 26 functions against 11 lines of Go — and ten review rounds went into hardening a validation harness that had turned into an unintended product | accepted |

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

- **[0005](./0005-reproducible-as-of.md) is `proposed`**, not accepted — and the hole it names is
  live and reproduced: the same recorded-axis report, re-run either side of one concurrent commit,
  moved revenue by 45% with every check green. `recorded_at` is transaction-*start* time, and a
  timestamp cannot order commits. The as-of cursor blocks
  **M5**, not M4 — M4 is the RDS benchmark and is unblocked. Both time axes are now asserted
  (the deleted `tests/bitemporal.sql` suite); what 0005 still owes is *reproducibility
  under concurrent writes*, which needs a commit-ordered cursor.
- **Inter-scope obligations reconcile against nothing.** A tenant booking 100,000.00 of
  `due_from_treasury` against an operator booking 60,000.00 of `due_to_tenants` leaves every scope
  balanced, both drift views empty, and 40,000.00 of asset owed by nobody. Each sub-book is
  internally consistent; nothing compares the two sides. This is the same limit as the entry below,
  stated in the units it costs.
- **The balance sheet nets counterparties the chart declares un-nettable, and the schema cannot
  express the fix.** `balance_sheet` groups by `fs_line` and never reads `counterparty_scope`, so
  owing t1 425.00 while t2 owes 425.00 prints a payables line of **zero** — both sides understated,
  `trial_balance` holding the correct gross figures, the two reports disagreeing, and every check
  green. That is the exact harm the seed says sharding the account per counterparty fixed; it did
  not, because the netting happens in the *report*, one level above the account. And an account's
  statement line is fixed by its type, so t2's opposite-sign position has no line to move to even
  if the column were read. IAS 32.42 / ASC 210-20-45-1 permit offset only between the same two
  parties.
- **The balance sheet has no period, and the income statement has no parameter.** With no close,
  the synthesised earnings plug sums revenue and expense over *all posted history* — it was
  captioned "Current year earnings" and reported 34,000.00 against a true current year of 4,000.00
  on a three-year book, growing without bound. The caption now says
  "Undistributed earnings (since inception)", which is honest but is not the fix; the fix is the
  period close, designed and unbuilt. `retained_earnings` ships in the chart and stays at zero
  forever because nothing routes to it.
- **The balance cache includes `pending`; every report excludes it.** `ledger_account_balances` is
  described as the O(1) current-balance read and `ledger_balance_drift` as the alarm "over all
  THREE copies of every balance" — all three copies count pending transactions, and no report
  does. A customer served from the cache can be shown 500.00 while the balance sheet shows 0.00,
  with both drift views empty, because nothing compares the alarm's population to the reports'.
  Arguably available-versus-posted by design; nothing says so, and no view surfaces the pending
  population.
- **No report accepts both time axes, and the three statements accept neither.**
  `accounting_equation` takes one axis; `trial_balance`, `balance_sheet` and `income_statement` are
  parameterless. So an issued statement cannot be reproduced after any backdated posting — legal,
  append-only, every check green. This is *separate* from [0005](./0005-reproducible-as-of.md): a
  perfect commit cursor still would not reproduce an issued effective-period report through a
  single-axis parameter.
- **`counterparty_scope` and `is_perimeter` are declarative.** Both are documented at length, both
  carry CHECK constraints, and no view or function reads either. The offsetting rule ADR-0009 §5
  states as a mechanism is not implemented. A consequence worth stating: because nothing reads
  them, **a wrong value in either is undetectable by any test** — mutation testing flips them and
  nothing fails, and no test we could write would change that without first building the mechanism.
  They are documentation stored in a column.
- **Row-level security does not exist yet.** `schema/` contains no `CREATE POLICY` and no
  `ENABLE ROW LEVEL SECURITY`, while [0001](./0001-go-and-postgres.md) asserts "tenant isolation
  *is* row-level security" and spike 004 calls it a correctness constraint. `tenant_id` leading
  every key is the *prerequisite*, and it is built; the policies are not. The bullet below
  described only a design conflict, as though the feature were otherwise in place.
- **Row-level security conflicts with bulk loading.** Postgres refuses `COPY FROM` on a table with
  RLS enabled — and `COPY` is what makes batched posting fast. Likely resolution: post through a
  role that bypasses RLS, so RLS guards reads only. Not yet decided.
- **Historical balances get slower as history grows, and nothing bounds it yet.** Reading "the
  balance right now" is a single index lookup (0.018 ms). Reading "the balance as of last June"
  has to add up entries, which is linear. The per-entry rate and the 105.91 ms at 1M usually quoted
  here come from a one-off run with **no harness in the repository**; the linearity is the claim. The fix is the accountants' one: close each period and store its closing balance, so a
  query only has to add up the current period. Designed but not built —
  [0003](./0003-bitemporal-balances.md) has the numbers.
- **`event_id` is nullable**, so "every transaction references its causing event" is a convention
  rather than an invariant. `NOT NULL` is the fix; it is not done.
- **There is no idempotency replay path.** `idempotency_hash` is written and never read, so
  "same key + same body replays the stored result; a different body is refused" is designed and
  unbuilt. The unique index only makes the second attempt fail.
- **The write path requires READ COMMITTED.** REPEATABLE READ and SERIALIZABLE lose most writes to
  serialization failures on the balance upsert, and a retry loop does not rescue it. *Nothing in
  the deleted suites, `spikes/` or `schema/` sets an isolation level*, so the figures the roadmap quotes
  are observations from a one-off run, not measurements — the roadmap says so and this page said
  "Measured" for three rounds. The conclusion does not depend on them: `ON CONFLICT DO UPDATE`
  under a stricter isolation level fails with `could not serialize access`, which is a property of
  Postgres. A hard deployment constraint, recorded in no ADR.
- **Striping is not built.** The stack summary above quotes striped figures; there is no stripe
  column in `schema/`, and `uq_accounts__house` would currently prevent one on the accounts
  that need it.
- ~~**There is no CI.**~~ **There is now**: `.github/workflows/test.yml` applies the migrations
  against PostgreSQL 18 and runs the deleted test runner suite on every push and pull request. This was listed here
  as "the highest-leverage item" for eight rounds while nine layers of anti-forgery machinery were
  added to the deleted test runner suite — machinery whose own header says it "does not defend against a determined
  author" and names CI as the durable answer. Everyone agreed on the answer and wrote the ladder
  instead. **The schema snapshot test is still not wired to anything**, and that half stays open:
  `expected_schema.sql` is twenty-one lines containing one `SELECT` that emits a string — there is no
  committed snapshot to diff it against and no failure path, so wiring it into CI today would assert
  nothing. The missing half is the snapshot, not the invocation. [0006](./0006-schema-conventions.md)
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
- **Hold-flow findings recorded rather than closed** — the list lives in
  [0010 §Known, and not fixed](./0010-authorization-holds.md#known-and-not-fixed), and **one of
  them under-reserves credit**, the failure this project calls the cardinal sin.

  *There is deliberately no copy of that list here.* It was copied by hand and miscounted four
  rounds running — "two", then "three", then "four", each time corrected and each time wrong again
  by the next round, because the fix was always to correct the number rather than to stop
  duplicating the list. A count maintained in two files is a count that drifts.
- **Completeness is guaranteed WITHIN a scope, not across them**, and that limit is recorded only
  in `schema/schema.sql`. A scope with no accounts at all is invisible to every report, and
  `balance_sheet_balances`' `p_tenant` is exactly the "parameter in which to pass an incomplete
  list" that
  [0009](./0009-chart-and-completeness.md) says should not exist. `vision.md` states the
  completeness guarantee without that qualification.
- **Intercompany balances are presented GROSS.** [0009](./0009-chart-and-completeness.md) says it:
  nothing nets `due_from_treasury` against `due_to_tenants`, so a consolidated balance sheet shows
  both sides at full size. The golden trace asserts they eliminate to zero; no *report* does.
- **The state-machine diagram still names Temporal.** `docs/diagrams/03-state-machines.svg` reads
  "This is the Temporal boundary" — [0008](./0008-durable-timers.md) decided against Temporal.
- **Shipped surface nothing reads.** `webhook_deliveries`, `hold_expires_at` and `clearing_deadline`
  exist in `schema/schema.sql`, carry rationale in comments, and are referenced by no view, no
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
  The reasoning is in `schema/schema.sql`.
- **Balances are stored debit-positive**, and `trial_balance` splits `balance_minor`
  (presentation, normal-balance-signed) from `balance_debit_positive` (arithmetic). Every report
  does its addition in the second and its display in the first.
- **`webhook_deliveries` is a separate table** from `ledger_events`: HTTP-layer redelivery is a
  different concern from ledger identity, and collapsing them makes a retried webhook look like a
  business event.
- **`uq_txn__one_per_event` has no ADR**, and it is a correctness constraint with a reproduced
  counterexample: without it "two transactions were produced from one event row", so the
  idempotency spine does not by itself prevent double-posting. It belongs in
  [0004](./0004-event-log.md), which owns the event log, and is in neither that nor
  [0011](./0011-what-the-database-enforces.md).
- **Five named correctness constraints appear in no document at all**: `uq_txn__one_resolution`,
  `uq_txn__one_reversal` (the double-reversal guard spike 001 identifies as a real Formance bug
  class), `uq_accounts__id_currency`, `uq_txn__id_effective` and `fk_entries__txn_effective`. All
  five ship in `schema/schema.sql`. **Three were exercised by the deleted suites; the other two cannot be, and
  that is stronger.** `uq_accounts__id_currency` and `uq_txn__id_effective` are the referenced-side
  unique indexes the composite foreign keys point at — remove either and `0001` does not load
  (`there is no unique constraint matching given keys`). A constraint whose absence makes the schema
  unbuildable needs no test, which is the shape this log argues for elsewhere; the earlier sentence
  claimed a test for them and no such test exists.
- **PostgreSQL 18 is a floor, not a preference.** `uuidv7()` is the default on **six** tables and
  does not exist before 18. The roadmap targets RDS for M4/M6, which must therefore run 18.
- **Three chart constraints have no ADR**: `uq_fs_lines__caption` (two lines sharing a caption are
  indistinguishable on the face of the statement, which is the restricted-cash harm arrived at from
  the other side; it was introduced because nothing in the suite read a caption, and it now has two
  controls of its own); `ck_fs_lines__code_reserved` (a real chart line may not shadow the
  `current_year_earnings` plug the balance sheet synthesises); and `ck_fs_lines__caption_reserved`,
  **the half that does the harm** — `balance_sheet` emits that plug's caption as a literal, so it
  sits outside the UNIQUE, and a line under any other code could take it. This entry said "two" and
  omitted the one with the measured counterexample.

## On sourcing

Claims about third-party systems are the weakest evidence in this repository, and twice now a
number attributed to a named project turned out never to have existed. Once it was written by us;
once a reviewer commissioned to check such claims **fabricated an entire verification section** —
URLs, quoted text, commit counts, price tables — after its own sub-agents died without reporting.

Three rules follow, and they are cheap:

- **A third-party figure needs a fetchable source next to it**, or it is marked unverified. Not
  softened — marked. "I could not check this" is a finding, not an embarrassment.
  *This rule is not met.* An audit counted **five** external URLs in the whole tree against dozens
  of third-party figures. Three successive attempts to fix it with a *section banner* were each
  found, in the next round, to cover less than the round before claimed: first the bannered
  sections missed Monzo, Supabase and every accounting-standard paragraph citation (IAS 1.32/1.41,
  ASC 210-20-45-1, ASC 606-10-55-36, IFRS 15.B34–B38, IFRS 8 / ASC 280, the IFRS Conceptual
  Framework, FFIEC suspense guidance); then they missed spike 006's processor message shapes,
  pgledger's 10,636.8 / 7,558.9 transfers/s, and the Visa/Mastercard rule corpus. A banner is a
  claim about scope, and every version of it was wrong. **So: treat every third-party figure in
  this repository as unverified unless a URL sits next to it.** That is the rule; the banners were
  the substitute, and three rounds of narrowing scope is the argument against substitutes.
- **Corrections get applied to the document that carries the claim**, not only to the ADR that
  discovered it. Three struck numbers stayed live in the migrations and spikes they came from,
  while the ADRs said "fabricated — struck". *This rule was itself violated the day it was
  written*: the invented processor survey survived in `spikes/006/holds.sql`, the one file that
  actually carries it, for a further round. `grep` the struck phrase across the whole tree, not
  just `docs/`.
- **A spike's own verification can be dead.** `spikes/006/cases.sql` claimed eight measured cases,
  contained six, and none of the six ran against the schema in the same directory. It has been
  deleted and its banner rewritten to say so. Nothing in `spikes/` is executed by CI — and nothing
  in `spikes/` runs against the shipped schema at all — so "measured" there means "was measured
  once, against something". The live attestation was the deleted suites; today it is nothing, and the findings live in these ADRs.

## On grading the graders

Seven rounds have each found a way to make the deleted test runner suite print PASS over a suite that proves
nothing, and each fix added a guard that reads **something the thing it polices controls** — the
floor reads output the file prints, the call-site count reads the file's own source, the sentinel
reads a string the file emits, and the canary reads whether a suite that can recognise it went red.
Every one was forged in the next round, in between one and five lines.

So the threat model is written down now rather than implied. **These guards defend against erosion —
a control quietly deleted, a helper weakened, a file truncated, a floor with slack — and they do not
defend against a determined author.** Nothing checked into a repository can: whoever edits the tests
can edit the thing that checks them. The durable answers are outside the file — review, and CI
running a pinned configuration the branch cannot edit. **CI now exists**
([`.github/workflows/test.yml`](../../schema/schema.sql)); it is what eight rounds of
in-tree guards were a substitute for, and it was written only after a round asked why the substitute
kept being rebuilt instead of the thing itself.

**A census must read state the file it lives in has not touched.** Round 10 deleted one line from
`schema/schema.sql` — the `ENABLE ALWAYS` on the transaction seal's trigger — and the whole build
printed PASS. The catalog census that exists to catch exactly that sat at the *end* of
the deleted `tests/negative_controls.sql` suite, and by then the file had issued thirteen `ALTER TABLE … ENABLE
ALWAYS` statements of its own as part of unrelated controls: **the suite had repaired the mutant it
was measuring.** It runs immediately after `BEGIN;` now. The same round found the other half of the
rule: **a census filter must be as wide as the guard it audits.** The inheritance guard names three
relkinds because a *foreign table* child reproduced the harm verbatim; the census filtered ordinary
tables, so a foreign-table child of `ledger_accounts` was invisible to it — and one
`INSERT … SELECT * FROM ONLY ledger_accounts` then doubled every number in every report with both
drift views empty.

The one guard in this tree that a test file cannot forge is not in the tests. `assert_type_matches_fs_line`
refused two mutants at **seed time**: the wrong chart could not be loaded, so the wrong system could
not be built, and no test had to notice. That is the shape worth generalising — **prefer a constraint
that makes a state unreachable to a check that looks for it afterwards.** Everything in the deleted suites was a
second choice, and the ones worth the most are the ones that could have been constraints.

## On mutation testing

Six rounds of adversarial review have used the same measure: change the schema so it is wrong, and
see whether the suite notices. It is the only measure that distinguishes a test suite from a
transcript. Two things learned the hard way:

**An "equivalent mutant" is a claim, and it needs an argument.** Reviewers have reported real gaps
as equivalent and equivalent mutants as real gaps, and both cost a round. The ones now recorded as
genuinely equivalent each have a one-line reason: `SUM(held_minor)` vs `SUM(total_minor)` under
`held_minor > 0` (`held_minor` is `GREATEST(total_minor,0)`, so under that predicate they are the
same number); and — found by us, not by a reviewer — **swapping the `assets` and `liabilities_and_equity` output
columns of `balance_sheet_balances`**, which a reviewer reported as a gap. On a balanced sheet
those two numbers are equal by construction, so no assertion about a balanced book can tell them
apart. The mutant is only distinguishable on books that are already broken.

**An equivalence argument can be wrong, and one recorded here was.** This section used to list
*"dropping `tenant_id` from a partition key (ids are `uuidv7`, globally unique)"* as genuinely
equivalent. The reason is false and the mutant is not equivalent. `ledger_accounts.id` has a
`DEFAULT uuidv7()` and **no assignment trigger**, and `GRANT INSERT` covers every column — so the
app role can supply the id, and two tenants can hold the same one. ADR-0011's own thesis names
`uuidv7()` ids among the columns that "all had defaults and nothing else, and every one of them
turned out to be forgeable by an INSERT"; it is the one of the four that was never fixed. With two
tenants sharing an account id, both books balanced and posted entirely as `openledger_app`, the
shipped drift window reports 0 rows and the mutant reports a false corruption alarm on a correct
book. the deleted `tests/negative_controls.sql` suite carried that as a control before the suites were deleted. **A one-line reason is required,
and a one-line reason can be wrong; what makes it checkable is that it names a state, so someone
can go and build it.**

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
