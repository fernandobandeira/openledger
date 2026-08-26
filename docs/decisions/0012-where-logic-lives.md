# 0012 — The ledger goes in Go; PostgreSQL holds the shape

**Status:** accepted
**Supersedes the enforcement half of** [0011](./0011-what-the-database-enforces.md)

## The decision

**The ledger is written in Go. PostgreSQL holds the shape** — tables, types, `NOT NULL`, single-row
`CHECK`s, foreign keys, unique indexes. No PL/pgSQL business logic, no orchestration, no
derivation-with-backfill.

**A trigger needs a written justification, and the default is none.** Each one must state, in the
schema beside it:

1. **the invariant** it holds;
2. **why nothing declarative holds it** — no `CHECK`, no key, no `GENERATED` column, and not simply
   withholding the privilege;
3. **what it does NOT protect against**, said out loud rather than implied.

Two invariants clear that bar, as eight trigger objects over two functions: append-only and
`TRUNCATE`-refusal on the four immutable logs. Twenty-five other triggers did not.

The sharper version of the bar, adopted from Formance's own line between what they deleted and what
they kept:

> **A trigger survives if it needs to read or write rows OTHER than the one being written. It goes
> if it is a pure function of the new row.**

Everything they dropped is computable from the row's own columns; everything they kept needs a
*different* row — `set_log_hash` needs the predecessor's hash under a lock, the effective-volume pair
needs neighbouring moves in business-date order, the metadata-history triggers need
`max(revision)+1`. The dropped kind is free to do in Go; the kept kind costs a round trip and a race.
That rule is a better predictor than "no business logic" — and it does not quite cover our two, which
read only `OLD` and should by that rule be in Go. They cannot be, because **the writer we are
protecting against is not ours.** Their rule is about *cost*; ours is about *who*.

## Why

**The schema had quietly become the ledger.** Measured when this ADR was written:

| | |
| --- | --- |
| Go, outside `spikes/` | **11 lines** — `cmd/openledger/main.go`, which prints "nothing to run yet" |
| SQL and test harness | **10,053 lines** |
| PL/pgSQL functions | **26** |
| Triggers | **27** |

This is a design project: the deliverable is the decisions, and the SQL existed to check that a
decision was implementable. Instead the balance invariant, sequence assignment, running balances, the
report views and the **entire card authorization state machine** became PL/pgSQL, and ten rounds of
adversarial review went into hardening it. The review found real defects every round, and almost none
were *ledger* defects: a provably dead `WHERE` disjunct, a catalog census that repaired the mutant it
was measuring, a `PIPESTATUS` read clobbered by the `|| fail=1` beside it, a bash command
substitution that aborted under `set -e`. **The finding count measured how much machinery there was
to attack, not how much risk there was.**

**Triggers were the symptom, not the disease.** You only need a trigger to police a table arbitrary
callers write to directly, and callers only write directly when there is no service in front of the
database. The count was a measurement of how much ledger had leaked into the schema:

| Group | Count | What replaces it |
| --- | --- | --- |
| `TRUNCATE` refusal | 7 → **4 kept** | Kept, on the four immutable logs. There is no declarative alternative and no way to collapse them: PostgreSQL refuses event triggers for `TRUNCATE TABLE` outright (verified: `ERROR: event triggers are not supported for TRUNCATE TABLE`), and `TRUNCATE` fires no `ON DELETE` trigger. |
| Immutability (no `UPDATE`/`DELETE` on the journal) | 5 → **4 kept** | `REVOKE` **and** a trigger. The grant binds the application role; the trigger is the only thing that also binds a backfill script or a human at a psql prompt. One `refuse_mutation()` over the four logs. |
| Assignment (`recorded_at`, `xact_id`, `account_seq`, `balance_after`) | 5 | The Go writer assigns them, with no parameter for a caller to supply — stronger than a `DEFAULT`, which is overridable, and that was a measured defect: a client-settable insertion axis let an already-issued report be rewritten by a transaction claiming to predate it. |
| Cross-row validation | ~10 | Two became **foreign keys** (below). The rest — "debits equal credits", "at least two entries", correction targets — are enforced by *construction*: the Go writer builds both legs in one code path, so an unbalanced transaction is **unrepresentable** rather than refused ([0013](./0013-the-write-path.md)). |

**Two triggers became keys, which is strictly better.** Both are visible in `\d`, cannot be forgotten
by a new writer, and need no test. An account may not disagree with its type: `ledger_accounts`
carries `category` and `normal_balance` deliberately — a report must not have to join the chart to
know the sign of a balance — so the copy is a composite foreign key into the row it was copied from,
`(purpose, category, normal_balance) → account_types (code, category, normal_balance)`. And a type's
statement line must agree with its category: `account_types` gains two `GENERATED ALWAYS … STORED`
columns for the statement and side its category implies, plus
`(fs_line, fs_statement, fs_side) → fs_lines (code, statement, side)`. That replaces the guard this
log repeatedly called its best, which refused a wrong chart at *seed* time — the wrong system could
not be built and no test had to notice. A foreign key does the same thing declaratively.

**The survey says the category to remove is orchestration, not integrity**
([spike 009](../../spikes/009-how-other-ledgers-enforce/README.md),
[spike 001](../../spikes/001-formance/README.md)). Formance ran this exact experiment — Go,
PostgreSQL, in production, the closest analogue there is. Their `0-init-schema` created a full
PL/pgSQL write engine: an `AFTER INSERT` trigger `handle_log()` dispatching into
`insert_transaction()` → `insert_posting()` → `insert_move()`, with an unbounded `UPDATE` cascade over
history to maintain effective-axis volumes. Migration 11, `make-stateless`, dropped the five triggers
and moved orchestration to Go; migration 37, `clean-database`, dropped twenty-seven stored functions,
its own comment calling them *"useless … inherited from stateful version"*. Eight repair migrations
exist because of that design — and they still run seven triggers per ledger today, on by default.
**Airbnb's demolition is the same shape**: MySQL triggers doing change-data-capture into audit tables,
feeding an ETL pipeline that eventually took over 24 hours to run, with the verdict *"SQL is good for
lightweight data transformation. It is not designed to handle complicated business data flow."*
**Neither project removed a constraint.** Meanwhile **TigerBeetle enforces its invariants inside the
database on purpose** — *"accounting invariants such as balance limits are enforced within the
database"* — but it is not SQL: there is no `UPDATE`, no `DELETE`, and no way to submit half a
transfer, so there is nothing for a guard to police.

## Alternatives

| | Why not |
| --- | --- |
| **Zero triggers** | Reasoned from maintainability alone, and [spike 009](../../spikes/009-how-other-ledgers-enforce/README.md) corrects it: the line falls between orchestration and integrity, and two invariants have no declarative form and no Go-side reach. Three of the nine ledgers surveyed ship triggers in production, and the anti-trigger doctrine has no canonical citation. |
| **Keep the PL/pgSQL and keep hardening it** | Ten rounds bought defect counts, not safety. The intricate artefact was in the wrong language, at the wrong layer, before deciding it should exist. |
| **"One service owns the writes"** | A hope about deployment, not a guarantee — it fails the day someone writes a second adapter or a backfill. Formance ships **zero `GRANT` and zero `REVOKE` in its entire repository** and does not bet on it either; their guarantee is a *type*. See [0013](./0013-the-write-path.md). |
| **A trigger per invariant, justified case by case** | What we do — but the default is none, and the justification is written in the schema, not in review. |

## What it costs

The write-path invariants hold only against writers that are the Go service:

- **direct DML by the owner**, including a backfill script or a psql session;
- **`pg_restore --disable-triggers`** and the **logical-replication apply path**, which set
  `session_replication_role = 'replica'`; PostgreSQL's manual states that *"in the default
  configuration, triggers do not fire on replicas"*, and that **foreign keys are themselves
  implemented as triggers** and are skipped there too;
- **a second adapter** written later that talks to the tables instead of the service.

The two surviving triggers are marked `ENABLE ALWAYS`, which the manual documents as firing
*"regardless of the current replication role"* — demonstrated by counterexample rather than asserted:
with `ENABLE ALWAYS` removed, `SET session_replication_role='replica'; DELETE FROM ledger_events`
deletes the row; with it, the same statement is refused.

**They still bind accidents, not intent.** An owner can disable or drop a trigger in one statement.
Nobody in this field holds append-only with a database mechanism: Monzo does it with a reviewed
service-mesh allowlist that took `service.ledger` from callable-by-1,500 to callable-by-six, and Uber
does it with cryptographic signatures over each record. Those are the two published answers and both
live outside the database. What is here is the cheap 80%, and the cheap 80% is worth having.

**Until the Go write path exists, nothing enforces balance at all.** `ledger_entries` stores
independent rows carrying a `direction`, so an unbalanced transaction is fully expressible, and the
deferred trigger that used to refuse it is gone. Every system in the survey that made this move
shipped the enforcing code path first; we did not. The fix is not a grant and not a trigger — it is to
make the write primitive posting-shaped, which is [0013](./0013-the-write-path.md).

**What survives from the SQL:** [`schema/schema.sql`](../../schema/schema.sql) — 11 tables, 5 views,
8 triggers over 2 functions, and it loads. It exists to prove the shape these ADRs describe is
expressible declaratively, and `schema/chart.sql` seeds a chart that satisfies it. The test suites
(`tests/run.sh`, `tests/canary.sh`, `tests/concurrency.sh`) are deleted: they tested PL/pgSQL that no
longer exists. What they *learned* is in these ADRs, which is where the output of a design project
belongs — order tolerance under out-of-order delivery, cumulative-total versus delta conventions, an
over-capture leaving a negative residue that swallows the next increment, an authorization writing no
entry while a clearing posts, the recorded and effective axes. Those findings were worth the rounds;
the code that produced them was not worth keeping. They come back as **Go tests**, next to the Go
that will implement them.
