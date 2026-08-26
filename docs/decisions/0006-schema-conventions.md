# 0006 — Schema conventions that make a silent mistake loud

**Status:** accepted

## The decision

**1. Name every object `<prefix>_<table>__<what>`**, prefix one of `pk_ uq_ ix_ ck_ fk_`; the double
underscore survives table names that already contain underscores. `<what>` is a **rule name**, not a
column list — `ix_entries__balance_lookup`, `uq_txn__one_reversal`, `ix_entries__asof_recorded` —
because a rule name does not go stale when a column joins the index. `<table>` is usually
abbreviated (`entries`, `txn`, `balances`), since an index name is capped at 63 characters.

**2. A schema snapshot test in CI.**
[`expected_schema.sql`](../../spikes/002-sqlc-vs-jet/expected_schema.sql) dumps every index,
constraint, trigger, and — separately — every `NOT VALID` constraint; CI diffs it against a
committed snapshot. **This is the highest-leverage item here, and it is not built**: what exists is
twenty-one lines containing one `SELECT` that emits a string, with no committed snapshot, no
comparison and no failure path — it runs green against the shipped schema and a mutated one alike.

**3. Keep foreign keys.** Integrators will do things we never anticipated, and a constraint is the
only part of a design that survives an unanticipated caller.

**4. Keep Postgres enums.** The historical argument for `text` + `CHECK` was that
`ALTER TYPE ... ADD VALUE` could not run inside a transaction block. **Verified on PG18: that
restriction was lifted in PG12** — the new value simply cannot be *used* until after commit. So we
keep enums and gain sqlc's typed Go constants with a validating `Scan`.

**5. `NOT VALID` is a two-step, never a one-step.** The zero-downtime pattern
(`ADD CONSTRAINT ... NOT VALID` → `VALIDATE CONSTRAINT` → `SET NOT NULL` → `DROP CONSTRAINT`) is
worth adopting, but a `NOT VALID` constraint that never gets validated is a lie in the schema —
which is why the snapshot test lists them separately. One surviving past the migration that
introduced it is a review failure.

**6. Covering indexes only on append-only tables.** `INCLUDE` gives a true index-only scan only when
the visibility map bit is set, which needs a vacuum and holds reliably only on tables that are never
updated. Measured: our balance-lookup index reaches zero heap fetches on settled data at +16% index
size when freshly built (11 MB against 9736 kB) — but on a **freshly inserted row, which is exactly
what the hot path reads**, the bit isn't set and it still costs a heap fetch. And +16% is the
*build-time* cost: after a 200,000-row append-only load the live index is **20 MB against 11 MB
rebuilt**, because its `DESC` ordering puts every insert at the leftmost page and gives up the
rightmost-split fast path. **So `INCLUDE` here is justified by reporting, not by the hot path** —
recorded so nobody later "optimises the hot path" with covering indexes that do nothing.

**7. Split a table when its write frequency differs from its parent.** Balance changes on every
posting; account identity and metadata almost never. Folding balance into `ledger_accounts` would
mean every posting updating a wide row carrying jsonb and several indexes. A narrow balance row is
cheap to lock and stays in cache — and spike 003 found that this row's lock *is* the system's
serialization point, the thing that sets the ceiling and the thing every throughput lever
manipulates. "Cheap to lock" is the most performance-critical property in the schema.

**8. Never store JSON in a text column, and `timestamptz` everywhere.** Our `jsonb` stays `jsonb`.

## Why

Reading Formance's 54 migrations ([spike 001](../../spikes/001-formance/README.md)) showed that
most of their schema problems are not design mistakes. They are **process** mistakes a convention
would have caught:

- A migration dropped a column; Postgres silently dropped the two indexes built on it. Their
  point-in-time balance read has been a scan-and-sort ever since, unnoticed for sixteen migrations.
  A snapshot diff turns that from a latent performance bug into a failed build.
- A migration named `accounts-metadata-index` creates an index on the `accounts` table, not
  `accounts_metadata`. The real gap — a sequential scan on every metadata write, forever — was
  hidden by the name.
- Two composite primary keys are named in a way that reads like single-column indexes.
- At the commit [spike 009](../../spikes/009-how-other-ledgers-enforce/README.md) read, Formance's census is **four `CHECK` constraints, all four unvalidated, and zero foreign keys** — an earlier read of five-of-nine was true at a different commit.
- Their canonical record of money movement is a `varchar` holding pretty-printed JSON. It cannot be
  queried, indexed or validated, so four additional jsonb columns and three GIN indexes exist
  solely to make it queryable. They made the same mistake twice.
- They use `timestamp without time zone` throughout and hold UTC by convention — and have a
  migration literally named `fix-invalid-date-format`. A convention is not a constraint.

## Alternatives

| | Why not |
| --- | --- |
| **No foreign keys** (Formance has essentially none — nullable back-pointers, no referential integrity) | Defensible for an engine chasing unconstrained write throughput; wrong on this project's stated correctness priority. |
| **`text` + `CHECK` instead of enums** | Its one advantage was lifted in PG12. |
| **Column lists in index names** | Go stale the moment the index gains a column. |
| **A covering index on the hot path** | The visibility-map bit is unset on the row it would serve. |

## What it costs

- **Foreign keys cost something real on the bulk-insert path.** A run on the shipped schema (seven
  foreign keys in the tables under test, same CHECKs and indexes, 50k rows, three trials) gave
  **3002/3176/3672 ms with them against 1257/1067/793 ms without**. Read it as a direction, not a
  benchmark — the harness is not in the repo. The cost is on bulk load, and we accept it.
- **An enum value cannot be removed**, and reordering requires recreating the type.
- **CI needs the snapshot-diff step before M1 lands.** It is worth more than any test we would
  write by hand, and until it exists convention 2 is aspiration.
- **Rule names are not greppable by column.** *"Does this table have an index on X"* still means
  reading the definitions, which is the price of names that don't go stale.
- Verified against [`schema/schema.sql`](../../schema/schema.sql): **every index and every named
  constraint matches `^(pk|uq|ix|ck|fk)_`**, and no object carries a PostgreSQL default name. One
  thing a reader running that query will see and should not be alarmed by: PostgreSQL 18 materialises
  `NOT NULL` as a real catalog constraint, so `pg_constraint` lists ~90 server-generated rows named
  `<table>_<column>_not_null`. They cannot be supplied in `CREATE TABLE`, and nothing references them.
