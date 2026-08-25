# Spike 002 — sqlc or go-jet

**Question:** Does `database/sql` (which go-jet requires) make arrays, jsonb, and the auth
transaction painful enough to outweigh Jet's builder and its one-struct-per-table model?

**Timebox:** one session. Build both against the same real schema, then delete the loser.
**Blocks:** [ADR-0002](../decisions/0002-data-access-layer.md).
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

## Findings — hands-on (sqlc v1.29.0, pgx/v5, Postgres 18.6)

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
