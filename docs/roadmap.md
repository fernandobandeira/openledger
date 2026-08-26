# Roadmap

Ordered by what unblocks what, not by size. No estimates — the risk here is correctness, and
correctness does not estimate well.

**The ledger core is the product.** Cards, spend controls, and credit lines are a *reference
implementation* built on it ([ADR-0007](./decisions/0007-open-source-positioning.md)). So the core
must be verifiable by strangers before a reference product matters, and the deployment story is
part of the product — something unrunnable is not adoptable, however correct it is.

---

# Phase 1 — the core

## M0 · The conformance suite — **mostly done**

[`tests/`](../tests/) exists and runs against a throwaway database via `make test-sql`:
a full card lifecycle asserted state-by-state, the hold flow, both time axes, query-plan
assertions, a concurrency suite, and every deliberate breakage we can think of — each of which must
be refused, and refused for the stated reason. Writing it, and the adversarial rounds since, found defects in every part of the design — several of
which under-reserved credit. [ADR-0010](./decisions/0010-authorization-holds.md) and
[ADR-0011](./decisions/0011-what-the-database-enforces.md) record them. *No count is given here
because it would be stale within the day.*

One design note, learned the hard way: **counting errors is not a pass criterion.** An earlier
suite expected "seven failures" and got eight, and the extra one was a *different* invariant
failing for an unrelated reason. Every assertion names what it asserts, and every refusal checks
the reason, not merely that something was refused.

**The suite is measured by mutation, not by size.** Six adversarial rounds have asked the only
question that separates a test suite from a transcript: change the schema so it is wrong, and does
anything fail? The last round found 58 mutants that survived, including the whole pending/posted
lifecycle. They are closed, each verified by re-running its mutation.

Three of the escapes found were in the harness itself, and those matter most, because they make
every other result meaningless: the assertion floor counted *output* rather than assertions, so
prepending fake notices and quitting early passed for all five files; `concurrency.sh` was outside
both the manifest and the floor, so replacing its body with `exit 0` printed PASS; and
`session_replication_role` leaked out of one `DO` block to the end of `negative_controls.sql`, so
two hundred lines of controls ran on the replication apply path *only*. Each is now closed by
something that fails loudly.

**And the harness had to be fixed twice.** After the first round of fixes, an audit replaced
`card_holds.sql` — the only evidence for the entire hold flow — with **five lines**
that raise 160 notices in a loop and print the completion sentinel. The build said PASS. So did
replacing `concurrency.sh` with four lines of `echo`. Every guard was reading output the file
printed *about itself*: the manifest checks existence, the floor counts notices, the sentinel is a
string the file emits. The fix is to count assertion **call sites in the source** — a stub that
prints 160 `ok`s has two — and to keep the floors exact rather than slack, because seven
assertions of headroom turned out to be exactly enough to delete the three most recently added
controls and walk a live mutant back in.

The general lesson, which is the reason this is in the roadmap and not only in a test comment:
**a test suite that grades itself grades nothing.** Every check on a suite has to read something
the suite cannot produce.

Still open: putting it in CI, and the
[ADR-0006 schema snapshot test](./decisions/0006-schema-conventions.md).

The properties the core must hold, at any point, against any history:

- Every transaction balances, per currency.
- Every `balance_after` equals the recomputation from its entries.
- Per-account sequences are gapless and duplicate-free.
- Replaying an idempotency key returns the stored result; a different body is refused.
- An as-of query at instant T returns the same answer whenever it is re-run.
- **No transaction's entry set spans more than one tenant.** New, and load-bearing — see M1.
- **A pending transaction is not reported, and its resolution is counted once.** Added after a
  mutation audit deleted `status = 'posted'` from all four reports with the whole suite green —
  and `migrations/0002` records that exact defect as measured, at 500.00 of interchange twice.

One of these is **not yet asserted**, and saying "the rest are" would be the kind of claim this
project exists to avoid:

- ~~**Gaplessness.**~~ Now both enforced and asserted — but *not* the way an earlier correction
  here claimed. It said `ck_entries__seq` "requires an entry's sequence to be the one the balance
  upsert issued". It does not require anything of the client: `assign_entry_seq` **overwrites**
  whatever arrives with `MAX + 1` over that account's own entries, read from the journal and never
  from the cache. Validating against the cached `last_seq` is the design
  [ADR-0011](./decisions/0011-what-the-database-enforces.md) calls "the same mistake one level
  down" — trusting a writable column. What holds: the trigger assigns, and
  [`tests/concurrency.sh`](../tests/concurrency.sh) asserts `max(seq) = count(*) = count(distinct
  seq)` per account under concurrent load.
- **Idempotency replay.** There is no replay path to test: `idempotency_hash` is written and
  **never read**. The negative control proves only that a unique index fires — identically for a
  replay and for a different body, which is exactly the distinction the ADR says matters.

**The as-of property is now asserted**, on both axes, by
[`tests/bitemporal.sql`](../tests/bitemporal.sql). It builds a fixture that separates the axes in
both directions — a February transaction learned about in April, and a May transaction learned
about in February — and pins the numbers at five instants. The file's last assertion is the one
[ADR-0003](./decisions/0003-bitemporal-balances.md) is about: the running balance reports **520**
for a business-date question whose truth is **120**, and the test fails if the fixture ever stops
separating the axes. What remains open is *reproducibility* under concurrent writes, which is
[ADR-0005](./decisions/0005-reproducible-as-of.md)'s commit-ordered cursor and is still
`proposed`.

**Done when:** the suite is in CI alongside the schema snapshot test, and the as-of property is
covered.

## M1 · Schema, invariants, and the snapshot test — **schema landed**

[`migrations/0001`](../migrations/0001_ledger_core.sql) is the core —  `ledger_accounts`,
`ledger_transactions`, `ledger_entries`, `ledger_account_balances`, `ledger_events` — written by
hand rather than promoted from the spikes, which held three competing posting engines and two
competing hold models. [`0002`](../migrations/0002_chart_of_accounts.sql) adds the chart of
accounts and the completeness layer ([ADR-0009](./decisions/0009-chart-and-completeness.md));
[`0003`](../migrations/0003_card_holds.sql) the hold model
([ADR-0010](./decisions/0010-authorization-holds.md)). No API, no Go beyond migrations.

Landed with it: composite `(tenant_id, …)` keys throughout, the cross-tenant guard as a composite
foreign key, an immutability trigger on the journal, and the drift views both ADR-0003 and
ADR-0010 rely on. **Striping is not built.** The design is one integer on the account row and a `SUM` on read;
there is no such column in `migrations/` and nothing implements it. An earlier version of this
sentence read as though the column existed.

Carried forward: balanced-per-currency enforced by the database; append-only via an immutability
trigger (the `REVOKE` narrows the blast radius; it is not the mechanism); `amount_minor bigint CHECK (> 0)` so direction carries
the sign; idempotency keyed to the **event**, not the business object.

**`ledger_events`** ([ADR-0004](./decisions/0004-event-log.md)) — the idempotency spine for the
majority of the lifecycle that writes no ledger transaction: authorizations, declines, hold
expiry, reversals, statement close, limit changes. None of those can be made idempotent today,
because idempotency lives on a table they never touch.

**Composite `(tenant_id, …)` keys — done.** Every ledger table carries `tenant_id NOT NULL`,
primary keys are `(tenant_id, id)`, and every index and foreign key on the ledger tables carries the
prefix. Two foreign keys deliberately do not: `ledger_accounts.purpose → account_types` and
`account_types.fs_line → fs_lines`. The chart is **deployment-global**, not per tenant — which is a
real limitation, not an oversight: a tenant cannot add an account type without a migration. Listed
in [ADR-0009](./decisions/0009-chart-and-completeness.md).

**This was the one irreversible decision on the list, and it was free.** It is the prerequisite for
row-level security, partitioning, and ever splitting across instances — none work without it, all
are expensive to retrofit. A widely-cited sharding post-mortem named exactly this omission as its regret —
`spikes/003` attributes the lesson to Nubank and this line once said Notion. Neither attribution
has a source in the repo, so **the company is unverified**; the mechanics are the load-bearing
part. The column is in before there is data, which was the whole point.

**Tenant-local transactions, via intercompany clearing.** Some accounts genuinely cannot be
per-tenant: `operating_cash` mirrors *one real bank account*. A treasury transaction therefore
spans a tenant account and a shared one — and under row-level security the tenant sees only their
half, leaving their books out by the full amount
([measured](../spikes/004-chart-of-accounts/README.md)). The fix is a `due_from_treasury` /
`due_to_tenants` pair, splitting one cross-scope transaction into two, each balanced *within* one
scope. That is why "no transaction spans a tenant" is a conformance property, not an optimization.

[The golden trace](../tests/golden_trace.sql) now runs on that pair rather than describing it: the
facility draw, the network settlement and the ACH collection are all cross-scope, both scopes
balance independently at every step, and the two sides are asserted to eliminate exactly. The
program's profit turns out to equal its claim on treasury, from opposite directions.

**Striping as a schema concept — not built.** The design is that an account declares a stripe
count and a balance read `SUM`s across stripes. There is no such column in `migrations/`, and
`uq_accounts__house` currently makes it impossible anyway: it is `UNIQUE (tenant_id, purpose,
currency)` for house accounts, so `network_settlement_payable` — one of the two accounts spike 003
identifies as hot — cannot have a second row. Striping needs a stripe number in that key before it
can exist at all. Worth roughly 8×. Note *striping* is the contention
mechanism, not per-tenant splitting — at 90/10 skew per-tenant gave 1.07× while striping still gave
7.8×. Per-tenant accounts earn their place for reconciliation and tenant-locality, not throughput.

**Done when:** the schema snapshot test is in CI, and striping exists. The rest is done — every
invariant listed above has a migration and a negative control that is refused *by Postgres*, and
`fk_entries__txn` makes a cross-tenant transaction structurally unrepresentable.

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

**That last clause holds only under READ COMMITTED, and that had never been written down.**
*The figures in this paragraph have **no harness in the repository** — nothing in `tests/`,
`spikes/` or `migrations/` sets an isolation level, and spike 003 never varied one. They come from
a one-off adversarial run and are recorded as observations, not as reproducible measurements. The
conclusion does not depend on the numbers: `ON CONFLICT DO UPDATE` under a stricter isolation
level fails with `could not serialize access due to concurrent update`, which is a property of
Postgres, not of this workload.*

Observed, same sorted workload, no retry: READ COMMITTED **1200/1200 committed**; REPEATABLE READ
**369**, with 831 serialization failures; SERIALIZABLE **244**, with 956. The failure is the
`ON CONFLICT DO UPDATE` itself — `could not serialize access due to concurrent update`. It fails
closed, so nothing corrupts, but a deployment that sets a stricter default silently loses most of
its writes. Adding an external retry loop does not rescue it either: at REPEATABLE READ with 25
retries it still takes 2.8 retries per posting and leaves 28 permanent failures. **The write path
requires READ COMMITTED**, or it needs a different concurrency primitive.
`tenant_id` leads the conflict target because it leads the primary key; without it this statement
does not run at all (`there is no unique or exclusion constraint matching the ON CONFLICT
specification`). The working version is `post()` in [the golden trace](../tests/golden_trace.sql).
Spike 003 ran it over 1,721 accounts: zero mismatches, zero gaps, zero unbalanced transactions.
Two traps from Formance's bug history:

- **The first-entry race does not apply to the upsert form, and this was worth testing rather than
  assuming.** The warning is real for `SELECT … FOR UPDATE` — you cannot lock a row that does not
  exist. But `INSERT … ON CONFLICT DO UPDATE` *is* the insert-and-lock, so there is no gap to race
  through. Attacked with 25 independent races, each a fresh tenant with no balance row and 32
  writers released simultaneously on a start barrier: **800/800 committed, zero deadlocks, zero
  unique violations**, every sequence gapless from 1. *That harness is **not in the repo** —
  `tests/concurrency.sh` uses fixed tenants and no start barrier — so treat it as a one-off
  observation.* What IS shipped and does hold: `concurrency.sh` asserts `max(seq) = count(*) =
  count(distinct seq)` per account under concurrent load, on every run.
- **Deterministic lock ordering, batch-wide.** Sort accounts by id on read and write paths. Spike
  003 found that sorting within a single clearing does *not* order locks across a batch —
  throughput collapsed 10× into deadlocks.

**Partly done.** [`tests/concurrency.sh`](../tests/concurrency.sh) runs N writers against
overlapping account sets, half of them posting the legs in reverse order, and asserts zero
deadlocks, gapless per-account sequences, every transaction balanced, and both drift views empty.
It also hammers one hold group through `record_auth_event`, which is where the ingest lock either
serialises the read-modify-write or does not.

That found a live gap: **the deterministic lock ordering this section prescribes was not
implemented.** `post()` locked balance rows in whatever order the legs arrived, so two writers
touching the same two accounts in opposite order deadlocked — 138 deadlocks and 138 rollbacks out
of 320 postings, every failure a deadlock. (That run is not in the repo:
`concurrency.sh` ships a 6x15 workload over **six** accounts, because with two the planner drives a
nested loop that emits the legs in account order for free, and the deadlock cannot be produced at
all.) Sorting the legs by account id takes it to **zero**, and
the test fails if the sort is removed.

**Done when:** the same holds with **batching** enabled, which does not exist yet — batch-wide
ordering is the harder half of this milestone and is untested.

## M3 · The posting engine

Given a balanced set of entries and an idempotency key: post atomically or return the stored
result. Pending → posted is a **new** transaction with `resolves_id`, never an UPDATE.

Three design constraints, not later optimizations:

- **Coalesced batching.** N postings to one account collapse into a single upsert advancing the
  balance by the total and `last_seq` by the count; each entry's running balance is derived by
  walking backwards from the returned totals. This is the only batching that does not deadlock.
- **Single-call posting.** The whole operation in one server-side call rather than six round
  trips. Worth ~14% on localhost, decisive on RDS where five saved round trips cost ~2.5 ms
  against ~1.3 ms of real work.
- **Striping and batching must not both be applied blindly.** Random stripe selection makes them
  *cancel* — measured worse than either alone. Tenant- or worker-affinity stripe selection makes
  them compose.

**Decision needed here: `COPY FROM` is not supported on tables with row-level security.**
Measured, a hard error. Coalesced batching uses `CopyFrom`, so RLS on `ledger_entries` and bulk
batching are mutually exclusive. Likely resolution is posting as a `BYPASSRLS` role so RLS guards
only the read path — but it must be decided, not discovered.

**Done when:** M0's conformance suite passes under concurrent load, with and without batching, and
with striping on and off.

## M4 · The RDS benchmark

**Nothing has been measured over a network**, and that is now the largest open caveat in the
project. Every number is from localhost, where a round trip costs 0.05 ms; on RDS it is roughly
ten times that, which *reorders* the tuning levers rather than merely scaling them.

Placed before bitemporal reads because it is **unblocked** — it needs only M3 and a DSN — while M5
is blocked on an open decision.

Point spike 003's harness at real RDS and re-run the ladder, plus what localhost cannot show:
Multi-AZ synchronous replication cost per commit, across plausible instance classes.

**Done when:** there is a measured, reproducible number for a named instance class, with the method
published alongside it. Only then does any throughput figure go in a README.

## M5 · Bitemporal reads

Two axes, two mechanisms ([ADR-0003](./decisions/0003-bitemporal-balances.md)). Current and
recorded-axis balances come from `balance_after`; business-date balances aggregate over
`effective_at`. Every reporting function names its axis explicitly.

**Blocked on [ADR-0005](./decisions/0005-reproducible-as-of.md), still `proposed`.** `recorded_at`
defaults to transaction *start* time and is not monotonic with commit order, so the same as-of
query can return different answers when re-run. A reproducible cursor must be commit-ordered.
Decide it before writing code against `recorded_at <= :as_of`.

Also unbounded: the effective-axis aggregate grows linearly with history — observed (one-off, no harness in repo) at 105.91 ms at
1M entries in range. Period-close checkpoints are the bound — materialize each account's closing balance per
period so a business-date query reads "prior close + entries since."

**Done when:** an as-of query at instant T returns the same answer when re-run under concurrent
writes, and the backdating case (insertion order ≠ effective order) is correct on both axes.

## M6 · Drop it into AWS

The adoption surface, and the milestone that decides whether any of the above gets used.

- A container image and migration runner an adopter can point at RDS without reading our source.
- `docker compose up` for local development, already half-done.
- A worked deployment example — the smallest thing that stands up a working ledger.
- Documentation stating **which throughput lever applies to which write path**. Recommending both
  is actively harmful: the combination measured **worse than either alone** -- 2,356 clearings/s
  against 6,850 for striping by itself and 3,338 for batching by itself. An earlier version of this
  line said "3x worse than either", which is true of striping and false of batching.

**Done when:** someone who has never seen this repository can stand up a working ledger against
RDS from the README alone.

---

# Phase 2 — the reference implementation

Only after Phase 1 holds. A *consumer* of the ledger, not part of it.

## M7 · Cards

`credit_lines`, `spend_controls`, `card_holds` — the transaction from
[the reference product spec §03](./reference-product.md), against a fake processor. Read-only with respect to the ledger:
an authorization writes no entry.

[The reference product's](./reference-product.md) balance table is this milestone's acceptance
test, and it already replays: [`tests/golden_trace.sql`](../tests/golden_trace.sql) asserts the
complete state after every step, and [`tests/card_holds.sql`](../tests/card_holds.sql) covers
the hold flow including over-capture clamping, expiry, re-delivery and re-grouping.

What is **not** covered, and is the real remaining work here: forced posts, negative available
credit as a **legal state**, duplicate auths returning the **stored** decision rather than
re-evaluating against a limit that may have moved, and STIP. Those need `credit_lines` and
`spend_controls`, which do not exist.

**Done when:** the branch cases replay too, against a fake processor.

## M8 · Durable timers

Durable timers enter here and not before — hold expiry and the ACH return window are the first
two things that genuinely need them. They run **in-process on Postgres**, in the same transaction
as the ledger write, so a hold and its expiry timer commit together or not at all
([ADR-0008](./decisions/0008-durable-timers.md)). Handlers are idempotent already, which M3 gives
us.

Ship the reconciliation sweep alongside it: groups past their deadline that are still holding,
behind `ix_hold_groups__held`. The deadline lives on the event, so a lost job becomes recoverable
rather than silent — [ADR-0008](./decisions/0008-durable-timers.md) has the query, executed against
the shipped schema. (This line previously quoted `WHERE state = 'open' AND expires_at < now()`
against a table migration 0003 deleted.)

**A scheduler is not a throughput mechanism.** A contended row lock is held for the duration of a
transaction; making the write asynchronous relocates who waits rather than removing it. Its place
is owning the *sweep* that consolidates suspense accounts, and draining event streams in batches.

---

## Known work, not yet scheduled

- **Per-row hash chaining** for tamper evidence. Needs a total order, so decide it alongside
  [ADR-0005](./decisions/0005-reproducible-as-of.md). Never build Formance's block-hashing layer.
- **The suspense sweep** for affinity striping. Workflow-shaped, so it wants M8.
- **The auth path has never been measured.** It writes no ledger entry and serializes per company,
  so it should scale far better than clearing — but it has a latency deadline rather than a
  throughput target. No claim until it has its own spike.
- **Metadata history**, if metadata ever feeds reporting. Cheapest path is making metadata changes
  *be* event-log entries.
- **Replica identity on every table**, if reporting is ever fed by CDC. Also the precondition for
  moving a tenant between instances with row-filtered logical replication.

## Open questions

- **Does v0.1 need an HTTP API, or is a Go library plus migrations enough to adopt?** The API is
  the adoption surface for anyone not writing Go. Deferred, but no longer obviously so.
- **How much of the card product belongs in this repository?** A reference implementation argues
  for keeping it; a clean core argues for a separate module. Not urgent until M7.

## Deliberately not now

- **Sharding across instances.** Striping *within* one instance is in scope because it is the
  lever that matters. The composite keys in M1 keep the door open.
- **Partitioning by tenant.** **Not illegal** — an earlier version of this line said it was, and
  said so "(measured)". Re-run on the shipped schema, `PARTITION BY HASH (tenant_id)` succeeds on
  `ledger_entries`, `ledger_transactions` and `ledger_accounts` carrying every constraint they
  actually have, including the composite FKs and both partial unique indexes. `tenant_id` leading
  every key is precisely what makes it legal — which was the point of putting it there. What is
  true: there is no in-place `ALTER TABLE` conversion, and it buys per-tenant `DETACH` rather than
  throughput, since table size barely affects an append-only workload. The planning-cost figure
  that accompanied the illegality claim has no method recorded anywhere and is struck.
- **Caching balances.** `posted` is read straight off the ledger by construction, so there is no
  second copy to drift.
- **Multi-currency FX.** The schema carries currency and balances per currency; conversion is a
  separate problem with its own ADR.
- **A scripting language for transactions**, and configurable correctness in any form.
- **Statements, disputes, AP/AR, wallet.** All real, all after the core holds.
