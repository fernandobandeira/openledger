# Spike 023 — the harness specification

**The question.** On the *shipped* schema, what contract must a Rust read path honour to reach
`report_cursor()`, `trial_balance_at`, `income_statement_for` and `balance_sheet_at` without losing
tenant isolation or report reproducibility?

M5 is the last unbuilt Phase 1 milestone, and it is the only one where the SQL is applied and
**nothing in Rust has ever called it**. `openledger_read` — the role the whole read-side tenant fence
hangs off — is referenced only by e2e fixtures; no service code has ever connected as it. So the
spike measures *service-shaped* things: what a pooled connection does with session state, what a
report function does with a caller's arguments, and what an inception scan costs against a 30-second
`statement_timeout`.

Nothing outside `spikes/023-read-path-contract/` was modified. No migration, no crate, no doc.

---

## Ground rules, taken from spike 022's methodology and one added

- **A real database, and not the shared one.** `CREATE DATABASE spike023` on the project's own
  instance (`make up`, PostgreSQL 18-alpine on port 5433), schema applied by the **compiled binary**
  (`cargo build -p openledger`, then `DATABASE_URL=… openledger migrate` — three migrations, 174 ms),
  chart seeded from `schema/chart.sql` by psql. The `openledger` database another process may be
  using was never touched.
- **Gate every experiment on correctness.** `SELECT * FROM reconciliation` must show ten checks at
  zero breaks. A finding from a book that does not reconcile is not a finding.
- **Record the machine's load with every number**, and say plainly that another agent was loading
  this machine. It was — see below, and it turned into a finding.
- **Write through the compiled binary over HTTP wherever it can be done.** A read-path spike that
  writes with hand-built SQL is measuring a schema, not a system. Two exceptions, both stated at
  their use: the ADR-0006 breaker needs a transaction held open across a cursor capture, which the
  HTTP writer cannot do because it commits before it answers; and Q5's million-entry book cannot be
  posted one HTTP call at a time in the time available.
- **New rule, added because it bit spike 022 (`DESIGN-QUESTIONS.md` §6's correction):** every
  number quoted in `FINDINGS.md` is grep-able in a kept file under `out/`. Nothing is quoted from a
  smoke run.

### One ground rule that broke, and became evidence

For most of this spike, **another agent's spike was running against the same PostgreSQL cluster and
holding a transaction open in a different database** (`spike024arms`, pid 6042, `idle in
transaction` from 14:48:22 UTC). `pg_snapshot_xmin` is a *cluster* horizon, so `report_cursor()` was
frozen at 15760 for the whole of the Q3 run — and 8 of this book's 16 committed entries sat above
it, i.e. **a report issued at that moment would have omitted half the book**.

ADR-0011's cost list predicts this exactly (*"it bit this ADR's own measurements … the horizon is per
cluster, not per database"*), and `recon_cursor_breaks` did what ADR-0010 says it does: it reported
10,016 `above_horizon` breaks on a book with nothing wrong with it. Two consequences for the method:

1. Q3's negative control could not be *"a fresh cursor moves"*, because it did not. It is instead
   *"a cursor explicitly above every committed write shows the writes the pinned cursor withholds"*,
   which is the same claim without the environmental dependency.
2. The oracle gate is satisfied at the **end** of the run, after the foreign transaction cleared:
   `book reconciled — 10 checks, 0 breaks, 28970 ms` (`out/99-oracle.txt`). During the run,
   nine of ten checks were at zero and every `cursor_forgery` break was `reason = above_horizon`
   with `xact_id = txn_xact_id` on all 10,016 rows — no forgery, just the horizon
   (`out/q5-gate-cursor-forgery-is-the-horizon.txt`).

The 28,970 ms is itself a datum: at 1.11 M entries the daily sweep is at **29.0 s against the
serving pool's 30 s `statement_timeout`**, and it only survives because `reconcile` opens its own
`PgConnection` and sets no timeout on it.

---

## The workload

### The book the correctness questions run on

Two tenants, and the same account pair the e2e suite uses (`crates/e2e/.../support/book.rs`): a
`per_shard` `customer_receivable` owned by a company, and a house `fee_revenue`
(`sql/00-seed-accounts.sql`). Neither type is `is_perimeter`, which is what keeps
`chart_lint.perimeter_unattested` — correct, and permanently firing until the attestation feed
exists (roadmap M7) — out of the ten-check oracle. Both accounts carry `stripe_count = 8`, so a
current-balance read is a `SUM` over several rows rather than one (ADR-0018, and the roadmap's own
correction to *"an O(1) read"*).

**t1's entries are ADR-0006's own worked table, scaled by 100 and posted in ADR-0006's own order:**

| effective | amount | how it arrived |
| --- | --- | --- |
| 2026-01-10 | +10,000 | first |
| 2026-01-30 | +5,000 | second |
| 2026-01-20 | +3,000 | third — **backdated** |

so the effective-axis answer as of Jan 25 must be 13,000 (ADR-0006's 130) and since inception 18,000
(its 180). Insertion order is not effective order, which is M5's second done-when criterion.

### The books the cost question runs on

Three tenants — `big10k`, `big100k`, `big1m` — at 10,000 / 100,000 / 1,000,000 entries, written by
`sql/10-bulk-book.sql`: one event, one transaction and two entries per posting (the two legs
`expand_postings` emits for one `source → destination`), business dates spread over three years, on
8 stripes with the stripe chosen as a writer of index `n mod 8` would have chosen it. The cache is
computed from the journal in the same transaction at the same
`(account, currency, stripe)` grain and `account_seq` is dense per stripe, so
`recon_balance_breaks` — which checks exactly that — passes. `ledger_entries` reached 454 MB.

---

## The shape of each experiment

### Q1 · the GUC on a pooled connection — `harness/src/guc.rs`

A real `sqlx::PgPool` configured the way `crates/db` configures the serving process's (same
`after_connect` session timeouts, same sqlx 0.9 line) but with **`max_connections(1)`**, which makes
"the connection the next request gets" deterministic — a leak becomes a fact rather than a race.
Six cases, in one process, in order, so each one's starting state is the previous one's ending state:

- **A** unset GUC, read as `openledger_read`, on the base tables *and* through all four report
  surfaces;
- **B** `SET app.tenant_id = 't1'` on checkout 1, then checkout 2 sets nothing and reads;
- **C** `SET LOCAL` inside `BEGIN … READ ONLY`, then the same connection after `COMMIT`, then the
  next checkout;
- **D** `SET app.tenant_id = $1` (to establish whether the parameterised form exists at all), then
  `set_config('app.tenant_id', $1, true)`, then the same with a hostile bind
  (`t2'; SET ROLE openledger_app; --`);
- **E** `set_config(..., is_local => true)` with **no explicit transaction**, and the read it was
  meant to scope;
- and, in `role.rs` **F**, what `RESET app.tenant_id` leaves behind versus a connection that never
  set it, plus whether a tenant can be named `''` at all.

### Q2 · the read role — `harness/src/role.rs`, `sql/01-login-roles.sql`, `sql/02-policy-union.sql`

Two pool shapes, both real: the writer's (nothing assumed about the role) and a candidate read pool
whose `after_connect` issues `SET ROLE openledger_read` **once per connection**. Plus two login
roles the shipped tree does not have, created by hand in the scratch database and dropped by
`sql/99-teardown.sql`, because the owner is not bound by RLS at all
(`FORCE ROW LEVEL SECURITY` is deliberately unset) and therefore cannot answer the question a
deployment faces:

| login | membership |
| --- | --- |
| `spike023_reader` | `openledger_read` only |
| `spike023_dual` | `openledger_app` **and** `openledger_read` — a serving login that must write and whose pool reads are meant to share |

`sql/02-policy-union.sql` runs the same four reads as each login: no GUC, scoped through inherited
membership, scoped behind `SET LOCAL ROLE`, and through the report surfaces. `role.rs` adds the
session-`SET ROLE`-then-write leak, the rollback case, `RESET ROLE` on a read-pool connection, the
prepared-statement-cache case, and whether a read pool can carry its own `statement_timeout`.

### Q3 · the cursor — `RUN-q3.sh`

1. **The branch audit, from the catalog rather than the source file**: `pg_get_functiondef` for all
   five functions dumped to `out/03-functiondef.txt`, then every table each one reads classified by
   whether it carries an `xact_id` column at all, plus `proisstrict` and `proacl` for all five.
2. **The ADR-0006 breaker, constructed**: adversary A opens a transaction on a FIFO-fed psql and
   posts by hand (`sql/post-by-hand.sql` — the same CTE shape as `CLAIM_AND_APPEND`, so the rows it
   leaves are indistinguishable from the writer's), taking an `xact_id` and **not committing**;
   B then posts through the compiled binary over HTTP and commits, so B's id is *higher* than A's
   and already visible. Two candidate cursors are captured at that instant —
   `report_cursor()` and `max(xact_id) + 1` — all three reports are rendered at each, A commits,
   and all three are re-rendered and diffed.
3. **The negative control**: a cursor explicitly above every committed write.
4. **A NULL cursor**, a NULL as-of instant and a NULL effective range, on all three functions and on
   `recon_equation_breaks`.
5. **The chart-version default**: explicit v1 against the run-time default, plus an append to a
   frozen version (must be refused) and an append to the current version at a **fixed** cursor.
6. **The `scopes` CTE**: one new EUR account, nothing posted to it, same cursor, diffed.

### Q4 · backdating — `RUN-q3.sh` §9

The effective axis read at three instants either side of the backdated entry, and the recorded axis
read as the same function with the cursor as its parameter.

### Q5 · cost — `RUN-q5.sh`

Five passes per cell, median quoted, range printed, `EXPLAIN (ANALYZE, TIMING OFF, BUFFERS)` rather
than `\timing` so psql's round trip is excluded and the buffer counts come along. Five reads per
book: the three reports since inception, one account's current balance (the `SUM` over stripes), and
a mid-book business-date range. Then the 1M plans, the row counts the reports *return*, a hand
decomposition of `balance_sheet_at` into its A14 guard / `pos` / `plug` terms
(`out/q5-balance-sheet-decomposed.txt`), and a catalog-wide search for any function or view that
reads `ledger_period_balances`.

### Q8 · the error grammar — `RUN-q8.sh`

Ten groups, every one with `VERBOSITY=verbose` so the SQLSTATE is printed: unknown chart version,
an unpresented type, a malformed cursor (four forms including `-1` and `xid8` max), an absent
cursor, an unknown tenant, a one-character tenant typo, the two shapes of an empty book, an
RLS scope-out, an unscoped reader, an unknown account, an account that exists but has never been
written, and a currency the account does not hold.

### Q9 · isolation — `RUN-q9.sh`

The same two-statement report run at `READ COMMITTED` and at `REPEATABLE READ READ ONLY`, with an
account created between the two statements in each case; then an 11-second `REPEATABLE READ` report
on `big1m` with `report_cursor()` and `pg_stat_activity.backend_xmin` sampled while it runs; then
`EXPLAIN` of both function shapes to show that one inlines and the other does not.

### Q6 and Q7

Reasoned, against the tree: `crates/api/src/lib.rs` (the route table, `AppState`), `crates/ledger/src/port.rs`
and `crates/ledger/src/repository.rs` (the two ports and their stated rules),
`crates/openledger/src/main.rs` (the composition root), `crates/openledger/src/batching.rs`
(`DISPATCHERS`, and the `const` assertion that couples it to `db::POOL_CONNECTIONS`), `deny.toml`
and `clippy.toml`. No experiment; labelled as reasoned in `FINDINGS.md`.

---

## Deliverables

- `DESIGN-QUESTIONS.md` — written before the answers.
- `SPEC.md` — this file.
- `FINDINGS.md` — the answers, each labelled **proven**, **measured** or **unmeasured / reasoned**.
- `RECOMMENDATION.md` — numbered rulings, each with a one-line *because*, and what to refuse.
- `harness/` — a self-contained Cargo project, **not** a workspace member (empty `[workspace]`
  table, its own `Cargo.lock`, `.gitignore` for `target/`), copying spike 022's pattern.
- `RUN-q3.sh`, `RUN-q5.sh`, `RUN-q8.sh`, `RUN-q9.sh`, `post.sh` — the drivers.
- `sql/` — the seed, the login roles, the policy-union script, the by-hand posting, the bulk loader,
  the teardown.
- `out/` — every transcript and every rendered report that any quoted number comes from.
