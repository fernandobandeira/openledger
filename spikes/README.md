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
| [006](./006-append-only-holds/) | Should holds be a mutable row or an append-only event log? | Append-only, and `SUM` being commutative makes it order-tolerant for free. The spike's "one formula covers every edge case" did **not** survive contact: the shipped design in `schema/schema.sql` has no `group_key` column on the event at all (grouping is its own bitemporal table) and needs a materialised total, a delta/total convention, and expiry snapshots besides. | **closed** — superseded by [ADR-0008](../docs/decisions/0008-authorization-holds.md) |
| [005](./005-durable-timers/) | Can Postgres replace Temporal for durable timers? | Yes — verified with River; the need is durable *scheduling*, not workflow orchestration, and idempotency already comes from the event log. | **closed** |
| [004](./004-chart-of-accounts/) | What does a general ledger ship when the chart of accounts is business-specific? | Ship the chart as **data** plus constraints that make the accounting identity a theorem. But the identity does **not** prove completeness — that needs its own guard. | **closed** |

**Nine spikes, and this index listed six of them.** 007, 008 and 009 were missing — including the
two that reversed [ADR-0004](../docs/decisions/0004-where-logic-lives.md) and produced
[ADR-0003](../docs/decisions/0003-migrations.md).

| | question | outcome | fed |
| --- | --- | --- | --- |
| [007](./007-schema-migrations/) | How do schema changes get applied? | goose, from Go, as a pre-deploy job. A *blocking* advisory lock deadlocks against `CREATE INDEX CONCURRENTLY`; goose polls a try-lock | [0003](../docs/decisions/0003-migrations.md) |
| [008](./008-processor-hold-semantics/) | What do card processors actually do? | No convention for delta-vs-total; grouping is a revisable inference; our "authorization writes no ledger entry" is a minority choice, not a domain law | [0008](../docs/decisions/0008-authorization-holds.md) |
| [009](./009-how-other-ledgers-enforce/) | Do real ledgers use triggers, and where does the balance invariant live? | Triggers are widely used for immutability and hash chaining; **nobody** enforces debits-equal-credits in the database | [0004](../docs/decisions/0004-where-logic-lives.md), [0005](../docs/decisions/0005-event-log-and-write-path.md) |

Outcomes fed the decision log from [ADR-0001](../docs/decisions/0001-rust-and-postgres.md) through
[ADR-0003](../docs/decisions/0003-migrations.md).

## Artifacts worth knowing about

Spike 002 and 004 left behind files worth reading, because they were built against a real database
rather than sketched. **None of them ships, and nearly none of them runs.** Nine of the eleven `.sql` files in `spikes/`
fail against the shipped schema -- on an object that already exists, a column that no longer exists, or a `NOT NULL`
that did not exist when it was written. **There are exactly two exceptions**, and they are the two files that contain no DDL:
`002-sqlc-vs-jet/expected_schema.sql` and `003-throughput-ceiling/bench_schema.sql` both run clean.
An earlier version of this paragraph named two exceptions, a later one claimed there were none and
invoked "a banner is a claim about scope" to justify itself — **the over-correction was the error.**
Verified by loading the shipped schema and running all eleven. Nothing in `spikes/`
is executed by CI, so "measured" in this directory means "was measured once, against something".
**The live attestation is the deleted test suites.**

| File | What it is |
| --- | --- |
| [`002-sqlc-vs-jet/schema.sql`](./002-sqlc-vs-jet/schema.sql) | The ledger schema. **Did not graduate.** `schema/schema.sql` was written by hand; this schema puts `idempotency_key` on `ledger_transactions`, where ADR-0005 moved it off. |
| [`002-sqlc-vs-jet/invariants.sql`](./002-sqlc-vs-jet/invariants.sql) | Nine invariants: **seven** assert Postgres *refuses* an illegal write, and two are positive controls that must SUCCEED (a balanced transaction; the same idempotency key in a different tenant). The file's own header says so; this line said all nine. |
| [`002-sqlc-vs-jet/expected_schema.sql`](./002-sqlc-vs-jet/expected_schema.sql) | One `SELECT` that emits a schema summary. ADR-0007 wants a snapshot *guard* built on it -- a committed expected output plus a diff. Neither exists, so this is the query, not the guard. |
| [`002-sqlc-vs-jet/sqlc.yaml`](./002-sqlc-vs-jet/sqlc.yaml) | The verified codegen config. |
| [`004-chart-of-accounts/chart.sql`](./004-chart-of-accounts/chart.sql) | Account types as data, with the constraints that keep them honest. |
| [`004-chart-of-accounts/completeness.sql`](./004-chart-of-accounts/completeness.sql) | The guard against a report silently omitting an account. |
| [`004-chart-of-accounts/golden_trace.sql`](./004-chart-of-accounts/golden_trace.sql) | **Superseded** by the deleted `tests/golden_trace.sql`. Still runs against spike 002's schema; against the shipped one it fails on the very first statement, with `null value in column "tenant_id" of relation "ledger_accounts"` — it never reaches a unique index. It also writes `idempotency_key` to a table that no longer has it. |
