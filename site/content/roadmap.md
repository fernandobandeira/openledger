# Roadmap

Ordered by what unblocks what, not by size. No estimates — the risk is correctness, and correctness
does not estimate well. **The ledger core is the product**; cards, spend controls and credit lines
are a *reference implementation* built on it
([ADR-0002](/decisions/0002-scaling)). So the core must be verifiable by strangers before a reference
product matters.

**The schema is applied and verified; almost none of the Rust exists.**
`migrations/00001_baseline.sql` and `openledger migrate` are built and run in CI. The writer that
posts against that schema is not, and neither is the read path over it. That gap — not a deployment —
is the story now. Phase 1 is the ordered list of code to build to close it.

---

# Phase 1 — the core

**The build order.** The schema is done; what is missing is the Rust, in dependency order:

1. **The writer** ([M3](#m3--the-posting-engine)) — the posting API that is balanced by
   construction, the two-statement idempotency replay, the posted-only cache update and the
   transaction seal. The single largest gap between the design and the tree, and it unblocks
   everything below. **This is the immediate next step.**
2. **`openledger reconcile`** ([M2](#m2--openledger-reconcile-and-the-concurrency-proof)) — wire the
   ten reconciliation views to an exit code so the daily sweep is a real command. The views already
   ship in the baseline; the command does not.
3. **The stripe-picking writer** ([M3](#m3--the-posting-engine)) and **the CI schema-snapshot test**
   (M1, below) — stripe selection on the write path, and [0007](/decisions/0007-schema-conventions-and-chart)'s
   highest-leverage unbuilt guard against schema drift.
4. **The as-of read path** ([M5](#m5--bitemporal-reads)) — a Rust read path over the report
   functions, correct on both time axes.

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

## M1 · Schema, invariants, and the snapshot test — **schema and migration runner landed**

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
runs it twice. The tests in `src/migrate.rs`
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
The writer that picks a stripe is M3's.

**Done when:** the schema snapshot test is in CI, and striping exists. *(The migration runner is
done; striping's schema is applied; the snapshot test [ADR-0007](/decisions/0007-schema-conventions-and-chart)
calls the highest-leverage item here is still the gap.)* The snapshot's charge was widened for the
[0009](/decisions/0009-append-only-perimeter) owner-accident DDL class it is the only backstop for:
beyond `pg_trigger.tgenabled` / `pg_event_trigger.evtenabled`, `pg_policy` and view `reloptions`, it
must dump `pg_class.relrowsecurity`/`relforcerowsecurity`, `pg_get_viewdef` for every view,
`account_types.is_perimeter`/`mirror_type`, and the full `pg_constraint` set
([ADR-0007](/decisions/0007-schema-conventions-and-chart) §2).

## M3 · The posting engine

**This is the immediate next step — the single largest gap between the design and the tree, and it
unblocks everything else in Phase 1.** Given a balanced set of entries and an idempotency key: post
atomically or return the stored result. Pending → posted is a **new** transaction with
`resolves_id`, never an UPDATE. Three design constraints, not later optimizations:

- **Coalesced batching.** N postings to one account collapse into a single upsert advancing the
  balance by the total and `last_seq` by the count; each entry's running balance is derived by
  walking backwards from the returned totals. This is the only batching that does not deadlock.
- **Single-call posting.** The whole operation in one server-side call rather than six round trips
  — worth ~14% on localhost, and worth more the higher round-trip latency climbs, where five saved
  round trips cost ~2.5 ms against ~1.3 ms of real work ([spike 003](/spikes/003-throughput-ceiling)).
- **Striping and batching must not both be applied blindly.** Random stripe selection makes them
  *cancel*, measured worse than either alone; tenant- or worker-affinity selection composes. The
  stripe-picking writer is the third build step above.

**Decided: RLS and batching are not mutually exclusive, and the `BYPASSRLS` sketch is refused**
([ADR-0013](/decisions/0013-write-path-contract) §5, answering the [settled RLS framing decision](#rls-guards-reads-the-writer-is-admitted-not-exempt)
above). `unnest`-based multi-row `INSERT` measured within 2% of `COPY` on `ledger_entries` at
25–10,000 rows — the composite foreign keys dominate, not the wire format — and `BYPASSRLS` cannot
be granted on RDS or Aurora at all. The writer posts under an explicit admit-all policy; RLS scopes
the read role.

**Done when:** M0's conformance suite, rebuilt in Rust, passes under concurrent load, with and
without batching, and with striping on and off.

## M2 · `openledger reconcile` and the concurrency proof

Two things live here: a command that is buildable now, and a proof that waits on the writer above.

**Buildable now — the `openledger reconcile` subcommand.** The ten reconciliation views ship in
`migrations/00001_baseline.sql`, but nothing runs them: `src/main.rs` carries only `migrate` today.
The command is the same binary and shape as `openledger migrate` ([ADR-0010](/decisions/0010-reconciliation)),
running the reconciliation views once a day in one `REPEATABLE READ READ ONLY` transaction as
`openledger_recon` and turning `SELECT * FROM reconciliation` into an exit code. The views exist; the
command that schedules them does not. [ADR-0010](/decisions/0010-reconciliation) specifies the layer,
every drift class was reproduced and caught with a clean-book negative control
([spike 011](/spikes/011-reconciliation)).

**The concurrency proof — waits on M3's writer and batching.** The mechanism is settled: a
per-(account, currency) balance row, updated by [one atomic upsert](/database) returning **both** the
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

**Done when:** the reconcile command runs the views to an exit code, and — once the writer and
batching exist — N writers against overlapping account sets, half posting their legs in reverse
order, produce zero deadlocks, gapless per-account sequences and balanced transactions **with
batching enabled**. Batch-wide ordering is the harder half and is untested. The acceptance test is
`SELECT * FROM reconciliation` returning ten zeros under concurrent load, with batching on.

## M5 · Bitemporal reads

Two axes, two mechanisms ([ADR-0006](/decisions/0006-time-and-as-of)): the current balance is a
primary-key read of `ledger_account_balances`, recorded-axis and business-date balances are
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
from inception, and the checkpoint's only reader is `recon_checkpoint_breaks` ([spike 020](/spikes/016-close-cost-at-scale)).

**Make the checkpoint pay for itself** (moved here from the decision log): teach `balance_sheet_at` to
read `ledger_period_balances` plus the two tails, partition the checkpoint by period, and bound
`recon_checkpoint_breaks`' per-close prefix scan — it is O(entries × closes) today (1 : 3.2 : 5.8 : 8.2
over 3/6/9/12 closes), re-aggregating the whole prefix per close ([spike 020](/spikes/016-close-cost-at-scale)).
And the close's own cost is now measured: **linear in account count and per currency** (~49 s and
1,000,003 checkpoint rows / 135 MB to close 1 M accounts in one currency), and the **write dominates
(~96%)** — one row per account plus PK/FK maintenance — not the aggregation (~4%).

**Done when:** an as-of query at instant T returns the same answer when re-run under concurrent
writes, the backdating case (insertion order ≠ effective order) is correct on both axes, and the
statement functions read the checkpoint rather than scanning from inception.

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
un-parking it is **migration 00002 creating a `card` schema** (leaving the core in `public`), and the
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

Both answered, neither in a hurry when they were asked:

- **Does v0.1 need an HTTP API?** No — v0.1's adoption surface is `openledger migrate`, the schema
  it applies, and a Rust crate once [M3](#m3--the-posting-engine)'s writer exists. The split in the
  field is not "API or no API" but *who owns the database*, and [ADR-0003](/decisions/0003-migrations)
  answered that before the question was asked: the command runs against a database the operator
  already has, and you cannot hide a schema that is the product. [ADR-0005](/decisions/0005-event-log-and-write-path)
  already refused the API as a place a guarantee can live — *"that is a check, not a shape"* — and
  there is no `src/lib.rs` to put an API in front of yet. The shape is not hypothetical: `sqlx-ledger`
  (Galoy, in production) and `pgledger` ship exactly it, a Rust crate handing the adopter its
  migrations. **Revisit when both hold: M3 exists, and a consumer that is not written in Rust actually
  needs to post** — a fact about the world, not a date. This is build order, not an invariant, which
  is why it lives here and not in the decision log.
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
- **Caching balances.** `posted` is read straight off the ledger. `ledger_account_balances` ships as the write-side serialisation point and an O(1) read, so there *is* a second copy — it is rebuildable from the journal, and a drift view is what keeps it honest.
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
  2,356 clearings/s against 6,850 for striping alone and 3,338 for batching alone, so recommending
  both is actively harmful.
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

### The baseline is editable until v0.1

`migrations/00001_baseline.sql` may be edited in place until the first tagged release, then it
freezes; the exception is written into [ADR-0003](/decisions/0003-migrations) with that cut-off named.
A migration no kept database has ever seen is not history, and one flat readable file is worth more
than a file plus a stack of patches at this stage. Every queued schema fix from
[0009](/decisions/0009-append-only-perimeter)–[0013](/decisions/0013-write-path-contract) landed under
that exception and the merged baseline was re-verified end to end.

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
