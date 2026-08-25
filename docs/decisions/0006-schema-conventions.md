# 0006 — Schema conventions

**Status:** accepted
**Date:** 2026-08-25

## Context

Reading Formance's 54 migrations ([spike 001](../../spikes/001-formance/README.md)) showed that
most of their schema problems are not design mistakes. They are **process** mistakes a convention
would have caught:

- A migration dropped a column; Postgres silently dropped the two indexes built on it. Their
  point-in-time balance read has been a scan-and-sort ever since — unnoticed for thirty
  migrations.
- A migration named `accounts-metadata-index` creates an index on the `accounts` table, not
  `accounts_metadata`. The real gap — a sequential scan on every metadata write, forever — was
  hidden by the name.
- Two composite primary keys are named in a way that reads like single-column indexes.
- All four of their `CHECK` constraints are `NOT VALID` and none was ever validated, so they
  constrain new rows only — not what a reader would assume.

Cheap to prevent, expensive to discover.

## Decisions

**1. Naming: `ix_<table>__<cols>` / `uq_<table>__<cols>` / `ck_<table>__<rule>`.** Mechanical and
greppable, so "does this table have an index on X" is answerable by reading the schema. The double
underscore survives table names that already contain underscores.

**2. A schema snapshot test in CI.**
[`expected_schema.sql`](../../spikes/002-sqlc-vs-jet/expected_schema.sql) dumps every index,
constraint, trigger, and — separately — every `NOT VALID` constraint; CI diffs it against a
committed snapshot. **This is the highest-leverage item here.** It turns "a migration silently
dropped an index" from a latent performance bug into a failed build. Formance hit that exact
failure four times from two migrations.

**3. Keep foreign keys.** Formance has essentially none — nullable back-pointers with no
referential integrity — which is defensible for an engine chasing unconstrained write throughput.
It is the wrong trade here, and we keep them on the project's stated correctness priority, NOT on a measurement. Not FK validation, not
index maintenance, not I/O. The cost Formance dropped FKs to avoid is one we looked for and could
not find. A general engine has *more* reason to keep them, because integrators will do things we
never anticipated and a constraint is the only part of the design that survives an unanticipated
caller.

**4. Keep Postgres enums.** The historical argument for `text` + `CHECK` was that
`ALTER TYPE ... ADD VALUE` could not run inside a transaction block. **Verified on PG18: that
restriction was lifted in PG12** — the new value simply cannot be *used* until after commit. So we
keep enums and gain sqlc's typed Go constants with a validating `Scan`. Residual cost: a value
cannot be removed, and reordering requires recreating the type.

**5. `NOT VALID` is a two-step, never a one-step.** The zero-downtime pattern
(`ADD CONSTRAINT ... NOT VALID` → `VALIDATE CONSTRAINT` → `SET NOT NULL` → `DROP CONSTRAINT`) is
worth adopting, but a `NOT VALID` constraint that never gets validated is a lie in the schema. The
snapshot test lists them separately for exactly this reason: one surviving past the migration that
introduced it is a review failure.

**6. Covering indexes only on append-only tables.** `INCLUDE` gives a true index-only scan only
when the visibility map bit is set, which requires a vacuum and holds reliably only on tables that
are never updated. Measured: our balance-lookup index reaches zero heap fetches on settled data at
+19% index size — but on a **freshly inserted row, which is exactly what the hot path reads**, the
bit isn't set yet and it still costs a heap fetch. **So `INCLUDE` here is justified by the
reporting workload, not the hot path.** Recorded so nobody later "optimises the hot path" with
covering indexes that do nothing. The inverse is why Formance's equivalent index is a mistake: it
sits on an UPDATE-heavy table, paying two index writes per posting for a heap fetch it mostly
won't get.

**7. Split a table when its write frequency differs from its parent.** Balance changes on every
posting; account identity and metadata almost never. Folding balance into `ledger_accounts` would
mean every posting updating a wide row carrying jsonb and several indexes. A narrow balance row is
cheap to lock and stays in cache. **Since confirmed:** spike 003 found that this row's lock *is*
the system's serialization point — the thing that sets the ceiling and the thing every throughput
lever manipulates. "Cheap to lock" went from aesthetic preference to the most
performance-critical property in the schema.

**8. Never store JSON in a text column.** Formance's canonical record of money movement is a
`varchar` holding pretty-printed JSON. It cannot be queried, indexed, or validated — so four
additional jsonb columns and three GIN indexes exist solely to make it queryable. They made the
same mistake twice. Our `jsonb` stays `jsonb`.

## Consequences

- The schema is renamed to the convention and carries its measured index rationale in comments.
- CI needs the snapshot-diff step before M1 lands. It is worth more than any test we would write
  by hand.
- **`timestamptz` everywhere, never `timestamp`.** Formance uses `timestamp without time zone`
  throughout and holds UTC by convention — and has a migration literally named
  `fix-invalid-date-format`. A convention is not a constraint.
