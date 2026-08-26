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
| [006](./006-append-only-holds/) | Should holds be a mutable row or an append-only event log? | Append-only, and `SUM` being commutative makes it order-tolerant for free. The spike's "one formula covers every edge case" did **not** survive contact: the shipped design in `migrations/0003` has no `group_key` column on the event at all (grouping is its own bitemporal table) and needs a materialised total, a delta/total convention, and expiry snapshots besides. | **closed** — superseded by [ADR-0010](../docs/decisions/0010-authorization-holds.md) |
| [005](./005-durable-timers/) | Can Postgres replace Temporal for durable timers? | Yes — verified with River; the need is durable *scheduling*, not workflow orchestration, and idempotency already comes from the event log. | **closed** |
| [004](./004-chart-of-accounts/) | What does a general ledger ship when the chart of accounts is business-specific? | Ship the chart as **data** plus constraints that make the accounting identity a theorem. But the identity does **not** prove completeness — that needs its own guard. | **closed** |

Outcomes fed the decision log from [ADR-0002](../docs/decisions/0002-data-access-layer.md) through
[ADR-0011](../docs/decisions/0011-what-the-database-enforces.md) — spike 004 fed 0009, spike 005 fed 0008, and spike 006 fed 0010.

## Artifacts worth knowing about

Spike 002 and 004 left behind files worth reading, because they were built against a real database
rather than sketched. **None of them ships, and none of them runs.** Every `.sql` file in `spikes/` fails against the
shipped schema -- on an object that already exists, a column that no longer exists, or a `NOT NULL`
that did not exist when it was written. An earlier version of this paragraph named two files as the
exceptions; there are no exceptions, and naming two was the same "a banner is a claim about scope"
error [the decision log](../docs/decisions/README.md) records against itself. Nothing in `spikes/`
is executed by CI, so "measured" in this directory means "was measured once, against something".
**The live attestation is [`tests/`](../tests/).**

| File | What it is |
| --- | --- |
| [`002-sqlc-vs-jet/schema.sql`](./002-sqlc-vs-jet/schema.sql) | The ledger schema. **Did not graduate.** `migrations/0001` was written by hand; this schema puts `idempotency_key` on `ledger_transactions`, where ADR-0004 moved it off. |
| [`002-sqlc-vs-jet/invariants.sql`](./002-sqlc-vs-jet/invariants.sql) | Nine invariants: **seven** assert Postgres *refuses* an illegal write, and two are positive controls that must SUCCEED (a balanced transaction; the same idempotency key in a different tenant). The file's own header says so; this line said all nine. |
| [`002-sqlc-vs-jet/expected_schema.sql`](./002-sqlc-vs-jet/expected_schema.sql) | One `SELECT` that emits a schema summary. ADR-0006 wants a snapshot *guard* built on it -- a committed expected output plus a diff. Neither exists, so this is the query, not the guard. |
| [`002-sqlc-vs-jet/sqlc.yaml`](./002-sqlc-vs-jet/sqlc.yaml) | The verified codegen config. |
| [`004-chart-of-accounts/chart.sql`](./004-chart-of-accounts/chart.sql) | Account types as data, with the constraints that keep them honest. |
| [`004-chart-of-accounts/completeness.sql`](./004-chart-of-accounts/completeness.sql) | The guard against a report silently omitting an account. |
| [`004-chart-of-accounts/golden_trace.sql`](./004-chart-of-accounts/golden_trace.sql) | **Superseded** by [`tests/golden_trace.sql`](../tests/golden_trace.sql). Still runs against spike 002's schema; against the shipped one it fails on the very first statement, with `null value in column "tenant_id" of relation "ledger_accounts"` — it never reaches a unique index. It also writes `idempotency_key` to a table that no longer has it. |
