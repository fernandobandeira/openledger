# Roadmap

Ordered by what unblocks what, not by size. No estimates — the risk is correctness, and correctness
does not estimate well. **The ledger core is the product**; cards, spend controls and credit lines
are a *reference implementation* built on it
([ADR-0002](/decisions/0002-scaling)). So the core must be verifiable by strangers before a reference
product matters.

**The schema is applied and verified, and the first vertical slice of the Rust exists.**
`migrations/00001_baseline.sql` and `openledger migrate` are built and run in CI — and since
2026-08-27 so are M3's lean writer, the one HTTP endpoint in front of it
([ADR-0014](/decisions/0014-http-api)), and the e2e suite that spawns the binary and posts over the
wire; since 2026-08-28 the writer posts in a **single server-side call**, and since 2026-08-31 it
holds pending → posted — and its undo: reversals, and the void — too
([M3](#m3--the-posting-engine), [ADR-0016](/decisions/0016-pending-to-posted)). **Since 2026-09-01
the load-bearing half is built too**: stripe selection on the write path, coalescing across
requests, and the concurrency proof that pins the deterministic lock ordering
([ADR-0018](/decisions/0018-batching-and-stripe-selection),
[spike 018](/spikes/018-batching-and-stripe-selection)).

**What is missing is now the read path**, and one honest asymmetry inside what just landed: striping
is worth a measured **4.3×** and pays today, while cross-request batching buys nothing until offered
load approaches the unbatched ceiling — **at or a little above ~1,940 clearings/s**, which the
measurement ladder brackets from below only, about **39× the peak
[ADR-0002](/decisions/0002-scaling) derives** — and ships inert below that by dispatching on
completion rather than on a timer. That
gap — not a deployment — is the story now. Phase 1 is the ordered list of code to build to close it.

**Since 2026-09-01 the read path has a decided contract and an audited substrate.**
[ADR-0019](/decisions/0019-read-path) settles how a read reaches the database and what its cursor
promises ([spike 019](/spikes/019-read-path-contract)), and an adversarial round against the
reporting layer produced twelve findings, eleven of them reproduced on a real book
([spike 021](/spikes/021-reporting-layer-defects)) — including a check the schema calls its
highest-leverage one that **cannot fail**, and a forgotten `INSERT` that reports a period's revenue
as 0.00 while the sweep exits 0. Neither the endpoints nor the fixes are built yet, and this page
says which is which throughout.

---

# Phase 1 — the core

**The build order.** The schema is done; what is missing is the Rust, in dependency order:

1. **The writer** ([M3](#m3--the-posting-engine)) — the posting API that is balanced by
   construction, the two-statement idempotency replay, the posted-only cache update and the
   transaction seal. **The lean core of this landed on 2026-08-27**, behind one HTTP endpoint
   ([ADR-0014](/decisions/0014-http-api)), **single-call posting followed on 2026-08-28**, and
   **pending → posted on 2026-08-31** ([ADR-0016](/decisions/0016-pending-to-posted)), and
   **batching under load plus stripe selection on 2026-09-01**
   ([ADR-0018](/decisions/0018-batching-and-stripe-selection)) — **M3 is done**.
2. **`openledger reconcile`** ([M2](#m2--openledger-reconcile-and-the-concurrency-proof)) — wire the
   ten reconciliation views to an exit code so the daily sweep is a real command. **Built
   2026-08-28**: the subcommand runs the views in one snapshot as `openledger_recon`. **M2 closed
   2026-09-01** when the concurrency proof landed with the batching it waited on — `concurrency.rs`,
   two tests, both order sources. *(This line read "what remains of M2 is the concurrency proof,
   which waits on M3's batching" in the same commit that shipped both.)*
3. **The stripe-picking writer** ([M3](#m3--the-posting-engine)) — stripe selection on the write
   path. **Built 2026-09-01**, keyed on the writer rather than the tenant:
   [spike 018](/spikes/018-batching-and-stripe-selection) measured **4.31×** against an unstriped
   control, and on the whale workload where the two keys are compared side by side the writer key
   beats the tenant key **2.8×** (1,897 against 677 clearings/s) — refuting
   [spike 004](/spikes/004-chart-of-accounts)'s refinement on its own whale evidence.
   *(This line quoted a tenant-keyed "1.09×". That ratio paired the whale workload against a
   no-whale baseline; **no unstriped whale control was ever run**, so it is withdrawn — see
   [ADR-0018 §1](/decisions/0018-batching-and-stripe-selection).)*
   *(This step used to carry **the CI schema-snapshot test** too —
   [0007](/decisions/0007-schema-conventions-and-chart)'s highest-leverage guard against schema
   drift landed on 2026-08-31, closing [M1](#m1--schema-invariants-and-the-snapshot-test).)*
4. **The as-of read path** ([M5](#m5--bitemporal-reads)) — a Rust read path over the report
   functions, correct on both time axes. **Its contract is decided as of 2026-09-01**
   ([ADR-0019](/decisions/0019-read-path), [spike 019](/spikes/019-read-path-contract)): a second
   inbound port on its own pool and its own login, five GET routes, and the cursor validated in Rust
   before it reaches SQL. What that spike found is why the contract is a decision and not a
   detail — **a login that is a member of both the writer and reader roles reads every tenant**,
   because RLS policies are permissive and OR'd and `pg_has_role` decides which apply. Building it
   is what remains.

The milestone numbers are stable identifiers carried over from the decision log; the list above is
the order to build in. Cards and durable timers are Phase 2, deliberately later.

## M0 · Validating the decisions — **done, and deleted**

A SQL implementation and its conformance suite proved the design and then outgrew it. Ten
adversarial rounds found real defects, several of which under-reserved credit; those findings are
recorded in [ADR-0007](/decisions/0007-schema-conventions-and-chart),
[card 0001 · authorization holds](/card/decisions/0001-authorization-holds) and
[ADR-0004](/decisions/0004-where-logic-lives). It has been deleted, and
[ADR-0004](/decisions/0004-where-logic-lives) is why. **The same assertions come back as Rust
tests, once the writer exists.**

## M1 · Schema, invariants, and the snapshot test — **done: schema, migration runner, and the snapshot test**

`migrations/00001_baseline.sql` is the core — `ledger_accounts`,
`ledger_transactions`, `ledger_entries`, `ledger_account_balances`, `ledger_events` — plus the
chart-of-accounts and completeness *tables* ([ADR-0007](/decisions/0007-schema-conventions-and-chart)),
which it creates **empty**: the example chart is `schema/chart.sql`, seeded separately by
`make chart` and owned by no migration.
Every object in it is justified in place per
[ADR-0004](/decisions/0004-where-logic-lives); the counted inventory lives in
[the database page](/database#what-the-schema-enforces-today). It was written by hand rather than
promoted from the spikes, which held three competing posting engines and two competing hold
models. No API, no
service code beyond the migration runner. Balanced-per-currency is deliberately *not* in there: it
belongs to the writer ([0005](/decisions/0005-event-log-and-write-path)).

**`openledger migrate` is built** ([ADR-0003](/decisions/0003-migrations)) — `sqlx` with its
blocking lock replaced by a `pg_try_advisory_lock` poll, migrations compiled into the binary, no
down migrations, and a wait budget an operator chooses (900 s by default,
`OPENLEDGER_MIGRATE_LOCK_SECS` or `--lock-secs` to change it). It applies the baseline to an empty
database.
***Idempotent on re-run* is verified, and now checked on every push.** Run twice against a fresh
database on 2026-08-27 it exited 0 both times, 51 ms then 1 ms, and `.github/workflows/test.yml`
runs it twice. The tests in `crates/db/src/migrate.rs`
additionally assert that the set carries no down migration and that a `-- no-transaction` migration
holds exactly one statement.

**The card hold model is parked**, in [`parked/card/`](/card/parked), and applied by
no migration. Its design ([card 0001 · authorization holds](/card/decisions/0001-authorization-holds)) stands; the DDL waits
for M7. [`database.md`](/database) is the drawn and explained version of what is deployed.

**Tenant-leading keys were the one irreversible decision on the list, and they were free.** Every
ledger table carries `tenant_id NOT NULL`, primary keys are `(tenant_id, id)`, and every index and
foreign key on those tables carries the prefix — the prerequisite for row-level security,
partitioning and ever splitting across instances, all expensive to retrofit. A widely-cited
sharding post-mortem named exactly this omission as its regret; **which company is unverified**.
The chart's two foreign keys deliberately lack the prefix because the chart is
deployment-global, so a tenant cannot add an account type without a migration — a real limitation, listed in ADR-0007. Tenant-locality follows
from the same keys and is a conformance property: `operating_cash` mirrors one real bank account
and cannot be per-tenant, so treasury movements split into a `due_from_treasury` /
`due_to_tenants` pair rather than one transaction that leaves a tenant's own books short by the
full amount ([measured](/spikes/004-chart-of-accounts)).

**Striping — designed as schema and applied.** An account declares a `stripe_count` and a balance
read `SUM`s the stripe rows that exist ([ADR-0013](/decisions/0013-write-path-contract)). An
earlier version of this paragraph said `uq_accounts__house` made it impossible; that was the stripe
imagined one table too high — a stripe is a row in `ledger_account_balances`, not an account, so
the index that refuses two house accounts of one purpose is untouched while 64 stripes of one
account are 64 balance rows. Re-measured on the shipped baseline plus the stripe column: 7.7–9.2×,
and it is *striping* that removes contention, not per-tenant splitting: at 90/10 skew per-tenant
accounts gave 1.07× while striping still gave 7.8× ([spike 003](/spikes/003-throughput-ceiling)).
**The writer that picks a stripe was built on 2026-09-01**
([ADR-0018](/decisions/0018-batching-and-stripe-selection)).

**Through that writer the figure is 4.31×, not 7.7–9.2×, and the two measure different things.** The
number above is **upserts/s against one logical account**; end to end it is clearings/s through a
writer that also hashes a payload, claims a key and inserts an event, a transaction and four
entries, one of whose accounts is per-company and never contended
([spike 018](/spikes/018-batching-and-stripe-selection) §A). Amdahl, not a regression — but the two
should never be quoted as the same measurement, and an earlier draft of that spike did exactly that
and would have reported ADR-0013 as overstated.

**Done when:** the schema snapshot test is in CI, and striping exists. **Both hold as of
2026-08-31.** The migration runner is done, striping's schema is applied, and the snapshot test —
the item [ADR-0007](/decisions/0007-schema-conventions-and-chart) calls the highest-leverage one
here — is built: the e2e suite migrates an empty scratch database with the compiled binary, dumps
the catalog as deterministic text, and diffs it against the committed `schema/snapshot.txt`
(`crates/e2e/tests/e2e/schema_snapshot.rs`; `make schema-snapshot-check`, with regeneration the
explicit opt-in `make schema-snapshot` — the same write-under-env-var contract as the OpenAPI
snapshot, so a normal run can only fail on drift, never rewrite the file it compares against).
The charge that was widened for the [0009](/decisions/0009-append-only-perimeter) owner-accident
DDL class is in the dump: `pg_trigger.tgenabled` / `pg_event_trigger.evtenabled`, full `pg_policy`
definitions, view `reloptions`, `pg_class.relrowsecurity`/`relforcerowsecurity`, `pg_get_viewdef`
for every view, `account_types.is_perimeter`/`mirror_type`, the full `pg_constraint` set, every
catalog comment (`pg_description`), and `NOT VALID` constraints as their own must-stay-empty
section ([ADR-0007](/decisions/0007-schema-conventions-and-chart) §2) — plus function bodies,
grants and role attributes, which sit in the same accident class. Proved red before trusted green:
a disabled append-only trigger, a disabled event trigger, a dropped RLS policy plus
`DISABLE ROW LEVEL SECURITY`, and a `CREATE OR REPLACE VIEW` body swap plus a `security_invoker`
reset were each injected by hand, and each failed the test naming exactly the drifted lines.

## M3 · The posting engine

**The lean core of this landed on 2026-08-27** ([ADR-0014](/decisions/0014-http-api)): given a
balanced set of entries and an idempotency key, post atomically or return the stored result — built,
behind `POST /v1/transactions`, and verified by the caller-shaped e2e suite with
`SELECT * FROM reconciliation` as its oracle. **The load-bearing half is now built too** — the last
of it on 2026-09-01. *(This sentence read "what remains here is the load-bearing half" after that
half had shipped.)*
Pending → posted is a **new** transaction with `resolves_id`, never an UPDATE — **built 2026-08-31**
([ADR-0016](/decisions/0016-pending-to-posted)): the same endpoint takes an optional `status` and
`resolves_id`, a pending post issues sequence numbers without moving the posted cache, and the
writer refuses a resolution whose target is missing, not pending, or already superseded — the
semantic linkage [ADR-0004](/decisions/0004-where-logic-lives) proved no foreign key holds.
**Reversals and the void followed the same day** (ADR-0016's reversal section, migration 00003):
`reverses_id` on the same endpoint, the mirror derived server-side from a posted target, a pending
target voided by a zero-entry marker, and one supersession index refereeing the resolve-vs-reverse
race. Hold *expiry* — the timer that fires a void unprompted — stays M8's. Three
design constraints, not later optimizations — **all three are now settled**: the second landed on
2026-08-28, the first on 2026-09-01, and the third was re-measured on the shipped writer the same
day. *(This line read "the other two are not in the lean core yet" directly above a bullet headed
"built 2026-09-01".)*

- **Coalesced batching — built 2026-09-01.** N postings to one account collapse into a single upsert
  advancing the balance by the total and `last_seq` by the count; each entry's `account_seq` is
  derived by walking backwards from the returned totals. This is the only batching that does not
  deadlock. Coalescing *across* requests is now built too, and it arrived with a finding that
  reframes it: **batching trades lock count for lock hold time, so it pays only when members share
  accounts.** Measured 2–2.8× *slower* across 32 uniform tenants where a batch of 25 touches 25
  different account pairs, and 1.24× faster under a dominant tenant where it coalesces. Batches are
  therefore tenant-homogeneous, and the accumulator dispatches **on completion rather than on a
  timer** — below saturation every batch has one member and takes the single statement, so the
  batched path is unreachable until requests actually queue
  ([ADR-0018](/decisions/0018-batching-and-stripe-selection)).
- **Single-call posting — built 2026-08-28.** The whole append — key claim, transaction row,
  balance upserts in account order, entries — is one `unnest`-based CTE pipeline in one statement
  ([the service page has the shape](/service#the-write-path-as-implemented)), so a posting costs
  **three round trips** (`BEGIN ISOLATION LEVEL READ COMMITTED`, the statement, `COMMIT`) where
  the lean writer spent **eight**. The replay lookup stays a *separate* statement B, because
  folding it into the claim is the one-statement hole
  [ADR-0013 §2](/decisions/0013-write-path-contract) reproduced. Why it is a constraint and not a
  knob: worth ~14% on localhost, and worth more the higher round-trip latency climbs, where five
  saved round trips cost ~2.5 ms against ~1.3 ms of real work
  ([spike 003](/spikes/003-throughput-ceiling) — the spike's numbers). **This binary's own
  throughput is still unmeasured**, and [spike 018](/spikes/018-batching-and-stripe-selection) did
  not close it: its harness depends on none of `ledger`, `ledger-postgres`, `api` or `openledger`,
  builds the statements as strings and speaks no HTTP, so it measured the *shipped SQL against the
  shipped schema* — a real advance on spike 003's bench schema, and still not a load test of the
  compiled binary.
- **Striping and batching must not both be applied blindly** — **and the cancellation this line
  warned about does not reproduce on the shipped writer.** [Spike 003](/spikes/003-throughput-ceiling)
  measured random stripe selection making the two levers *cancel*, worse than either alone, on a
  bench schema with a per-leg posting function. Re-measured on the shipped SQL, striping under
  batching is still worth **1.42×** *(this read 1.43×; the committed medians are 1,427 → 2,020, a
  ratio of 1.415)*, and choosing the stripe after the coalesce rather than per member is
  worth only **+7.6%** — a real effect, far smaller than "worse than either alone"
  ([spike 018](/spikes/018-batching-and-stripe-selection) §B). What replaces the warning is the
  overlap rule in the bullet above. The affinity key is the **writer**, not the tenant: a business
  key relocates the hot spot wherever that key is skewed, and payment volume always is.

**Decided: RLS and batching are not mutually exclusive, and the `BYPASSRLS` sketch is refused**
([ADR-0013](/decisions/0013-write-path-contract) §5, answering the [settled RLS framing decision](#rls-guards-reads-the-writer-is-admitted-not-exempt)
below). `unnest`-based multi-row `INSERT` measured within 2% of `COPY` on `ledger_entries` at
25–10,000 rows — the composite foreign keys dominate, not the wire format — and `BYPASSRLS` cannot
be granted on RDS or Aurora at all. The writer posts under an explicit admit-all policy; RLS scopes
the read role.

**Done when:** M0's conformance suite, rebuilt in Rust, passes under concurrent load, with and
without batching, and with striping on and off. **Held as of 2026-09-01** — the e2e suite posts
concurrently through the accumulator against striped accounts and reads
`SELECT * FROM reconciliation` at ten zeros, and the spike ran the same shapes across 302
configurations, every one oracle-gated.

## M2 · `openledger reconcile` and the concurrency proof

Two things live here: a command that is built, and a proof that waits on the writer above.

**Built 2026-08-28 — the `openledger reconcile` subcommand.** The ten reconciliation views ship in
`migrations/00001_baseline.sql`, and the command that runs them as a sweep now exists: the same
binary and shape as `openledger migrate` ([ADR-0010](/decisions/0010-reconciliation)), running the
views in one `REPEATABLE READ READ ONLY` transaction as `openledger_recon` (`SET ROLE` after
connecting — the role is `NOLOGIN`) and turning `SELECT * FROM reconciliation` into an exit code:
ten checks at zero breaks is exit 0, drift is exit 1 with each breaking check named on stderr
(`crates/db/src/reconcile.rs`; the [service page](/service) has the operator contract). Scheduling
the daily run stays the operator's — a cron entry or a Kubernetes CronJob, the same way `migrate`
is a pre-deploy job. [ADR-0010](/decisions/0010-reconciliation) specifies the layer, every drift
class was reproduced and caught with a clean-book negative control
([spike 011](/spikes/011-reconciliation)) — and the e2e suite now holds both halves against the
compiled binary: a clean book to exit 0, a forged cache to exit 1.

**The concurrency proof — built 2026-09-01, and the `ORDER BY` is finally pinned.** The mechanism is settled: a
per-(account, currency, stripe) balance row *(the stripe joined the grain on 2026-09-01,
[ADR-0018](/decisions/0018-batching-and-stripe-selection) §1)*, updated by
[one atomic upsert](/database) returning **both** the
new balance and the next sequence number, so the row lock *is* the serialization point — no
`SELECT max()`, no advisory lock, no retry loop. `tenant_id` leads the conflict target because it
leads the primary key; without it the statement does not run at all. Three traps:

- **It holds only under READ COMMITTED.** Stricter isolation makes `ON CONFLICT DO UPDATE` fail
  with `could not serialize access due to concurrent update` — a property of Postgres, not of this
  workload. It fails closed, so nothing corrupts, but a deployment that sets a stricter default
  silently loses most of its writes: measured at 8 writers over five repetitions, `none` loses
  **64–82%** (90% at 16 writers) and READ COMMITTED loses **0** — and an in-transaction retry loop
  rescued **0 of 25,074** serialization failures across every run, because the snapshot does not
  move. The writer therefore issues `BEGIN ISOLATION LEVEL READ COMMITTED` explicitly
  ([ADR-0013](/decisions/0013-write-path-contract) §1).
- **Deterministic lock ordering, batch-wide.** Sort accounts by id on both paths. [Spike
  003](/spikes/003-throughput-ceiling) found that sorting within a single clearing does
  *not* order locks across a batch — throughput collapsed 10× into deadlocks. A test that does not
  fail when the sort is removed is not testing the sort, and it needs more than two accounts: with
  two, the planner emits the legs in account order for free and no deadlock can be produced at all.
- **The first-entry race does not apply to the upsert form.** The warning is real for
  `SELECT … FOR UPDATE` — you cannot lock a row that does not exist — but
  `INSERT … ON CONFLICT DO UPDATE` *is* the insert-and-lock, so there is no gap to race through.

**Done when:** the reconcile command runs the views to an exit code (**done**), and N writers against
overlapping account sets produce zero deadlocks, gapless per-account sequences and balanced
transactions **with batching enabled**, with `SELECT * FROM reconciliation` at ten zeros under
concurrent load. **Both hold as of 2026-09-01.** The proof covers **both order sources**: the planned
path takes its delta order from the bound arrays, while the mirror path
([ADR-0016](/decisions/0016-pending-to-posted)'s server-derived reversal) takes its order from a
`GROUP BY` over the target's entries.

**Two amendments this section owes the reader, because the criterion above is not the one it
originally stated.**

*The `ORDER BY` is no longer unpinned — and it turned out to be load-bearing on only one of the two
paths.* This section used to record that "removing or inverting the statement's `ORDER BY` survives
the entire suite today", with two-account fixtures as the reason. Eight accounts and 128 concurrent
writers is the configuration that fails, and **the committed suite now holds it red**: delete the
batched statement's sort and the concurrency test fails **4 of 4**, with 95–218 deadlocks reaching
callers as 500s.

The **single** statement's sort is a *second* line of defence, not the only one. `coalesce` returns
a `BTreeMap`, so the writer binds its deltas already sorted by `(account_id, currency)` — remove the
SQL sort there and the suite stays green, because the Rust guarantee still holds. The batched path
has no such guarantee: its delta order comes from a `GROUP BY` across members inside the statement.
**Batching trades a compile-time ordering guarantee for a runtime one**, which is precisely why the
runtime one needed a test. A sort two writers can *disagree* about fails both paths.

*"Half posting their legs in reverse order" is not achievable on the batched path, and that is a
finding rather than a shortfall.* Coalescing normalizes lock order before the insert, so **a caller
cannot influence it there at all**. Reversed presentation is the *single* path's hazard and is
tested as such; the batched path's real hazard is differing account subsets across concurrent
batches, which is what produced the 95–218 deadlocks above. *(This read "the 833 above". 833 is
[spike 018](/spikes/018-batching-and-stripe-selection) §E's deadlocks-per-1,000-statements on the
harness's batched arm, and it appears nowhere on this page.)* An earlier version of the harness
conflated the two
and credited real deadlocks to a flag that was inert on that path.

## M5 · Bitemporal reads

Two axes, two mechanisms ([ADR-0006](/decisions/0006-time-and-as-of)): the current balance is a
`SUM` over an account's stripe rows in `ledger_account_balances` *(this read "a primary-key read of
the one row" — the primary key is `(tenant_id, account_id, currency, stripe)`, so a striped account
holds several and every read SUMs them)*, recorded-axis and business-date balances are
aggregates over `recorded_at` and `effective_at` respectively, and every reporting function names
its axis explicitly.

**Unblocked by [ADR-0011](/decisions/0011-period-close-and-report-axes).** The cursor is decided and
in the schema — `xact_id xid8` on every journal row, pinned at
`pg_snapshot_xmin(pg_current_snapshot())` — and the mechanism ADR-0006 originally specified is
*refuted*, not merely unbuilt: its watermark admits a row below a value already issued
([spike 012](/spikes/012-period-close)). The effective-axis aggregate *can* be bounded by the period-close
checkpoints (measured at ~40–230× at a close boundary, ~8–9× mid-period, neither decaying with
history), so a business-date query could read "prior close + entries since". **But that benefit is real
and not yet wired in**: the shipped `balance_sheet_at` / `income_statement_for` / `trial_balance_at`
never read `ledger_period_balances` — proven from `pg_get_functiondef` — so they scan `ledger_entries`
from inception, and the checkpoint's only reader is `recon_checkpoint_breaks` ([spike 020](/spikes/016-close-cost-at-scale)
— this site's spike 016; the spike directories carry their own numbering).

**Make the checkpoint pay for itself** (moved here from the decision log): teach `balance_sheet_at` to
read `ledger_period_balances` plus the two tails, partition the checkpoint by period, and bound
`recon_checkpoint_breaks`' per-close prefix scan — it is O(entries × closes) today (1 : 3.2 : 5.8 : 8.2
over 3/6/9/12 closes), re-aggregating the whole prefix per close ([spike 020](/spikes/016-close-cost-at-scale)).
And the close's own cost is now measured: **linear in account count and per currency** (~49 s and
1,000,003 checkpoint rows / 135 MB to close 1 M accounts in one currency), and the **write dominates
(~96%)** — one row per account plus PK/FK maintenance — not the aggregation (~4%).

**The contract is decided, and the first of the three criteria below is already proven on the shipped
SQL.** [ADR-0019](/decisions/0019-read-path) (ruled 2026-09-01,
[spike 019](/spikes/019-read-path-contract)) settles how a read reaches the database, what the cursor
promises, which five routes ship, and where the read path sits in the hexagon — and `report_cursor()`
is **confirmed end to end**: the interleaving that refuted
[ADR-0006](/decisions/0006-time-and-as-of)'s watermark left all three reports byte-identical, while
`max(xact_id) + 1` moved 131,000 → 230,000 across the same commit. Three findings from that spike
shape what gets built:

- **A login that is a member of both `openledger_app` and `openledger_read` reads every tenant.** RLS
  policies are permissive and OR'd, and `pg_has_role` — not equality — decides which apply, so the
  writer's `USING (true)` unions with the reader's tenant qual and `app.tenant_id` becomes
  decoration. The shipped tree cannot observe this: its one `DATABASE_URL` is the owner's, and the
  owner is not subject to RLS. Hence a second pool on a second login.
- **The cursor pins the amounts, not the row set.** `ledger_accounts`, `chart_versions`,
  `chart_presentation`, `fs_lines`, `account_types` and `ledger_period_closes` carry **no `xact_id`
  column at all**, so one new account added ten balance-sheet rows at a fixed cursor with every
  pre-existing amount byte-identical. The contract promises reproducible amounts and says so.
- **The read path must validate the cursor, because the database cannot.** `'-1'::xid8` silently
  wraps to `18446744073709551615` and returns the entire unpinned book with today's correct numbers;
  SQL `NULL` fabricates the complete face at 0.00, *balanced*, and `recon_equation_breaks(NULL, …)`
  reports zero breaks on it. Both are legal `xid8`.

**And the layer being read is defective in eleven reproduced ways** — [spike
021](/spikes/021-reporting-layer-defects) built each one on a real book with a ten-zero control first.
Two bear directly on this milestone: the three statement functions declare `bigint` in their
`RETURNS TABLE` and cast a `numeric` total back down, so a legal book makes a report **raise** rather
than answer — the inverse of the defect that was reported — and the worst finding needs no adversary
at all: a genuine close whose `ledger_period_closes` row was never inserted reports **0.00 revenue on
a period that earned**, with the balance sheet correct to the unit and `openledger reconcile` exiting
0. Migration `00004` is where those fixes land; `FIX-NOTES.md` in that spike carries each one's cost.

**Done when:** an as-of query at instant T returns the same answer when re-run under concurrent
writes (**proven on the SQL as of 2026-09-01**; still to hold through the compiled binary), the
backdating case (insertion order ≠ effective order) is correct on both axes, and the statement
functions read the checkpoint rather than scanning from inception.

---

# Phase 2 — the reference implementation

Only after Phase 1 holds. A *consumer* of the ledger, not part of it.

## M7 · Cards

`credit_lines`, `spend_controls` and the clearing path — the authorization transaction described in
[card 0001 · authorization holds](/card/decisions/0001-authorization-holds), against a fake processor. Read-only with respect to the ledger: an
authorization writes no entry. The hold model itself is written and **parked** in `parked/card/schema.sql`
([card 0001 · authorization holds](/card/decisions/0001-authorization-holds)); `credit_lines` and `spend_controls` are not,
and nothing reads a limit today.

The [lifecycle trace](/card#the-card-lifecycle) is this milestone's acceptance
test. Not yet covered anywhere, and the real remaining work: forced posts, negative available
credit as a **legal state**, duplicate auths returning the **stored** decision rather than
re-evaluating against a limit that may have moved, and STIP.

**Also here, moved from the decision log** ([0008](/decisions/0008-module-boundaries)): the card
schema is *parked*, not *separated* —
un-parking it is **a new numbered migration creating a `card` schema** (leaving the core in `public` —
the next free number when that day comes, not a reserved one: 00002 went to
[ADR-0003](/decisions/0003-migrations)'s role-race fix), and the
collision test [0008](/decisions/0008-module-boundaries) requires still does not exist. And the
**perimeter-attestation feed** — importing bank statements, network settlement reports and trustee
statements into `perimeter_attestations` so `perimeter_drift` has something to compare — is unowned and
unscheduled ([0012](/decisions/0012-chart-governance)); until it exists, `chart_lint.perimeter_unattested`
fires for every perimeter account.

**Done when:** the trace and its branch cases replay against a fake processor.

## M8 · Durable timers

Hold expiry and the ACH return window are the first two things that genuinely need a timer, which
is why timers enter here and not before. They run **in-process on Postgres**, in the same
transaction as the ledger write, so a hold and its expiry timer commit together or not at all
([card 0001 · authorization holds](/card/decisions/0001-authorization-holds)). Handlers are idempotent already, which the writer gives.
Ship the reconciliation sweep alongside — groups past their deadline that are still holding, behind
`ix_auth_events__hold_expiry` — the deadline is the selective column, not the held amount, and
`ix_hold_groups__held` serves the authorization read instead. The deadline lives on the event, so a
lost job becomes recoverable rather
than silent. **Both of those indexes are in [`parked/card/schema.sql`](/card/parked) and applied by
no migration**, so the sweep query ADR-0001 carries needs the parked file loaded before it can run.

**A scheduler is not a throughput mechanism.** A contended row lock is held for the duration of a
transaction, so making the write asynchronous relocates who waits rather than removing it. Its
place is owning the *sweep* that consolidates suspense accounts, and draining events in batches.

---

## Known work, not yet scheduled

- **Per-row hash chaining** for tamper evidence. Needs a total order, so decide it alongside
  [ADR-0006](/decisions/0006-time-and-as-of). Never build Formance's block-hashing layer.
- **The auth path has never been measured.** It writes no ledger entry and serializes per company,
  so it should scale far better than clearing — but it has a latency deadline rather than a
  throughput target, and gets no claim until it has its own spike.
- **Metadata history**, if metadata ever feeds reporting. Cheapest path is making metadata changes
  *be* event-log entries.
- **Replica identity on every table**, if reporting is ever fed by CDC. Also the precondition for
  moving a tenant between instances with row-filtered logical replication.

## Open questions

Both answered, neither in a hurry when they were asked — and the first answer has since
been reversed:

- **Does v0.1 need an HTTP API?** It does now — **reversed on 2026-08-27**, with the original *no*
  kept below because half of its reasoning still binds. The writer will not ship as a library crate:
  a crate is callable from exactly one language, and the adopter this project wants is anyone who can
  speak HTTP. So **the API is the adoption surface**, and [M3](#m3--the-posting-engine) ships behind
  it as one vertical slice — a `tokio` + `axum` service in the same binary, with the e2e suite
  calling the endpoint over HTTP against a real Postgres and reading `SELECT * FROM reconciliation`
  as its oracle. What the reversal does *not* move is the guarantee:
  [ADR-0005](/decisions/0005-event-log-and-write-path)'s refusal — *"that is a check, not a shape"* —
  still holds, so balance lives in the posting type the handlers deserialize into and the API stays a
  thin mapping over error types the writer names. [ADR-0013](/decisions/0013-write-path-contract)'s
  HTTP semantics — 422 for the poisoned replay, `Idempotency-Replayed: true`, no invented 409 —
  finally get the surface they were specified against. [ADR-0003](/decisions/0003-migrations)'s half
  is unchanged: the service runs against a database the operator already has, and you cannot hide a
  schema that is the product. The OpenAPI story is settled: **`utoipa` core only** — `utoipa-axum` refused on
  its 19-month-stale release and RUSTSEC-2024-0436, `aide` on maintenance and its silent naive
  failure mode — with the spec a committed, snapshot-tested artifact in the spirit of
  [0007](/decisions/0007-schema-conventions-and-chart)'s convention 2
  ([ADR-0014](/decisions/0014-http-api), [spike 017](/spikes/017-openapi-tooling)).
  *(The original answer, for the record: v0.1's surface was to be `openledger migrate` plus a Rust
  crate — the `sqlx-ledger`/`pgledger` shape — revisited only when a consumer not written in Rust
  actually needed to post. The condition fired early because the deciding argument changed: a writer
  only Rust code can call is not a deliverable, and the HTTP boundary is what makes the e2e tests
  caller-shaped.)*
- **How much of the card product belongs in this repository?** All of it that exists, with
  [`parked/`](/card/parked) as the boundary, then a `card` schema, then a migration set only at the
  second rail ([0008](/decisions/0008-module-boundaries)).

## Deliberately not now

- **Sharding across instances.** Striping *within* one instance is the lever that matters, and the
  composite keys in M1 keep the door open.
- **Partitioning by tenant.** Legal on the shipped schema — `PARTITION BY HASH (tenant_id)`
  succeeds on `ledger_entries`, `ledger_transactions` and `ledger_accounts` carrying every
  constraint they actually have, which is precisely what tenant-leading keys bought. Not now
  because there is no in-place `ALTER TABLE` conversion, and it buys per-tenant `DETACH` rather
  than throughput: table size barely affects an append-only workload.
  *(**Caveat added 2026-09-01** — [spike 020](/spikes/020-checkpoint-on-the-report-path): that claim
  needs one, because `ck_journal__no_inherit` refuses a child of any protected table, so the
  statement is not true as written on the shipped schema. And a second, larger one applies to
  partitioning **anything** here: the snapshot test records `relkind`, so converting a table to
  partitioned is visible, but the partition key, the bounds and whether a child is attached are
  dumped nowhere — so one `DETACH PARTITION` removes rows from every reader with the snapshot
  byte-identical ([ADR-0020](/decisions/0020-checkpoint-on-the-report-path) amends
  [0007](/decisions/0007-schema-conventions-and-chart) §2 for it).)*
- **Caching balances.** `posted` is read straight off the ledger. `ledger_account_balances` ships as the write-side serialisation point and an **O(stripes)** read — a `SUM` over the account's rows, one per stripe — so there *is* a second copy: it is rebuildable from the journal, and a drift view is what keeps it honest. *(This read "an O(1) read". The primary key is `(tenant_id, account_id, currency, stripe)`, so a striped account holds many rows and a naive single-row read under-reports the balance — the same correction applied in [the card walkthrough](/card) and [the database page](/database), made live by [ADR-0018](/decisions/0018-batching-and-stripe-selection).)*
- **Multi-currency FX.** The schema carries currency and balances per currency; conversion is a
  separate problem with its own ADR.
- **A scripting language for transactions**, and configurable correctness in any form.
- **Statements, disputes, AP/AR, wallet.** All real, all after the core holds.

## If this ever wants a production story

Not a milestone, and not next — the core has to be built and verified first, and none of that needs
a cloud. When and if a production deployment matters, the deferred items the old RDS-benchmark and
drop-into-AWS milestones carried move from *deferred* to *scheduled*, and their homework is already
done:

- **Measure over a network.** Every number in this repository is from localhost, where a round trip
  costs ~0.05 ms; on RDS it is roughly ten times that, which *reorders* the tuning levers rather than
  merely scaling them — the largest open caveat in the project. Point [spike 003](/spikes/003-throughput-ceiling)'s
  harness at a real RDS DSN, re-run the ladder, and add what localhost cannot show: Multi-AZ
  synchronous replication cost per commit, across instance classes. Until such a measured,
  reproducible number exists for a named instance class — with its method published alongside — no
  throughput figure goes in a README. And the docs must state **which lever applies to which write
  path**: [spike 003](/spikes/003-throughput-ceiling) measured striping *and* batching together at
  2,356 clearings/s against 6,850 for striping alone and 3,338 for batching alone. *(This line
  concluded from those numbers that "recommending both is actively harmful", and the shipped writer
  does not bear that out — **the cancellation does not reproduce on this binary**. Spike 003
  measured it on a bench schema driven by a per-leg posting function; re-measured on the shipped SQL,
  striping under batching is worth **1.42×** and choosing the stripe per member rather than per batch
  costs only **+7.6%** ([spike 018](/spikes/018-batching-and-stripe-selection) §B, retracted at
  length in the M3 bullet above and in [ADR-0002](/decisions/0002-scaling)). Both levers ship
  together. The spike 003 figures stand as what they were — a property of that bench schema, not of
  this design — and what the docs owe an RDS reader is the overlap rule that replaced the warning:
  batching trades lock count for lock hold time and pays only where batch members share accounts.)*
- **Can managed Postgres install the append-only perimeter?** Answered.
  [Spike 015](/spikes/015-managed-postgres-event-triggers) confirmed the baseline's event triggers
  install on **AWS RDS and Aurora PostgreSQL 18** via the master account, and **not** on GCP Cloud
  SQL or Azure Flexible Server — on either, the [0009](/decisions/0009-append-only-perimeter)
  perimeter falls back to the CI snapshot test alone.
- **The role split** ([0009](/decisions/0009-append-only-perimeter)). The event trigger is one
  `DROP FUNCTION … CASCADE` away while the migrator owns the database; 0009 requires a migrator that
  owns the **tables** and not the **database**. Spike 015 confirmed the baseline installs on
  RDS/Aurora via the master account, so the residual is arranging that split **inside** the RDS role
  model — `docker-compose.yml`, `make reset` and `openledger migrate` all still run as one role
  today. A deployment-shape task, not a schema change.

The adoption surface itself — a container image, `docker compose up` for local development, and a
worked deployment example an adopter could point at RDS without reading our source — belongs to the
same someday. The migration runner, the part an adopter actually needs, already exists
([ADR-0003](/decisions/0003-migrations)) — the same binary run with a different command.

---

# Settled framing decisions

Six framing questions where a reasonable person could once have picked either way, now settled — and
kept here as statements rather than questions, below the milestones, because the reasoning that got
there is worth more than the verdict alone. Each names the ADR that owns it. **Everything that once sat in the decision log's open list is now
either a milestone on this roadmap or an accepted cost in the owning ADR — none of it waiting on an
answer here.**

### The baseline was editable until it froze — on 2026-08-27, ahead of v0.1

`migrations/00001_baseline.sql` could be edited in place while no kept database had seen it; every
queued schema fix from [0009](/decisions/0009-append-only-perimeter)–[0013](/decisions/0013-write-path-contract)
landed under that exception and the merged baseline was re-verified end to end. The freeze then came
early: with the merged baseline committed, [ADR-0003](/decisions/0003-migrations)'s own reasoning cut
the exception off before any tag, and the rule is now enforced by CI —
`scripts/check-migrations-immutable.sh` refuses any edit to an existing migration, the baseline
included, with no opt-out. From here every schema change is a new numbered migration.

### The cache means posted

`ledger_account_balances.input`/`output` accumulate POSTED transactions only; `last_seq` advances on
*every* entry, because a pending entry still needs its `account_seq` issued under the same lock
([ADR-0010](/decisions/0010-reconciliation)). "Available" is *derived* as posted plus the enumerated,
aged pending population by `recon_pending_bridge`, never stored — giving one row two definitions is
what this refuses. Available-versus-posted is a holds concept and belongs on the card rail
([card 0001 · authorization holds](/card/decisions/0001-authorization-holds)), not in the core's serialization point.

### RLS guards reads; the writer is admitted, not exempt

Row-level security scopes the read role per tenant and **fails closed** when unscoped; the writer is
admitted by an explicit `USING (true)` policy rather than `BYPASSRLS`
([ADR-0013](/decisions/0013-write-path-contract) §5). The `BYPASSRLS` sketch is overturned on its
mechanism twice: it is ungrantable on RDS and Aurora, and `COPY` — the thing it would have preserved —
is not load-bearing (`INSERT … SELECT FROM unnest(…)` measured within 2% of it, the composite foreign
keys dominating). `trial_balance` carries `security_invoker`, without which a scoped reader was handed
both tenants. [ADR-0001](/decisions/0001-rust-and-postgres)'s "tenant isolation *is* row-level
security" is amended: RLS is a read-path control and does not protect against a compromised writer.

### The core ships a period close, statements, and checkpoints together

All three, in one mechanism, against the original recommendation to defer the close
([ADR-0011](/decisions/0011-period-close-and-report-axes)). The close computes exactly the balances the
checkpoint stores, so writing them is one `INSERT … SELECT` in a transaction already running, and a
`retained_earnings` account that never receives an entry cannot produce a statement of changes in
equity. What it refuses is the *period lock*: a late clearing carrying a closed period's business date
is normal, and the commit cursor makes it harmless to issued reports instead of refusing it —
`close_disclosures` enumerates such arrivals, the analogue of IAS 1.41. The statements are functions of
an effective range and the cursor.

### Per-shard lines and the counterparty axis

A `per_shard` type gets its counterparty in the account key, not netted inside one house account
([ADR-0012](/decisions/0012-chart-governance)). `ck_accounts__per_shard_is_owned` refuses a house
account for any `per_shard` type — one owned account *is* one counterparty (`uq_accounts__owned`) — and
the balance sheet evaluates the position per account, routing an opposite-sign one to its declared
`fs_line_contra`, gross, per IAS 32.42. The 425.00-against-425.00 book prints both sides instead of a
zero. The cross-scope reconciliation groups its pair sum by counterparty so a third scope cannot cancel
a real gap ([ADR-0010](/decisions/0010-reconciliation)).

### The chart is global and versioned

Deployment-global, and VERSIONED rather than frozen, against the original recommendation to freeze
([ADR-0012](/decisions/0012-chart-governance)). IAS 1.41 requires the *same prior period presented
under both mappings at once*, which effective-dating cannot express and freezing forbids, so
presentation moved out of `account_types` into `chart_presentation`, keyed by an append-only
`chart_version`: a reclassification is a new version, never an edit, and an issued statement names the
version it was presented under. The chart stays global — a platform whose tenants are separate
reporting entities needs a database each.

### The running balance (`balance_after`) is dropped

The per-entry running balance is out of the baseline
([spike 009](/spikes/009-where-the-balance-lives)): a running balance is a point-in-time answer on the
*recorded* axis, and every as-of question a business asks is an *effective-date* one, which backfills.
[ADR-0006](/decisions/0006-time-and-as-of)'s read-path table points "now" at
`ledger_account_balances`, and the drift check became *recompute from the entries and compare* — the
first version of that check that is actually independent, since the writer used to compute both numbers
from the same locked row. It leaves the balance cache carrying three jobs — the write lock, the
`account_seq` counter, and the balance.
