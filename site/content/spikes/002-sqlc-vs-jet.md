# Spike 002 — sqlc or go-jet

**The question.** Both generate Go code from a Postgres schema. **sqlc** takes SQL you wrote and
emits typed functions. **go-jet** generates a type-safe query *builder* plus one clean struct per
table. Which one survives our hardest queries, and does go-jet's requirement of `database/sql`
(rather than native `pgx`) cost too much?

**Status:** closed, and **the question is now moot**. It produced an ADR on the Go data-access
layer that no longer exists: [spike 010](/spikes/010-go-or-rust) moved the language and `sqlx`
replaced both candidates. What outlived it is the silent-zero finding, which is the central argument
of [ADR-0001](/decisions/0001-rust-and-postgres).

---

## The answer

**sqlc, on native `pgxpool`** — reversing the proposal in the ADR that then stood. Recommended configuration:
`sqlc.yaml`, verified end to end against a live database.

The pre-registered decision rule was *"if arrays and jsonb are ugly under `database/sql` → sqlc."*
**That rule never fired** — arrays are fine under both tools, so the premise of the whole ADR was
wrong. sqlc won on two grounds neither brief anticipated:

1. **go-jet has a silent-zero scan trap.** A mis-aliased column scans as `0` with `err == nil`. On
   a money query that is the worst possible failure — worse than a crash, because it reconciles.
   sqlc structurally cannot do this: the struct and the column list are generated together from the
   same query text.
2. **go-jet's generator requires a live, migrated Postgres, with no offline path.** There is no DDL
   parser in the tree and the maintainer has declined to add one. sqlc parses the migrations
   directory offline; its database-backed analyzer is an *optional* accuracy upgrade.

Both objections that motivated go-jet dissolved on measurement:

- **Arrays** — `sql_package: "pgx/v5"` emits native `[]int32` and `[]string`, not `pgtype.FlatArray`
  and not `[]byte`. Verified round-tripping through a live `RETURNING *`.
- **Struct sprawl** — sqlc already returns the bare table struct for any `SELECT *` /
  `SELECT alias.*` / `RETURNING *`. `sqlc.embed()` and `overrides` handle the rest (below).

## What it cost

- **Every aggregate needs `COALESCE(...)` *and* an explicit cast.** This is a genuine landmine and
  it needs a CI lint, not a code-review convention — see [the aggregate matrix](#the-aggregate-typing-landmine).
- **`sqlc.embed` on a LEFT JOIN is unsafe** (generates non-nullable fields, fails at runtime).
  INNER JOINs only.
- **`overrides` fail silently** when the type name doesn't match. Every one must be verified in the
  generated output.
- Dynamic queries use `sqlc.narg` + `IS NULL OR` rather than a builder. Acceptable — a reporting
  query that's slightly awkward to assemble is not a correctness risk.

---

# The evidence

Run against a real database, not read from docs. sqlc v1.31.1, pgx/v5, Postgres 18.6. The schema
deliberately includes 9 enums, `int[]`, `text[]`, `jsonb`, `bigint` money, four partial unique
indexes, and a deferred constraint trigger.

## What established the driver-stack fork

Verified against `go-jet/jet v2.15.0`, `qrm/db.go`:

```go
type Queryable interface {
    QueryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error)
}
```

Jet returns `*sql.Rows` and therefore **cannot** execute on a native `pgxpool.Pool`. So this was
never "which generator" — it was a driver-stack choice, with the generator following from it:

- **A** — `database/sql` + `pgx/v5/stdlib` + Jet. Raw SQL and builder share one `*sql.Tx`.
- **B** — native `pgxpool` + sqlc. Native `pgtype`, per-query structs, no builder.

## The hard queries all survive

Five queries were chosen because each is a place the abstraction can fail. Every one generated and
executed on the first attempt:

| Query | Result |
| --- | --- |
| `SELECT … FOR UPDATE` | ✅ clean, works inside `q.WithTx(tx)` |
| Two-grain `SUM(GREATEST(…)) FILTER (WHERE …)` | ✅ both grains, both `int64` |
| `ON CONFLICT DO NOTHING RETURNING` | ✅ **and** the duplicate case is distinguishable — `errors.Is(err, pgx.ErrNoRows)` |
| `ORDER BY account_seq DESC LIMIT 1` | ✅ |
| Dynamic filters via `sqlc.narg` + `IS NULL OR` | ✅ 5 optional predicates + pagination |
| `bigint` → `int64` | ✅ never a float, anywhere |

The full auth flow ran end to end: lock the credit line, read held, insert the hold, replay the
duplicate, observe held go 0 → 50000 with no counter anywhere.

## The aggregate typing landmine

**The most important finding in the spike, and it is money-relevant.**

`sqlc.yaml` accepts an optional `database.uri` + `analyzer.database: true`, which types queries by
asking Postgres instead of guessing statically. Same four queries, both engines:

| SQL | static engine | db-backed analyzer |
| --- | --- | --- |
| `SUM(x)` | `int64` ❌ | `pgtype.Numeric` ✅ |
| `SUM(x)::bigint` | `int64` ⚠️ | `int64` ⚠️ |
| `COALESCE(SUM(x), 0)` | `interface{}` ❌ | `pgtype.Numeric` ✅ |
| `COALESCE(SUM(x), 0)::bigint` | `int64` ✅ | `int64` ✅ |

**The static engine is wrong about the *type*, not just the nullability.** `SUM(bigint)` returns
`numeric` in Postgres, not `bigint`. Confirmed at runtime, not theorised:

```
SUM, no rows  err = can't scan into dest[0] (col: total): cannot scan NULL into *int64
```

Two independent rules:

1. **Turn the analyzer on.** It converts the two dangerous forms from "compiles, then fails at
   runtime on an empty account" into a NULL-safe type you notice at compile time.
2. **`COALESCE(SUM(…), 0)::bigint` is still the only form correct under both engines.** Row 2 is
   the residual landmine — non-nullable `int64` under *both* engines while returning NULL over zero
   rows. **Neither engine catches it.** That needs the CI lint.

Exactly the failure mode a ledger cannot tolerate: a brand-new account with no entries is the
*first* thing every integration test touches.

Honesty cost: enabling the analyzer means codegen wants a live database — the same criticism
levelled at go-jet. The difference is real but narrower than it looks: sqlc degrades gracefully to
static analysis when the database is absent; go-jet's generator cannot run at all. Soft dependency
vs hard one.

## Struct sprawl is smaller than assumed

sqlc **already returns the bare table struct** whenever a query selects all columns of one table in
declaration order — verified in our own output:

```go
func (q *Queries) GetSpendControls(ctx, cardID string) (SpendControl, error)   // SELECT *
func (q *Queries) UpsertSpendControls(ctx, arg …) (SpendControl, error)        // RETURNING *
```

Zero `Row` structs emitted for either. The condition is same column count, same order, same names,
same types, one table — so **always write `SELECT *` or `SELECT alias.*`, never hand-list a full
column set**, since re-ordering silently forces a `Row` struct (upstream #3328).

`sqlc.embed(table)` handles joins by emitting the **canonical** table struct inside a one-line
wrapper — `LedgerEntry` there is the same `LedgerEntry` every other query uses:

```go
type ListEntriesWithAccountRow struct {
    LedgerEntry   LedgerEntry
    LedgerAccount LedgerAccount
}
```

`omit_unused_structs: true` prunes the rest. What survives is genuine projections — the `…Row`
structs sqlc emits for multi-column queries — which are *report shapes*, not entities. (This line
named `GetBalanceRow`; there is no such symbol in `gen/` — `GetBalance` returns a bare `int64`,
because it selects one column.) go-jet gives you an ad-hoc destination
struct for those too.

⚠️ **`sqlc.embed` on a LEFT JOIN generates non-nullable fields and fails at runtime** (upstream
#3240, #2997, #2348, all open). INNER JOINs only; for LEFT JOINs list columns explicitly and let
sqlc's nullability analysis work. Also unsupported: embedding a CTE (hard error), and `array_agg`
into a slice of embedded structs.

## Generated structs can BE the domain entities

`overrides` reshapes the generated models so there is nothing left to map:

```yaml
overrides:
  - {db_type: "uuid",            go_type: "github.com/google/uuid.UUID"}
  - {db_type: "timestamptz",     go_type: "time.Time"}
  - {db_type: "timestamptz",     nullable: true, go_type: {type: "time.Time", pointer: true}}
  - {db_type: "pg_catalog.int8", nullable: true, go_type: {type: "int64",  pointer: true}}
  - {db_type: "text",            nullable: true, go_type: {type: "string", pointer: true}}
  - {db_type: "jsonb",           go_type: {import: "encoding/json", type: "RawMessage"}}
```

Before → after, same table:

```go
ID         pgtype.UUID          →   ID         uuid.UUID
TenantID   pgtype.Text          →   TenantID   *string
Metadata   []byte               →   Metadata   json.RawMessage
CreatedAt  pgtype.Timestamptz   →   CreatedAt  time.Time
```

**Zero `pgtype` leakage into the domain.** You don't map sqlc's types into domain types — you
generate the domain shape directly. Postgres enums become typed Go constants with `Scan`/`Value`
implemented.

### The sharp edge: `db_type` spelling is unpredictable and a miss is silent

Measured on our own schema, where the DDL says `bigint`:

| `db_type:` | applied? |
| --- | --- |
| `int8` | no |
| `bigint` | no |
| `pg_catalog.bigint` | no |
| `pg_catalog.int8` | **yes** |

Whereas `uuid`, `timestamptz`, `jsonb` and `text` all take the bare name. **There is no rule to
memorise — verify every override actually landed by reading the generated struct.** A typo does not
error; it silently leaves you with `pgtype.X`.

**Overrides also apply asymmetrically.** Same column, same run:

```go
type SpendControl struct              { CapMinor *int64      }  // model:  overridden
type UpsertSpendControlsParams struct { CapMinor pgtype.Int8 }  // params: NOT overridden
```

So "zero pgtype leakage" holds for entities, not for parameter structs.

Other verified items: `initialisms: ["id", "mcc", "api", "url"]` fixes `AllowedMcc` → `AllowedMCC`
and `Id` → `ID` globally (this line quoted only `["mcc"]`; `sqlc.yaml` carries four);
`emit_db_tags: true` makes models readable by `pgx.RowToStructByNameLax`, so hand-written dynamic
queries return the *same* generated structs (flat models only — it does not recurse into
`sqlc.embed`'s named fields); Postgres `DOMAIN` types fall through to `interface{}` and need an
explicit override.

## Still open

- jsonb as `json.RawMessage` still needs an unmarshal at the call site. Acceptable — `metadata` and
  `external_ref` are not hot-path.
- The deferred balance trigger is invisible to sqlc (it fires at `COMMIT`). Posting code must handle
  a constraint violation surfacing from `tx.Commit()`, not from the `INSERT`. Worth an explicit test
  in M1.
- **`CopyFrom` — which **spike 003** found load-bearing, on its coalesced-batching path; there is
  no `CopyFrom` anywhere in this spike — is unsupported on tables with row-level security.** See [spike 004](/spikes/004-chart-of-accounts#rls); it forces a decision about
  where RLS applies.
