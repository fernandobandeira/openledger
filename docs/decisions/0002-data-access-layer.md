# 0002 — Data access: native pgx + sqlc

**Status:** accepted
**Date:** 2026-08-25

## Context

[0001](./0001-go-and-postgres.md) rules out an ORM, leaving two very different tools:

- **sqlc** — you write SQL; it generates typed Go functions and a result struct per query.
- **go-jet** — generates a model and a type-safe query *builder*; you compose queries in Go.

The codebase has two query populations with opposite needs. The **hot path** is a small fixed set
of hand-tuned statements that must stay readable as SQL. **Reporting** is many queries with
dynamic filters, where a builder pays for itself.

## Decision

**Native `pgxpool` + sqlc.** Configuration in
[`spikes/002-sqlc-vs-jet/sqlc.yaml`](../../spikes/002-sqlc-vs-jet/sqlc.yaml).

The decisive structural fact: **go-jet is hard-wired to `database/sql`** — its `Queryable`
interface returns `*sql.Rows`, so it cannot run on a native `pgxpool`. Choosing it means choosing
a driver stack, not just a generator, and losing `pgx.Batch` and `CopyFrom` with it.

## What changed since

This ADR originally proposed go-jet, on the theory that arrays and jsonb would be painful under
`database/sql` and that go-jet's one-struct-per-table model beat sqlc's per-query structs.
[Spike 002](../../spikes/002-sqlc-vs-jet/README.md) reversed it. The array premise was simply
wrong — both tools handle arrays well. Two unanticipated findings decided it instead:

**1. go-jet has a silent-zero scan trap.** It keys result columns as
`<structTypeName>.<fieldName>`. A bare alias scanned into a named struct returns **zeros with
`err == nil`**. Measured on a money query. The guard is off by default and *panics* rather than
erroring. sqlc structurally cannot fail this way — struct and column list are generated together
from the same query text. For a ledger a silently-zero balance is worse than a crash, because it
reconciles.

**2. go-jet's generator needs a live, migrated Postgres.** There is no DDL parser and the
maintainer has declined to add one, so Docker becomes a permanent hard dependency of codegen.
sqlc parses the migrations directory offline.

Everything else was close to a wash — go-jet handled every hard query we have.

## Consequences

- **`CopyFrom` turned out load-bearing, not a free extra.** Spike 003's coalesced-batching path,
  worth 4.4×, is built on it. This is the clearest retrospective vindication of the reversal.
- **Struct sprawl was overstated.** sqlc returns the bare table struct for `SELECT *`,
  `SELECT alias.*`, and `RETURNING *`. **Always `SELECT *`, never a hand-listed full column
  set** — re-ordering silently forces a per-query `Row` struct.
- **Generated models are the domain entities.** The `overrides` block yields `uuid.UUID`,
  `time.Time`, `*string`, `json.RawMessage`. No mapper layer; the only DTO boundary is at the
  HTTP edge.
- **Use `sqlc.embed` on INNER JOINs only.** On a LEFT JOIN it generates non-nullable fields and
  fails at runtime. It cannot embed a CTE at all.
- **Every aggregate needs `COALESCE(...)` *and* an explicit cast.** `SUM(x)::bigint` types as
  non-nullable `int64` but returns NULL over zero rows, and neither sqlc engine catches it.
  **This wants a CI lint over the query files** — it is the one landmine the tooling misses.
- **Verify each `overrides` entry actually landed.** The `db_type` spelling is unpredictable
  (`bigint` needs `pg_catalog.int8`; `uuid` and `jsonb` take the bare name) and a miss is silent.
- **Dynamic queries** use `sqlc.narg` + `IS NULL OR`, escalating to hand-written SQL scanned by
  `pgx.RowToStructByNameLax` into the same generated structs.

**Not blocked by this:** M1 is schema and migrations — pure SQL. The spike schema applies cleanly
with its invariants enforced by Postgres and graduates to `migrations/0001`.
