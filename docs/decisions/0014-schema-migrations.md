# 0014 — Migrations are goose, applied from Go as their own pre-deploy command

**Status:** accepted
**Closes** the "how schema changes get applied is undecided" entry — a gap
[0012](./0012-where-logic-lives.md) introduced when it replaced an ordered `migrations/` directory
with one flat file and did not say what replaced the ordering.
**Evidence:** [spike 007](../../spikes/007-schema-migrations/README.md).

## The decision

**[goose](https://github.com/pressly/goose), driven from Go, as its own command — not at application
startup and not from goose's CLI.**

- `openledger migrate` is a subcommand of the same binary, so a deployment runs the **same image**
  with a different command. It applies migrations and exits.
- It runs as a **pre-deploy job** — a Kubernetes `Job`, a Helm `pre-upgrade` hook, an ECS one-off
  task — that must succeed before the new pods roll. The ledger process never migrates.
- `schema/schema.sql` becomes `migrations/00001_baseline.sql`, **with its own `BEGIN;`/`COMMIT;`
  removed**.
- Migrations are embedded with `//go:embed` and applied by
  `goose.NewProvider(dialect, db, fsys, goose.WithSessionLocker(...))`.
- `-- +goose NO TRANSACTION` marks the migrations that must run outside a transaction.
- **No down migrations.**
- sqlc reads `migrations/`. There is exactly one copy of the schema.

## Why

**A separate command, because a bad migration should stop a deploy, not crash-loop a ledger.**
Migrating at application startup couples two things that fail differently. A pre-deploy job also
means the schema change happens **once, before** any new code sees the database, which is the only
ordering that makes an expand/contract migration safe.

**A blocking advisory lock deadlocks against `CREATE INDEX CONCURRENTLY`** — and that, not the
library API, is what picks the tool. Three instances booting at once, applying a migration that
builds an index concurrently: golang-migrate and tern both lose two of three, reproducibly, and
PostgreSQL prints the cycle:

```
DETAIL:  Process 762228 waits for ExclusiveLock on advisory lock [...]; blocked by process 762227.
  Process 762227 waits for ShareLock on virtual transaction 10/64577; blocked by process 762228.
  Process 762228: SELECT pg_advisory_lock($1)
  Process 762227: CREATE UNIQUE INDEX CONCURRENTLY uq_accounts__house_striped ...
```

`CONCURRENTLY` waits for every concurrent virtual transaction, and an instance blocked in
`pg_advisory_lock()` is one of them. **goose and Atlas take `pg_try_advisory_lock` and poll**, so they
never enter the cycle. Striping is on the roadmap and every index on a populated `ledger_entries`
will want `CONCURRENTLY`, so this is not a corner case for this project.

**And it has to be the library, not the CLI.** The goose CLI has no lock flag at all and races
exactly like the others (two of three failed with `column "stripe" already exists`).
`goose_db_version` carries **no unique index on `version_id`** — nothing but the lock prevents a
double apply.

**A pre-deploy job is an intention, not a guarantee of one migrator**, which is why the lock still
matters. A Kubernetes `Job` retries on `backoffLimit`; a Helm hook can be re-run after a timeout; a
CD tool can sync twice; a rolled-back release redeploys over one still finishing. A try-lock that
polls is strictly better behaviour than a blocking lock that deadlocks.

**The spike found a real defect in our own file while measuring this.** `schema/schema.sql` shipped
with `BEGIN;` and `COMMIT;` around it. goose wraps each migration in its own transaction, and **an
inner `COMMIT;` ends it** — so a migration that fails after that line leaves its earlier objects
behind *and* is not recorded as applied, and the retry dies on `relation already exists`. Reproduced,
with the control (same file, two lines removed) rolling back cleanly. Both lines are gone; `make
schema` now gets atomicity from `psql --single-transaction`, which is the caller's business rather
than the file's.

**A declarative diff cannot contain an ordering.** We just made the schema one flat file, so a
desired-state tool looks like the natural pairing, and it is a trap for a reason specific to a ledger:
Atlas's plan for the striping change drops `uq_accounts__house` *before* building its replacement —
correct, and a window with no uniqueness on house accounts. The engine cannot know that index is a
correctness constraint. [0006](./0006-schema-conventions.md) already made this argument for
`NOT VALID`, where the zero-downtime pattern *is* an ordering. What one flat file actually buys is
readability, and we keep it: `schema.sql` becomes migration 00001, and the thing that cashes in "the
database matches the file" is [0006](./0006-schema-conventions.md)'s **still-unbuilt snapshot test** —
apply to an empty database, dump every index, constraint and `NOT VALID` row, diff against a
committed snapshot. No diff engine, no dev database, no login.

**No down migrations, because a down migration on a ledger is a lie or data loss.** `DROP COLUMN
stripe` destroys real state, `DROP INDEX` restores an index the data may no longer satisfy, and
neither restores rows. The honest operation is roll-forward — a new migration, reviewed like any
other, with the ordering visible. golang-migrate argues the same thing from the other side: its
recovery from a failed migration is a human running `migrate force`.

## Alternatives

| | Why not |
| --- | --- |
| **tern** | The strongest runner-up and the only native-pgx candidate — better on the criterion [0002](./0002-data-access-layer.md) actually named. Blocking `pg_advisory_lock` → the deadlock above. Also a 452-vs-14 commit bus factor. |
| **golang-migrate** | Same deadlock; no per-migration transaction and no directive to opt out, so `CONCURRENTLY` fails anyway and the fix is one statement per file; a failure sets a `dirty` flag whose documented recovery is a human running `migrate force`. |
| **Atlas** | Community **refuses this schema**: `views are available to logged-in users only`. RLS policies are gated the same way, and we already know we need them. `migrate lint` is Pro. The Go SDK shells out to a 121 MB binary. A dev database is mandatory. Same open-core shape as River's periodic jobs in [0008](./0008-durable-timers.md). |
| **psqldef** | SIGSEGV on `trial_balance`. |
| **dbmate**, **sql-migrate** | No locking at all in the Postgres path. Rejected on source inspection, not run — said plainly rather than implied. |
| **Skeema**, **Bytebase** | MySQL only; and a server with a web UI, not a library. |

## What it costs

- **A `database/sql` dependency we did not want.** `goose.NewProvider` requires `*sql.DB`, so
  migrations run over `pgx/stdlib` — one `sql.Open("pgx", dsn)` at startup, closed after migrating,
  with the hot path staying on `pgxpool`. [0002](./0002-data-access-layer.md) chose native pgx to
  protect the *query path* — batching, `CopyFrom`, binary parameters, scanning money without silent
  zeroes — and none of that is in play in a DDL runner, so the dependency lands where it does not
  matter. It is still a real concession, and **tern would have avoided it entirely**.
- **The lock has a ceiling.** goose polls every 5 s, 60 times — five minutes. A migration slower than
  that makes a *second* migrator give up rather than wait. With a pre-deploy job that is the right
  failure — a job that gives up is visible and re-runnable — but it must be set deliberately rather
  than inherited. Read from source, not exercised.
- **A killed migrator leaves an INVALID index behind, and the retry does not heal it.** This is the
  failure mode a pre-deploy job makes *more* likely, because pods get evicted,
  `activeDeadlineSeconds` fires, and nodes drain. Reproduced against PostgreSQL 18: kill the backend
  mid-build and

  ```
  ix_t_v  indisvalid=false  indisready=true
  $ CREATE INDEX CONCURRENTLY ix_t_v ON t (v);
  ERROR:  relation "ix_t_v" already exists
  ```

  The planner then ignores the index — the database is *correct and silently slow*, and if it were a
  UNIQUE index it would be enforcing nothing. **So every `CONCURRENTLY` migration is written in the
  idempotent form**, which was verified to recover cleanly:

  ```sql
  -- +goose NO TRANSACTION
  DROP INDEX CONCURRENTLY IF EXISTS uq_accounts__house_striped;
  CREATE UNIQUE INDEX CONCURRENTLY uq_accounts__house_striped ON ...;
  ```

  A job that can be re-run is only useful if the migration it runs can be re-run.
- **Every migration touching a populated table needs a `CONCURRENTLY` decision**, expressed as a
  directive. `NO TRANSACTION` gives up atomicity for that migration, so those should carry one step
  each — splitting is cheaper than debugging a half-applied migration.
- `make schema` becomes a development shortcut, not the deployment path.
- sqlc needs `strict_order_by: false`, because `trial_balance` has an ambiguous `tenant_id` across a
  join. A pre-existing wart that sqlc surfaces rather than causes.
