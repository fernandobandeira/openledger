# 0009 — The card module gets its own Postgres schema, not its own migration set

**Status:** proposed
**Evidence:** [spike 011](../../spikes/011-optional-modules/README.md).

## The decision

**One migration set, one lock, one order — and the card objects move out of `public` into a `card`
schema.** [0003](./0003-migrations.md) is otherwise unchanged: `schema/schema.sql` is still migration
00001, still applied by one pre-deploy runner holding one advisory lock.

- `core` and `card` are two schemas in one database, created by that one migration: against
  PostgreSQL 18.6 it lands **7 tables / 3 views / 23 indexes** in `core`, **4 / 2 / 10** in `card`.
- **The card module becomes removable, not optional.** A wallet-only user still gets its tables.
  `DROP SCHEMA card CASCADE` then removes them in one statement — verified to leave all seven core
  tables, all nine core foreign keys and all three report views intact.
- **[0002](./0002-scaling.md)'s "plug-in" sentence changes.** The *code* is a plug-in and that is now
  measured. The *schema* is not, and claiming it was is the defect this decision closes.
- A committed test asserts **no relation name is defined in both schemas**, because
  `search_path = card, core` resolves a collision silently to the card one.

## Why

**Because the seam is already clean and nobody was using it.** Read from `pg_constraint`, **not one
foreign key crosses the card/core boundary in either direction** — the only card FK is
`card_auth_event_group → card_auth_events`. The whole database-level coupling is three objects: the
`auth_event_kind` enum (in the core preamble, used by **no core table**), the `refuse_mutation`/
`refuse_truncate` trigger functions, and one `GRANT` block. Cut on that seam into a 725-line core set
and a 471-line card set, the two applied in order produce a `pg_dump -s` **identical to the
monolith's** but for pg_dump 18's random `\restrict` nonce. The boundary was drawn correctly and then
not drawn in the database; splitting the file is not the hard part.

**Because `sqlx` can hold two migration sets, and the second one has no ordering.** 0.9.0 ships
`dangerous_set_table_name()` and `create_schema()` (`sqlx-core-0.9.0/src/migrate/migrator.rs:110,122`),
so per-module version tables work first time — `core_mig._sqlx_migrations` and
`card_mig._sqlx_migrations`, both at version 1, both applied. What it does **not** ship is any
dependency declaration between sets: no `dependencies`, no `run_before`. Ordering becomes the order
Rust calls `run()` in. Run card first on an empty database and you get

```
card -> Err(ExecuteMigration(Database([42883] function refuse_mutation() does not exist), 1))
```

which rolls back cleanly today only because that migration happens to be transactional. **A second
ordering that nothing enforces is a worse trade than four unused tables.**

**Because one version table cannot hold two sets, and the escape hatch is worse.** Against the default
`_sqlx_migrations`, colliding numbers give `Err(VersionMismatch(1))` and disjoint numbers (core 1,
card 1000) give `Err(VersionMissing(1))` — each `Migrator` treats the table as its own complete world.
`set_ignore_missing(true)` on both sides works, and turns off the check that a migration was applied
and then deleted, for everything.

**Because nobody sharing a database gets this right.** Read from source: Formance and Temporal
separate cleanly by giving each component **its own database**, with zero cross-component foreign keys
and no ordering mechanism at all. Odoo has the only working uninstall and pays by having **no
migration files**. Keycloak built per-module changelog tables (`DATABASECHANGELOG_<factoryId>`) and
then **declined to use them for its own optional features** — `AUTHORIZATION` and `ORGANIZATION` are
disableable and their tables ship unconditionally in the core changelog. Django, Rails, Medusa and
Discourse share one ledger table and live with orphan rows or a lost uninstall.

**And the Rust half already works, which is the half worth keeping.** A workspace of
`openledger-core` + `openledger-card` with a Cargo feature on the server composes with `sqlx`'s
compile-time checking. Against a database carrying only the core set,
`--no-default-features` **compiles clean** — the card crate is not in the graph, so its `query!` never
runs — while `--features card` fails at compile time:

```
error: error returned from database: relation "card_hold_groups" does not exist
 --> card/src/lib.rs:3:13
```

Each crate carries its own `.sqlx/` — the macro checks `SQLX_OFFLINE_DIR`, then `manifest_dir/.sqlx`,
then `workspace_root/.sqlx` (`sqlx-macros-core-0.9.0/src/query/mod.rs:97-101`); both built offline.

## Alternatives

| | Why not |
| --- | --- |
| **(a) One set, card tables in `public`** | What we have. Costs a wallet user 4 tables, 2 views, 10 indexes and 1 enum they never write to — which is cheap — and costs [0002](./0002-scaling.md) a claim that is false, which is not. This decision keeps (a)'s machinery and fixes only the claim. |
| **(b) A migration set per module** | Works mechanically — two version tables, two try-locks, and two `CREATE INDEX CONCURRENTLY` builds in parallel measured at **2.86 s for both against 3.05 s for one alone** on PostgreSQL 18.6, so the [0003](./0003-migrations.md) deadlock does not return. It buys a per-module version line and costs the single ordered list that makes expand/contract safe. Revisit at the *second* rail, not the first. |
| **Separate databases**, as Formance and Temporal do | The card module reads the `customer_receivable` balance inside a ~1 s budget. A second database makes that one read a network hop and a consistency boundary, to separate two things with no foreign key between them. |
| **Odoo-style derived DDL** | Buys a refcounted uninstall by deleting the migration files. [0003](./0003-migrations.md) already refused a declarative diff for a ledger. |

## What it costs

- **`DROP SCHEMA card CASCADE` takes core objects with it and only says so in a NOTICE.** A core view
  over a card table went silently as `drop cascades to view core.exposure`; `RESTRICT` refuses, but it
  also refuses on the schema's own objects, so the pre-check has to be a `pg_depend` query of ours.
- **`search_path` is now load-bearing.** `card, core` resolves `ledger_accounts` to a card table of
  that name with no warning — the silent-wrong-answer class this project ranks worst. The collision
  test is the mechanism; ordering `core, card` is only the convention.
- **`schema/schema.sql` hardcodes `public` twice** (lines 1186 and 1224), and
  [0007](./0007-schema-conventions-and-chart.md)'s unbuilt snapshot test now covers two schemas.
- **CI needs two database shapes**, or a committed `.sqlx/` per crate, to prove both build
  configurations. Both verified separately; neither is wired up.
- **A defect this decision found in [0003](./0003-migrations.md), and it is not about modules.** Its
  recommended idempotent form — `-- no-transaction`, then `DROP INDEX CONCURRENTLY IF EXISTS` and
  `CREATE INDEX CONCURRENTLY` — **does not run under `sqlx` 0.9.0**:

  ```
  Err(ExecuteMigration(Database([25001] DROP INDEX CONCURRENTLY cannot run inside a transaction block), 4))
  ```

  `no_tx` parses correctly; the transport is the problem. `execute_migration` sends the whole file as
  one simple query (`sqlx-postgres-0.9.0/src/migrate.rs:315-323`), and PostgreSQL runs a multi-statement
  simple query in an **implicit** transaction block — proved with a control where the second statement
  divides by zero and the first one's table is absent afterwards. Either statement **alone** applies
  fine. So every `CONCURRENTLY` migration is **one statement** and the idempotent pair is two
  migrations. Verified against goose in spike 007, carried into a `sqlx` decision without being re-run.
