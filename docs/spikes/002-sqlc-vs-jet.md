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

## Findings

*(empty — spike not yet run)*
