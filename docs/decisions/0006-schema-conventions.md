# 0006 — Schema conventions

**Status:** accepted
**Date:** 2026-08-25

## Context

The table-design pass in [spike 001](../../spikes/001-formance/README.md#addendum--table-design-pass)
found that most of Formance's schema problems are not design mistakes. They are **process**
mistakes that a convention would have caught:

- Migration 37 dropped a column; Postgres silently dropped the two indexes built on it; their
  point-in-time balance read has been a scan-and-sort ever since. Nobody noticed for thirty
  migrations.
- A migration named `accounts-metadata-index` creates an index on the `accounts` table, not
  `accounts_metadata`. The real gap on `accounts_metadata` — a sequential scan on every
  metadata write, forever — was hidden by the name.
- Two of their composite primary keys are named `accounts_ledger` and `logs_ledger`, which read
  like single-column indexes on `ledger`.
- All four of their `CHECK` constraints are `NOT VALID` and none was ever validated. They
  constrain new rows only, which is not what anyone reading the schema would assume.

These are cheap to prevent and expensive to discover.

## Decisions

### 1. Naming: `ix_<table>__<cols>` / `uq_<table>__<cols>` / `ck_<table>__<rule>`

Mechanical and greppable. "Does this table have an index on X" is answerable by reading the
schema rather than querying the catalog. The double underscore separates the table from the
columns so the boundary survives table names that contain underscores.

### 2. A schema snapshot test in CI

[`spikes/002-sqlc-vs-jet/expected_schema.sql`](../../spikes/002-sqlc-vs-jet/expected_schema.sql)
dumps every index, constraint, trigger, and — separately — every `NOT VALID` constraint. CI
asserts it against a committed snapshot.

This is the single highest-leverage item from the whole spike. It converts "a migration silently
dropped an index" from a thirty-migration latent performance bug into a failed build. Formance
suffered that exact failure four separate times from two migrations.

### 3. Keep foreign keys

Formance has **zero foreign keys** in their entire bucket schema — `moves.transactions_id`,
`transactions_metadata.transactions_id`, and `accounts_metadata.accounts_address` are all
nullable back-pointers with no referential integrity. (One FK exists in their whole codebase,
on an unrelated system table.)

This is a reasonable choice for a general-purpose engine that shards by bucket and wants
unconstrained write throughput. ~~It is the wrong choice for us: we are one product, at under
1 TPS~~ It is the wrong choice for us — see the measured version of this argument below — where
the cost of a dangling `transaction_id` is a number in a lender report that no one can explain.
Keep FKs, and keep them `NOT NULL` where the relationship is mandatory.

> **Amended under [ADR-0007](./0007-open-source-positioning.md).** The original justification was
> "we are one product, at under 1 TPS" — which the pivot removes, since we are now *also* a
> general-purpose engine and no longer know our users' volume. The decision is unchanged and the
> argument is now stronger, because it is measured rather than assumed.
>
> [Spike 003](../../spikes/003-throughput-ceiling/README.md) benchmarked the FK-carrying schema at
> **800 clearings/s unsharded and 7,897 striped**, and identified the bottleneck precisely: row-lock
> contention on shared accounts. Not FK validation, not index maintenance, not I/O, not WAL flush.
> Formance's reason for dropping foreign keys — unconstrained write throughput — is a cost we
> looked for and could not find at any configuration we tested.
>
> So the honest form is: **referential integrity is not what limits this design, and we have the
> numbers to say so.** A general engine has *more* reason to keep FKs than a single product did,
> because its integrators will do things to the schema we never anticipated, and a constraint is
> the only part of the design that survives contact with an unanticipated caller.

### 4. Keep Postgres enums

Their `log_type` enum required `ALTER TYPE ... ADD VALUE` to add a variant, which historically
could not run inside a transaction block — a real argument for `text` + `CHECK`.

**Verified on PG18: that restriction no longer applies.** `ALTER TYPE ... ADD VALUE` runs
inside a transaction block (relaxed in PG12); the new value simply cannot be *used* until after
commit. The argument was pre-PG12 reasoning.

So we keep enums, and gain what [spike 002](../../spikes/002-sqlc-vs-jet/README.md) verified: sqlc
generates typed Go constants plus a validating `Scan` from them. The residual cost is real but
acceptable — a value cannot be removed, and reordering requires recreating the type.

### 5. `NOT VALID` is a two-step, never a one-step

The zero-downtime pattern (`ADD CONSTRAINT ... NOT VALID` → `VALIDATE CONSTRAINT` →
`SET NOT NULL` → `DROP CONSTRAINT`) is worth adopting. But a `NOT VALID` constraint that never
gets validated is a lie in the schema. The snapshot test reports them separately for exactly
this reason: any `NOT VALID` constraint surviving past the migration that introduced it is a
review failure.

### 6. Covering indexes only on append-only tables

`INCLUDE` gives a true index-only scan only when the visibility map bit is set, which requires
a vacuum and holds reliably only on tables that are not updated.

**Measured on 400k rows.** `ix_entries__balance_lookup (account_id, account_seq DESC) INCLUDE
(balance_after)` reaches `Heap Fetches: 0` on settled data at +19% index size (19MB vs 16MB).
But on a **freshly inserted row — exactly what the auth hot path reads** — the bit is not yet
set and it is still `Heap Fetches: 1`.

So the `INCLUDE` is justified by the [ADR-0003](./0003-bitemporal-balances.md) reporting
workload over settled history, **not** by the hot path. Recording this so nobody later "optimises
the hot path" by adding covering indexes that do nothing.

The inverse is why Formance's equivalent covering index is a mistake: it sits on an UPDATE-heavy
balances table, paying two index writes per posting to save a heap fetch it will mostly not get.

### 7. Split a table when its write frequency differs from its parent

The principle their end state encodes, though they arrived at it rather than designing to it —
`accounts_volumes` did not exist for eleven migrations.

Balance changes on every posting; account identity and metadata change almost never. Folding
balance into `ledger_accounts` would mean every posting updating a wide row carrying `metadata
jsonb` and several indexes. A narrow balance row is cheap to lock, cheap to update, and stays in
cache. This is an independent argument for the `ledger_account_balances` table that roadmap M2
already wants for sequence assignment.

**Since confirmed by measurement.** [Spike 003](../../spikes/003-throughput-ceiling/README.md)
built exactly this table and found that the balance row's lock *is* the system's serialization
point — the thing that sets the ceiling, and the thing every throughput lever in
[ADR-0007](./0007-open-source-positioning.md) manipulates. "Cheap to lock" stopped being an
aesthetic preference and became the single most performance-critical property in the schema.

### 8. Never store JSON in a text column

Their `transactions.postings` — the canonical record of the actual money movement — is `varchar`
holding `jsonb_pretty()` output. It cannot be queried, indexed, or validated. Four additional
jsonb columns and three GIN indexes exist solely to make it queryable. One type mistake, and
they made it twice (`exporters.config` too).

Our `jsonb` columns stay `jsonb`.

## Consequences

- The spike schema has been renamed to the convention and carries the measured index rationale
  in comments.
- CI needs a snapshot-diff step before M1 lands. It is worth more than any test we would write
  by hand.
- `timestamptz` everywhere, never `timestamp` — Formance uses `timestamp without time zone`
  throughout and holds UTC by convention. A convention is not a constraint, and their migration
  33 is literally `fix-invalid-date-format`. We already do this; recording it so it stays.
