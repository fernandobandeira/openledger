# Decisions

Everything we've decided, on one page. Read this to know where the project stands; follow a link only
when you want the reasoning behind a particular call.

New to ledgers? Start with the [glossary](/glossary) — it defines every domain term used here, so
the ADRs don't each stop to re-explain them.

## The stack

- **Rust** — the ledger is written in Rust; Postgres holds the shape. Chosen over Go after
  [spike 007](/spikes/007-go-or-rust) built both against the real schema and seeded
  this project's own bugs into each: Rust's compiler caught **5 of 5**, Go's caught **0 of 5**, and
  two of the five were guarantees an accepted ADR had already claimed in writing and did not have.
- **Postgres**, one instance — measured at ~800 **clearings**/s untuned (a clearing is one card
  transaction = 3 ledger entries), rising to ~6,970/s with the hot account striped 64 ways and 7,897/s
  striping *and* posting in a single call, on a 2 GB table; the comparable 43 MB figure is 7,816.
  Re-measured on the shipped baseline plus the stripe column at **7.7–9.2×** over three runs
  ([0013](/decisions/0013-write-path-contract)). Spike 003's own banner applies: re-auditing the same
  configurations moved the baseline from 833 to 482, so **treat these as shape, not as a benchmark**.
  Nothing has been measured over a network.
- **sqlx**, no ORM — we write the SQL; it is checked against a live database at compile time. The hot
  queries stay reviewable *as SQL*.
- **Postgres for durable timers too** — an in-process job queue, no scheduler cluster to run.
- **Migrations are `sqlx` plus our own try-lock**, run as `openledger migrate`, a pre-deploy command.
  Exactly one Rust migrator attempts cross-process coordination and it does it the wrong way. **This
  one is built** — `crates/db/src/migrate.rs`, and `migrations/00001_baseline.sql` is what it applies. The
  baseline is **frozen — since 2026-08-27, ahead of any tag**, CI-enforced with no opt-out; the
  written exception that let it be edited until then, and why it closed early, are in
  [0003](/decisions/0003-migrations).

## The decisions

Seventeen, each one file, each stating the decision first and then its evidence, its alternatives and
what it costs. Each decision shows its `Status` — the decision itself — and, where useful, an
`Artifact:` line for what is actually in the tree, with build status tracked on the [roadmap](/roadmap).
The card rail's own two live under [the card decisions](/card). There is no separate
"open" list: **decided-but-unbuilt work lives on the [roadmap](/roadmap)**, and every limitation a
decision accepted lives in that ADR's own *"What it costs"*.

| # | We decided | Because | Status |
| --- | --- | --- | --- |
| [0001](/decisions/0001-rust-and-postgres) | **Rust** on one Postgres 18, with sqlx and no ORM | Two of this project's written guarantees turned out false in Go, and only a type system catches that. Postgres has measured headroom of 16–40× what we sized for | accepted |
| [0002](/decisions/0002-scaling) | One Postgres, with the hot account striped | The bottleneck is one contended row, not the hardware — and splitting per tenant *relocates* it (1.07× under a dominant tenant) where striping removes it | accepted |
| [0003](/decisions/0003-migrations) | `sqlx` + our own try-lock, as an `openledger migrate` pre-deploy command — and the baseline editable until it froze (2026-08-27) | A *blocking* advisory lock deadlocks against `CREATE INDEX CONCURRENTLY`. sqlx blocks; every other Rust migrator has no lock at all | accepted |
| [0004](/decisions/0004-where-logic-lives) | **The ledger goes in Rust. Postgres holds the shape, and a trigger needs a written justification** | The schema had quietly become the ledger — 27 triggers and 26 functions against 11 lines of application code. And a column with a `DEFAULT` is not a constraint: `recorded_at`, `account_seq` and `xact_id` each had one and each was forgeable by an `INSERT` | accepted |
| [0005](/decisions/0005-event-log-and-write-path) | An append-only `ledger_events` table, and **a posting — not an entry — as the write primitive** | Most accepted operations write no ledger transaction, so idempotency cannot live on the transactions table. And "one service owns the writes" is a hope about deployment; a type that cannot express an unbalanced transaction holds for every caller | accepted |
| [0006](/decisions/0006-time-and-as-of) | Running balance for "now", aggregate-on-read for "as of a business date" — and reports pinned to a commit-ordered cursor | A backdated entry lands with a *later* sequence number. And `recorded_at` is transaction-*start* time, so the same "as of" query re-runs to a different answer | accepted; its cursor *mechanism* is superseded by [0011](/decisions/0011-period-close-and-report-axes) |
| [0007](/decisions/0007-schema-conventions-and-chart) | Naming rules, a CI schema-snapshot test, and the chart of accounts as data with completeness as a separate invariant | Dropping a column silently drops its indexes — Formance lost two that way, unnoticed for sixteen migrations. And a dropped *balanced sub-book* satisfies the accounting equation while the report is incomplete | accepted |
| [0008](/decisions/0008-module-boundaries) | **The card module gets its own Postgres schema, not its own migration set** | Not one foreign key crosses the card/core boundary, so the seam is real — but `sqlx` has no ordering between migration sets, and of eight systems read from source, the only two that separate cleanly give each component its own *database* | accepted; artifact parked |
| [0009](/decisions/0009-append-only-perimeter) | **The append-only perimeter is the application role — and the naive migration accident is inside the threat model**, so DDL against posted history gets an event-trigger speed-bump (the real backstop is the CI snapshot test plus the role split) and the account owner gets a foreign key | The eighteen DML triggers cover DML only: `ALTER COLUMN … TYPE` rewrote posted history with both `ENABLE ALWAYS` and neither firing, a child table both doubled and removed parent-visible rows, and the `ENABLE ALWAYS` fix this log once proposed for foreign keys **is not a statement PostgreSQL accepts** | accepted |
| [0010](/decisions/0010-reconciliation) | **A reconciliation layer of reporting views, run daily by `openledger reconcile` as a role that cannot write what it checks** | Six of this log's open rows were the same missing object — and the obvious version of the check is wrong: a raw journal-minus-report gap is nonzero on every healthy book carrying a hold. A reconciliation is a statement with its reconciling items named, not a subtraction | accepted |
| [0011](/decisions/0011-period-close-and-report-axes) | **The close is an ordinary posting, the as-of cursor is an `xid8`, and the statements become functions of an effective range and that cursor** | A timestamp cannot order commits and neither can a sequence — 0006's own watermark admits a row below a watermark already issued. And the same cursor is what makes a stored period-end balance safe under a backdated entry: the late arrival lands in a tail, not in a contradiction | accepted |
| [0012](/decisions/0012-chart-governance) | **The chart splits into identity and a versioned, append-only presentation — and netting is declared per type** | Reclassifying a line silently restated issued statements and IAS 1.41 requires the comparatives to move with it. And the balance-sheet side was two-valued, so 1,000.00 of paid-in capital presented under "Accounts payable and accrued" with every check green | accepted |
| [0013](/decisions/0013-write-path-contract) | **`READ COMMITTED` on the write path, a two-statement replay contract, `event_id NOT NULL`, and the stripe below the account** | A retry loop rescues 0 of 25,074 serialization failures because the snapshot never moves; the one-statement replay returns zero rows under its own race; `NOT NULL` is free today and needs `DISABLE TRIGGER` tomorrow; and `uq_accounts__house` was never what blocked striping | accepted |
| [0014](/decisions/0014-http-api) | **The HTTP API is the adoption surface — tokio + axum, `utoipa` core only, the spec a committed snapshot-tested artifact** — reversing the roadmap's original "no API in v0.1" | A writer only Rust code can call is not a deliverable, and the HTTP boundary is what makes the e2e tests caller-shaped. `utoipa-axum` is 19 months stale and ships RUSTSEC-2024-0436; `aide`'s naive failure mode is an endpoint with no `responses` at all, silently | accepted |
| [0015](/decisions/0015-workspace-enforcement) | **Five crates plus a test-only crate, hexagonal by dependency direction — and the boundary machine-enforced** by deny.toml's capability ratchet, strict advisories, and the clock lint | An in-crate module cannot be forbidden a dependency; a crate can. The domain crate holds zero sqlx and `cargo deny check` fails the build if that ever changes — the boundary is a refusal, not a review habit | accepted |
| [0016](/decisions/0016-pending-to-posted) | **Pending → posted is a new posted transaction carrying `resolves_id`, surfaced as two optional fields on `POST /v1/transactions`** — the target must be pending and unresolved, and the writer is what holds that. A reversals-and-void section (ratified 2026-08-31, unbuilt) adds `reverses_id`: server-derived contra mirror, the void as a zero-posting marker, one supersession index | The schema carried the whole shape since the baseline; what it cannot hold is the semantic linkage — ADR-0004 reproduced a posted transaction "resolved" by another posted one at revenue −49,223 with every check green. A `/resolve` route would restate the body schema to add one field | proposed — the API shape awaits ratification |
| [0017](/decisions/0017-no-authentication) | **No authentication: the ledger deploys internally only, and `tenant_id` in the body is data scoping, not an auth claim** — authenticating callers is the deployer's layer (mesh, gateway, mTLS) | A second, ledger-shaped copy of the perimeter's identity machinery is security every deployment would have to configure correctly twice; the binary cannot verify its own network position either way, so the honest form of the requirement is a stated one | accepted (ruled 2026-08-31) |

## Non-negotiable

No decision may trade these away. They are what makes the numbers trustworthy:

- **Append-only.** No `UPDATE`, no `DELETE`, no `TRUNCATE` on entries — enforced by triggers that
  refuse the statement outright, not by discipline and **not by the grants**. A `REVOKE` is a
  point-in-time change to a privilege; one `GRANT ALL` undoes it. The perimeter now extends to the
  DDL channel and to the chart's presentation history ([0009](/decisions/0009-append-only-perimeter),
  [0012](/decisions/0012-chart-governance)).
- **Balanced per currency.** Enforced by *construction* in the Rust writer — a posting names a source
  and a destination, so one leg is unconstructible ([0005](/decisions/0005-event-log-and-write-path)).
  An unbalanced transaction is not something the code rejects but something no caller can express; and
  `recon_transaction_breaks` is the exception list that reports any violation in the data
  ([0010](/decisions/0010-reconciliation)).
- **Bitemporal.** Every entry records both when it happened and when we learned about it — and a
  third column, the commit-ordering `xact_id`, is what makes a report of either axis reproducible
  ([0011](/decisions/0011-period-close-and-report-axes)).
- **Event-logged.** Every accepted operation is recorded, whether or not it moves money.
  **Enforced:** `ledger_transactions.event_id` is `NOT NULL`, so a transaction without a causing
  event is unwritable ([0013](/decisions/0013-write-path-contract)).
- **Correctness is never configurable.** Formance made historization a feature flag and got
  point-in-time queries that silently return empty — *"a green check that didn't actually execute."*
  Make the product pluggable; never the invariants.
- **Prefer a constraint that makes a state unreachable to a check that looks for it afterwards.** The
  chart guard refused a wrong chart at *seed* time: the wrong system could not be built, so no test
  had to notice. [0004](/decisions/0004-where-logic-lives) turned it into a foreign key, which is the same
  property, declaratively.
