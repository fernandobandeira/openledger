# Spike 002 — sqlc or go-jet

**Question:** Does `database/sql` (which go-jet requires) make arrays, jsonb, and the auth
transaction painful enough to outweigh Jet's builder and its one-struct-per-table model?

**Timebox:** one session. Build both against the same real schema, then delete the loser.
**Blocks:** [ADR-0002](../../docs/decisions/0002-data-access-layer.md).
**Does not block:** milestone 1 (schema + constraints) — that is pure SQL. Start there.

## Already established

Verified against `go-jet/jet v2.15.0`, `qrm/db.go`:

```go
type Queryable interface {
    QueryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error)
}
```

Jet returns `*sql.Rows` and therefore **cannot** execute on a native `pgxpool.Pool`. So the
choice is a driver-stack choice, and the generator follows from it:

- **A** — `database/sql` + `pgx/v5/stdlib` + Jet. Raw SQL and builder share one `*sql.Tx`.
- **B** — native `pgxpool` + sqlc (`sql_package: pgx/v5`). Native `pgtype`, per-query structs,
  no builder.

ADR-0002 proposes **A**. This spike tries to break it.

## Method

Apply `migrations/0001_ledger_core.sql` to a scratch database, point both generators at it,
and implement the *same five things* twice. Not toy queries — these five, because each one is
a place the abstraction can fail:

1. **The auth transaction** (v1-vision §03) — `SELECT ... FOR UPDATE`, then the two-grain
   aggregate `SUM(GREATEST(amount_minor - cleared_minor, 0)) FILTER (WHERE card_id = ?)`, then
   `INSERT ... ON CONFLICT (auth_id) DO NOTHING RETURNING decision`.
2. **The balance read** — `ORDER BY account_seq DESC LIMIT 1`, and the as-of variant with the
   extra `recorded_at <= ?` predicate.
3. **Posting a transaction** — insert N balanced entries with computed `account_seq` and
   `balance_after`, in one round trip if the stack allows it.
4. **`spend_controls` round trip** — `allowed_mcc[]`, `blocked_mcc[]`, `allowed_merchants[]`
   read and written. **This is the crux.**
5. **A dynamic reporting query** — entries filtered by any subset of {account, date range,
   direction, transaction kind}, paginated. The case that argues for a builder.

## Scorecard

Fill this in with evidence, not impressions.

| Criterion | Weight | A · Jet | B · sqlc |
| --- | --- | --- | --- |
| Arrays (`text[]`, `int[]`) round-trip cleanly | **high** | | |
| jsonb (`external_ref`, `metadata`) round-trip cleanly | **high** | | |
| `FILTER` aggregate expressible without dropping to raw | high | | |
| `ON CONFLICT DO NOTHING RETURNING` — can you tell "no row" from an error? | high | | |
| `COALESCE(SUM(...), 0)` generates a **non-nullable** Go type | high | | |
| `FOR UPDATE` in a multi-statement tx, ergonomically | high | | |
| Enums (`direction`, `category`, `normal_balance`) → typed constants | medium | | |
| `bigint` → `int64`, never a float, anywhere | **veto** | | |
| Entity structs a human (and an LLM) can hold in their head | medium | | |
| Dynamic filter composition | medium | | |
| Codegen needs a live DB? (ordering vs migrations) | low | | |
| Generated LOC for the same five features | low | | |

## Decision rule — written before the evidence, on purpose

- Any **veto** row failing → that option is out, full stop.
- If arrays **and** jsonb are ugly under `database/sql` → **B**, and we accept per-query
  structs and hand-rolled dynamic SQL as the cost of native `pgtype`.
- If arrays and jsonb are merely *slightly* worse (a `sql.Scanner` wrapper each, written once)
  → **A**, as ADR-0002 proposes.
- If it's genuinely a coin flip → **A**, on the tiebreak that the builder's value grows with
  the reporting surface and the reporting surface only ever grows.

Record the outcome in ADR-0002. Move the status to `accepted`, keep the losing analysis.

## Anti-goal

Do not let this become "let's write our own thin wrapper." That is a third option nobody
scoped, it always looks cheapest on day one, and it is how projects acquire a private ORM with
no documentation. If the spike ends pointing there, write a **new ADR** arguing for it
explicitly, with the maintenance cost stated.

## Findings — hands-on (sqlc v1.31.1, pgx/v5, Postgres 18.6)

Run against a real database, not read from docs. Code: [`/spikes/002-sqlc-vs-jet`](../../spikes/002-sqlc-vs-jet).
The schema deliberately includes 9 enums, `int[]`, `text[]`, `jsonb`, `bigint` money, two
partial unique indexes, and a deferred constraint trigger.

### The array/jsonb objection — resolved, in sqlc's favour

ADR-0002 named this as the thing that would flip the decision. It flipped it.

`sql_package: "pgx/v5"` emits **native Go types** for arrays — not `pgtype.FlatArray`, not
`[]byte`:

```go
AllowedMcc       []int32   // int[]
BlockedMcc       []int32   // int[]
AllowedMerchants []string  // text[]
```

Verified round-tripping through a live `UpsertSpendControls ... RETURNING *`. There is no
wrapper type and no manual unmarshalling. The concern that motivated ADR-0002's proposal of
go-jet does not exist under sqlc's pgx mode.

### The entity-sprawl objection — mitigated by `sqlc.embed()`

`sqlc.embed(table)` emits the **canonical table struct**, shared across every query, inside a
one-line wrapper:

```sql
SELECT sqlc.embed(ledger_entries), sqlc.embed(ledger_accounts)
FROM ledger_entries JOIN ledger_accounts ON ...
```
```go
type ListEntriesWithAccountRow struct {
    LedgerEntry   LedgerEntry   `json:"ledger_entry"`
    LedgerAccount LedgerAccount `json:"ledger_account"`
}
```

`LedgerEntry` here is the same `LedgerEntry` every other query uses. Embeds compose with joins
and mix freely with bare scalar columns. The remaining sprawl is a named wrapper per query —
which is a different, much smaller complaint than "a new copy of the entity per query."

### Generated structs can BE the domain entities

`overrides` reshapes the generated models so there is nothing left to map:

```yaml
overrides:
  - {db_type: "uuid",           go_type: "github.com/google/uuid.UUID"}
  - {db_type: "timestamptz",    go_type: "time.Time"}
  - {db_type: "timestamptz",    nullable: true, go_type: {type: "time.Time", pointer: true}}
  - {db_type: "pg_catalog.int8", nullable: true, go_type: {type: "int64",  pointer: true}}
  - {db_type: "text",           nullable: true, go_type: {type: "string",  pointer: true}}
  - {db_type: "jsonb",          go_type: {import: "encoding/json", type: "RawMessage"}}
```

Before → after, same table:

```go
ID         pgtype.UUID          →   ID         uuid.UUID
TenantID   pgtype.Text          →   TenantID   *string
Metadata   []byte               →   Metadata   json.RawMessage
CreatedAt  pgtype.Timestamptz   →   CreatedAt  time.Time
```

**Zero `pgtype` leakage into the domain.** This is the answer to "how do we simplify the
transition from sqlc into our domain entity": you don't transition, you generate the domain
shape directly. Gotcha: `go_type` as a bare string only accepts basic types and
`pkg.Type` — `map[string]any` is rejected, use the `{import:, type:}` form.

Postgres enums become typed Go constants plus a `NullX` wrapper, with `Scan`/`Value` implemented:

```go
type HoldState string
const (
    HoldStateOpen    HoldState = "open"
    HoldStateCleared HoldState = "cleared"
    ...
)
```

### The hard queries all survive intact

Every one generated and executed on the first attempt:

| Query | Result |
| --- | --- |
| `SELECT ... FOR UPDATE` | ✅ clean, works inside `q.WithTx(tx)` |
| Two-grain `SUM(GREATEST(...)) FILTER (WHERE ...)` | ✅ both grains, both `int64` |
| `ON CONFLICT DO NOTHING RETURNING` | ✅ **and** the duplicate case is distinguishable — `errors.Is(err, pgx.ErrNoRows) == true` |
| `ORDER BY account_seq DESC LIMIT 1` | ✅ |
| Dynamic filters via `sqlc.narg` + `IS NULL OR` | ✅ generated; 5 optional predicates + pagination |
| `bigint` → `int64` | ✅ never a float, anywhere |

The auth flow ran end to end: lock the credit line, read held, insert the hold, replay the
duplicate, observe `company_held` go 0 → 50000 with no counter anywhere. The insert *is* the
reduction, as designed.

### ⚠️ The landmine — nullability inference on aggregates

**This is the most important finding in the spike, and it is money-relevant.**

sqlc infers `SUM()` as non-nullable. SQL says `SUM()` over **zero rows is NULL**. Confirmed at
runtime, not theorised:

```
6. SUM, no rows  err = can't scan into dest[0] (col: total): cannot scan NULL into *int64
```

An explicit `::bigint` cast does **not** save you — it fixes type inference, not nullability.
The full matrix:

| SQL | Generated Go | Safe? |
| --- | --- | --- |
| `SUM(x)` | `int64` | ❌ runtime error on zero rows |
| `SUM(x)::bigint` | `int64` | ❌ runtime error on zero rows |
| `COALESCE(SUM(x), 0)` | `interface{}` | ⚠️ compiles, silently untyped |
| `COALESCE(SUM(x), 0)::bigint` | `int64` | ✅ correct |

**Rule: every aggregate gets `COALESCE(...)` AND an explicit cast. Both. Always.** Neither
alone is sufficient — one gives you a runtime panic on an empty account, the other gives you
`interface{}` money. This deserves a CI check over `queries.sql`, not a code-review convention.

Note this is exactly the failure mode a ledger cannot tolerate: a brand-new account with no
entries is the *first* thing every integration test does.

### Still open

- jsonb as `json.RawMessage` still needs an unmarshal at the call site. Acceptable — `metadata`
  and `external_ref` are not hot-path.
- The deferred balance trigger is invisible to sqlc (it fires at COMMIT). Posting code must
  handle a constraint violation surfacing from `tx.Commit()`, not from the INSERT. Worth an
  explicit test in M1.

---

## Findings — the aggregate typing matrix (the important one)

Superseding the simpler matrix above. `sqlc.yaml` accepts an optional
`database.uri` + `analyzer.database: true`, which types queries by asking Postgres
instead of guessing statically. Same four queries, both engines:

| SQL | static engine | **db-backed analyzer** |
| --- | --- | --- |
| `SUM(x)` | `int64` ❌ | `pgtype.Numeric` ✅ |
| `SUM(x)::bigint` | `int64` ⚠️ | `int64` ⚠️ |
| `COALESCE(SUM(x), 0)` | `interface{}` ❌ | `pgtype.Numeric` ✅ |
| `COALESCE(SUM(x), 0)::bigint` | `int64` ✅ | `int64` ✅ |

**The static engine was wrong about the type, not just the nullability.**
`SUM(bigint)` returns **`numeric`** in Postgres, not `bigint`. The static engine says
`int64`; the analyzer correctly says `pgtype.Numeric`, which is also NULL-safe.

Two rules follow, and they are independent:

1. **Turn the analyzer on.** It converts the two dangerous forms from "compiles, then
   fails at runtime on an empty account" into a NULL-safe type you notice at compile
   time. This is a safety net, not a style preference.
2. **`COALESCE(SUM(...), 0)::bigint` is still the only form correct under both engines.**
   Row 2 is the residual landmine — `SUM(x)::bigint` types as a non-nullable `int64`
   under *both* engines and returns NULL over zero rows. **Neither engine catches it.**
   That is what needs the CI lint over `queries.sql`.

Note the honesty cost: enabling the analyzer means codegen wants a live database, which
was a criticism levelled at go-jet. The difference is real but narrower than it looks —
sqlc degrades gracefully to static analysis when the database is absent, whereas go-jet's
generator cannot run at all. Soft dependency vs hard one.

## Findings — struct sprawl is smaller than assumed

`sqlc.embed()` is not even the main mechanism. sqlc **already returns the bare table
struct** whenever a query selects all columns of one table in declaration order —
verified in our own output:

```go
func (q *Queries) GetSpendControls(ctx, cardID string) (SpendControl, error)      // SELECT *
func (q *Queries) UpsertSpendControls(ctx, arg ...) (SpendControl, error)         // RETURNING *
```

Zero `Row` structs emitted for either. The condition is same column count, same order,
same names, same types, one table — so **always write `SELECT *` or `SELECT alias.*`,
never hand-list a full column set**, since re-ordering silently forces a `Row` struct
(upstream #3328).

`omit_unused_structs: true` prunes the rest per-package. What survives is genuine
projections — `GetHeldRow`, `GetBalanceRow` — which are *report shapes*, not entities.
go-jet gives you an ad-hoc destination struct for those too.

⚠️ **`sqlc.embed` on a LEFT JOIN generates non-nullable fields and fails at runtime**
(upstream #3240, #2997, #2348, all open). Use it on INNER JOINs only; for LEFT JOINs list
columns explicitly and let sqlc's nullability analysis work. Also unsupported: embedding
a CTE (hard error), and `array_agg` into a slice of embedded structs.

## Findings — overrides, and their sharp edge

The override block turns generated models into domain types with nothing left to map
(`uuid.UUID`, `time.Time`, `*string`, `json.RawMessage`, `[]int32`, `[]string`, `int64`).

**But the `db_type` spelling is not predictable and a miss is silent.** Measured on our
own schema, where the DDL says `bigint`:

| `db_type:` | applied? |
| --- | --- |
| `int8` | no |
| `bigint` | no |
| `pg_catalog.bigint` | no |
| `pg_catalog.int8` | **yes** |

Whereas `uuid`, `timestamptz`, `jsonb`, and `text` all take the bare name. There is no
rule to memorise here — **verify every override actually landed by reading the generated
struct.** A typo does not error; it silently leaves you with `pgtype.X`.

**Overrides also apply asymmetrically.** Same column, same run:

```go
type SpendControl struct            { CapMinor *int64      }  // model:  overridden
type UpsertSpendControlsParams struct { CapMinor pgtype.Int8 }  // params: NOT overridden
```

Not fatal, but it means "zero pgtype leakage" holds for entities and not for parameter
structs.

Other verified items: `initialisms: ["mcc"]` fixes `AllowedMcc` → `AllowedMCC` globally;
`emit_db_tags: true` makes the models readable by `pgx.RowToStructByNameLax`, so
hand-written dynamic queries return the *same* generated structs (flat models only — it
does not recurse into `sqlc.embed`'s named fields); Postgres `DOMAIN` types fall through
to `interface{}` and need an explicit override.

## Verdict

**Option B — native `pgxpool` + sqlc.** ADR-0002 moves to `accepted`, reversing its own
proposal. The recommended configuration is
[`spikes/002-sqlc-vs-jet/sqlc.yaml`](./sqlc.yaml), verified
end to end against a live database.

The decision rule written before the evidence said "if arrays and jsonb are ugly under
`database/sql` → B." The evidence went differently: **arrays are fine under both tools**,
so that rule never fired. B wins on two grounds neither option's brief anticipated —
go-jet's silent-zero scan trap on mis-aliased columns, and its generator's hard
requirement of a live database with no offline path.

