# Spike 007 — how do schema changes get applied?

**Status:** closed → [ADR-0003](../../docs/decisions/0003-migrations.md)

**Question.** [ADR-0004](../../docs/decisions/0004-where-logic-lives.md) replaced an ordered
`migrations/` directory with one flat `schema/schema.sql` and did not say what replaces the
ordering. A ledger cannot take a schema change by hand. Which tool, and versioned or declarative?

**Method.** Nine candidates. Four were **run** — goose, golang-migrate, tern and Atlas — against
PostgreSQL 18.6 with a **200,019-account, 71 MB** `ledger_accounts`, applying the real change from
our own open list: add a `stripe` column, build its replacement unique index
`CONCURRENTLY`, drop the old one. That change must not run inside a transaction, which is the whole
point of choosing it. 30 throwaway databases created, 30 dropped.

---

## The finding nobody expected: a blocking advisory lock deadlocks against `CONCURRENTLY`

Three instances booting at once, each applying migrations:

```
golang-migrate                          tern
instance 0: elapsed=1.016s err=<nil>    instance 0: err=deadlock detected (40P01)
instance 1: err=deadlock detected       instance 1: err=deadlock detected (40P01)
instance 2: err=deadlock detected       instance 2: version=2 err=<nil>
```

Reproducible 5 of 5. The PostgreSQL wait graph, from the server log:

```
ERROR:  deadlock detected
DETAIL:  Process 762228 waits for ExclusiveLock on advisory lock [...]; blocked by process 762227.
  Process 762227 waits for ShareLock on virtual transaction 10/64577; blocked by process 762228.
  Process 762228: SELECT pg_advisory_lock($1)
  Process 762227: CREATE UNIQUE INDEX CONCURRENTLY uq_accounts__house_striped ...
```

`CREATE INDEX CONCURRENTLY` waits for **every concurrent virtual transaction to finish** — and an
instance blocked inside `pg_advisory_lock()` *is* one. Cycle. The detector kills the waiter after
`deadlock_timeout`, which is exactly the 1 s elapsed above.

**goose and Atlas do not have this problem, because they take `pg_try_advisory_lock` and poll.**
That is the whole reason goose wins, and it is not a property anyone would have compared on paper.

## The second finding: our own `schema.sql` defeated the runner

The file shipped with `BEGIN;` at the top and `COMMIT;` at the bottom. goose wraps each migration in
its own transaction — and an inner `COMMIT;` **ends it**. Isolated:

```sql
-- +goose Up
BEGIN;
CREATE TABLE inner_tx_table (i int);
COMMIT;
CREATE TABLE after_commit_table (i int);
SELECT 1/0;
```
```
$ goose up
goose run: ERROR ...: division by zero (SQLSTATE 22012)
$ psql -c '\dt'
 public | after_commit_table   <-- survived a FAILED migration
 public | inner_tx_table       <-- survived
$ psql -c 'select * from goose_db_version'
  1 | 0 | t                    <-- and it was not recorded as applied
$ goose up                      # the retry
goose run: ERROR ...: relation "inner_tx_table" already exists (SQLSTATE 42P07)
```

The same file without those two lines rolls back cleanly. **Fixed:** both removed;
`make schema` gets atomicity from `psql --single-transaction`, which is the caller's business.

## The third: the goose CLI races, the library does not

Three instances, database already at baseline:

```
CLI / library without a locker         library + WithSessionLocker
instance 0: err=column "stripe"        instance 0: applied=0 elapsed=5.015s  err=<nil>
            already exists (42701)     instance 1: applied=1 elapsed=58ms    err=<nil>
instance 1: applied=1 err=<nil>        instance 2: applied=0 elapsed=10.019s err=<nil>
instance 2: err=... (42701)
```

The 5 s / 10 s are the try-lock poll interval. **The CLI has no lock flag at all.** And
`goose_db_version` has **no unique index on `version_id`** — nothing but the lock prevents a double
apply. That is why [ADR-0003](../../docs/decisions/0003-migrations.md) drives migrations from the
service binary rather than from any tool's CLI.

---

## Why not declarative, given we just went declarative

Three reasons, in order of weight.

**A desired-state file describes a shape; a migration is a transition, and on a ledger the
transition is the interesting part.** Atlas's plan for our change was correct and would have opened a
window with no uniqueness on house accounts:

```
-> DROP INDEX "uq_accounts__house";
-> ALTER TABLE "ledger_accounts" ADD COLUMN "stripe" ...;
-> CREATE UNIQUE INDEX "uq_accounts__house_striped" ...;
-- no diagnostics found
```

The engine is not wrong — it cannot know that index is a correctness constraint rather than a
performance one. We know, and a versioned migration is where you say so.
[ADR-0007](../../docs/decisions/0007-schema-conventions-and-chart.md) already made this argument for
`NOT VALID`: the zero-downtime pattern *is an ordering*, and **a diff of two shapes cannot contain
an ordering**.

**Both desired-state tools choke on this schema.** Atlas Community refuses it outright —

```
$ atlas schema apply --to file://schema.sql --dev-url <dev>
Error: schema.sql:703: views are available to logged-in users only. Use 'atlas login'
```

— and RLS policies are gated the same way, which this project already knows it needs. Worse than the
error is the silent variant: `atlas schema inspect --format '{{ sql . }}' > inspect.sql` exits 0 with
259 clean-looking lines and **zero `CREATE VIEW`** in them; the "Skipping… Upgrade to Pro" notice
only appears on a TTY. psqldef v3.11.20 **SIGSEGVs** on `trial_balance`. Adopting either means paying
for Pro or deleting from `schema.sql` the objects it exists to prove are expressible — the same shape
as River's periodic jobs in [ADR-0008](../../docs/decisions/0008-authorization-holds.md).

**The declarative half was never about applying anything, and we keep it.** What one flat file buys
is readability and diffability. The synthesis is **versioned application, declarative verification**:
ordered migrations replayed with the transitions we chose, plus ADR-0007's still-unbuilt
snapshot test — apply to an empty database, dump every index, constraint and `NOT VALID` row, diff
against a committed snapshot. That yields "the database matches the file" with no diff engine, no dev
database and no login, and it catches the failure ADR-0007 is actually afraid of. **Spike 007 does
not build it; it removes the excuse that a declarative tool would have covered it.**

The honest case for declarative, on the record: after N migrations nobody can read the current shape
without replaying them, and this project's thesis is that the schema is a document. That is answered
by keeping `schema.sql` as migration 00001 and keeping the snapshot test current — not by handing a
diff engine authority over transitions on a ledger.

## Candidates, and why each lost

| | verdict |
| --- | --- |
| **goose** v3.27.3 | **Chosen.** `pg_try_advisory_lock` + poll. Library API, `embed.FS`, `-- +goose NO TRANSACTION`. MIT, 151 contributors — best bus factor here. |
| **tern** v2.4.3 | **Runner-up, and the only native-pgx candidate** — which is what ADR-0001 asked for. Loses on the blocking-lock deadlock, and on a 452-vs-14 commit bus factor. |
| **golang-migrate** v4.19.1 | Same deadlock. **No per-migration transaction and no way to opt out** — it sends the file as one `Exec`, so PostgreSQL's implicit transaction block rejects `CONCURRENTLY` anyway; the only fix is one statement per file. Failure sets a `dirty` flag whose documented recovery is a human running `migrate force`. |
| **Atlas** v1.3.3 | Refuses our views and our RLS below Pro; `migrate lint` is Pro; the Go SDK is a subprocess wrapper around a **121 MB** binary; a dev database is mandatory. Does the `CONCURRENTLY` part well. |
| **psqldef** v3.11.20 | SIGSEGV on `trial_balance`. Also: `go install` resolves to a stale `v1.0.7` that cannot parse a *named* inline primary key — which ADR-0007 mandates. |
| **dbmate**, **sql-migrate** | **No locking at all** in the Postgres path. Rejected on source inspection, not run — said plainly rather than implied. |
| **Skeema** | MySQL/MariaDB only. |
| **Bytebase** | A server with a web UI, not a library. |

## What it costs, named rather than smoothed over

**goose's `NewProvider` requires `*sql.DB`, so migrations run over `pgx/stdlib`** — a
`database/sql` dependency [ADR-0001](../../docs/decisions/0001-rust-and-postgres.md) deliberately
avoided. One `sql.Open("pgx", dsn)` at startup, closed after migrating; the hot path stays on
`pgxpool`. **tern would have avoided this entirely.**

And a ceiling read from source, not exercised: goose polls every 5 s, 60 times — **five minutes**.
A baseline slower than that makes the *other* instances give up. `lock.WithLockTimeout` needs setting
deliberately before M4.

## What could not be verified

Whether `atlas login` on a *free* account lifts the views gate, or whether that needs a paid seat —
no account was created. The licence of the distributed Atlas binary (the repo is Apache-2.0; the
binary enforces login-gated features and no separate EULA was found). Atlas Community built from
source — it does not compile under Go 1.26.5 here, so every Atlas result is from the official binary,
which may gate differently. Whether golang-migrate has a lock-disable option outside the two driver
files that were read. dbmate, sql-migrate, Bytebase, Skeema, pgroll and pg-schema-diff were not
executed. psqldef's panic was not minimised below "the whole `trial_balance` view". Nothing was
measured over a network or on RDS — the lock-wait *shapes* should hold anywhere, the millisecond
figures should not be quoted. The five-minute goose lock ceiling is read from source, not exercised.
