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
| [010](/spikes/010-append-only-perimeter) | Where does append-only actually stop? | **The fix the decision log prescribed does not exist** — `ENABLE ALWAYS TRIGGER <fk>` is not a statement PostgreSQL accepts, the spelling that works needs a real superuser, and `ENABLE TRIGGER ALL` after a data-only restore silently downgrades every guard. What holds instead: three event triggers, a composite-FK owner freeze, and a role split the deployment does not have yet | [0009](/decisions/0009-append-only-perimeter) |
| [011](/spikes/011-reconciliation) | Which pairs of numbers should agree, and what compares them? | **Seven views**, six drifts reproduced and caught, one negative control. The obvious check is wrong — a raw journal-minus-report gap is nonzero on every healthy book with a hold. Formance ships **zero** drift or repair mechanism; TigerBeetle's is test-only | [0010](/decisions/0010-reconciliation) |
| [012](/spikes/012-period-close) | What does an "as of" have to name to be reproducible? | **0006's own watermark is refuted** — it admits a row below a value already issued, while a bare `xid8` pinned at `pg_snapshot_xmin` stays stable across the interleaving that breaks it. The close, the checkpoint and the cursor are one design: 45–49× at a close boundary, and an issued statement byte-identical across a backdated posting | [0011](/decisions/0011-period-close-and-report-axes) |
| [013](/spikes/013-chart-governance) | Who owns the chart of accounts, and what happens when it changes? | **A reclassification is a new chart version, never an edit** — IAS 1.41 requires the same period presented two ways at once, which effective-dating cannot do. And the balance sheet nets counterparties because an account's line was fixed by its type; the fix is a second declared line, plus a constraint the report cannot supply | [0012](/decisions/0012-chart-governance) |
| [014](/spikes/014-write-path-contract) | What does the write path actually require of its deployment? | **READ COMMITTED, measured rather than assumed** — an in-transaction retry rescued 0 of 25,074 serialization failures. The one-statement replay CTE returns zero rows under its own race; `COPY` is not load-bearing (`unnest` within 2%); and the stripe belongs one table below the account, where `uq_accounts__house` never blocked it | [0013](/decisions/0013-write-path-contract) |
| [015](/spikes/015-managed-postgres-event-triggers) | Can [0009](/decisions/0009-append-only-perimeter)'s event triggers be applied on managed PostgreSQL? | **RDS and Aurora PG 18 clear the bar via the master account** — AWS documents the `NOSUPERUSER` master as able to create and modify event triggers, and the eighteen `ENABLE ALWAYS` clauses only ever needed table ownership. **Cloud SQL and Azure do not** permit customer event triggers; there the fallback is the snapshot test alone. The residual is the role split | [0009](/decisions/0009-append-only-perimeter) |
| [016](/spikes/016-close-cost-at-scale) | What does a period close cost at a million accounts, and does the checkpoint pay for itself? | **Linear in accounts, per currency (~49 s / 135 MB for 1 M), and the WRITE dominates (~96%)** — not the aggregation (~4%), inverting [0011](/decisions/0011-period-close-and-report-axes)'s framing. And the shipped statement functions **never read the checkpoint** (proven from `pg_get_functiondef`), so the 45–49× as-of benefit is real but unrealized; `recon_checkpoint_breaks` is O(entries × closes) | [0011](/decisions/0011-period-close-and-report-axes) |

**Four more spikes are filed under [the card rail](/card)**, numbered from 1 there:
[001](/card/spikes/001-append-only-holds) on append-only holds,
[002](/card/spikes/002-processor-hold-semantics) on what card processors actually do,
[003](/card/spikes/003-durable-timers) on Postgres as a durable timer, and
[004](/card/spikes/004-hold-corrections) on closing the hold-flow findings. They are the evidence
behind the card rail's [authorization-holds decision](/card/decisions/0001-authorization-holds) and
its [hold-corrections follow-up](/card/decisions/0002-hold-corrections), and they sit beside them.

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
against is now four tables short of the one it was measured against. And every spike since has added
its own harness, so `spikes/` now holds **76** `.sql` files, not the eleven that were measured (the
period-close, chart-governance, write-path, hold-correction and adversary-fix spikes carry a dozen
each). **Nobody has re-run them against the merged baseline, so the current count of failures is
unknown.** Nothing in `spikes/` is executed by CI, so "measured" in this directory
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
