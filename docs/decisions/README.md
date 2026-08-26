# Decisions

Everything we've decided, on one page. Read this to know where the project stands; follow a link only
when you want the reasoning behind a particular call.

New to ledgers? Start with the [glossary](../glossary.md) — it defines every domain term used here, so
the ADRs don't each stop to re-explain them.

## The stack

- **Rust** — the ledger is written in Rust; Postgres holds the shape. Chosen over Go after
  [spike 010](../../spikes/010-go-or-rust/README.md) built both against the real schema and seeded
  this project's own bugs into each: Rust's compiler caught **5 of 5**, Go's caught **0 of 5**, and
  two of the five were guarantees an accepted ADR had already claimed in writing and did not have.
- **Postgres**, one instance — measured at ~800 **clearings**/s untuned (a clearing is one card
  transaction = 3 ledger entries), rising to ~6,970/s with the hot account striped 64 ways and 7,897/s
  striping *and* posting in a single call, on a 2 GB table; the comparable 43 MB figure is 7,816.
  Spike 003's own banner applies: re-auditing the same configurations moved the baseline from 833 to
  482, so **treat these as shape, not as a benchmark**. Nothing has been measured over a network.
- **sqlx**, no ORM — we write the SQL; it is checked against a live database at compile time. The hot
  queries stay reviewable *as SQL*.
- **Postgres for durable timers too** — an in-process job queue, no scheduler cluster to run.
- **Migrations are `sqlx` plus fifteen lines of our own locking**, run as a pre-deploy command.
  Exactly one Rust migrator attempts cross-process coordination and it does it the wrong way.

## The decisions

Nine. Eight came from consolidating fourteen by subject once the language changed; the ninth
answers how an optional module that owns tables gets shipped. Two files were
archaeology: one recorded what a deleted PL/pgSQL implementation could not guarantee, one compared
two Go code generators. Their evidence moved into the file that owns the subject; their narrative did
not. **One decision nearly went with them** — *"a general ledger with a card product as its reference
implementation, not a card ledger"* — and is now the opening line of
[0002](./0002-scaling.md), because it is what decides the build order.

| # | We decided | Because | Status |
| --- | --- | --- | --- |
| [0001](./0001-rust-and-postgres.md) | **Rust** on one Postgres 18, with sqlx and no ORM | Two of this project's written guarantees turned out false in Go, and only a type system catches that. Postgres has measured headroom of 16–40× what we sized for | accepted |
| [0002](./0002-scaling.md) | One Postgres, with the hot account striped | The bottleneck is one contended row, not the hardware — and splitting per tenant *relocates* it (1.07× under a dominant tenant) where striping removes it | accepted |
| [0003](./0003-migrations.md) | `sqlx` + our own try-lock, as an `openledger migrate` pre-deploy command | A *blocking* advisory lock deadlocks against `CREATE INDEX CONCURRENTLY`. sqlx blocks; every other Rust migrator has no lock at all | accepted |
| [0004](./0004-where-logic-lives.md) | **The ledger goes in Rust. Postgres holds the shape, and a trigger needs a written justification** | The schema had quietly become the ledger — 27 triggers and 26 functions against 11 lines of application code. And a column with a `DEFAULT` is not a constraint: `recorded_at`, `account_seq` and `xact_id` each had one and each was forgeable by an `INSERT` | accepted |
| [0005](./0005-event-log-and-write-path.md) | An append-only `ledger_events` table, and **a posting — not an entry — as the write primitive** | Most accepted operations write no ledger transaction, so idempotency cannot live on the transactions table. And "one service owns the writes" is a hope about deployment; a type that cannot express an unbalanced transaction holds for every caller | accepted |
| [0006](./0006-time-and-as-of.md) | Running balance for "now", aggregate-on-read for "as of a business date" — and reports pinned to a commit-ordered cursor | A backdated entry lands with a *later* sequence number. And `recorded_at` is transaction-*start* time, so the same "as of" query re-runs to a different answer | accepted; **the as-of cursor is unbuilt and blocks M5** |
| [0007](./0007-schema-conventions-and-chart.md) | Naming rules, a CI schema-snapshot test, and the chart of accounts as data with completeness as a separate invariant | Dropping a column silently drops its indexes — Formance lost two that way, unnoticed for sixteen migrations. And a dropped *balanced sub-book* satisfies the accounting equation while the report is incomplete | accepted |
| [0008](./0008-authorization-holds.md) | A hold is a SUM over an append-only event log, and its timers are job rows in Postgres, not a workflow engine | Grouping a clearing to its authorization is a revisable inference, and processors disagree on whether an increment carries a delta or a cumulative total. The need is durable *scheduling*, and a job row commits in the same transaction as the ledger write, which Temporal cannot do | accepted |
| [0009](./0009-module-boundaries.md) | **The card module gets its own Postgres schema, not its own migration set** | Not one foreign key crosses the card/core boundary, so the seam is real — but `sqlx` has no ordering between migration sets, and of eight systems read from source, the only two that separate cleanly give each component its own *database* | **proposed** |

## Non-negotiable

No decision may trade these away. They are what makes the numbers trustworthy:

- **Append-only.** No `UPDATE`, no `DELETE`, no `TRUNCATE` on entries — enforced by triggers that
  refuse the statement outright, not by discipline and **not by the grants**. A `REVOKE` is a
  point-in-time change to a privilege; one `GRANT ALL` undoes it.
- **Balanced per currency.** Enforced by *construction* in the Rust writer — a posting names a source
  and a destination, so one leg is unconstructible ([0005](./0005-event-log-and-write-path.md)). Non-negotiable
  as a property of the design; **not true of the current tree, because the writer is not built.**
- **Bitemporal.** Every entry records both when it happened and when we learned about it.
- **Event-logged.** Every accepted operation is recorded, whether or not it moves money. *Not yet
  enforced:* `ledger_transactions.event_id` is nullable — see "Still open".
- **Correctness is never configurable.** Formance made historization a feature flag and got
  point-in-time queries that silently return empty — *"a green check that didn't actually execute."*
  Make the product pluggable; never the invariants.
- **Prefer a constraint that makes a state unreachable to a check that looks for it afterwards.** The
  chart guard refused a wrong chart at *seed* time: the wrong system could not be built, so no test
  had to notice. [0004](./0004-where-logic-lives.md) turned it into a foreign key, which is the same
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
| **Debits equal credits** | **Deliberate.** [0005](./0005-event-log-and-write-path.md) makes it unconstructible in the Rust writer rather than refused in SQL. Until that writer exists, **nothing enforces it at all**, and it says so. |
| `recorded_at`, `xact_id`, `account_seq`, `balance_after` | **Deliberate.** Assigned by the writer, which has no parameter for them. Today `recorded_at` and `xact_id` are bare `DEFAULT`s; `account_seq` and `balance_after` have no default at all and are wholly caller-supplied and are forgeable by an `INSERT` — verified, `recorded_at` accepted as `1999-01-01`. |
| **Foreign keys on the replication apply path** | **Not deliberate.** All 40 internal FK triggers are `ENABLE ORIGIN`. Under `session_replication_role = 'replica'` every foreign key is skipped — verified: a two-tenant entry in a currency its account does not hold, dated 1999, committed. |
| **Table inheritance** | **Not deliberate.** The event trigger went with the PL/pgSQL. A child of `ledger_entries` plus one `INSERT … SELECT * FROM ONLY` doubles every number in every report — verified. |
| **Reclassifying a statement line** | **Not deliberate.** `fk_types__fs_line` blocks a move that contradicts the category; it does **not** block a move to another line of the same statement and side. Verified: 440.00 of customer float moved from restricted cash to unrestricted on an already-issued balance sheet. |

The last three are the honest cost of [0004](./0004-where-logic-lives.md), and they are in *Still
open* below.

## Still open

Undecided, listed plainly rather than buried.

| | |
| --- | --- |
| **Three guarantees [0004](./0004-where-logic-lives.md) removed** | All three were closed by PL/pgSQL that no longer exists, and all three are reproducible on the shipped schema. **Foreign keys are skipped on the replication apply path** — 40 internal FK triggers (ten foreign keys, four triggers each), all `ENABLE ORIGIN`; the fix is one `ALTER TABLE … ENABLE ALWAYS TRIGGER` each, and it needs a decision about whether a design-stage schema should carry it. **Table inheritance is open again** — a child of `ledger_entries` is visible through the parent to every view and carries none of its keys or triggers. **A statement line can be reclassified under posted history**, as long as the new line shares the old one's statement and side. |
| **[0006](./0006-time-and-as-of.md)'s as-of cursor is unbuilt** | The hole it names is live: the same recorded-axis report, re-run either side of one concurrent commit, moved revenue by 45% with every check green. `recorded_at` is transaction-*start* time, and a timestamp cannot order commits. The as-of cursor blocks **M5**, not M4 — M4 is the RDS benchmark and is unblocked. |
| **Inter-scope obligations reconcile against nothing** | A tenant booking 100,000.00 of `due_from_treasury` against an operator booking 60,000.00 of `due_to_tenants` leaves every scope balanced, every check green, and 40,000.00 of asset owed by nobody. No view compares the two sides — the ledger-side drift views were deleted by [0004](./0004-where-logic-lives.md), and the one that remains, `card_hold_drift`, is card-specific. Each sub-book is internally consistent; nothing compares the two sides. |
| **The balance sheet nets counterparties the chart declares un-nettable, and the schema cannot express the fix** | `balance_sheet` groups by `fs_line` and never reads `counterparty_scope`, so owing t1 425.00 while t2 owes 425.00 prints a payables line of **zero** — both sides understated, `trial_balance` holding the correct gross figures, and every check green. Sharding the account per counterparty does not fix it: the netting happens in the *report*, one level above the account, and an account's statement line is fixed by its type, so t2's opposite-sign position has no line to move to even if the column were read. IAS 32.42 / ASC 210-20-45-1 permit offset only between the same two parties. |
| **The balance sheet has no period, and the income statement has no parameter** | With no close, the synthesised earnings plug sums revenue and expense over *all posted history* — 34,000.00 against a true current year of 4,000.00 on a three-year book, growing without bound. The caption now says "Undistributed earnings (since inception)", which is honest and is not the fix. The fix is the period close, designed and unbuilt; `retained_earnings` ships in the chart and stays at zero forever because nothing routes to it. |
| **The balance cache includes `pending`; every report excludes it** | All three copies of every balance count pending transactions and no report does, so a customer served from the cache can be shown 500.00 while the balance sheet shows 0.00, and nothing reconciles the two. Arguably available-versus-posted by design; nothing says so, and no view surfaces the pending population. |
| **No report accepts both time axes, and the three statements accept neither** | the accounting equation, when it is rebuilt in Rust, must take one axis; `trial_balance`, `balance_sheet` and `income_statement` are parameterless. An issued statement cannot be reproduced after any backdated posting — legal, append-only, every check green. Separate from [0006](./0006-time-and-as-of.md): a perfect commit cursor still would not reproduce an issued effective-period report through a single-axis parameter. |
| **`counterparty_scope` and `is_perimeter` are declarative** | Both documented at length, both carrying CHECK constraints, and no view or function reads either — so the offsetting rule [0007](./0007-schema-conventions-and-chart.md) §5 states as a mechanism is not implemented, and **a wrong value in either is undetectable by any test.** Documentation stored in a column. |
| **Row-level security does not exist yet** | `schema/` contains no `CREATE POLICY` and no `ENABLE ROW LEVEL SECURITY`, while [0001](./0001-rust-and-postgres.md) asserts "tenant isolation *is* row-level security". `tenant_id` leading every key is the prerequisite and is built; the policies are not. It also conflicts with bulk loading — Postgres refuses `COPY FROM` on a table with RLS enabled, and `COPY` is what makes batched posting fast. Likely resolution: post through a role that bypasses RLS, so RLS guards reads only. |
| **Historical balances get slower as history grows** | "The balance right now" is a single index lookup (0.018 ms); "as of last June" adds up entries, which is linear. The per-entry rate and the 105.91 ms at 1M usually quoted here come from a one-off run with **no harness in the repository**; the linearity is the claim. The fix is the accountants' one — close each period and store its closing balance. [0006](./0006-time-and-as-of.md) has the numbers. |
| **The write path requires READ COMMITTED** | REPEATABLE READ and SERIALIZABLE lose most writes to serialization failures on the balance upsert, and a retry loop does not rescue it. Nothing in `spikes/` or `schema/` sets an isolation level, so the roadmap's figures are observations from a one-off run rather than measurements — but the conclusion does not depend on them: `ON CONFLICT DO UPDATE` under a stricter level fails with `could not serialize access`, which is a property of Postgres. A hard deployment constraint, recorded in no ADR. |
| **`event_id` is nullable** | So "every transaction references its causing event" is a convention rather than an invariant. `NOT NULL` is the fix; it is not done. |
| **There is no idempotency replay path** | `idempotency_hash` is written and never read, so "same key + same body replays the stored result; a different body is refused" is designed and unbuilt. The unique index only makes the second attempt fail. |
| **Striping is not built** | The stack summary above quotes striped figures. There is no stripe column in `schema/`, and `uq_accounts__house` would currently prevent one on the accounts that need it. |
| **There is no CI** | `.github/workflows/test.yml` was present in three commits' trees and was deleted with the suite it ran ([0004](./0004-where-logic-lives.md)). It comes back when the Rust tests do, and should run `cargo test` and load `schema/schema.sql` against a PostgreSQL 18 service. |
| **Hash chaining for tamper evidence is deferred, not decided** | [0005](./0005-event-log-and-write-path.md) leaves it open: it needs a total order, so it is entangled with [0006](./0006-time-and-as-of.md). The cost figures quoted there are extrapolated from spike 003's contended-row numbers, not measured. |
| **The chart of accounts is not versioned** | Changing which statement line an account reports under silently restates issued statements, and `fk_types__fs_line` blocks that **only across a statement or a side** — a move to another line of the *same* statement and side is accepted, which is the reclassification hole three rows above. An earlier version of this row said it was "blocked outright"; it is not. A stopgap either way, since IAS 1.41 *requires* reclassifying comparatives. See [0007](./0007-schema-conventions-and-chart.md). |
| **No number has been measured on RDS** | Everything so far is localhost, where a round trip is ten times cheaper. Nothing gets published until that is fixed. |
| **Hold-flow findings recorded rather than closed** | The list lives in [0008 §Known, and not fixed](./0008-authorization-holds.md#known-and-not-fixed), and **at least four of them under-reserve credit**, the failure this project calls the cardinal sin. *There is deliberately no copy of that list here* — a count maintained in two files is a count that drifts, and this one miscounted four rounds running. |
| **Completeness is guaranteed WITHIN a scope, not across them** | Recorded only in `schema/schema.sql`. A scope with no accounts at all is invisible to every report, and a tenant parameter on the balance-sheet report is exactly the "parameter in which to pass an incomplete list" that [0007](./0007-schema-conventions-and-chart.md) says should not exist. `vision.md` states the completeness guarantee without that qualification. |
| **Intercompany balances are presented GROSS** | Nothing nets `due_from_treasury` against `due_to_tenants`, so a consolidated balance sheet shows both sides at full size. The golden trace asserts they eliminate to zero; no *report* does. |
| **Statement periods have a timezone and nothing models it** | `reference-product.md` closes statements "in the customer's timezone" and [0008](./0008-authorization-holds.md) says per-customer timezones make the statement run a per-customer job. `grep -rn "AT TIME ZONE"` over the whole tree returns **zero hits**, and [0006](./0006-time-and-as-of.md), which owns time, scopes itself away from the question. A period boundary is a business-date boundary in *someone's* zone; nothing says whose. |
| **The card schema is not separated yet** | [0009](./0009-module-boundaries.md) decided it — card objects move to a `card` schema inside the one baseline, making the module **removable** rather than optional — and **that move is not done.** Today all 11 tables are in `public`, of which **4 are card-specific** (`card_auth_events`, `card_auth_event_group`, `card_hold_groups`, `webhook_deliveries`) along with 2 of the 5 views. 0009 is `proposed`, and the collision test it requires does not exist. |
| **The balance-sheet half of `fk_types__fs_line` is two-valued** | The income-statement half distinguishes revenue from expense; the balance-sheet half distinguishes only `asset` from `liability_equity`, so **`liability`, `equity` and any contra of either are freely interchangeable across all five liability-and-equity captions.** Verified: 1,000.00 of paid-in capital presented under "Accounts payable and accrued", assets − liabilities-and-equity = 0.00, every check green. The key is called this file's best guard; on the balance sheet it is a two-way check. Splitting the side into `liability` and `equity` is the obvious fix and would need every balance-sheet line re-declared. |
| **Nothing reconciles the journal against the reports** | A `SUM` over `ledger_entries` and a `SUM` over `trial_balance`, per tenant and currency, should agree and are compared by nothing. Measured on a book carrying one orphan pair: raw journal 55,280.96 against a trial balance of 5,280.96 — a 50,000.00 gap reported by no view, no constraint and no function. Three lines of SQL would surface it. This is the residual cost of joining the reports on currency: the orphan is now consistently absent rather than inconsistently present, which is better, but it is also unfalsifiable from inside the artefact. |
| **Reclassification has a second path, through the account** | The register above records the chart route (`account_types.fs_line`), which a schema snapshot test could see. `fk_accounts__type` is on `(purpose, category, normal_balance)`, so **any account may become any other type sharing its category and normal balance, with the chart byte-identical.** Verified: 1,400.00 of restricted cash became Other assets and 1,000.00 of customer funds became trade payables, every check green, `chart.sql` untouched. The interchangeable sets are **4** asset/debit types and **8** liability/credit types. `ledger_accounts`, `account_types` and `fs_lines` — the three tables that decide what every posted number *means* — carry no append-only guard and appear on neither the guarded list nor the "what deliberately has no guard" list, so the absence does not read as a decision. |
| **DDL walks straight through append-only** | The trigger guard covers DML only. `ALTER TABLE ledger_entries ALTER COLUMN balance_after TYPE bigint USING (balance_after / 10)` **rewrote posted history with both triggers still `ENABLE ALWAYS` and neither firing.** The same rewrite of `amount_minor` — the column that would change a *reported* number — is refused while the views exist (`cannot alter type of a column used by a view or rule`) and succeeds after `DROP VIEW trial_balance, balance_sheet, income_statement`, which an owner doing a migration would do anyway. An earlier version of this row pasted the `amount_minor` form as if it ran unaided; it does not. This is *not* the hole the schema admits to (an owner disabling or dropping the trigger). A `ddl_command_start` event trigger could cover `ALTER TABLE`/`DROP TABLE`; the schema argues event triggers are useless because they cannot cover `TRUNCATE`, which is true and does not cover this. **Related:** `pg_dump -a` warns that the circular foreign keys on `ledger_transactions` require `--disable-triggers` to restore, and that flag issues `ALTER TABLE … DISABLE TRIGGER ALL` — so the ordinary data-only restore path routes through the one hole the file does name. |
| **Inheritance is a DELETE channel, not only a doubling one** | The register records that a child of `ledger_entries` doubles every report. It is also a way to **remove** rows: `DELETE FROM shadow_entries` took the parent-visible count from 8 to 4. The child carries 3 CHECKs and no foreign key, no unique index and no trigger. |
| **The chart is global; the ledger is multi-tenant** | `fs_lines` and `account_types` carry no `tenant_id` and are keyed on `code` alone, so **per-tenant charts are unrepresentable** and one tenant's reclassification restates every tenant's issued statements. Recorded nowhere before this line. |
| **One transaction can span two currencies at an implicit rate of 1.0** | Each leg satisfies `fk_entries__account` in its own account's own currency, so 100.00 USD became 100.00 EUR — accepted, at an implicit rate of 1.0. **The balance sheet then does *not* balance**, by +100.00 in USD and −100.00 in EUR; only debits-equal-credits *within the transaction* survives, and an earlier version of this row claimed both books balanced, which is more than the database does. The harm is the acceptance, not a silent report: there is **no FX gain/loss line in `fs_lines` and no FX type in `account_types`**, so even a correct writer has nowhere to book the difference. |
| **Nothing in the shipped artefact would notice debits ≠ credits** | The register already says nothing *enforces* it. The sharper point: nothing *reports* it either. No view mentions balance; the only multi-row constraints on `ledger_entries` are three single-row CHECKs. A posted transaction with one entry, or zero entries, is accepted and appears in no exception list. |
| **The balance cache and the journal have no relationship** | Using only the app role's granted `UPDATE`, the cache was moved from 1,000.00 to 100.00 with `last_seq` forged; the balance sheet was unchanged and every check stayed green. **Zero shipped views compare the cache to the journal, and zero constraints reference `ledger_entries` from it.** The ledger-side drift views went with [0004](./0004-where-logic-lives.md) and nothing replaced them. |
| **`balance_after` is forgeable and two writers collide on it silently** | [0006](./0006-time-and-as-of.md)'s headline O(1) read returned 9,999.99 where the cache and a journal aggregate both said 220.00. Worse, two concurrent sessions that do not route through the cache row both committed `balance_after = 1000` at sequences 4 and 5 where the truth was 200.00 and 210.00 — **nothing serializes them.** Separately: a whole book written with `balance_after = 0` on every entry produced three correct reports, because no report reads the column. |
| **An account's owner can be nulled** | `UPDATE ledger_accounts SET owner_type='house', owner_id=NULL` leaves the liability on the balance sheet owed to nobody, every check green. Credit where due: `uq_accounts__owned` and `uq_accounts__house` *do* bind updates — reassigning a wallet to another owner and collapsing two house accounts were both refused. |
| **`ach_pull_returnable` presents customer cash as a trade payable** | Same class as the `outbound_transfer_in_transit` line fixed in the chart: customer cash inside an ACH return window reports under `payables`, so the `payables` line hosts six types mixing `per_shard` and `shared` counterparty scopes and the netting problem recorded for `due_to_tenants` silently covers customer float too. |
| **A wrong-but-valid `status` is unfixable in place** | `status` is an enum, so only `pending` and `posted` are possible — but a complete balanced transaction written `pending` by mistake vanishes from all three reports, is counted by the balance cache, and `ledger_transactions` is append-only. The resolution path (`resolves_id`) is the intended recovery and no document says so. **No shipped view surfaces the pending population at all.** |
| **The auth hot path reads tables the schema does not define** | The authorization decision reads `credit_lines`; `schema/schema.sql` defines no `credit_lines`, no `spend_controls` and no `card_holds`. [Spike 010](../../spikes/010-go-or-rust/README.md) had to add a minimal `credit_lines` before either implementation could run the hot path at all. **The card flow's decision step is not implementable against the committed schema** — the hold *log* is built, the credit line it is decided against is not. |
| **Shipped surface nothing reads** | `webhook_deliveries` exist in `schema/schema.sql`, carry rationale in comments, and is referenced by no view and no function. `hold_expires_at` and `clearing_deadline` are *exposed* by `card_auth_unmatched` (it selects `e.*`) but nothing reads them for a decision, and nothing writes them — see [0008](./0008-authorization-holds.md), whose reconciliation sweep filters on one of them and therefore matches nothing. Either the next milestone's work or dead weight — and [0008](./0008-authorization-holds.md)'s reconciliation sweep *reads* one of them, which is why that sweep can never fire. |
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
  prevent double-posting. It belongs in [0005](./0005-event-log-and-write-path.md).
- **Four named correctness constraints are reasoned about in no document**: `uq_txn__one_resolution`,
  `uq_accounts__id_currency`, `uq_txn__id_effective` and `fk_entries__txn_effective`. A fifth,
  `uq_txn__one_reversal` — the double-reversal guard spike 001 identifies as a real Formance bug class
  — appears in [0007](./0007-schema-conventions-and-chart.md), but only as a naming example, which is not the
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

> **Every accounting-standard citation in this tree is unverified, everywhere it appears.** IAS 32.42,
> IAS 1.41, ASC 210-20-45-1, Reg S-X 5-02.1 and ASC 230-10-45-4 are behind paywalls, so no URL can sit
> next to them. Stated once here rather than marked at each of the eight sites, because a marker
> maintained in eight places is a marker that drifts — which is the failure this section exists to
> stop. **Treat every one of them as a paraphrase from memory until an accountant confirms it.**

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
