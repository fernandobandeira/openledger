# 0004 — The ledger goes in Rust; PostgreSQL holds the shape

**Status:** accepted
**Evidence:** [spike 006](/spikes/006-how-other-ledgers-enforce)
for the survey, [spike 001](/spikes/001-formance) for Formance.

## The decision

**The ledger is Rust. PostgreSQL holds the shape** — tables, types, `NOT NULL`, single-row `CHECK`s,
foreign keys, unique indexes. No PL/pgSQL logic, no orchestration, no derivation-with-backfill.

**A trigger needs a written justification in the schema beside it, and the default is none:** **the
invariant** it holds, **why nothing declarative holds it** — no `CHECK`, no key, no `GENERATED`
column, not simply withholding the privilege — and **what it does NOT protect against**. Two clear
that bar, as six trigger objects over two functions: append-only and `TRUNCATE`-refusal on the three
immutable logs. Nineteen did not; the table below sums 27 removed-or-kept. *(It was eight objects
over four logs while the card event log shipped in the same file; that log is now parked, and the
two functions are unchanged.)*

## Why

**A column with a `DEFAULT` is not a constraint.** `recorded_at`, `account_seq`, `xact_id` and
`uuidv7()` ids had a default and nothing else, and every one proved forgeable by an `INSERT`;
`effective_at` was made honest inside a composite key. Each row below is a state the design claimed
impossible, reached with the application role's ordinary `INSERT` grant and every check green.

| The invariant | What was reached without it |
| --- | --- |
| **The journal is sealed at commit** — an entry may not join a transaction created by a *different, already committed* one. | Append-only protected the **entry**, not the **journal**: a balanced, correctly-dated, correctly-sequenced pair of legs was added to a transaction committed and reported months earlier — February revenue 500.00 → **1,166.00**, with the drift view, the equation and the balance sheet all green. Deleting a transaction's legs *and* its row together erased 50,000 of revenue past the min-entries guard. |
| **`recorded_at` assigned, never accepted** — and assignment is still not enough. | Client-supplied insertion times let an already-issued recorded-axis report be rewritten months later, let one transaction's two legs carry different recording times (a balanced journal reporting **unbalanced**), and produced a green report that was 50% wrong. Assigning `now()` shrinks the window without closing it: `now()` is transaction-*start* time, so a writer that begins before a report and commits after it inserts rows claiming to predate it — same query, same as-of, either side of one `COMMIT`, revenue 110,000.00 → **160,000.00**, balanced both times, zero drift. **A timestamp cannot order commits**; [0006](/decisions/0006-time-and-as-of) is the outstanding work. |
| **`account_seq` *issued*, not validated.** | Uniqueness and positivity were not enough: an `INSERT` left a 48-wide gap and later filled it with a backdated, balanced, same-account round trip — gross turnover 100 → **100,000,000**, all three copies of the balance agreeing. Validating the incoming value against the balance cache is the same mistake one level down, because the application role holds `UPDATE` on that table: the counter was not issued, it was *asked*. **A drift view detects disagreement, never fabrication.** |
| **`TRUNCATE` refused.** | `TRUNCATE ledger_entries, ledger_account_balances` left eleven transactions standing with zero entries, every currency `balanced = t`, drift at zero rows, the equation satisfied. Nothing was wrong with any report; there was nothing left to disagree with — **silence read as assent.** A deferred `ck_txn__has_entries` cannot speak: it fires at the commit of a statement that *touched* a transaction, and `TRUNCATE` is not one. The schema comment beside the `REVOKE`s said *"Nothing in SQL can stop that."* A reviewer disproved it in four lines. **A "cannot" is a claim like any other.** |
| **Immutability on the event log**, not just assignment. | `ledger_events` stamped `recorded_at` on insert and let an `UPDATE` rewrite it afterwards — and `idempotency_hash` with it, the column whose entire job is *same key, different body, refuse*. Rewrite the hash and the next replay of that key returns the wrong stored result. |
| **An account's owner frozen.** `purpose`, `currency` and `tenant_id` are frozen by unique indexes and composite foreign keys; the owner is not. | One `UPDATE` moved 110,000 of receivable from a named company to `owner_id NULL`: every balance identical, trial balance balanced, drift silent — because no report reads the owner. A receivable owed by nobody is not a receivable, and there is no entry to reverse. |
| **A correction pointing at something it can correct.** `resolves_id` and `reverses_id` have foreign keys, so the target must *exist*. | Nothing requires the target to be in a state the correction means anything against. A posted transaction "resolved" by another posted one, and a pending one "reversed", took revenue to **−49,223** with drift at 0 and the equation balanced. The referential integrity was real; the semantic linkage was assumed. |
| **`ENABLE ALWAYS` on triggers — including the foreign keys' own.** | `session_replication_role = 'replica'` (the logical-replication apply path, and what `pg_restore --disable-triggers` sets) skips triggers left in the default `ENABLE ORIGIN` state, **and foreign keys are implemented as triggers**. With the FK triggers left in that state, a transaction spanning two tenants, both legs in a currency their account does not hold, dated 27 years before its own transaction, committed cleanly on that path. *(Open: all **36** internal FK triggers in the shipped schema are `ENABLE ORIGIN` — nine foreign keys, four triggers each, re-counted after the card split took the tenth.)* |
| **A chart that cannot contradict itself.** | Pointing a `revenue` type at a cost-of-revenue line put 6,000 of revenue on the expense side of the income statement — the harm [0007](/decisions/0007-schema-conventions-and-chart) is about — with every check green. A balance-sheet line carrying side `debit` was counted on *neither* side and vanished: 90% of a sheet missing, reporting balanced. Now a composite foreign key rather than a trigger, which is strictly better. |
| **One convention per hold group; expiry measured against a snapshot.** | Mixing deltas with cumulative totals is *irreconcilable*, not merely awkward. And `assigned_at > expired_at` compares two `now()` values, so any writer whose transaction opened before the release timer fired was invisible. Both are [0001](/card/decisions/0001-authorization-holds)'s, and both survive in the card DDL — now parked in [`parked/card/`](/card/parked) and applied by no migration. |

**A finding is a claim, too.** One escape once recorded here — plant a transaction carrying a *future*
`xact_id`, wait for the counter to reach it, then append legs — reached an ADR and a migration on a
reviewer's report alone and does not reproduce: the forged value seals the transaction against its own
legs at plant time, and a leg-less transaction cannot commit. **An adversary's demonstration adopted
without re-running it is the sourcing failure nobody watches for.**

**The schema had quietly become the ledger.** At the time: **11 lines** of application code outside
`spikes/` — a `main` printing "nothing to run yet" — against **10,053 lines** of SQL and harness,
**26** PL/pgSQL functions, **27** triggers. SQL written to check a decision was implementable had
absorbed the balance invariant, sequence assignment, running balances, the report views and the
**entire card authorization state machine**; ten rounds of adversarial review hardened it. Real
defects turned up every round, almost none *ledger* defects: a provably dead `WHERE` disjunct, a
catalog census that repaired the mutant it measured, a `PIPESTATUS` read clobbered by the `|| fail=1`
beside it, a bash substitution aborting under `set -e`. **The finding count measured how much
machinery there was to attack, not how much risk.** Triggers were the symptom: you need one only to
police a table arbitrary callers write to directly, which happens only where no service fronts it.

| Group | Count | What replaces it |
| --- | --- | --- |
| `TRUNCATE` refusal | 7 → **3 kept** (4 while the card log shipped) | Kept, on the immutable logs. There is no declarative alternative and no way to collapse them: PostgreSQL refuses event triggers for `TRUNCATE TABLE` outright (verified: `ERROR: event triggers are not supported for TRUNCATE TABLE`), and `TRUNCATE` fires no `ON DELETE` trigger. |
| Immutability (no `UPDATE`/`DELETE` on the journal) | 5 → **3 kept** (4 while the card log shipped) | `REVOKE` **and** a trigger. The grant binds the application role; the trigger is the only thing that also binds a backfill script or a human at a psql prompt. One `refuse_mutation()` over them all. |
| Assignment (`recorded_at`, `xact_id`, `account_seq`) | 5 | The writer assigns them, with no parameter for a caller to supply — stronger than a `DEFAULT`, which is overridable, and that was a measured defect: a client-settable insertion axis let an already-issued report be rewritten by a transaction claiming to predate it. |
| Cross-row validation | ~10 | Two became **foreign keys** (below). The rest — "debits equal credits", "at least two entries", correction targets — are enforced by *construction*: the writer builds both legs in one code path, so an unbalanced transaction is **unrepresentable** rather than refused ([0005](/decisions/0005-event-log-and-write-path)). |

**Two triggers became keys, which is strictly better** — visible in `\d`, needing no test.
`ledger_accounts` copies `category` and `normal_balance` from its type, so the copy is now `(purpose,
category, normal_balance) → account_types (code, category, normal_balance)`; and `account_types`
gained two `GENERATED ALWAYS … STORED` columns for the statement and side its category implies, plus
`(fs_line, fs_statement, fs_side) → fs_lines (code, statement, side)`. Both replace *seed*-time
guards.

**The survey says the category to remove is orchestration, not integrity.** Formance ran it in
production. Their `0-init-schema` was a full PL/pgSQL write engine: an `AFTER INSERT` trigger
`handle_log()` dispatching into `insert_transaction()` → `insert_posting()` → `insert_move()`, with an
unbounded `UPDATE` cascade over effective-axis volumes. Migration 11, `make-stateless`, dropped the
five triggers, moving orchestration into Go; migration 37, `clean-database`, dropped twenty-seven
stored functions, its comment calling them *"useless … inherited from stateful version"*. Eight repair
migrations exist because of it, and seven per ledger still run today. Their line between the two is
the sharper form of our bar: **a trigger survives if it needs rows OTHER than the one being written,
and goes if it is a pure function of the new row** — `set_log_hash` needs the predecessor's hash under
a lock, the effective-volume pair needs neighbouring moves in business-date order, the
metadata-history triggers need `max(revision)+1`. It does not cover our two, which read only `OLD`:
**the writer we protect against is not ours.** Their rule is about *cost*, ours about *who*.

**Airbnb's demolition is the same shape**: MySQL triggers doing change-data-capture into audit tables,
feeding an ETL pipeline that took over 24 hours — *"SQL is good for lightweight data transformation.
It is not designed to handle complicated business data flow."* **Neither removed a constraint.**
**TigerBeetle enforces its invariants in the database on purpose** — *"accounting invariants such as
balance limits are enforced within the database"* — but not in SQL: no `UPDATE`, no `DELETE`, no half
a transfer, nothing for a guard to police.

## Alternatives

| | Why not |
| --- | --- |
| **Zero triggers** | Reasoned from maintainability alone, and [spike 006](/spikes/006-how-other-ledgers-enforce) corrects it: three of the nine ledgers surveyed ship triggers in production, the anti-trigger doctrine has no canonical citation, and two invariants have no declarative form and no application-side reach. |
| **Validate rather than assign** | Tried for `account_seq` against the balance cache: the application role can write the thing being validated against, and a brand-new account has no cache row at all, so bigint-max was accepted and the account was permanently bricked. |
| **A Postgres sequence for `account_seq`** | Three reasons, and the first two are fatal. A sequence is **per table, not per account** — `account_seq` has to run 1, 2, 3 *within each account*, so a shared counter gives account A 1, 5, 9 and account B 2, 3, 4; getting per-account numbering out of sequences means one sequence object per account, created by DDL at account-open time. And **`nextval()` is non-transactional and deliberately leaks gaps**: a transaction that takes 5 and aborts leaves a permanent hole, which is exactly what [0006](/decisions/0006-time-and-as-of) rejects `bigserial` for on the as-of cursor, and what Formance documents against its own per-ledger sequence — *"we can still have holes on ids since a sql transaction can be reverted after a usage of the sequence"*. Gaplessness is the property `account_seq` exists to provide: it is the key a drift check walks and every as-of reconstruction depends on, so a hole makes *"did we lose an entry, or did a transaction abort?"* unanswerable. Third and cheapest: the writer already holds the balance row's lock, so `last_seq = b.last_seq + 1` in that same statement is free and advances the balance and the counter **atomically together**, where a separate sequence is a second source of truth that can disagree with the balance it orders. |
| **"One service owns the writes"** | A hope about deployment — it fails the day someone writes a second adapter or a backfill. Formance ships **zero `GRANT` and zero `REVOKE` in its entire repository** and does not bet on it either; their guarantee is a *type* ([0005](/decisions/0005-event-log-and-write-path)). |

## What it costs

These invariants bind only writers that are ours — not **direct DML by the owner**, not **a second
adapter** written later, not the `session_replication_role = 'replica'` paths above, where the manual
says *"in the default configuration, triggers do not fire on replicas"*. The six triggers are
`ENABLE ALWAYS`, firing *"regardless of the current replication role"* — by counterexample: with it
removed, `SET session_replication_role='replica'; DELETE FROM ledger_events` deletes the row; with it,
refused.

**They still bind accidents, not intent.** An owner drops a trigger in one statement, and nobody in
this field holds append-only with a database mechanism: Monzo uses a reviewed service-mesh allowlist
that took `service.ledger` from callable-by-1,500 to callable-by-six, Uber cryptographic signatures
over each record. Both published answers live outside the database; this is the cheap 80%.

**What the database still cannot enforce**, recorded because the alternative is implying it can:

| | |
| --- | --- |
| **`REVOKE CREATE ON SCHEMA public FROM PUBLIC` is a no-op here** | Since PostgreSQL 15, PUBLIC has no `CREATE` on `public` to revoke — load-bearing only on PG ≤ 14, and our floor is 18. Not a defence. |
| **`GRANT ALL` re-grants everything** | And a superuser can set `session_replication_role` or drop the triggers. There the defence is backups and audit, not the schema. |
| **Table inheritance disarms every constraint — open** | `CHECK`s are inherited; foreign keys, unique indexes and triggers are not. A child of `ledger_entries` plus one `INSERT … SELECT * FROM ONLY` took an income statement from 900 to 1,800, and the child stays visible through the parent to every view. `pg_event_trigger` is empty. |
| **Gaplessness is enforced at issue, not verified at rest** | Nothing scans the journal for a gap that arrived some other way. |
| **The chart is not versioned** | `fk_types__fs_line` blocks a statement-line change only across a statement or a side; **within one statement and side it is accepted, under posted history** ([0007](/decisions/0007-schema-conventions-and-chart)). Reclassifying `fbo_cash` from `restricted_cash` to `cash` moved 440.00 of customer float into unrestricted liquidity, one statement, no error. A stopgap, since IAS 1.41 *requires* reclassifying comparatives. |

**Until the write path exists, nothing enforces balance at all.** `ledger_entries` stores independent
rows carrying a `direction`, so an unbalanced transaction is expressible and the deferred trigger that
refused it is gone. Every system in the survey that made this move shipped the enforcing code path
first; we did not. The fix is a posting-shaped write primitive, not a grant and not a trigger
([0005](/decisions/0005-event-log-and-write-path)).

**What survives:** `migrations/00001_baseline.sql`, applied by
`openledger migrate` — the counted inventory of what is in it lives in one place,
[the database page](/database#what-the-schema-enforces-today), and is deliberately not repeated
here. It proves the shape is expressible
declaratively, and `schema/chart.sql` seeds a chart satisfying it. The suites that exercised it are
deleted; what they *learned* is in these ADRs, and returns as tests beside the code.
