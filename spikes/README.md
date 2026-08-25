# Spikes

A spike is **timeboxed investigation to kill a specific uncertainty**, not exploratory coding.
Every brief states the question, the timebox, and what evidence would settle it — before any
code is written.

**One directory per spike**, holding the brief, the findings, and any throwaway code together.
The `README.md` is the brief; findings get appended to it as the spike runs. Code is evidence
for those findings — once a finding is written into an [ADR](../docs/decisions/), the code can
be deleted without loss.

Code here is throwaway: not built by CI, not imported by `/internal` or `/cmd`, not held to the
project's quality bar. Each spike with code is its own Go module so its dependencies never leak
into the root `go.mod`.

A spike ends one of three ways: it answers its question (write the finding into an ADR), it
proves the question was wrong (say so), or it hits the timebox (record what's known and decide
with partial information — do not extend silently).

| # | Question | Outcome | Status |
| --- | --- | --- | --- |
| [001](./001-formance/) | What can we take from Formance's open-source ledger? | [ADR-0003](../docs/decisions/0003-bitemporal-balances.md), [0004](../docs/decisions/0004-event-log.md), [0005](../docs/decisions/0005-reproducible-as-of.md), [0006](../docs/decisions/0006-schema-conventions.md) | **closed** |
| [002](./002-sqlc-vs-jet/) | sqlc or go-jet? | [ADR-0002](../docs/decisions/0002-data-access-layer.md) — sqlc | **closed** |
| [003](./003-throughput-ceiling/) | Where does the Postgres design top out, and what moves it? | [ADR-0007](../docs/decisions/0007-open-source-positioning.md) | **closed** |

## Artifacts worth knowing about

Spike 002 left behind files the project will actually use, because they were built against a
real database rather than sketched:

| File | What it is |
| --- | --- |
| [`002-sqlc-vs-jet/schema.sql`](./002-sqlc-vs-jet/schema.sql) | The ledger schema. Graduates to `migrations/0001` at M1. |
| [`002-sqlc-vs-jet/invariants.sql`](./002-sqlc-vs-jet/invariants.sql) | Nine invariants, each asserting Postgres *refuses* an illegal write. |
| [`002-sqlc-vs-jet/expected_schema.sql`](./002-sqlc-vs-jet/expected_schema.sql) | The schema snapshot guard from [ADR-0006](../docs/decisions/0006-schema-conventions.md). |
| [`002-sqlc-vs-jet/sqlc.yaml`](./002-sqlc-vs-jet/sqlc.yaml) | The verified codegen config. |
