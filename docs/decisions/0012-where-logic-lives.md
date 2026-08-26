# 0012 — Where the logic lives: Go, not the database

**Status:** accepted
**Supersedes the enforcement half of** [0011](./0011-what-the-database-enforces.md)

## The decision

**The ledger is written in Go. PostgreSQL holds the shape.** Tables, types, `NOT NULL`, single-row
`CHECK`s, foreign keys, unique indexes — and no PL/pgSQL business logic, no orchestration, no
derivation-with-backfill.

**A trigger needs a written justification, and the default is none.** Each one must state, in the
schema beside it:

1. **the invariant** it holds;
2. **why nothing declarative holds it** — no `CHECK`, no key, no `GENERATED` column, and not simply
   withholding the privilege;
3. **what it does NOT protect against**, said out loud rather than implied.

Two clear that bar today. Twenty-five did not.

The first version of this ADR said *zero* triggers. That was an overcorrection, and the research in
spike 007 is what corrected it — see **Where the line actually falls** below.

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
| `TRUNCATE` refusal | 7 → **4 kept** | Kept, on the four immutable logs. There is no declarative alternative and no way to collapse them into one object: PostgreSQL refuses event triggers for `TRUNCATE TABLE` outright (verified: `ERROR: event triggers are not supported for TRUNCATE TABLE`), and `TRUNCATE` fires no `ON DELETE` trigger, so the guard above does not see it. |
| Immutability (no `UPDATE`/`DELETE` on the journal) | 5 → **4 kept** | `REVOKE` **and** a trigger. The grant binds the application role; the trigger is the only thing that also binds a backfill script or a human at a psql prompt. One `refuse_mutation()` function on the four immutable logs. |
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

## Where the line actually falls

The first draft of this ADR said "zero triggers" and reasoned from maintainability alone. Spike 007
went and looked at what other ledgers actually do, and the line is sharper than that.

**Formance ran this exact experiment.** Go, PostgreSQL, in production, the closest analogue there
is. Their `0-init-schema` created a full PL/pgSQL write engine — an `AFTER INSERT` trigger
`handle_log()` dispatching on event type into `insert_transaction()` → `insert_posting()` →
`insert_move()`, with an unbounded `UPDATE` cascade over history to maintain effective-axis volumes.
Then migration 11, `make-stateless`, dropped the five triggers and moved orchestration to Go; and
migration 37, `clean-database`, dropped twenty-seven stored functions, its own comment calling them
*"useless … inherited from stateful version"*. Eight repair migrations exist because of that design.

**And Formance still runs seven triggers per ledger today, on by default** — log hashing, effective
volumes, metadata-history snapshots. **Airbnb's demolition is the same shape**: their MySQL triggers
were change-data-capture into audit tables, retrofitted onto a mutable data model, feeding an ETL
pipeline that eventually took over 24 hours to run. Their verdict — *"SQL is good for lightweight
data transformation. It is not designed to handle complicated business data flow"* — is the exact
indictment of what this schema had become. **Neither project removed a constraint.**

Meanwhile **TigerBeetle enforces its invariants inside the database on purpose** — *"accounting
invariants such as balance limits are enforced within the database"*. It simply is not SQL: there
is no `UPDATE`, no `DELETE`, and no way to submit half a transfer, so there is nothing for a guard
to police.

So the category that gets removed is **orchestration and derivation-with-backfill**, not integrity.
That is the bar this ADR now states, and it is why two *invariants* survived — eight trigger objects over two functions.

**Formance's own line is sharper than ours, and it is worth adopting.** Reading what they dropped
against what they kept:

> **A trigger survived if it needs to read or write rows OTHER than the one being written. It was
> deleted if it was a pure function of the new row.**

Everything they dropped in migrations 11, 37 and 46 — `sources`, `destinations`, `address_array`,
`sources_arrays` — is computable from the row's own columns. Everything they kept needs a *different*
row: `set_log_hash` needs the predecessor's hash under a lock; the effective-volume pair needs the
neighbouring moves in business-date order; the metadata-history triggers need `max(revision)+1` for
that entity. The dropped kind is free to do in Go. The kept kind costs a round trip and a race.

That rule is a better predictor than "no business logic", and it explains our own two: refusing an
`UPDATE` reads only `OLD`, so by Formance's rule it should be in Go — **and it cannot be, because
the writer we are protecting against is not ours.** The rule is about *cost*; ours is about *who*.
Both of ours are there for a caller Go does not mediate, which is the case the rule does not cover.

Their kept triggers are not free, either, and they say so: `set_log_hash` is why every write takes
`pg_advisory_xact_lock(ledger_id)` and serialises — *"that lock, not the hashing, is what limits
write throughput"*.

## What this costs, stated plainly

The write-path invariants — balance, sequence assignment, the hold flow — hold only against writers
that are the Go service:

- **direct DML by the owner**, including a backfill script or a psql session;
- **`pg_restore --disable-triggers`** and the **logical-replication apply path**, which set
  `session_replication_role = 'replica'`; PostgreSQL's manual states that *"in the default
  configuration, triggers do not fire on replicas"*, and that **foreign keys are themselves
  implemented as triggers** and are skipped there too;
- **a second adapter** written later that talks to the tables instead of the service.

The two surviving triggers are marked `ENABLE ALWAYS`, which the manual documents as firing
*"regardless of the current replication role"*. Demonstrated by counterexample rather than asserted:
with `ENABLE ALWAYS` removed, `SET session_replication_role='replica'; DELETE FROM ledger_events`
deletes the row; with it, the same statement is refused.

**They still bind accidents, not intent.** An owner can disable or drop a trigger in one statement.
Nobody in this field holds append-only with a database mechanism: Monzo does it with a reviewed
service-mesh allowlist that took `service.ledger` from callable-by-1,500 to callable-by-six, and
Uber does it with cryptographic signatures over each record. Those are the two published answers and
both live outside the database. What is here is the cheap 80%, and the cheap 80% is worth having.

[0011](./0011-what-the-database-enforces.md)'s *findings* stand as a catalogue of what a database
can and cannot be made to guarantee. Its *conclusion* — defend against every writer — is superseded.

## "One writer" is not the argument, and saying it was is a mistake

An earlier version of this section ended *"the bet is that one service owns the writes."* That was
never decided. It fell out of removing the enforcement, and the justification was written
afterwards — which is backwards, and the survey says so: **every system that moved the balance
invariant into application code shipped the enforcing code path first.**

Look at what Formance actually relies on. They have **zero `GRANT` and zero `REVOKE` in the entire
repository** — they are not betting on one writer either. Their guarantee is a *type*:

```go
type Posting struct {
	Source      string   `json:"source"`
	Destination string   `json:"destination"`
	Amount      *big.Int `json:"amount"`
	Asset       string   `json:"asset"`
}
```

A `Posting` **cannot express one leg.** `Postings.Validate()` checks the amount and the addresses
and contains no balance check at all, because there is nothing left to check. Any Go caller, however
many services exist, gets a balanced pair or nothing. That is a structural property, not a
deployment assumption — and it is why the guarantee survives a second writer appearing.

The flip side was measured against their applied schema: insert a single unbalanced row directly
into `moves` and it commits silently — 500 USD leaving `world` and arriving nowhere.

**So the distinction that matters is not one writer versus many. It is:**

| | |
| --- | --- |
| *"One service owns the writes"* | a hope about deployment. Nothing enforces it, and it fails the day someone writes a second adapter or a backfill. |
| *"The type cannot express an unbalanced transaction"* | holds for every caller in the language, forever, and needs no coordination. |

We have neither yet, and that is the honest position: `ledger_entries` stores independent rows
carrying a `direction`, so an unbalanced transaction is fully expressible, and the deferred trigger
that used to refuse it is gone. **Until the Go write path exists, nothing enforces balance at all.**

The fix is not a grant and not a trigger — it is to make the write primitive posting-shaped, so an
unbalanced transaction is unconstructible rather than refused. That is [0013](./0013-the-write-path.md).

The plain-text ledgers make the same point from the other end, and more elegantly. Beancount,
hledger and `ledger` all let you **elide the amount on exactly one posting** and infer it from the
requirement that the transaction balance — *"the same balance amounts that are used to check that
the transaction balances to zero are used to fill in the missing amounts."* There, the invariant is
not a validation bolted onto the model; it is the thing that **completes** the model. That is a
better argument for one write path than anything about maintainability.

## What survives from the SQL

[`schema/schema.sql`](../../schema/schema.sql) — 11 tables, 5 views, **8 triggers over 2
functions**, and it loads. (This line said "zero triggers, zero functions" and contradicted its own
file, which says two invariants clear the bar. It also predated restoring the two card alarm views,
which are declarative and should never have gone.) It exists to prove the shape the ADRs describe is expressible
declaratively, and `schema/chart.sql` seeds a chart that satisfies it.

The test suites, `tests/run.sh`, `tests/canary.sh` and `tests/concurrency.sh` are deleted. They
tested PL/pgSQL that no longer exists. What they *learned* is in these ADRs, which is where the
output of a design project belongs — order tolerance under out-of-order delivery, cumulative-total
versus delta conventions, an over-capture leaving a negative residue that swallows the next
increment, an authorization writing no entry while a clearing posts, the recorded and effective
axes. Those findings were worth the rounds. The code that produced them was not worth keeping.

They come back as **Go tests**, next to the Go that will implement them.
