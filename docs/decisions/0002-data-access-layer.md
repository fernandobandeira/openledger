# 0002 — Data access layer: sqlc vs go-jet

**Status:** accepted
**Date:** 2026-08-25 (proposed) · 2026-08-25 (accepted, reversing the proposal)

## Context

[ADR-0001](./0001-go-and-postgres.md) rules out an ORM. That leaves two shapes of tool, and
they are not the same kind of thing:

- **sqlc** — you write SQL, it generates typed Go functions and a result struct **per query**.
- **go-jet** — generates a model + type-safe query **builder** from the live schema; you
  compose queries in a Go DSL.

This codebase has two query populations with opposite needs:

1. **Ledger core / hot path** — a small, fixed set of gnarly hand-tuned statements. The auth
   transaction, the balance read, the entry batch insert. These must stay readable *as SQL*.
2. **Reporting, admin, list endpoints** — dynamic filters, as-of predicates, pagination,
   joins. Many queries, lower stakes, and exactly where a builder pays for itself.

## Finding that reshapes the choice

Verified against `go-jet/jet v2.15.0`:

```go
// qrm/db.go
type Queryable interface {
    QueryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error)
}
```

**Jet is hard-wired to `database/sql`.** It cannot execute against a native `pgxpool.Pool`.
Using it means either routing everything through `database/sql` with the pgx stdlib driver, or
running two pools — and two pools cannot share a transaction, which kills any hope of mixing
hand-written hot-path SQL with builder-composed reads inside one `BEGIN`.

So this is not "which generator" but **which driver stack**, and the generator follows:

| | **A · `database/sql` + pgx stdlib + Jet** | **B · native `pgxpool` + sqlc** |
| --- | --- | --- |
| Entity structs | one clean `model.LedgerEntries` per table | one struct per **query** (`GetHeldByCompanyRow`, …) |
| Hand-written SQL | yes — `tx.QueryRowContext` on the **same `*sql.Tx`** Jet uses | yes — that's the whole model |
| Dynamic queries | native (the builder) | not supported; string-building by hand |
| Arrays / jsonb / numeric | via `database/sql` — **the open risk** | native `pgtype`, excellent |
| `pgx.Batch`, `CopyFrom` | lost (or awkward via `conn.Raw()`) | native |
| SQL under review | raw for the core; DSL for the rest | always raw, always in the repo |

## Decision

**Option B — native `pgxpool` + sqlc**, with `sqlc.yaml` as the recommended configuration in
[`spikes/002-sqlc-vs-jet/sqlc.yaml`](../../spikes/002-sqlc-vs-jet/sqlc.yaml).

**This reverses the proposal below.** The original argument for Option A is kept intact so the
reasoning trail survives; [spike 002](../../spikes/002-sqlc-vs-jet/README.md) is what changed it, and the
section after it says why.

## Superseded proposal (kept for the trail)

**Option A**, with hand-written SQL for the ledger core executed on the same `*sql.Tx`.

Reasoning:

1. What A gives up — pipelining, `CopyFrom`, native pgx types — is performance we have
   [explicitly declined to need](../v1-vision.md#01--size-it-before-designing). Trading
   throughput for ergonomics is the correct direction *for this system specifically*.
2. Jet's `model` package is one struct per table. That is better context for a human reader
   and materially better context for an LLM than sqlc's per-query struct sprawl.
3. **Raw SQL and Jet coexist in one transaction** because they share `database/sql`. This is
   the property that makes the hybrid work, and it is the property sqlc + Jet cannot have.
4. "Reproduce any number as of any date" means the reporting surface will be dynamic. That is
   the builder's home turf.

## The one thing that could flip it

Row 4 of the table. `spend_controls.allowed_mcc[]` / `blocked_mcc[]` are arrays;
`ledger_transactions.external_ref` and `metadata` are jsonb. Under native pgx these are a
solved problem via `pgtype`. Under `database/sql`, `driver.Value` is limited to
`int64/float64/bool/[]byte/string/time.Time`, so arrays and jsonb may arrive as `[]byte`
needing manual unmarshalling at every call site.

If that turns out to be pervasive and ugly, sqlc's native pgx handling is worth more than
Jet's builder, and the decision flips to B.

**[Spike 002](../../spikes/002-sqlc-vs-jet/README.md) exists to answer exactly that**, plus whether the
auth transaction's `FILTER` aggregate and `ON CONFLICT ... DO NOTHING RETURNING` survive each
stack intact.

---

## Why the spike reversed it

The pre-registered decision rule was: *"if arrays and jsonb are ugly under `database/sql` → B."*
**That rule never fired.** Arrays turned out to be fine under *both* tools — sqlc's pgx/v5 mode
emits native `[]int32` / `[]string`, and go-jet emits `pq.StringArray` with typed builder
operators (`@>`, `&&`). The premise of the whole ADR was wrong.

The tiebreak said a coin flip goes to A. It was not a coin flip. Two findings decided it, and
neither was anticipated by either brief:

**1. go-jet's silent-zero scan trap.** `qrm` keys result columns as
`<structTypeName>.<fieldName>`. A bare alias — `AS("company_held")` — scanned into a named
struct returns **zeros with `err == nil`**. Measured on a money query. The guard,
`qrm.GlobalConfig.StrictFieldMapping`, is off by default and *panics* rather than returning an
error. sqlc structurally cannot have this failure mode: the struct and the column list are
generated together from the same query text. For a ledger, a silently-zero balance is the worst
available outcome — worse than a crash, because it reconciles.

**2. go-jet's generator requires a live, migrated Postgres, with no offline path.** There is no
DDL parser in the tree, and the maintainer has explicitly declined to add one (upstream #136,
#271). Docker becomes a permanent hard dependency of codegen. sqlc parses the migrations
directory offline; its database-backed analyzer is an *optional* accuracy upgrade that degrades
gracefully when absent. Soft dependency vs hard one.

Everything else was close to a wash. go-jet handled every hard query we have, including the
`FILTER` aggregate (via the maintainer's own `CustomExpression` helper) and
`ON CONFLICT ... DO NOTHING RETURNING` (conflict distinguishable via `qrm.ErrNoRows`). Its
strongest card — `RawStatement` participates in qrm scanning, so hand-written SQL maps into
generated models — is real, and is undercut by the same aliasing trap, since hand-written SQL
is exactly where the `"table.column"` convention gets forgotten.

## Consequences

- **`pgxpool` native.** `pgx.Batch`, `CopyFrom`, and `pgtype` are available. ~~We do not need
  them at under 1 TPS, but they cost nothing to keep.~~ **Amended:** they turned out to be
  load-bearing, not free extras. [Spike 003](../../spikes/003-throughput-ceiling/README.md)'s
  coalesced-batching path — worth 4.4× on its own — is built on `CopyFrom` for bulk entry
  insertion. Under the [ADR-0007](./0007-open-source-positioning.md) pivot this is the clearest
  retrospective vindication of choosing B: go-jet's `database/sql` constraint would have made the
  single highest-value throughput lever materially harder to build.
- **Struct sprawl is smaller than the objection assumed.** sqlc returns the bare table struct
  for any `SELECT *` / `SELECT alias.*` / `RETURNING *`. Combined with `omit_unused_structs`,
  what remains is genuine projections. **Always `SELECT *`, never a hand-listed full column
  set** — re-ordering silently forces a `Row` struct (upstream #3328).
- **Generated models are the domain entities.** The `overrides` block yields `uuid.UUID`,
  `time.Time`, `*string`, `json.RawMessage`. No mapper layer. Follow coder/coder's pattern:
  generate into a package we also hand-write in, and put the only real DTO boundary at the
  HTTP edge.
- **`sqlc.embed` on INNER JOINs only.** On a LEFT JOIN it generates non-nullable fields and
  fails at runtime (upstream #3240, #2997, #2348, all open). It also cannot embed a CTE.
- **Every aggregate needs `COALESCE(...)` *and* an explicit cast.** `SUM(x)::bigint` types as
  non-nullable `int64` under both the static engine and the analyzer, and returns NULL over
  zero rows. Neither engine catches it. **This needs a CI lint over `queries.sql`** — it is the
  one landmine the tooling will not find for us.
- **Verify every `overrides` entry landed.** The `db_type` spelling is not predictable
  (`bigint` needs `pg_catalog.int8`; `uuid`/`timestamptz`/`jsonb` take the bare name) and a
  miss is silent. Overrides also apply to model structs but not consistently to params structs.
- **Dynamic queries** use `sqlc.narg` + `IS NULL OR`, escalating to hand-written SQL scanned by
  `pgx.RowToStructByNameLax` into the same generated structs (needs `emit_db_tags: true`).

## Not blocked by this

M1 — schema, constraints, and the `account_seq` / `balance_after` concurrency proof — is pure
SQL and migrations. The spike schema in
[`spikes/002-sqlc-vs-jet/schema.sql`](../../spikes/002-sqlc-vs-jet/schema.sql) already applies
cleanly with all seven invariants verified as enforced by Postgres, and graduates to
`migrations/0001` from there.
