# 0003 — Migrations are `sqlx`, plus fifteen lines of our own locking, run as their own command

**Status:** accepted
**Evidence:** [spike 007](../../spikes/007-schema-migrations/README.md) for the deployment shape,
[spike 010](../../spikes/010-go-or-rust/README.md) for the locking.

## The decision

**`sqlx::migrate`, with its own locking disabled and replaced by a polling try-lock we write.**

- `openledger migrate` is a subcommand of the same binary, so a deployment runs the **same image**
  with a different command. It applies migrations and exits.
- It runs as a **pre-deploy job** — a Kubernetes `Job`, a Helm `pre-upgrade` hook, an ECS one-off
  task — that must succeed before the new pods roll. **The ledger process never migrates.**
- `schema/schema.sql` becomes `migrations/00001_baseline.sql`. It carries no `BEGIN;`/`COMMIT;` of
  its own, deliberately.
- `-- no-transaction` marks the migrations that must run outside a transaction.
- **`Migrator::set_locking(false)`**, and we take `pg_try_advisory_lock` in a poll around the run.
- **No down migrations.**
- There is exactly one copy of the schema.

## Why

**A separate command, because a bad migration should stop a deploy, not crash-loop a ledger.**
Migrating at application startup couples two things that fail differently. A pre-deploy job also
means the schema change happens **once, before** any new code sees the database, which is the only
ordering that makes an expand/contract migration safe.

**A blocking advisory lock deadlocks against `CREATE INDEX CONCURRENTLY`.** `CONCURRENTLY` waits for
every concurrent virtual transaction, and a migrator blocked in `pg_advisory_lock()` is one of them.
Three migrators, one migration that builds an index concurrently, and PostgreSQL prints the cycle:

```
ERROR:  deadlock detected
DETAIL:  Process 831046 waits for ExclusiveLock on advisory lock [...]; blocked by process 831045.
	Process 831045 waits for ShareLock on virtual transaction 13/65162; blocked by process 831044.
	Process 831044 waits for ExclusiveLock on advisory lock [...]; blocked by process 831046.
	Process 831044: SELECT pg_advisory_lock($1)
	Process 831045: CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_t_v ON t (v)
```

Striping ([0002](./0002-scaling.md)) is on the roadmap and every index on a populated
`ledger_entries` will want `CONCURRENTLY`, so this is not a corner case for this project.

**And the fix is ours, because the Rust ecosystem does not attempt this.** Read against published
sources — `grep -rn "advisory" --include=*.rs` over each:

| crate | version | cross-process lock | can it run `CREATE INDEX CONCURRENTLY`? |
| --- | --- | --- | --- |
| **`sqlx`** | 0.9.0 | **blocking `pg_advisory_lock`** | yes, `-- no-transaction` |
| `diesel_migrations` | 2.3.2 | **none** | yes, `run_in_transaction = false` |
| `sea-orm-migration` | 2.0.2 | **none** | yes, `use_transaction()` |
| `geni` | 1.3.3 | **none** | yes, `transaction: no` |
| `movine` | 0.11.4 | **none** | no |
| `migrant` | 0.14.0 | **none** | — |
| `schemamama` | 0.3.0 | **none** | — |
| `refinery` | 0.9.2 | **none** | **no** — `cannot run inside a transaction block` |

**Exactly one Rust migrator attempts cross-process coordination at all, and it is the one that does
it the wrong way.** The rest have no lock to be wrong. This is not a Rust library being behind on a
detail; it is a different default. Go's goose and Atlas both poll a try-lock. So we take
`pg_try_advisory_lock` ourselves — **verified 0 of 3 failures across every trial**, against sqlx's
default 2 of 3 failures across every trial.

**A pre-deploy job is an intention, not a guarantee of one migrator**, which is why the lock still
matters even though the chosen topology has a single runner. A Kubernetes `Job` retries on
`backoffLimit`; a Helm hook can be re-run after a timeout; a CD tool can sync twice; a rolled-back
release redeploys over one still finishing.

**A declarative diff cannot contain an ordering.** The schema is one flat file, so a desired-state
tool looks like the natural pairing, and it is a trap for a reason specific to a ledger: Atlas's plan
for the striping change drops `uq_accounts__house` *before* building its replacement — correct, and a
window with no uniqueness on house accounts. The engine cannot know that index is a correctness
constraint. What one flat file actually buys is readability, and we keep it: `schema.sql` becomes
migration 00001, and the thing that cashes in "the database matches the file" is
[0007](./0007-schema-conventions-and-chart.md)'s **still-unbuilt snapshot test** — apply to an empty
database, dump every index, constraint and `NOT VALID` row, diff against a committed snapshot. No
diff engine, no dev database, no login.

**No down migrations, because a down migration on a ledger is a lie or data loss.** `DROP COLUMN
stripe` destroys real state; `DROP INDEX` restores an index the data may no longer satisfy; neither
restores rows. The honest operation is roll-forward — a new migration, reviewed like any other, with
the ordering visible.

**A defect this decision found in our own file.** `schema/schema.sql` shipped with `BEGIN;` and
`COMMIT;` around it. A migrator wraps each migration in its own transaction, and **an inner `COMMIT;`
ends it** — so a migration that fails after that line leaves its earlier objects behind *and* is not
recorded as applied, and the retry dies on `relation already exists`. Reproduced, with the control
(same file, two lines removed) rolling back cleanly. Both lines are gone; `make schema` now gets
atomicity from `psql --single-transaction`, which is the caller's business rather than the file's.

## Alternatives

| | Why not |
| --- | --- |
| **`sqlx` as shipped** | The blocking lock above: 2 of 3 migrators lost, every trial. Everything else about it is what we want, which is why we keep it and replace one behaviour. |
| **`refinery`** | Cannot run `CREATE INDEX CONCURRENTLY` at all — every migration is wrapped in a transaction with no opt-out. Disqualifying for a project whose next schema change is a concurrent index on a populated table. |
| **`diesel_migrations`, `sea-orm-migration`, `geni`** | All handle `CONCURRENTLY`; none has any cross-process lock, so we would be writing the same fifteen lines *and* adopting a second query layer. `sqlx` is already [0001](./0001-rust-and-postgres.md)'s. |
| **Atlas** | Community **refuses this schema**: `views are available to logged-in users only`. RLS policies are gated the same way, and we know we need them. `migrate lint` is Pro. A dev database is mandatory. |
| **goose (via a Go sidecar)** | It is the tool that gets the lock right, and running it would mean a second language and a second binary in the deploy path to avoid writing fifteen lines. |

## What it costs

- **We own the locker.** Fifteen lines of `pg_try_advisory_lock` polling, and the bug reports about
  them come to us. This is the sharpest cost of [0001](./0001-rust-and-postgres.md) that is not about
  types. **The poll ceiling must be set deliberately** — a migration slower than the retry budget
  makes a *second* migrator give up rather than wait. With a pre-deploy job that is the right failure,
  because a job that gives up is visible and re-runnable, but it is a number someone has to choose.
- **A killed migrator leaves an INVALID index behind, and the retry does not heal it.** This is the
  failure a pre-deploy job makes *more* likely, because pods get evicted, `activeDeadlineSeconds`
  fires and nodes drain. Reproduced against PostgreSQL 18: kill the backend mid-build and

  ```
  ix_t_v  indisvalid=false  indisready=true
  $ CREATE INDEX CONCURRENTLY ix_t_v ON t (v);
  ERROR:  relation "ix_t_v" already exists
  ```

  The planner then ignores the index — the database is *correct and silently slow*, and if it were a
  UNIQUE index it would be enforcing nothing. **So every `CONCURRENTLY` migration is written in the
  idempotent form — as TWO migrations, each holding exactly one statement:**

  ```sql
  -- 00007_drop_striped_index.sql        -- 00008_build_striped_index.sql
  -- no-transaction                      -- no-transaction
  DROP INDEX CONCURRENTLY IF EXISTS      CREATE UNIQUE INDEX CONCURRENTLY
    uq_accounts__house_striped;            uq_accounts__house_striped ON ...;
  ```

  **They cannot share a file, and an earlier version of this ADR said they could.** That pair was
  verified against goose in [spike 007](../../spikes/007-schema-migrations/README.md) and carried
  into an `sqlx` decision without being re-run. Under `sqlx` 0.9.0 it fails:

  ```
  Err(ExecuteMigration(Database([25001] DROP INDEX CONCURRENTLY cannot run inside a
  transaction block), 4))
  ```

  `-- no-transaction` parses correctly; **the transport is the problem.** `execute_migration` sends
  the whole file as one *simple query* (`sqlx-postgres-0.9.0/src/migrate.rs:315-323`), and PostgreSQL
  runs a multi-statement simple query in an **implicit transaction block**. Proved with a control:
  two statements where the second divides by zero leave the first's table absent afterwards. Either
  statement alone applies fine. A job that can be re-run is only useful if the migration it runs can
  be re-run — and this is the second time a form was carried across a tool change without being
  re-run against the new tool.
- **Every migration touching a populated table needs a `CONCURRENTLY` decision**, expressed as a
  directive. `-- no-transaction` gives up atomicity for that migration, so those carry one step each:
  splitting is cheaper than debugging a half-applied migration.
- **The lock is not the only thing preventing a double apply**, and an earlier version of this line
  said it was. `sqlx-postgres/src/migrate.rs:130-131` declares the version table as
  `version BIGINT PRIMARY KEY`, and a primary key is a unique index — a second apply of the same
  version fails on it. That is a backstop, not a substitute: it stops the *duplicate row*, not two
  migrators running DDL against each other, which is what the lock is for.
- `make schema` becomes a development shortcut, not the deployment path.
- One thing this decision *stopped* costing: the previous tool needed a `database/sql` handle, so
  migrations ran over a second driver stack. `sqlx` migrates over the same pool the ledger uses.
