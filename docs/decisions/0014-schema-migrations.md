# 0014 — Schema migrations: goose, applied from Go

**Status:** accepted
**Closes** the "how schema changes get applied is undecided" entry — a gap
[0012](./0012-where-logic-lives.md) introduced when it replaced an ordered `migrations/` directory
with one flat file and did not say what replaced the ordering.
**Evidence:** [spike 007](../../spikes/007-schema-migrations/README.md).

## The decision

**[goose](https://github.com/pressly/goose), driven from Go, never from the CLI.**

- `schema/schema.sql` becomes `migrations/00001_baseline.sql`, **with its own `BEGIN;`/`COMMIT;`
  removed** — see below; that was a real defect, not a style point.
- Migrations are embedded with `//go:embed` and applied by
  `goose.NewProvider(dialect, db, fsys, goose.WithSessionLocker(...))` at startup.
- `-- +goose NO TRANSACTION` marks the migrations that must run outside a transaction.
- **No down migrations.**
- sqlc reads `migrations/`. There is exactly one copy of the schema.

## Why goose, and it is not the reason you would guess

The obvious comparison — library API, licence, maintenance — puts goose and **tern** close, and tern
is *better* on the criterion [0002](./0002-data-access-layer.md) actually named: it is native pgx,
where goose needs `database/sql`. The measurement that decides it is one nobody would compare on
paper.

**A blocking advisory lock deadlocks against `CREATE INDEX CONCURRENTLY`.** Three instances booting
at once, applying a migration that builds an index concurrently — golang-migrate and tern both lose
two of three, reproducibly, and PostgreSQL prints the cycle:

```
DETAIL:  Process 762228 waits for ExclusiveLock on advisory lock [...]; blocked by process 762227.
  Process 762227 waits for ShareLock on virtual transaction 10/64577; blocked by process 762228.
  Process 762228: SELECT pg_advisory_lock($1)
  Process 762227: CREATE UNIQUE INDEX CONCURRENTLY uq_accounts__house_striped ...
```

`CONCURRENTLY` waits for every concurrent virtual transaction, and an instance blocked in
`pg_advisory_lock()` is one of them. **goose and Atlas take `pg_try_advisory_lock` and poll**, so
they never enter the cycle. Since striping is on the roadmap and every index on a populated
`ledger_entries` will want `CONCURRENTLY`, that is not a corner case for this project.

**And it has to be the library.** The goose *CLI* has no lock flag at all and races exactly like the
others (two of three failed with `column "stripe" already exists`). `goose_db_version` carries **no
unique index on `version_id`** — nothing but the lock prevents a double apply.

## The defect this spike found in our own file

`schema/schema.sql` shipped with `BEGIN;` and `COMMIT;` around it. goose wraps each migration in its
own transaction, and **an inner `COMMIT;` ends it** — so a migration that fails after that line
leaves its earlier objects behind *and* is not recorded as applied, and the retry dies on
`relation already exists`. Reproduced, with the control (same file, two lines removed) rolling back
cleanly. Both lines are gone; `make schema` now gets atomicity from `psql --single-transaction`,
which is the caller's business rather than the file's.

## Alternatives

| | Why not |
| --- | --- |
| **tern** | The strongest runner-up and the only native-pgx candidate. Blocking `pg_advisory_lock` → the deadlock above. Also a 452-vs-14 commit bus factor. **If we ever drop "instances migrate at boot" and an operator runs migrations out of band, this choice flips.** |
| **golang-migrate** | Same deadlock; no per-migration transaction and no directive to opt out, so `CONCURRENTLY` fails anyway and the fix is one statement per file; a failure sets a `dirty` flag whose documented recovery is a human running `migrate force`. |
| **Atlas** | Community **refuses this schema**: `views are available to logged-in users only`. RLS policies are gated the same way, and we already know we need them. `migrate lint` is Pro. The Go SDK shells out to a 121 MB binary. A dev database is mandatory. Same open-core shape as River's periodic jobs in [0008](./0008-durable-timers.md). |
| **psqldef** | SIGSEGV on `trial_balance`. |
| **dbmate**, **sql-migrate** | No locking at all in the Postgres path. Rejected on source inspection, not run — said plainly rather than implied. |
| **Skeema** | MySQL only. **Bytebase** — a server with a web UI, not a library. |

## Versioned application, declarative verification

We just made the schema one declarative file, so a desired-state tool looks like the natural pairing.
It is a trap, for a reason that is specific to a ledger: **a diff of two shapes cannot contain an
ordering.** Atlas's plan for the striping change drops `uq_accounts__house` *before* building its
replacement — correct, and a window with no uniqueness on house accounts. The engine cannot know that
index is a correctness constraint. [0006](./0006-schema-conventions.md) already made this argument
for `NOT VALID`, where the zero-downtime pattern *is* an ordering.

What one flat file actually buys is readability, and we keep that: `schema.sql` becomes migration
00001, and the thing that cashes in "the database matches the file" is
[0006](./0006-schema-conventions.md)'s **still-unbuilt snapshot test** — apply to an empty database,
dump every index, constraint and `NOT VALID` row, diff against a committed snapshot. No diff engine,
no dev database, no login. Spike 007 does not build it; it removes the excuse that a declarative tool
would have covered it.

## No down migrations

A down migration on a ledger is a lie or data loss: `DROP COLUMN stripe` destroys real state,
`DROP INDEX` restores an index the data may no longer satisfy, and neither restores rows. The honest
operation is roll-forward — a new migration, reviewed like any other, with the ordering visible.
golang-migrate argues the same thing from the other side: its recovery from a failed migration is a
human running `migrate force`, which is exactly the operation [0012](./0012-where-logic-lives.md)
says the service owns.

## What it costs, stated plainly

- **A `database/sql` dependency we did not want.** `goose.NewProvider` requires `*sql.DB`, so
  migrations run over `pgx/stdlib` — one `sql.Open("pgx", dsn)` at startup, closed after migrating,
  with the hot path staying on `pgxpool`. [0002](./0002-data-access-layer.md) is untouched but this
  is a real concession, and **tern would have avoided it entirely**.
- **The lock has a ceiling.** goose polls every 5 s, 60 times — five minutes. A baseline slower than
  that makes the *other* instances give up. `lock.WithLockTimeout` must be set deliberately before
  the RDS milestone. Read from source, not exercised.
- **Every migration touching a populated table needs a `CONCURRENTLY` decision**, expressed as a
  directive. `NO TRANSACTION` gives up atomicity for that migration, so those should carry one step
  each — splitting is cheaper than debugging a half-applied migration.
- `make schema` becomes a development shortcut, not the deployment path.
- sqlc needs `strict_order_by: false`, because `trial_balance` has an ambiguous `tenant_id` across a
  join. A pre-existing wart that sqlc surfaces rather than causes.
