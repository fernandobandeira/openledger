# Spike 008 — How does an optional module that owns tables get shipped?

**Status:** closed. Produced [ADR-0008](/decisions/0008-module-boundaries).

**Question.** [ADR-0002](/decisions/0002-scaling) calls the card product a plug-in whose
entire coupling to the ledger core is one read. [ADR-0003](/decisions/0003-migrations)
says there is exactly one copy of the schema, applied by one pre-deploy runner holding one lock. But
`schema/schema.sql` contains the card tables, so a wallet-only user gets them anyway. **Those cannot
both be true.** What do comparable systems do, and what does it cost?

**Ran** 2026-08-26 · PostgreSQL 18.6 · sqlx 0.9.0 · rustc/cargo 1.97.1. Prior art from source clones
with commit SHAs, not from documentation.

---

## The answer

**Keep one migration set, one lock and one order. Move the card objects out of `public` into a `card`
schema inside that same baseline.** That makes the module **removable** rather than **optional**, and
it makes ADR-0002's claim true in the half where it is true: the *code* is a plug-in — measured — and
the *schema* is not.

**The one condition that changes it:** a second rail. At one module, a separate migration set buys a
per-module version line and costs the single ordered list. At two, the one-file argument breaks.

## Prior art

| System | Module owns migrations | Own version table | Own schema | Ordering | Uninstall |
|---|---|---|---|---|---|
| **Formance** | yes, per repo | yes, per set | no — own **database** | none between components | none |
| **Temporal** | yes | yes, PK `(version_partition, db_name)` | no — two **databases** | none between sets | `DROP DATABASE` |
| **Django** | yes, per app | one table **with an `app` column** | no | a real dependency DAG | `migrate app zero` |
| **Rails engines** | yes, then **copied into the host** | no — identity lost on copy | no | host timestamp order | none |
| **Keycloak** | yes | **yes**, `DATABASECHANGELOG_<factoryId>` | no | provider `Set` iteration — **undefined** | none |
| **Odoo** | no DDL files at all | **no table** — one column | no | `depends` → `(phase, depth, name)` | **yes, refcounted** |
| **Medusa v2** | yes | no — shared, keyed on name | defaults `public` | **none**; optionally concurrent | `down()` missing, **silently skipped** |
| **Discourse** | yes | no — one global table | no | appended to the global list | manual |

**The two that separate cleanly do it by giving each component its own database**, with zero
cross-component foreign keys — Temporal's `grep -rniE "foreign key" schema/` returns **0**. **The only
one with a working uninstall bought it by having no migration files.** And the sharpest datapoint:
**Keycloak built per-module changelog tables and then declined to use them for its own optional
features** — `AUTHORIZATION` and `ORGANIZATION` are disableable, and their tables are unconditional
includes in the core changelog.

## What we measured

**The seam is already clean and nobody was using it.** From `pg_constraint`: 10 foreign keys, and
**not one crosses the card/core boundary in either direction**. The whole database-level coupling is
three objects — the `auth_event_kind` enum (declared in the core preamble, used by **no core table**),
the two trigger functions, and one `GRANT` block. It is **4** card tables, not 3: `webhook_deliveries`
sits in the card block.

| | tables | views | indexes | triggers | enums |
|---|---|---|---|---|---|
| monolith | 11 | 5 | 33 | 8 | 6 |
| core only | 7 | 3 | 23 | 6 | 5 |

**(b) A migration set per module — works, and I would still not take it.** `core_mig.sql`
(725 lines) and `card_mig.sql` (471) applied in order produce a `pg_dump -s`
**identical to the monolith's** but for pg_dump 18's random `\restrict` nonce. `sqlx` ships the
mechanism (`dangerous_set_table_name()`, `create_schema()`). What it does not ship is ordering: no
`dependencies`, no `run_before`. Card first on an empty database →
`Err(ExecuteMigration(Database([42883] function refuse_mutation() does not exist), 1))`. And **one
version table cannot hold two sets** — colliding numbers give `VersionMismatch(1)`, disjoint numbers
give `VersionMissing(1)`, because each `Migrator` treats the table as its own complete world.

**Two locks are safe; it is the order you lose.** Two migrators on two try-lock keys, each building
`CREATE INDEX CONCURRENTLY` on a 670 MB table: **2.86 s for both against 3.05 s for one alone.** The
ADR-0003 deadlock does not return, because nobody blocks in `pg_advisory_lock`.

**(c) Schema-per-module — less breaks than expected.** `ALTER … SET SCHEMA` carries indexes, the
foreign key, and `ENABLE ALWAYS` on triggers. **RLS is unaffected** (policies are per-table).
Cross-schema foreign keys work. `sqlx` compile-time checking works via a `search_path` option and
unqualified SQL is unchanged. `DROP SCHEMA card CASCADE` leaves all 7 core tables, all 9 core foreign
keys and all 3 report views intact. **What breaks:** `search_path = card, core` **silently shadows** a
core table of the same name, and `DROP … CASCADE` takes a dependent core view with a NOTICE only.

**The Rust half already composes.** `--no-default-features` against a core-only database **compiles
clean**; `--features card` fails at *compile* time with `relation "card_hold_groups" does not exist`.
Per-crate `.sqlx/` works — the macro checks `SQLX_OFFLINE_DIR`, then `manifest_dir/.sqlx`, then
`workspace_root/.sqlx`.

## The defect this spike found, unrelated to modules

ADR-0003's recommended idempotent `CONCURRENTLY` form **does not run under `sqlx` 0.9.0**:

```
Err(ExecuteMigration(Database([25001] DROP INDEX CONCURRENTLY cannot run inside a transaction block), 4))
```

`no_tx` parses correctly — the transport is the problem. `execute_migration` sends the whole file as
**one simple query**, and PostgreSQL runs a multi-statement simple query in an **implicit transaction
block**. Proved with a control: two statements where the second divides by zero leave the first's
table absent. Either statement **alone** applies fine. **So every `CONCURRENTLY` migration is one
statement, and the idempotent pair is two migrations.** The form was verified against goose in
[spike 005](/spikes/005-schema-migrations) and carried into an `sqlx` decision without being
re-run — the same failure mode this repository keeps finding in itself.

## Not verified

- **Nothing ran at production scale or over a network.** Every timing is localhost.
- **The prior-art reads are static source reads.** No system was installed and uninstalled; Keycloak's
  per-provider table was not observed at runtime, and Odoo's uninstall was not run to completion.
- **Genuinely concurrent migrator processes** were tested via psql sessions and sequential Rust, not
  two replicas racing at startup.
- **The `card` schema was never exercised under load, or with RLS actually enforcing** — policies were
  created and read back from `pg_policies`, not driven by a tenant-isolated workload.
- `sqlx.toml`'s `table-name` path is source-verified only; `Migrator::undo` was not exercised.
