# Roadmap

Ordered by what unblocks what, not by size. No estimates — the risk is correctness, and correctness
does not estimate well. **The ledger core is the product**; cards, spend controls and credit lines
are a *reference implementation* built on it
([ADR-0002](/decisions/0002-scaling)). So the core must be verifiable by
strangers before a reference product matters, and the deployment story is part of the product.

---

# Blocked on a decision

Seven questions where a reasonable person could pick either way and no amount of code settles it. Each
one names what it blocks. **Everything else in the [decision log's open
list](/decisions#still-open) is work or a measurement** — real, sometimes ugly, and none of it
waiting on an answer. The two under [Open questions](#open-questions) below block nothing and are
not in a hurry; these seven are.

## 1 · Is `migrations/00001_baseline.sql` frozen, or editable until v0.1?

May the baseline still be edited in place, or does every schema fix land as a new numbered
migration? Nothing runs against a database anyone keeps — but
[ADR-0003](/decisions/0003-migrations) forbids editing an applied migration, and
[ADR-0008](/decisions/0008-module-boundaries) already reasons as though 00001 is frozen: that is why its
`core`/`card` split "has to be re-specified as migration 00002", and why parking the card DDL beat it.

- **Frozen.** Consistent with the rule as written. Every fix below becomes a 00002/00003 patch, so
  the one flat readable file ADR-0003 argues for turns into a file plus a stack of patches before
  anyone has deployed it once.
- **Editable until v0.1 ships, then frozen.** Keeps the baseline the single declarative statement of
  the schema. Costs a written exception to ADR-0003 and a named cut-off.

**Editable until v0.1 — write the exception into ADR-0003 and name the cut-off as the first tagged
release.** A migration nobody has applied to a database anybody keeps is not history, and treating
it as history buys expand/contract discipline at exactly the stage where one readable file is worth
more. Naming the cut-off is what stops the exception drifting.

> **This is now overdue rather than hypothetical.** Dropping `balance_after`
> ([spike 009](/spikes/009-where-the-balance-lives)) was done by editing 00001 in place, on the
> recommendation below. That is the right call for a schema no kept database has ever seen — but it
> is the second time the file has been edited after being applied, and the exception is still not
> written into ADR-0003.

**Blocks:** most of the one-line fixes in the open list — `event_id NOT NULL`, `ENABLE ALWAYS` on
the foreign keys, the stripe column, splitting the balance-sheet side of `fk_types__fs_line`, the
RLS policies, the card-schema move. None of them is hard. All of them are queued behind this.

## 2 · Does the ledger's `pending` inclusion mean "available balance", or is it a bug?

**The question is broader than this heading used to say.** It reads *"the balance cache's `pending`
inclusion"*, which blamed the cache. Measured on this schema with one posted 100.00 and one pending
500.00: the cache says **600.00**, and so does a straight recompute from `ledger_entries` — and so
did the running balance before it was dropped. The statements say 100.00. **No entry-level read
consults `ledger_transactions.status`**, because it is one join away, so this is a property of the
journal's shape rather than a defect in one table. Only the status-aware aggregate matches the
reports, and it is 4–14× the cost ([spike 009](/spikes/009-where-the-balance-lives)).

So a customer served from any cheap read can be shown 600.00 while the balance sheet shows 100.00,
and nothing reconciles the two.

- **Deliberate — it is an available balance.** Then it is a product surface: it needs a name, a
  second pair of columns so posted and available are both readable, and a drift check that compares
  only the posted half against the journal.
- **A bug.** The writer touches the cache on posted transactions only, `input`/`output` mean posted,
  and available balance is computed on the card rail or not at all.

**A bug.** The cache's job is the write lock and the sequence counter
([`database.md`](/database)); making it also mean "available" gives one row two definitions and no
way to check either. Available-versus-posted is a holds concept — a hold is a SUM over an append-only
event log ([ADR-0001](/card/decisions/0001-authorization-holds)) — and it belongs on that rail, not in
the core's serialization point.

**Blocks:** the drift view M2 has to build before it can assert on anything, and the writer's
cache-update rule in M3.

## 3 · Does row-level security guard reads only, with the writer bypassing it?

`COPY FROM` is refused on a table with row-level security, and M3's coalesced batching is a `COPY`.
RLS on `ledger_entries` and bulk batching cannot both be true.

- **A `BYPASSRLS` writer; RLS on the read path.** Batching survives.
  [ADR-0001](/decisions/0001-rust-and-postgres)'s "tenant isolation *is* row-level security" then
  describes half the system and has to be re-worded.
- **RLS everywhere, no `COPY`.** Batching falls back to multi-row `INSERT` at a cost nothing here
  has measured.
- **No RLS.** Tenant isolation is the writer's type plus `tenant_id` leading every key. Cheapest,
  and it withdraws a claim ADR-0001 makes in writing.

**A `BYPASSRLS` writer.** RLS is worth most exactly where a query is easiest to get wrong — a report,
an ad-hoc read, an integrator's query — and worth least on the one code path that is reviewed line
by line and already carries `tenant_id` in every key. Take the option that keeps the cheap guard on
the wide surface, and re-word ADR-0001 rather than pretending it still holds.

**Blocks:** M3.

## 4 · Does the core ship a period close, or since-inception statements?

There is no close, so the balance sheet's earnings plug sums revenue and expense over all posted
history — 34,000.00 against a true current year of 4,000.00 on a three-year book, growing without
bound with the age of the ledger. `retained_earnings` ships in the chart and stays at zero forever
because nothing routes to it. The same close is what would bound
[ADR-0006](/decisions/0006-time-and-as-of)'s effective-axis aggregate, which is linear in history.

- **A real close** — closing entries into `retained_earnings`, a period lock, and a restatement rule
  for an entry backdated into a closed period. It makes this an accounting system rather than a
  ledger, and it is a milestone of its own.
- **Effective-axis checkpoints only** — each account's closing balance materialized per period, for
  the read cost. No closing entries; the statements stay since-inception and honestly captioned.
- **Date parameters on the three reports and nothing else** — the statements become right and the
  aggregate stays unbounded.

**Date parameters first, checkpoints second, the real close deferred.** The parameters fix a wrong
number on a report someone would issue; the checkpoints fix a cost nobody has hit yet; the close
brings a period lock, and a lock on a ledger that has not yet written its first transaction through
its own writer is a rule with nothing to enforce. Say in ADR-0007 that the close is deferred and
which of the two halves M5 is buying.

**Blocks:** M5, on both halves — the reports and the aggregate bound.

## 5 · Does an account get a counterparty, or do per-shard lines print net?

`uq_accounts__house` is `(tenant_id, purpose, currency)`, so there is exactly one `due_to_tenants`
account and opposite-sign positions net **inside the account**, before any report sees them: owing t1
425.00 while t2 owes 425.00 prints a payables line of zero — reproduced on the shipped schema.
`counterparty_scope` declares this un-nettable and no view reads it.

- **Counterparty in the account key** — relax `uq_accounts__house` to carry it, and add the paired
  asset type so a net-debit counterparty has a line to report under. Correct, and it needs a
  reporting-date reclassification rule, which only exists once question 4 is answered.
- **Counterparty on the entry, grouped at report time.** Cheaper, and it still has nowhere to put a
  debit position: a negative liability prints on the liability side.
- **Leave it and disclose** that per-shard lines are net, with the gross figures in `trial_balance`.
  Free, and it is the presentation IAS 32.42 does not permit.

**Counterparty in the account key — and decide it alongside question 4, not before.** It is the only
option that puts each position on the side it belongs to, and the reclassification it needs is the
same machinery a period close brings. Until then the honest thing is to record that the line is net.

**Blocks:** nothing before M5 — but it is part of the period close's design, so answering 4 without
it means designing the close twice.

## 6 · Is the chart deployment-global and frozen under posted history, or per-tenant and versioned?

Two open entries, one question. `fs_lines` and `account_types` carry no `tenant_id` and are keyed on
`code` alone, so per-tenant charts are unrepresentable and one tenant's reclassification restates
every tenant's issued statements. And nothing versions the chart: a move to another line of the same
statement and side is accepted under posted history — `fbo_cash` from restricted cash to cash put
440.00 of customer float into unrestricted liquidity in one statement, no error.

- **Global and frozen.** The chart is deployment configuration; a change is a migration and a
  restatement, which IAS 1.41 requires anyway. Cheapest — and a deployment whose tenants are
  different businesses cannot exist.
- **Global and versioned.** Effective-dated chart rows; a report resolves the chart as of its own
  date, so an issued statement stays reproducible. A feature, not a fix.
- **Per-tenant.** `tenant_id` in both chart tables and in the two composite foreign keys. It gives
  up the deployment-global design ADR-0007 argues for and puts a chart join in every report.

**Global and frozen, with the restatement rule written down.** The tenants this schema is built for
are scopes of one business — `operating_cash` mirrors one real bank account — and that is what
tenant-locality already assumes. Versioning is the right answer later and it is a chart-history
feature; freezing is what makes the reclassification hole a stated limitation instead of a silent
one.

**Blocks:** ADR-0007's open reclassification cost, and the second reclassification route through
`fk_accounts__type` — both stay open while this does.

---

**Recently answered, and no longer waiting on you:** *does `balance_after` survive striping?*
**No — the column is dropped.** [Spike 009](/spikes/009-where-the-balance-lives) has the argument
and the prior art; the short version is that a running balance is a point-in-time answer on the
*recorded* axis, and every as-of question a business asks is an *effective-date* one, which
backfills. It was correct about an axis nobody queries. Striping was the prompt, not the reason.

In the tree: the column and `ix_entries__balance_lookup` are out of
`migrations/00001_baseline.sql` — the index was a straight duplicate of `uq_entries__account_seq`
once its `INCLUDE` payload went — [ADR-0006](/decisions/0006-time-and-as-of)'s read-path table now
points "now" at `ledger_account_balances`, and the drift check became *recompute from the entries
and compare*, which is the first version of that check that is actually independent: the writer used
to compute both numbers from the same locked row. It leaves the balance cache carrying three jobs
alone — the write lock, the `account_seq` counter, and the balance — which is the
[decision log's](/decisions#still-open) row to close, not a question for you.

---

# Phase 1 — the core

## M0 · Validating the decisions — **done, and deleted**

A SQL implementation and its conformance suite proved the design and then outgrew it. Ten
adversarial rounds found real defects, several of which under-reserved credit; those findings are
recorded in [ADR-0007](/decisions/0007-schema-conventions-and-chart),
[ADR-0001](/card/decisions/0001-authorization-holds) and
[ADR-0004](/decisions/0004-where-logic-lives). It has been deleted, and
[ADR-0004](/decisions/0004-where-logic-lives) is why. **The same assertions come back as Rust
tests, after M1.**

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
`OPENLEDGER_MIGRATE_LOCK_SECS` to change it). It applies the baseline to an empty database.
***Idempotent on re-run* is unverified.** The tests in `src/migrate.rs` assert that the set carries
no down migration and that a `-- no-transaction` migration holds exactly one statement; neither
touches a database, and nothing in this tree runs the command twice.

**The card hold model is parked**, in [`parked/card/`](/card/parked), and applied by
no migration. Its design ([ADR-0001](/card/decisions/0001-authorization-holds)) stands; the DDL waits
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

**Striping — not built.** An account would declare a stripe count and a balance read would `SUM`
across stripes. There is no such column, and `uq_accounts__house` makes it impossible anyway, since
`network_settlement_payable` cannot have a second row under `UNIQUE (tenant_id, purpose,
currency)`. Worth roughly 8×, and it is *striping* that removes contention, not per-tenant
splitting: at 90/10 skew per-tenant accounts gave 1.07× while striping still gave 7.8× ([spike
003](/spikes/003-throughput-ceiling)).

**Done when:** the schema snapshot test is in CI, and striping exists. *(The migration runner is
done; the snapshot test [ADR-0007](/decisions/0007-schema-conventions-and-chart) calls the
highest-leverage item here is still the gap.)*

## M2 · The concurrency proof

The mechanism is settled: a per-(account, currency) balance row, updated by [one atomic
upsert](/database) returning **both** the new balance and the next sequence number, so the row lock
*is* the serialization point — no `SELECT max()`, no advisory lock, no retry loop. `tenant_id` leads
the conflict target because it leads the primary key; without it the statement does not run at all.
Three traps:

- **It holds only under READ COMMITTED.** Stricter isolation makes `ON CONFLICT DO UPDATE` fail
  with `could not serialize access due to concurrent update` — a property of Postgres, not of this
  workload. It fails closed, so nothing corrupts, but a deployment that sets a stricter default
  silently loses most of its writes, and a retry loop does not rescue it. *How many is
  **unmeasured** — no harness in this tree varies an isolation level.*
- **Deterministic lock ordering, batch-wide.** Sort accounts by id on both paths. [Spike
  003](/spikes/003-throughput-ceiling) found that sorting within a single clearing does
  *not* order locks across a batch — throughput collapsed 10× into deadlocks. A test that does not
  fail when the sort is removed is not testing the sort, and it needs more than two accounts: with
  two, the planner emits the legs in account order for free and no deadlock can be produced at all.
- **The first-entry race does not apply to the upsert form.** The warning is real for
  `SELECT … FOR UPDATE` — you cannot lock a row that does not exist — but
  `INSERT … ON CONFLICT DO UPDATE` *is* the insert-and-lock, so there is no gap to race through.

**Done when:** N writers against overlapping account sets, half posting their legs in reverse
order, produce zero deadlocks, gapless per-account sequences and balanced transactions — **with
batching enabled**, which does not exist yet. Batch-wide ordering is the harder half of this
milestone and is untested. **Zero drift views are deployed**: the ledger-side ones were deleted with
[ADR-0004](/decisions/0004-where-logic-lives), and the only replacement ever written,
`card_hold_drift`, is parked with the rest of the card module. So this milestone has to build the
view it wants to assert on, or say it is not checking drift.

## M3 · The posting engine

Given a balanced set of entries and an idempotency key: post atomically or return the stored
result. Pending → posted is a **new** transaction with `resolves_id`, never an UPDATE. Three design
constraints, not later optimizations:

- **Coalesced batching.** N postings to one account collapse into a single upsert advancing the
  balance by the total and `last_seq` by the count; each entry's running balance is derived by
  walking backwards from the returned totals. This is the only batching that does not deadlock.
- **Single-call posting.** The whole operation in one server-side call rather than six round trips
  — worth ~14% on localhost, decisive on RDS where five saved round trips cost ~2.5 ms against
  ~1.3 ms of real work ([spike 003](/spikes/003-throughput-ceiling)).
- **Striping and batching must not both be applied blindly.** Random stripe selection makes them
  *cancel*, measured worse than either alone; tenant- or worker-affinity selection composes.

**Decision needed: `COPY FROM` is not supported on tables with row-level security** —
`ERROR: COPY FROM not supported with row-level security` on PG 18.6
([spike 004](/spikes/004-chart-of-accounts)). Coalesced batching uses `CopyFrom`, so
RLS on `ledger_entries` and bulk batching are mutually exclusive. Likely resolution is posting as a
`BYPASSRLS` role so RLS guards only the read path — but it must be decided, not discovered.

**Done when:** M0's conformance suite, rebuilt in Rust, passes under concurrent load, with and
without batching, and with striping on and off.

## M4 · The RDS benchmark

**Nothing has been measured over a network**, and that is the largest open caveat in the project.
Every number is from localhost, where a round trip costs 0.05 ms; on RDS it is roughly ten times
that, which *reorders* the tuning levers rather than merely scaling them. This comes before
bitemporal reads because it is **unblocked** — it needs only M3 and a DSN — while M5 is blocked on
an open decision. Point spike 003's harness at real RDS, re-run the ladder, and add what localhost
cannot show: Multi-AZ synchronous replication cost per commit, across instance classes.

**Done when:** a measured, reproducible number for a named instance class, with its method
published alongside. Only then does any throughput figure go in a README.

## M5 · Bitemporal reads

Two axes, two mechanisms ([ADR-0006](/decisions/0006-time-and-as-of)): the current balance is a
primary-key read of `ledger_account_balances`, recorded-axis and business-date balances are
aggregates over `recorded_at` and `effective_at` respectively, and every reporting function names
its axis explicitly.

**Blocked on the as-of cursor in [ADR-0006](/decisions/0006-time-and-as-of) — the ADR is accepted; the cursor is not built.** `recorded_at`
defaults to transaction *start* time and is not monotonic with commit order, so the same as-of
query can return different answers when re-run; a reproducible cursor must be commit-ordered.
Decide that before writing code against `recorded_at <= :as_of`. The effective-axis aggregate is
also unbounded, growing linearly with history at a cost that is **unmeasured**; period-close
checkpoints are the bound, so a business-date query reads "prior close + entries since".

**Done when:** an as-of query at instant T returns the same answer when re-run under concurrent
writes, and the backdating case (insertion order ≠ effective order) is correct on both axes.

## M6 · Drop it into AWS

The adoption surface: a container image and migration runner an adopter can point at RDS without
reading our source. **The runner is the part that exists** — `src/migrate.rs`, ADR-0003, the same
binary run with a different command. What is missing is everything around it: the image,
`docker compose up` for local development, already half-done; a worked deployment example; and
documentation stating **which throughput lever applies to which write path**. Recommending both is
actively harmful — [spike 003](/spikes/003-throughput-ceiling) measured the combination
at 2,356 clearings/s against 6,850 for striping alone and 3,338 for batching alone.

**Done when:** someone who has never seen this repository can stand up a working ledger against RDS
from the README alone.

---

# Phase 2 — the reference implementation

Only after Phase 1 holds. A *consumer* of the ledger, not part of it.

## M7 · Cards

`credit_lines`, `spend_controls` and the clearing path — the authorization transaction described in
[ADR-0001](/card/decisions/0001-authorization-holds), against a fake processor. Read-only with respect to the ledger: an
authorization writes no entry. The hold model itself is written and **parked** in `parked/card/schema.sql`
([ADR-0001](/card/decisions/0001-authorization-holds)); `credit_lines` and `spend_controls` are not,
and nothing reads a limit today.

The [lifecycle trace](/card#the-card-lifecycle) is this milestone's acceptance
test. Not yet covered anywhere, and the real remaining work: forced posts, negative available
credit as a **legal state**, duplicate auths returning the **stored** decision rather than
re-evaluating against a limit that may have moved, and STIP.

**Done when:** the trace and its branch cases replay against a fake processor.

## M8 · Durable timers

Hold expiry and the ACH return window are the first two things that genuinely need a timer, which
is why timers enter here and not before. They run **in-process on Postgres**, in the same
transaction as the ledger write, so a hold and its expiry timer commit together or not at all
([ADR-0001](/card/decisions/0001-authorization-holds)). Handlers are idempotent already, which M3 gives.
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
- **The suspense sweep** for affinity striping. Workflow-shaped, so it wants M8.
- **The auth path has never been measured.** It writes no ledger entry and serializes per company,
  so it should scale far better than clearing — but it has a latency deadline rather than a
  throughput target, and gets no claim until it has its own spike.
- **Metadata history**, if metadata ever feeds reporting. Cheapest path is making metadata changes
  *be* event-log entries.
- **Replica identity on every table**, if reporting is ever fed by CDC. Also the precondition for
  moving a tenant between instances with row-filtered logical replication.

## Open questions

- **Does v0.1 need an HTTP API, or is a Rust crate plus migrations enough to adopt?** The API is
  the adoption surface for anyone not writing Rust. Deferred, but no longer obviously so.
- **How much of the card product belongs in this repository?** A reference implementation argues
  for keeping it; a clean core argues for a separate module. Not urgent until M7.

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
