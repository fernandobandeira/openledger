# 0012 — No triggers, and the ledger goes in Go

**Status:** accepted
**Supersedes the enforcement half of** [0011](./0011-what-the-database-enforces.md)

## The decision

**Zero database triggers. Zero PL/pgSQL.** PostgreSQL keeps what is declarative — tables,
types, `NOT NULL`, single-row `CHECK`s, foreign keys, unique indexes — and nothing else. Every
rule that needs to read another row is enforced in Go.

## What went wrong

This is a design project. The deliverable is the decisions; the ledger gets built later. The SQL
existed to check that a decision was implementable and that its claimed properties held.

It stopped being that. Measured at the point this ADR was written:

| | |
| --- | --- |
| Go, outside `spikes/` | **11 lines** — `cmd/openledger/main.go`, which prints "nothing to run yet" |
| SQL and test harness | **10,053 lines** |
| PL/pgSQL functions | **26** |
| Triggers | **27** |

The balance invariant, sequence assignment, running balances, the report views and the **entire
card authorization state machine** were implemented in the database. `record_auth_event`,
`recompute_hold_group`, `held_for_company` and `expire_hold_group` were the product, and they were
PL/pgSQL. Ten rounds of adversarial review were then spent hardening that.

The review found real defects every round. Almost none of them were *ledger* defects: a provably
dead `WHERE` disjunct, a catalog census that repaired the mutant it was measuring, a `PIPESTATUS`
read clobbered by the `|| fail=1` beside it, a bash command substitution that aborted under
`set -e`. **The finding count measured how much machinery there was to attack, not how much risk
there was.** That is the cost of building an intricate artefact in the wrong language, at the wrong
layer, before deciding it should exist.

## Why triggers were the symptom, not the disease

You only need a trigger to police a table that arbitrary callers write to directly. Callers only
write directly when there is no service in front of the database. The trigger count was a
measurement of how much ledger had leaked into the schema.

The four groups, and what replaces each:

| Group | Count | Replacement |
| --- | --- | --- |
| `TRUNCATE` refusal | 7 | `REVOKE`. There is no declarative alternative — PostgreSQL refuses event triggers for `TRUNCATE TABLE`, verified — so the owner is trusted and the application role is simply never granted it. |
| Immutability (no `UPDATE`/`DELETE` on the journal) | 5 | `REVOKE`. The application role gets `SELECT` and nothing else on the journal; all writes go through Go. |
| Assignment (`recorded_at`, `xact_id`, `account_seq`, `balance_after`) | 5 | The Go writer assigns them. There is no parameter for a caller to supply, which is stronger than a `DEFAULT` — a `DEFAULT` is overridable, and that was a measured defect: a client-settable insertion axis let an already-issued report be rewritten by a transaction claiming to predate it. |
| Cross-row validation | ~10 | Two became **foreign keys** (below). The rest — "debits equal credits", "at least two entries", correction targets — are enforced by *construction*: the Go writer builds both legs of a transaction in one code path, so an unbalanced transaction is **unrepresentable** rather than refused. |

## Two triggers became keys, which is strictly better

Both are now visible in `\d`, cannot be forgotten by a new writer, and need no test:

- **An account may not disagree with its type.** `ledger_accounts` carries `category` and
  `normal_balance` deliberately — a report must not have to join the chart to know the sign of a
  balance — but a copy can drift, so the copy is a composite foreign key into the row it was copied
  from: `(purpose, category, normal_balance) → account_types (code, category, normal_balance)`.

- **A type's statement line must agree with its category and normal balance.** `account_types`
  gains two `GENERATED ALWAYS … STORED` columns for the statement and side its category implies,
  and a composite foreign key `(fs_line, fs_statement, fs_side) → fs_lines (code, statement, side)`.
  This replaces `assert_type_matches_fs_line`, the guard this log repeatedly called its best,
  because it refused a wrong chart at *seed* time — the wrong system could not be built and no test
  had to notice. A foreign key does the same thing declaratively. **That is the principle
  ["prefer a constraint that makes a state unreachable"](./README.md) actually achieved.**

## What this costs, stated plainly

The invariants no longer hold against writers that are not the Go service:

- **direct DML by the owner**, including a backfill script or a psql session;
- **`pg_restore --disable-triggers`** and the **logical-replication apply path** — with no triggers
  there is nothing to skip, but equally nothing to enforce, and foreign keys are themselves
  implemented as system triggers and are skipped there too;
- **a second adapter** written later that talks to the tables instead of the service.

Every one of those has bitten during this project's review history, and defending them is the
entire content of [0011](./0011-what-the-database-enforces.md). That ADR's *findings* stand — they
are a good catalogue of what a database can and cannot be made to guarantee. Its *conclusion* is
superseded: we are choosing a single write path in Go over a schema that defends itself against
every writer.

The bet is that one service owns the writes, and that a rule readable in one Go function is worth
more than the same rule scattered across twenty-seven database objects.

## What survives from the SQL

[`schema/schema.sql`](../../schema/schema.sql) — 11 tables, 3 report views, zero triggers, zero
functions, and it loads. It exists to prove the shape the ADRs describe is expressible
declaratively, and `schema/chart.sql` seeds a chart that satisfies it.

The test suites, `tests/run.sh`, `tests/canary.sh` and `tests/concurrency.sh` are deleted. They
tested PL/pgSQL that no longer exists. What they *learned* is in these ADRs, which is where the
output of a design project belongs — order tolerance under out-of-order delivery, cumulative-total
versus delta conventions, an over-capture leaving a negative residue that swallows the next
increment, an authorization writing no entry while a clearing posts, the recorded and effective
axes. Those findings were worth the rounds. The code that produced them was not worth keeping.

They come back as **Go tests**, next to the Go that will implement them.
