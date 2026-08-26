# Roadmap

Ordered by what unblocks what, not by size. No estimates — the risk is correctness, and correctness
does not estimate well. **The ledger core is the product**; cards, spend controls and credit lines
are a *reference implementation* built on it
([ADR-0002](./decisions/0002-scaling.md)). So the core must be verifiable by
strangers before a reference product matters, and the deployment story is part of the product.

---

# Phase 1 — the core

## M0 · Validating the decisions — **done, and deleted**

A SQL implementation and its conformance suite proved the design and then outgrew it. Ten
adversarial rounds found real defects, several of which under-reserved credit; those findings are
recorded in [ADR-0007](./decisions/0007-schema-conventions-and-chart.md),
[ADR-0008](./decisions/0008-authorization-holds.md) and
[ADR-0004](./decisions/0004-where-logic-lives.md). It has been deleted, and
[ADR-0004](./decisions/0004-where-logic-lives.md) is why. **The same assertions come back as Rust
tests, after M1.**

## M1 · Schema, invariants, and the snapshot test — **schema landed**

[`schema/schema.sql`](../schema/schema.sql) is the core — `ledger_accounts`,
`ledger_transactions`, `ledger_entries`, `ledger_account_balances`, `ledger_events` — plus the
chart of accounts and completeness layer ([ADR-0007](./decisions/0007-schema-conventions-and-chart.md))
and the hold model ([ADR-0008](./decisions/0008-authorization-holds.md)). Eleven tables, 5 report
views, 8 triggers over 2 functions each justified in place per
[ADR-0004](./decisions/0004-where-logic-lives.md). It was written by hand rather than promoted from
the spikes, which held three competing posting engines and two competing hold models. No API, no service code
beyond migrations. Balanced-per-currency is deliberately *not* in there: it belongs to the writer
([0005](./decisions/0005-event-log-and-write-path.md)).

**Tenant-leading keys were the one irreversible decision on the list, and they were free.** Every
ledger table carries `tenant_id NOT NULL`, primary keys are `(tenant_id, id)`, and every index and
foreign key on those tables carries the prefix — the prerequisite for row-level security,
partitioning and ever splitting across instances, all expensive to retrofit. A widely-cited
sharding post-mortem named exactly this omission as its regret; **which company is unverified** —
no source for the attribution exists in this tree, and the mechanics are the load-bearing part.
The chart's two foreign keys deliberately lack the prefix because the chart is
deployment-global, so a tenant cannot add an account type without a migration — a real limitation, listed in ADR-0007. Tenant-locality follows
from the same keys and is a conformance property: `operating_cash` mirrors one real bank account
and cannot be per-tenant, so treasury movements split into a `due_from_treasury` /
`due_to_tenants` pair rather than one transaction that leaves a tenant's own books short by the
full amount ([measured](../spikes/004-chart-of-accounts/README.md)).

**Striping — not built.** An account would declare a stripe count and a balance read would `SUM`
across stripes. There is no such column, and `uq_accounts__house` makes it impossible anyway, since
`network_settlement_payable` cannot have a second row under `UNIQUE (tenant_id, purpose,
currency)`. Worth roughly 8×, and it is *striping* that removes contention, not per-tenant
splitting: at 90/10 skew per-tenant accounts gave 1.07× while striping still gave 7.8× ([spike
003](../spikes/003-throughput-ceiling/README.md)).

**Done when:** the schema snapshot test is in CI, and striping exists.

## M2 · The concurrency proof

The mechanism is settled. A per-(account, currency) balance row, updated by one atomic upsert
returning **both** the new balance and the next sequence number:

```sql
INSERT INTO ledger_account_balances AS b (tenant_id, account_id, currency, input, output, last_seq)
VALUES (...)
ON CONFLICT (tenant_id, account_id, currency) DO UPDATE
   SET input    = b.input  + excluded.input,
       output   = b.output + excluded.output,
       last_seq = b.last_seq + 1
RETURNING b.last_seq, b.input - b.output;
```

The row lock *is* the serialization point — no `SELECT max()`, no advisory lock, no retry loop.
`tenant_id` leads the conflict target because it leads the primary key; without it the statement
does not run at all. Three traps:

- **It holds only under READ COMMITTED.** Stricter isolation makes `ON CONFLICT DO UPDATE` fail
  with `could not serialize access due to concurrent update` — a property of Postgres, not of this
  workload. It fails closed, so nothing corrupts, but a deployment that sets a stricter default
  silently loses most of its writes, and a retry loop does not rescue it. *How many is
  **unmeasured** — no harness in this tree varies an isolation level.*
- **Deterministic lock ordering, batch-wide.** Sort accounts by id on both paths. [Spike
  003](../spikes/003-throughput-ceiling/README.md) found that sorting within a single clearing does
  *not* order locks across a batch — throughput collapsed 10× into deadlocks. A test that does not
  fail when the sort is removed is not testing the sort, and it needs more than two accounts: with
  two, the planner emits the legs in account order for free and no deadlock can be produced at all.
- **The first-entry race does not apply to the upsert form.** The warning is real for
  `SELECT … FOR UPDATE` — you cannot lock a row that does not exist — but
  `INSERT … ON CONFLICT DO UPDATE` *is* the insert-and-lock, so there is no gap to race through.

**Done when:** N writers against overlapping account sets, half posting their legs in reverse
order, produce zero deadlocks, gapless per-account sequences, balanced transactions and empty drift
views — **with batching enabled**, which does not exist yet. Batch-wide ordering is the harder half
of this milestone and is untested.

## M3 · The posting engine

Given a balanced set of entries and an idempotency key: post atomically or return the stored
result. Pending → posted is a **new** transaction with `resolves_id`, never an UPDATE. Three design
constraints, not later optimizations:

- **Coalesced batching.** N postings to one account collapse into a single upsert advancing the
  balance by the total and `last_seq` by the count; each entry's running balance is derived by
  walking backwards from the returned totals. This is the only batching that does not deadlock.
- **Single-call posting.** The whole operation in one server-side call rather than six round trips
  — worth ~14% on localhost, decisive on RDS where five saved round trips cost ~2.5 ms against
  ~1.3 ms of real work ([spike 003](../spikes/003-throughput-ceiling/README.md)).
- **Striping and batching must not both be applied blindly.** Random stripe selection makes them
  *cancel*, measured worse than either alone; tenant- or worker-affinity selection composes.

**Decision needed: `COPY FROM` is not supported on tables with row-level security** —
`ERROR: COPY FROM not supported with row-level security` on PG 18.6
([spike 004](../spikes/004-chart-of-accounts/README.md)). Coalesced batching uses `CopyFrom`, so
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

Two axes, two mechanisms ([ADR-0006](./decisions/0006-time-and-as-of.md)): current and
recorded-axis balances come from `balance_after`, business-date balances aggregate over
`effective_at`, and every reporting function names its axis explicitly.

**Blocked on the as-of cursor in [ADR-0006](./decisions/0006-time-and-as-of.md) — the ADR is accepted; the cursor is not built.** `recorded_at`
defaults to transaction *start* time and is not monotonic with commit order, so the same as-of
query can return different answers when re-run; a reproducible cursor must be commit-ordered.
Decide that before writing code against `recorded_at <= :as_of`. The effective-axis aggregate is
also unbounded, growing linearly with history at a cost that is **unmeasured**; period-close
checkpoints are the bound, so a business-date query reads "prior close + entries since".

**Done when:** an as-of query at instant T returns the same answer when re-run under concurrent
writes, and the backdating case (insertion order ≠ effective order) is correct on both axes.

## M6 · Drop it into AWS

The adoption surface, and the milestone that decides whether any of the above gets used: a
container image and migration runner an adopter can point at RDS without reading our source;
`docker compose up` for local development, already half-done; a worked deployment example; and
documentation stating **which throughput lever applies to which write path**. Recommending both is
actively harmful — [spike 003](../spikes/003-throughput-ceiling/README.md) measured the combination
at 2,356 clearings/s against 6,850 for striping alone and 3,338 for batching alone.

**Done when:** someone who has never seen this repository can stand up a working ledger against RDS
from the README alone.

---

# Phase 2 — the reference implementation

Only after Phase 1 holds. A *consumer* of the ledger, not part of it.

## M7 · Cards

`credit_lines`, `spend_controls` and the clearing path — the authorization transaction described in
[ADR-0008](./decisions/0008-authorization-holds.md), against a fake processor. Read-only with respect to the ledger: an
authorization writes no entry. The hold model itself is already in `schema/schema.sql`
([ADR-0008](./decisions/0008-authorization-holds.md)); `credit_lines` and `spend_controls` are not,
and nothing reads a limit today.

The [lifecycle trace](./reference-product.md#the-card-lifecycle) is this milestone's acceptance
test. Not yet covered anywhere, and the real remaining work: forced posts, negative available
credit as a **legal state**, duplicate auths returning the **stored** decision rather than
re-evaluating against a limit that may have moved, and STIP.

**Done when:** the trace and its branch cases replay against a fake processor.

## M8 · Durable timers

Hold expiry and the ACH return window are the first two things that genuinely need a timer, which
is why timers enter here and not before. They run **in-process on Postgres**, in the same
transaction as the ledger write, so a hold and its expiry timer commit together or not at all
([ADR-0008](./decisions/0008-authorization-holds.md)). Handlers are idempotent already, which M3 gives.
Ship the reconciliation sweep alongside — groups past their deadline that are still holding, behind
`ix_auth_events__hold_expiry` — the deadline is the selective column, not the held amount, and
`ix_hold_groups__held` serves the authorization read instead. The deadline lives on the event, so a
lost job becomes recoverable rather
than silent; ADR-0008 has the query, executed against the shipped schema.

**A scheduler is not a throughput mechanism.** A contended row lock is held for the duration of a
transaction, so making the write asynchronous relocates who waits rather than removing it. Its
place is owning the *sweep* that consolidates suspense accounts, and draining events in batches.

---

## Known work, not yet scheduled

- **Per-row hash chaining** for tamper evidence. Needs a total order, so decide it alongside
  [ADR-0006](./decisions/0006-time-and-as-of.md). Never build Formance's block-hashing layer.
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
