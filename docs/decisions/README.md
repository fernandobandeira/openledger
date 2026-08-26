# Decisions

Everything we've decided, on one page. Read this to know where the project stands; follow a link only
when you want the reasoning behind a particular call.

New to ledgers? Start with the [glossary](../glossary.md) — it defines every domain term used here, so
the ADRs don't each stop to re-explain them.

## The stack

- **Go** — the ledger is written in Go; Postgres holds the shape.
- **Postgres**, one instance — measured at ~800 **clearings**/s untuned (a clearing is one card
  transaction = 3 ledger entries), rising to ~6,970/s with the hot account striped 64 ways and 7,897/s
  striping *and* posting in a single call, on a 2 GB table; the comparable 43 MB figure is 7,816.
  Spike 003's own banner applies: re-auditing the same configurations moved the baseline from 833 to
  482, so **treat these as shape, not as a benchmark**. Nothing has been measured over a network.
- **sqlc**, no ORM — we write the SQL; it generates typed Go. The hot queries stay reviewable *as
  SQL*.
- **Postgres for durable timers too** — an in-process job queue, no scheduler cluster to run.

## The decisions

| # | We decided | Because | Status |
| --- | --- | --- | --- |
| [0001](./0001-go-and-postgres.md) | Go + Postgres, no ORM | Postgres has measured headroom of 17–40× what we sized for | accepted |
| [0002](./0002-data-access-layer.md) | Native pgx + sqlc, over go-jet | go-jet can silently scan a money column as zero with no error, and its codegen needs a live database | accepted |
| [0003](./0003-bitemporal-balances.md) | Running balance for "now", aggregate-on-read for "as of a business date" | A backdated entry lands with a *later* sequence number, so a running balance answers business-date questions wrongly | accepted |
| [0004](./0004-event-log.md) | Add an append-only `ledger_events` table | Most accepted operations write no ledger transaction, so idempotency can't live on the transactions table | accepted |
| [0005](./0005-reproducible-as-of.md) | Pin reports to a commit-ordered cursor, not a timestamp | `recorded_at` is transaction-*start* time, so the same "as of" query re-runs to a different answer | **proposed** |
| [0006](./0006-schema-conventions.md) | Naming rules, a CI schema-snapshot test, keep FKs and enums | Dropping a column silently drops its indexes — Formance lost two that way, unnoticed for sixteen migrations | accepted |
| [0007](./0007-open-source-positioning.md) | Reframe as a general open-source ledger; keep Postgres | The bottleneck is one contended row, not the hardware — and striping fixes it | accepted |
| [0008](./0008-durable-timers.md) | Durable timers in Postgres, not Temporal | The need is durable *scheduling*, not workflow orchestration — and a job row commits in the same transaction as the ledger write, which Temporal cannot do | accepted |
| [0009](./0009-chart-and-completeness.md) | Chart of accounts as data; completeness is a separate invariant | A dropped *balanced sub-book* satisfies the accounting equation while the report is incomplete | accepted |
| [0010](./0010-authorization-holds.md) | A hold is a SUM over an append-only event log, not a mutable amount | Grouping a clearing to its authorization is a revisable inference, and processors disagree on whether an increment carries a delta or a cumulative total | accepted |
| [0011](./0011-what-the-database-enforces.md) | What a database can and cannot be made to guarantee | A column with a DEFAULT is not a constraint — `recorded_at`, `account_seq` and `xact_id` all had one, and each turned out forgeable by an INSERT | **enforcement half superseded by [0012](./0012-where-logic-lives.md)** |
| [0012](./0012-where-logic-lives.md) | **The ledger goes in Go. Postgres holds the shape, and a trigger needs a written justification** | The schema had quietly become the ledger — 27 triggers and 26 functions against 11 lines of Go — and ten review rounds went into hardening a validation harness that had turned into an unintended product | accepted |
| [0013](./0013-the-write-path.md) | **The write primitive is a posting, not an entry** — source, destination, amount, so one leg is unconstructible | "One service owns the writes" is a hope about deployment; a type that cannot express an unbalanced transaction holds for every caller. No established open-source ledger enforces this in the database — Formance deleted its deferred constraint trigger in favour of a unique index | accepted |
| [0014](./0014-schema-migrations.md) | **goose, from Go, as its own `openledger migrate` command run as a pre-deploy job** — never at startup, never from goose's CLI | A *blocking* advisory lock deadlocks against `CREATE INDEX CONCURRENTLY`, which kills tern and golang-migrate; goose polls a try-lock. Atlas Community refuses our views outright | accepted |

## Non-negotiable

No decision may trade these away. They are what makes the numbers trustworthy:

- **Append-only.** No `UPDATE`, no `DELETE`, no `TRUNCATE` on entries — enforced by triggers that
  refuse the statement outright, not by discipline and **not by the grants**. A `REVOKE` is a
  point-in-time change to a privilege; one `GRANT ALL` undoes it.
- **Balanced per currency.** Enforced by *construction* in the Go writer — a posting names a source
  and a destination, so one leg is unconstructible ([0013](./0013-the-write-path.md)). Non-negotiable
  as a property of the design; **not true of the current tree, because the writer is not built.**
- **Bitemporal.** Every entry records both when it happened and when we learned about it.
- **Event-logged.** Every accepted operation is recorded, whether or not it moves money. *Not yet
  enforced:* `ledger_transactions.event_id` is nullable — see "Still open".
- **Correctness is never configurable.** Formance made historization a feature flag and got
  point-in-time queries that silently return empty — *"a green check that didn't actually execute."*
  Make the product pluggable; never the invariants.
- **Prefer a constraint that makes a state unreachable to a check that looks for it afterwards.** The
  chart guard refused a wrong chart at *seed* time: the wrong system could not be built, so no test
  had to notice. [0012](./0012-where-logic-lives.md) turned it into a foreign key, which is the same
  property, declaratively.

## What the schema enforces today

Measured against a fresh load of [`schema/schema.sql`](../../schema/schema.sql), not asserted.

**11 tables · 5 views · 10 foreign keys · 8 triggers over 2 functions · 0 event triggers · 0 policies**

**Enforced by the database:**

- Single-row `CHECK`s — `amount_minor > 0`, ISO currency, the sign rule per authorization kind, house
  accounts having no owner, caption cleanliness, statement/side agreement.
- **Chart integrity, by two composite foreign keys.** An account cannot claim a category or normal
  balance its type does not have; a type cannot report under a statement line that contradicts its
  category. A wrong chart is refused at seed time — verified, three of four mutant charts died on
  load.
- **Append-only on the four immutable logs**, by trigger, `ENABLE ALWAYS`, so it holds on the
  replication apply path too. `TRUNCATE` refused on the same four.
- Uniqueness — `uq_events__idempotency`, `uq_event_group__current` (one live membership per event),
  `uq_accounts__house` (one house account per tenant, purpose and currency), and **`uq_entries__account_seq`**, the
  journal's per-account sequence, which is arguably its most important key.
- Three more single-row rules worth naming because they are easy to miss: `ck_balances__non_negative`
  on the cache, `ck_txn__no_self_reference`, and `ck_txn__not_both` (a transaction may resolve or
  reverse, not both).

**NOT enforced by the database, deliberately or otherwise:**

| | why |
| --- | --- |
| **Debits equal credits** | **Deliberate.** [0013](./0013-the-write-path.md) makes it unconstructible in the Go writer rather than refused in SQL. Until that writer exists, **nothing enforces it at all**, and 0013 says so. |
| `recorded_at`, `xact_id`, `account_seq`, `balance_after` | **Deliberate.** Assigned by the writer, which has no parameter for them. Today `recorded_at` and `xact_id` are bare `DEFAULT`s; `account_seq` and `balance_after` have no default at all and are wholly caller-supplied and are forgeable by an `INSERT` — verified, `recorded_at` accepted as `1999-01-01`. |
| **Foreign keys on the replication apply path** | **Not deliberate.** All 40 internal FK triggers are `ENABLE ORIGIN`. Under `session_replication_role = 'replica'` every foreign key is skipped — verified: a two-tenant entry in a currency its account does not hold, dated 1999, committed. |
| **Table inheritance** | **Not deliberate.** The event trigger went with the PL/pgSQL. A child of `ledger_entries` plus one `INSERT … SELECT * FROM ONLY` doubles every number in every report — verified. |
| **Reclassifying a statement line** | **Not deliberate.** `fk_types__fs_line` blocks a move that contradicts the category; it does **not** block a move to another line of the same statement and side. Verified: 440.00 of customer float moved from restricted cash to unrestricted on an already-issued balance sheet. |

The last three are the honest cost of [0012](./0012-where-logic-lives.md), and they are in *Still
open* below.

## Still open

Undecided, listed plainly rather than buried.

| | |
| --- | --- |
| **Three guarantees [0012](./0012-where-logic-lives.md) removed** | All three were closed by PL/pgSQL that no longer exists, and all three are reproducible on the shipped schema. **Foreign keys are skipped on the replication apply path** — 40 internal FK triggers (ten foreign keys, four triggers each), all `ENABLE ORIGIN`; the fix is one `ALTER TABLE … ENABLE ALWAYS TRIGGER` each, and it needs a decision about whether a design-stage schema should carry it. **Table inheritance is open again** — a child of `ledger_entries` is visible through the parent to every view and carries none of its keys or triggers. **A statement line can be reclassified under posted history**, as long as the new line shares the old one's statement and side. |
| **[0005](./0005-reproducible-as-of.md) is `proposed`** | The hole it names is live: the same recorded-axis report, re-run either side of one concurrent commit, moved revenue by 45% with every check green. `recorded_at` is transaction-*start* time, and a timestamp cannot order commits. The as-of cursor blocks **M5**, not M4 — M4 is the RDS benchmark and is unblocked. |
| **Inter-scope obligations reconcile against nothing** | A tenant booking 100,000.00 of `due_from_treasury` against an operator booking 60,000.00 of `due_to_tenants` leaves every scope balanced, every check green, and 40,000.00 of asset owed by nobody. No view compares the two sides — the ledger-side drift views were deleted by [0012](./0012-where-logic-lives.md), and the one that remains, `card_hold_drift`, is card-specific. Each sub-book is internally consistent; nothing compares the two sides. |
| **The balance sheet nets counterparties the chart declares un-nettable, and the schema cannot express the fix** | `balance_sheet` groups by `fs_line` and never reads `counterparty_scope`, so owing t1 425.00 while t2 owes 425.00 prints a payables line of **zero** — both sides understated, `trial_balance` holding the correct gross figures, and every check green. Sharding the account per counterparty does not fix it: the netting happens in the *report*, one level above the account, and an account's statement line is fixed by its type, so t2's opposite-sign position has no line to move to even if the column were read. IAS 32.42 / ASC 210-20-45-1 permit offset only between the same two parties. |
| **The balance sheet has no period, and the income statement has no parameter** | With no close, the synthesised earnings plug sums revenue and expense over *all posted history* — 34,000.00 against a true current year of 4,000.00 on a three-year book, growing without bound. The caption now says "Undistributed earnings (since inception)", which is honest and is not the fix. The fix is the period close, designed and unbuilt; `retained_earnings` ships in the chart and stays at zero forever because nothing routes to it. |
| **The balance cache includes `pending`; every report excludes it** | All three copies of every balance count pending transactions and no report does, so a customer served from the cache can be shown 500.00 while the balance sheet shows 0.00, and nothing reconciles the two. Arguably available-versus-posted by design; nothing says so, and no view surfaces the pending population. |
| **No report accepts both time axes, and the three statements accept neither** | the accounting equation, when it is rebuilt in Go, must take one axis; `trial_balance`, `balance_sheet` and `income_statement` are parameterless. An issued statement cannot be reproduced after any backdated posting — legal, append-only, every check green. Separate from [0005](./0005-reproducible-as-of.md): a perfect commit cursor still would not reproduce an issued effective-period report through a single-axis parameter. |
| **`counterparty_scope` and `is_perimeter` are declarative** | Both documented at length, both carrying CHECK constraints, and no view or function reads either — so the offsetting rule [0009](./0009-chart-and-completeness.md) §5 states as a mechanism is not implemented, and **a wrong value in either is undetectable by any test.** Documentation stored in a column. |
| **Row-level security does not exist yet** | `schema/` contains no `CREATE POLICY` and no `ENABLE ROW LEVEL SECURITY`, while [0001](./0001-go-and-postgres.md) asserts "tenant isolation *is* row-level security". `tenant_id` leading every key is the prerequisite and is built; the policies are not. It also conflicts with bulk loading — Postgres refuses `COPY FROM` on a table with RLS enabled, and `COPY` is what makes batched posting fast. Likely resolution: post through a role that bypasses RLS, so RLS guards reads only. |
| **Historical balances get slower as history grows** | "The balance right now" is a single index lookup (0.018 ms); "as of last June" adds up entries, which is linear. The per-entry rate and the 105.91 ms at 1M usually quoted here come from a one-off run with **no harness in the repository**; the linearity is the claim. The fix is the accountants' one — close each period and store its closing balance. [0003](./0003-bitemporal-balances.md) has the numbers. |
| **The write path requires READ COMMITTED** | REPEATABLE READ and SERIALIZABLE lose most writes to serialization failures on the balance upsert, and a retry loop does not rescue it. Nothing in `spikes/` or `schema/` sets an isolation level, so the roadmap's figures are observations from a one-off run rather than measurements — but the conclusion does not depend on them: `ON CONFLICT DO UPDATE` under a stricter level fails with `could not serialize access`, which is a property of Postgres. A hard deployment constraint, recorded in no ADR. |
| **`event_id` is nullable** | So "every transaction references its causing event" is a convention rather than an invariant. `NOT NULL` is the fix; it is not done. |
| **There is no idempotency replay path** | `idempotency_hash` is written and never read, so "same key + same body replays the stored result; a different body is refused" is designed and unbuilt. The unique index only makes the second attempt fail. |
| **Striping is not built** | The stack summary above quotes striped figures. There is no stripe column in `schema/`, and `uq_accounts__house` would currently prevent one on the accounts that need it. |
| **There is no CI** | `.github/workflows/test.yml` was present in three commits' trees and was deleted with the suite it ran ([0012](./0012-where-logic-lives.md)). It comes back when the Go tests do, and should run `go test ./...` and load `schema/schema.sql` against a PostgreSQL 18 service. |
| **Hash chaining for tamper evidence is deferred, not decided** | [0004](./0004-event-log.md) leaves it open: it needs a total order, so it is entangled with [0005](./0005-reproducible-as-of.md). The cost figures quoted there are extrapolated from spike 003's contended-row numbers, not measured. |
| **The chart of accounts is not versioned** | Changing which statement line an account reports under would silently restate issued statements, so it is blocked outright — a stopgap, since IAS 1.41 *requires* reclassifying comparatives. See [0009](./0009-chart-and-completeness.md). |
| **No number has been measured on RDS** | Everything so far is localhost, where a round trip is ten times cheaper. Nothing gets published until that is fixed. |
| **Hold-flow findings recorded rather than closed** | The list lives in [0010 §Known, and not fixed](./0010-authorization-holds.md#known-and-not-fixed), and **at least four of them under-reserve credit**, the failure this project calls the cardinal sin. *There is deliberately no copy of that list here* — a count maintained in two files is a count that drifts, and this one miscounted four rounds running. |
| **Completeness is guaranteed WITHIN a scope, not across them** | Recorded only in `schema/schema.sql`. A scope with no accounts at all is invisible to every report, and a tenant parameter on the balance-sheet report is exactly the "parameter in which to pass an incomplete list" that [0009](./0009-chart-and-completeness.md) says should not exist. `vision.md` states the completeness guarantee without that qualification. |
| **Intercompany balances are presented GROSS** | Nothing nets `due_from_treasury` against `due_to_tenants`, so a consolidated balance sheet shows both sides at full size. The golden trace asserts they eliminate to zero; no *report* does. |
| **`docs/design-board.html` still names Temporal** | "Temporal" in eight places — the masthead, the architecture diagram twice (its inline text and its `aria-label`, so a screen reader is told it too), the lifecycle prose, the `expires_at` comment, the state-machine boundary and twice in the §06 trace, both decided against by [0008](./0008-durable-timers.md). `docs/diagrams/03-state-machines.svg` has been updated and is embedded in [docs/README](../README.md#the-three-diagrams); the board's own copy of that diagram has not. |
| **Shipped surface nothing reads** | `webhook_deliveries` exist in `schema/schema.sql`, carry rationale in comments, and is referenced by no view and no function. `hold_expires_at` and `clearing_deadline` are *exposed* by `card_auth_unmatched` (it selects `e.*`) but nothing reads them for a decision, and nothing writes them — see [0008](./0008-durable-timers.md), whose reconciliation sweep filters on one of them and therefore matches nothing. Either the next milestone's work or dead weight — and [0008](./0008-durable-timers.md)'s reconciliation sweep *reads* one of them, which is why that sweep can never fire. |
| **Posting rules** | A deployment declares its own accounts; it must also declare how a business event becomes entries. Adyen proves those templates balance at design time. We have not designed ours. |

## Decided, but recorded only in the schema

Real decisions with real reasoning; none has an ADR, which makes the header above ("everything we've
decided, on one page") an overstatement. Listed here until they get one:

- **All three reports filter `status = 'posted'`.** Without it a pending authorization was recognised
  as revenue and its posted resolution counted it again — 500.00 of interchange twice.
- **Balances are stored debit-positive**, and `trial_balance` splits `balance_minor` (presentation,
  normal-balance-signed) from `balance_debit_positive` (arithmetic). Every report does its addition in
  the second and its display in the first.
- **`webhook_deliveries` is a separate table** from `ledger_events`: HTTP-layer redelivery is a
  different concern from ledger identity, and collapsing them makes a retried webhook look like a
  business event.
- **`uq_txn__one_per_event`** is a correctness constraint with a reproduced counterexample: without it
  "two transactions were produced from one event row", so the idempotency spine does not by itself
  prevent double-posting. It belongs in [0004](./0004-event-log.md).
- **Four named correctness constraints are reasoned about in no document**: `uq_txn__one_resolution`,
  `uq_accounts__id_currency`, `uq_txn__id_effective` and `fk_entries__txn_effective`. A fifth,
  `uq_txn__one_reversal` — the double-reversal guard spike 001 identifies as a real Formance bug class
  — appears in [0006](./0006-schema-conventions.md), but only as a naming example, which is not the
  same as being justified anywhere. Of the four, **`uq_accounts__id_currency` and `uq_txn__id_effective`
  are the referenced-side unique indexes the composite foreign keys point at** — drop either and the
  schema does not load (`there is no unique constraint matching given keys`), verified. A constraint
  whose absence makes the schema unbuildable needs no test. `fk_entries__txn_effective` is the foreign
  key itself, not an index, and dropping it loads cleanly — it does need one.
- **PostgreSQL 18 is a floor, not a preference.** `uuidv7()` is the default on **six** tables and does
  not exist before 18. The roadmap targets RDS for M4/M6, which must therefore run 18.
- **Three chart constraints have no ADR**: `uq_fs_lines__caption` (two lines sharing a caption are
  indistinguishable on the face of the statement — the restricted-cash harm arrived at from the other
  side); `ck_fs_lines__code_reserved` (a real chart line may not shadow the `current_year_earnings`
  plug the balance sheet synthesises); and `ck_fs_lines__caption_reserved`, **the half that does the
  harm** — `balance_sheet` emits that plug's caption as a literal, so it sits outside the UNIQUE and a
  line under any other code could take it.

## On sourcing

Claims about third-party systems are the weakest evidence in this repository, and twice a number
attributed to a named project turned out never to have existed. Three rules follow, and they are cheap:

- **A third-party figure needs a fetchable source next to it, or it is marked unverified.** Not
  softened — marked. "I could not check this" is a finding, not an embarrassment. *This rule is not met
  today:* an audit counted thirteen unique external URLs in the whole tree against dozens of third-party
  figures, and three attempts to cover the gap with a section banner each turned out to cover less than
  claimed. **So: treat every third-party figure in this repository as unverified unless a URL sits next
  to it.**
- **Corrections get applied to the document that carries the claim**, not only to the ADR that
  discovered it. `grep` the struck phrase across the whole tree, not just `docs/`.
- **A spike's own verification can be dead.** Nothing in `spikes/` is executed by CI, and nothing in
  `spikes/` runs against the shipped schema, so "measured" there means "was measured once, against
  something".

## How this log works

One file per decision, numbered, never deleted. A decision that turns out wrong gets a new ADR
superseding it; the old one stays, with its status changed, so the reasoning trail survives.

Each ADR states its decision as a claim, then **Why**, **Alternatives** and **What it costs**. Where
measurement later corrected a decision, the ADR states the current position **first** and summarises
what it superseded — you should never have to read a change history to learn what we think now.
