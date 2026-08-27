# Spikes

A spike is **timeboxed investigation to kill a specific uncertainty**, not exploratory coding. One
directory per spike, holding the question, the findings, and any throwaway code together. Each
README leads with its answer — you should be able to get the value without reading the evidence.

Code here is throwaway: not built by CI and not part of the workspace. Each spike with code is
self-contained, so its dependencies never leak into the root `Cargo.toml`. Spikes 001–007 predate
[ADR-0001](/decisions/0001-rust-and-postgres)'s move from Go to Rust and their code is Go;
they are kept as the record of what was asked and answered, not as a guide to how to build this.

| # | Question | What we learned | Fed |
| --- | --- | --- | --- |
| [001](/spikes/001-formance) | What can we take from Formance's production ledger? | Their running-balance problem was the **mutable business-date** one, not running balances in general — so we kept the immutable kind. **[Spike 009](/spikes/009-where-the-balance-lives) later overturned that**: the immutable axis is safe because nothing anyone asks about is ordered by it | [0005](/decisions/0005-event-log-and-write-path), [0006](/decisions/0006-time-and-as-of) |
| [002](/spikes/002-sqlc-vs-jet) | sqlc or go-jet? | **sqlc**, reversing the ADR's own proposal — go-jet's silent-zero scan trap decided it. **Moot as asked**: both are Go generators, [spike 007](/spikes/007-go-or-rust) moved the language and `sqlx` replaced both. The silent-zero finding outlived the question and is now [0001](/decisions/0001-rust-and-postgres)'s central argument | [0001](/decisions/0001-rust-and-postgres) |
| [003](/spikes/003-throughput-ceiling) | Where does the Postgres design top out, and what moves it? | **~800/s → 8,200/s** by removing contention on one shared row. Striping is the mechanism | [0002](/decisions/0002-scaling) |
| [004](/spikes/004-chart-of-accounts) | What does a general ledger ship when the chart of accounts is business-specific? | Ship the chart as **data** plus constraints that make the accounting identity a theorem. But the identity does **not** prove completeness — that needs its own guard | [0007](/decisions/0007-schema-conventions-and-chart) |
| [005](/spikes/005-schema-migrations) | How do schema changes get applied? | As a pre-deploy job, never at startup. A *blocking* advisory lock deadlocks against `CREATE INDEX CONCURRENTLY`; a polled try-lock does not. It concluded **goose**, which is Go — [spike 007](/spikes/007-go-or-rust) found no Rust migrator polls a try-lock either, so [0003](/decisions/0003-migrations) keeps the argument and writes the lock itself | [0003](/decisions/0003-migrations) |
| [006](/spikes/006-how-other-ledgers-enforce) | Do real ledgers use triggers, and where does the balance invariant live? | Triggers are widely used for immutability and hash chaining; **nobody** enforces debits-equal-credits in the database | [0004](/decisions/0004-where-logic-lives), [0005](/decisions/0005-event-log-and-write-path) |
| [007](/spikes/007-go-or-rust) | Go or Rust, now that the write primitive is a type? | **Rust.** 5 of 5 seeded bugs caught by the compiler against Go's 0 of 5 — and two of the five were guarantees an accepted ADR had already claimed in writing and did not have | [0001](/decisions/0001-rust-and-postgres), [0003](/decisions/0003-migrations) |
| [008](/spikes/008-optional-modules) | How does an optional module that owns tables get shipped? | Not one foreign key crosses the card/core boundary. Of eight systems read from source, the two that separate cleanly give each component its own **database**, and the only working uninstall belongs to the one with no migration files | [0008](/decisions/0008-module-boundaries) |
| [009](/spikes/009-where-the-balance-lives) | Where should "the balance" actually live? | **Dropped `balance_after`.** A running balance answers a point-in-time question on the *recorded* axis, and every as-of question a business asks is an *effective-date* one — which backfills. Fragment stores no such column for exactly this reason; TigerBeetle's is opt-in and costs ~9% throughput | [0006](/decisions/0006-time-and-as-of) |

**Three more spikes are filed under [the card rail](/card)**, numbered from 1 there:
[001](/card/spikes/001-append-only-holds) on append-only holds,
[002](/card/spikes/002-processor-hold-semantics) on what card processors actually do, and
[003](/card/spikes/003-durable-timers) on Postgres as a durable timer. They are the evidence behind
[the holds decision](/card/decisions/0001-authorization-holds), and they sit beside it.

Outcomes fed every ADR in the log. [ADR-0006](/decisions/0006-time-and-as-of) was originally argued
from the schema and from PostgreSQL's own behaviour rather than from a spike, and spike 009 is the
evidence it was missing.

## Artifacts worth knowing about

Spike 002 and 004 left behind files worth reading, because they were built against a real database
rather than sketched. **None of them ships, and nearly none of them runs.**

**That last claim is a historical measurement and is no longer reproducible.** At commit `9cb23ba`,
against the then-shipped `schema/schema.sql`, `spikes/` held eleven `.sql` files and **nine of them
failed** — on an object that already exists, a column that no longer exists, or a `NOT NULL` that did
not exist when it was written. The two that ran clean were the two containing no DDL:
`002-sqlc-vs-jet/expected_schema.sql` and `003-throughput-ceiling/bench_schema.sql`. (An earlier
version of this paragraph named two exceptions, a later one claimed there were none and invoked "a
banner is a claim about scope" to justify itself — **the over-correction was the error.**)

**Neither side of that measurement still exists.** `schema/schema.sql` is gone: the core became
`migrations/00001_baseline.sql` and the card half is parked in
[`parked/card/schema.sql`](/card/parked), so the schema a spike file would be loaded
against is now four tables short of the one it was measured against. And spike 008 added two more
`.sql` files, so there are **thirteen**, not eleven. **Nobody has re-run them, so the current count
of failures is unknown.** Nothing in `spikes/` is executed by CI, so "measured" in this directory
means "was measured once, against something".
**The live attestation is the deleted test suites.**

| File | What it is |
| --- | --- |
| `002-sqlc-vs-jet/schema.sql` | The ledger schema. **Did not graduate.** `migrations/00001_baseline.sql` was written by hand; this schema puts `idempotency_key` on `ledger_transactions`, where ADR-0005 moved it off. |
| `002-sqlc-vs-jet/invariants.sql` | Nine invariants: **seven** assert Postgres *refuses* an illegal write, and two are positive controls that must SUCCEED (a balanced transaction; the same idempotency key in a different tenant). The file's own header says so; this line said all nine. |
| `002-sqlc-vs-jet/expected_schema.sql` | One `SELECT` that emits a schema summary. ADR-0007 wants a snapshot *guard* built on it -- a committed expected output plus a diff. Neither exists, so this is the query, not the guard. |
| `002-sqlc-vs-jet/sqlc.yaml` | The verified codegen config. |
| `004-chart-of-accounts/chart.sql` | Account types as data, with the constraints that keep them honest. |
| `004-chart-of-accounts/completeness.sql` | The guard against a report silently omitting an account. |
| `004-chart-of-accounts/golden_trace.sql` | **Superseded** by the deleted `tests/golden_trace.sql`. Still runs against spike 002's schema; against the shipped one it fails on the very first statement, with `null value in column "tenant_id" of relation "ledger_accounts"` — it never reaches a unique index. It also writes `idempotency_key` to a table that no longer has it. |
