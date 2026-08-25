# Spikes

A spike is **timeboxed investigation to kill a specific uncertainty**, not exploratory coding. One
directory per spike, holding the question, the findings, and any throwaway code together. Each
README leads with its answer — you should be able to get the value without reading the evidence.

Code here is throwaway: not built by CI, not imported by `/internal` or `/cmd`. Each spike with
code is its own Go module so its dependencies never leak into the root `go.mod`.

| # | Question | What we learned | Status |
| --- | --- | --- | --- |
| [001](./001-formance/) | What can we take from Formance's production ledger? | Their running-balance problem was the **mutable business-date** one, not running balances in general. Ours is the immutable kind, so it stands. | **closed** |
| [002](./002-sqlc-vs-jet/) | sqlc or go-jet? | **sqlc**, reversing the ADR's own proposal. Arrays were fine under both, so the pre-registered rule never fired; go-jet's silent-zero scan trap decided it. | **closed** |
| [003](./003-throughput-ceiling/) | Where does the Postgres design top out, and what moves it? | **~800/s → 8,200/s** by removing contention on one shared row. Striping is the mechanism; dropping the running balance is not worth it. | **closed** |
| [005](./005-durable-timers/) | Can Postgres replace Temporal for durable timers? | Yes — verified with River; the need is durable *scheduling*, not workflow orchestration, and idempotency already comes from the event log. | **closed** |
| [004](./004-chart-of-accounts/) | What does a general ledger ship when the chart of accounts is business-specific? | Ship the chart as **data** plus constraints that make the accounting identity a theorem. But the identity does **not** prove completeness — that needs its own guard. | **closed** |

Outcomes fed [ADR-0002](../docs/decisions/0002-data-access-layer.md) through
[ADR-0007](../docs/decisions/0007-open-source-positioning.md).

## Artifacts worth knowing about

Spike 002 and 004 left behind files the project will actually use, because they were built against
a real database rather than sketched:

| File | What it is |
| --- | --- |
| [`002-sqlc-vs-jet/schema.sql`](./002-sqlc-vs-jet/schema.sql) | The ledger schema. Graduates to `migrations/0001` at M1. |
| [`002-sqlc-vs-jet/invariants.sql`](./002-sqlc-vs-jet/invariants.sql) | Nine invariants, each asserting Postgres *refuses* an illegal write. |
| [`002-sqlc-vs-jet/expected_schema.sql`](./002-sqlc-vs-jet/expected_schema.sql) | The schema snapshot guard from [ADR-0006](../docs/decisions/0006-schema-conventions.md). |
| [`002-sqlc-vs-jet/sqlc.yaml`](./002-sqlc-vs-jet/sqlc.yaml) | The verified codegen config. |
| [`004-chart-of-accounts/chart.sql`](./004-chart-of-accounts/chart.sql) | Account types as data, with the constraints that keep them honest. |
| [`004-chart-of-accounts/completeness.sql`](./004-chart-of-accounts/completeness.sql) | The guard against a report silently omitting an account. |
| [`004-chart-of-accounts/golden_trace.sql`](./004-chart-of-accounts/golden_trace.sql) | M0's acceptance test — the the reference product spec lifecycle, reproduced to the cent. |
