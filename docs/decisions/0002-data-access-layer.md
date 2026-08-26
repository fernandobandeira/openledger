# 0002 — Data access: native pgx + sqlc

**Status:** accepted

## The decision

**Native `pgxpool` + sqlc.** We write the SQL; sqlc generates typed Go functions and a result
struct per query. Configuration in
[`spikes/002-sqlc-vs-jet/sqlc.yaml`](../../spikes/002-sqlc-vs-jet/sqlc.yaml). Generated models
*are* the domain entities — no mapper layer, and the only DTO boundary is at the HTTP edge.

## Why

**go-jet is hard-wired to `database/sql`.** Its `Queryable` interface returns `*sql.Rows`, so it
cannot run on a native `pgxpool`. Choosing it means choosing a driver stack, not just a generator,
and losing `pgx.Batch` and `CopyFrom` with it. `CopyFrom` is load-bearing rather than a free extra:
spike 003's coalesced-batching path, worth **4.4×**, is built on it.

**go-jet has a silent-zero scan trap.** It keys result columns as
`<structTypeName>.<fieldName>`, so a bare alias scanned into a named struct returns **zeros with
`err == nil`** — measured on a money query in
[spike 002](../../spikes/002-sqlc-vs-jet/README.md). The guard is off by default and *panics*
rather than erroring. sqlc structurally cannot fail this way: struct and column list are generated
together from the same query text. For a ledger a silently-zero balance is worse than a crash,
because it reconciles.

**go-jet's generator needs a live, migrated Postgres.** There is no DDL parser and the maintainer
has declined to add one, so Docker becomes a permanent hard dependency of codegen. sqlc parses the
migrations directory offline.

Everything else was close to a wash — go-jet handled every hard query we have, arrays and jsonb
included.

## Alternatives

| | Why not |
| --- | --- |
| **go-jet** | `database/sql` only; silent-zero scan; codegen needs a live database. Its query builder is genuinely better for dynamic reporting filters — that is the cost we accept below. |
| **An ORM** | Ruled out by [0001](./0001-go-and-postgres.md): the hot queries must stay reviewable as SQL. |
| **Hand-written pgx everywhere** | Kept as the escape hatch for dynamic queries, not as the default — no generated types means no compile-time check that the struct matches the column list. |

## What it costs

Five sharp edges, all silent when you get them wrong, and one thing that is not what it looks like:

- **Always `SELECT *`, never a hand-listed full column set.** sqlc returns the bare table struct
  for `SELECT *`, `SELECT alias.*` and `RETURNING *`; re-ordering columns by hand silently forces
  a per-query `Row` struct.
- **`sqlc.embed` on INNER JOINs only.** On a LEFT JOIN it generates non-nullable fields and fails
  at runtime. It cannot embed a CTE at all.
- **Every aggregate needs `COALESCE(...)` *and* an explicit cast.** `SUM(x)::bigint` types as
  non-nullable `int64` but returns NULL over zero rows, and neither sqlc engine catches it. This
  wants a CI lint over the query files — the one landmine the tooling misses.
- **Verify each `overrides` entry actually landed.** The `db_type` spelling is unpredictable
  (`bigint` needs `pg_catalog.int8`; `uuid` and `jsonb` take the bare name) and a miss is silent.
- **Dynamic queries** use `sqlc.narg` + `IS NULL OR`, escalating to hand-written SQL scanned by
  **`pgx.RowToStructByName` — the strict one.** An earlier version of this line said `…Lax`, and
  [spike 010](../../spikes/010-go-or-rust/README.md) showed that recommendation reproduces, inside
  the pgx stack, the exact go-jet trap five paragraphs above. Company with a 1,000.00 limit and
  950.00 posted, so 50.00 of headroom; drop `posted_minor` from the SELECT list in a refactor and
  keep the field on the struct; `Lax` scans **`PostedMinor: 0`, `err == nil`**, available reads
  100,000, and a 200.00 authorization is **approved against 50.00**. `go build` and `go vet` are
  both clean. `RowToStructByNameLax` is one switch that makes *every* money field on a struct
  silently zeroable; the strict form fails the same case with `cannot find field posted_minor in
  returned row`. **The claim "sqlc structurally cannot fail this way" is true of sqlc and was false
  of the escape hatch this ADR put next to it.**
- **The spike schema did not graduate.** `spikes/002-sqlc-vs-jet/schema.sql` puts
  `idempotency_key` on `ledger_transactions`, which [0004](./0004-event-log.md) moved to
  `ledger_events`. `schema/schema.sql` was written by hand.
