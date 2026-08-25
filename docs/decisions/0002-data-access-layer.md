# 0002 — Data access layer: sqlc vs go-jet

**Status:** proposed — blocked on [spike 002](../spikes/002-sqlc-vs-jet.md)
**Date:** 2026-08-25

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

## Proposed decision

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

**[Spike 002](../spikes/002-sqlc-vs-jet.md) exists to answer exactly that**, plus whether the
auth transaction's `FILTER` aggregate and `ON CONFLICT ... DO NOTHING RETURNING` survive each
stack intact.

## Not deciding yet

Do not build on either until the spike lands. The first milestone — schema, constraints, and
the `account_seq` / `balance_after` concurrency proof — is pure SQL and migrations, and is
**not blocked by this ADR**. Start there.
