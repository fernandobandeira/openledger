# Roadmap

Ordered by what unblocks what, not by size. No estimates — the risk here is correctness, and
correctness doesn't estimate well.

**Scope: the ledger core is the product.** [ADR-0007](./decisions/0007-open-source-positioning.md)
reframes this as a general open-source ledger. Cards, spend controls, and credit lines are a
*reference implementation* built on it, not the thing itself. That inverts the old plan, which
treated the card rail as the destination and the ledger as its foundation.

Two consequences for ordering, and they are the whole reason this document was rewritten:

1. **The core must be verifiable by strangers before a reference product matters.** An adopter
   needs to confirm their deployment is correct without reading our card domain. That makes a
   conformance suite the first milestone rather than the card lifecycle fixture.
2. **The deployment story is part of the product now.** "A small startup drops this into AWS" is
   ADR-0007's stated audience. Something unrunnable is not adoptable, however correct it is.

[v1-vision.md](./v1-vision.md) is now best read as **the reference product's spec**, not as this
system's requirements. It remains the sharpest description of what the ledger has to survive.

---

# Phase 1 — the core

Everything needed for someone else to adopt this and trust it.

## M0 · The conformance suite

The old M0 encoded the vision doc's card balance table as a golden fixture. That fixture is still
valuable, but it tests the *reference product*, so it moves to **M7**.
The core needs its own acceptance test first, and it is a different shape: **properties, not a
trace.**

Two sources already exist and should be promoted out of the spikes rather than rewritten:

| Source | What it gives |
| --- | --- |
| [`spikes/002-sqlc-vs-jet/invariants.sql`](../spikes/002-sqlc-vs-jet/invariants.sql) | Nine invariants, each asserting Postgres *refuses* an illegal write |
| [Spike 003's verification queries](../spikes/003-throughput-ceiling/README.md) | Balance/sequence/balancedness checks that ran clean over 1,721 accounts under concurrent load |

The properties the core must hold, at any point, against any history:

- Every transaction balances, per currency.
- Every `balance_after` equals the recomputation from its entries.
- Per-account sequences are gapless and duplicate-free.
- Replaying an idempotency key returns the stored result, and a different body is refused.
- An as-of query at instant T returns the same answer whenever it is re-run.

This matters more for an open-source ledger than it did for a single-product one. It is what lets
an adopter verify their own deployment, and what lets us accept a contribution without hand-review
of its concurrency implications.

**Done when:** the suite runs against a live database, fails loudly when an invariant is broken
on purpose, and is wired into CI alongside the
[ADR-0006 schema snapshot test](./decisions/0006-schema-conventions.md).

## M1 · Schema, invariants, and the snapshot test

Starts from [`spikes/002-sqlc-vs-jet/schema.sql`](../spikes/002-sqlc-vs-jet/schema.sql), which
already applies cleanly with nine Postgres-enforced invariants and carries the
[spike 001](../spikes/001-formance/README.md) corrections — tenant-scoped idempotency with
`NULLS NOT DISTINCT`, request-body hash, double-reversal guards, denormalized `effective_at`.

Core tables: `ledger_accounts`, `ledger_transactions`, `ledger_entries`,
`ledger_account_balances`, `ledger_events`. No API, no Go beyond what runs migrations.

Carried forward unchanged:

- Balanced-per-currency enforced by the database, not by application code.
- Append-only enforced by `REVOKE UPDATE, DELETE` from the app role — two roles, and migrations
  that run as the other one.
- `amount_minor bigint CHECK (> 0)` — direction carries the sign, never the amount.
- Idempotency keys scoped to the **event**, not the business object.

**`ledger_events`** — [ADR-0004](./decisions/0004-event-log.md). The idempotency spine for the
majority of the lifecycle that writes no ledger transaction at all: authorizations, declines,
hold expiry, reversals, statement close, repayment initiation, limit changes, account openings.
Today none of those can be made idempotent, because idempotency lives on a table they never touch.

**New in this milestone, both from [spike 003](../spikes/003-throughput-ceiling/README.md):**

- **Per-tenant house accounts.** `uq_accounts__house` currently guarantees exactly one
  `interchange_revenue` per *deployment*. Correct for one product; wrong for a shared ledger,
  where it makes every tenant contend on the same rows and **the system gets slower as it gets
  more successful**. Measured: 16 tenants with their own house accounts scale like 16 stripes.
- **Striping as a schema concept.** An account declares a stripe count; balance reads `SUM`
  across stripes. One integer on the account row, and it is the difference between the baseline
  and roughly 8× the baseline. It has to be designed in here, not bolted on later.

**Done when:** every invariant has a migration and a test that tries to violate it and is refused
*by Postgres*; the schema snapshot test is in CI; and a second tenant's house accounts are
provably independent of the first's.

## M2 · The concurrency proof

The mechanism is settled — [spike 001](../spikes/001-formance/README.md) supplied it and
[spike 003](../spikes/003-throughput-ceiling/README.md) proved it under concurrent load. A
per-(account, currency) balance row, updated by one atomic upsert returning **both** the new
balance and the next sequence number:

```sql
INSERT INTO ledger_account_balances (...) VALUES (...)
ON CONFLICT (account_id, currency) DO UPDATE
   SET input    = ledger_account_balances.input  + excluded.input,
       output   = ledger_account_balances.output + excluded.output,
       last_seq = ledger_account_balances.last_seq + 1
RETURNING input, output, last_seq;
```

The row lock *is* the serialization point — no `SELECT max()`, no advisory lock, no retry loop.
Spike 003 ran this to completion over 1,721 accounts and found **zero balance mismatches, zero
sequence gaps, zero unbalanced transactions**.

What remains is proving it *in this codebase* rather than in a spike harness, and handling two
traps from Formance's bug history:

- **Insert the zero-balance row before locking it.** You cannot `FOR UPDATE` a row that does not
  exist, so two writers race on an account's *first* entry.
- **Deterministic lock ordering** — sort accounts by id in every operation, read and write paths
  both. Note this must be **batch-wide**, not per-transaction: spike 003 found that sorting within
  a single clearing does not order locks across a batch, and throughput collapsed 10× to deadlocks.

**Done when:** N concurrent posters against overlapping account sets produce a gapless,
duplicate-free sequence per account, every `balance_after` equals the recomputation from scratch,
and the batch-wide ordering holds with batching enabled. Run it enough times to trust it.

## M3 · The posting engine

The narrow API everything else talks to: given a balanced set of entries and an idempotency key,
post them atomically or return the stored result. Pending → posted is a **new** transaction with
`resolves_id`, never an UPDATE.

[Spike 003](../spikes/003-throughput-ceiling/README.md) determined the shape this must take, and
these are design constraints rather than optimizations to add later:

- **Coalesced batching.** N postings to the same account collapse into one upsert that advances
  the balance by the total and `last_seq` by the count; each entry's running balance is then
  derived by walking backwards from the returned totals. This is the only batching that does not
  deadlock, and it is what Formance's inverted write order was actually for.
- **Single-call posting.** The whole operation in one server-side call rather than six round
  trips. Worth ~14% on localhost, and decisive on RDS where the five saved round trips cost
  ~2.5ms against ~1.3ms of actual work.
- **Worker-affinity striping.** Random stripe selection makes striping and batching *cancel*
  (measured worse than either alone). Each writer owning a stripe makes them compose. The
  accounting name is a per-writer suspense account: post the shared leg to a row you alone own,
  keep every transaction balanced, sweep suspense into the house account periodically. The sweep
  itself is later work.

**Done when:** M0's conformance suite passes against the engine under concurrent load, with and
without batching, and with striping on and off.

## M4 · The RDS benchmark

**This validates ADR-0007's central claim, and nothing has been measured over a network.** That is
now the largest open caveat in the project. Every number we have is from localhost, where a round
trip costs 0.05ms; on RDS it costs roughly ten times that, which
[reorders the levers rather than merely scaling them](../spikes/003-throughput-ceiling/README.md) —
batching and single-call posting matter more, striping matters less.

Placed here, before bitemporal reads, because it is **unblocked** (it needs only M3 and a DSN)
while M5 is blocked on an open decision. De-risking the positioning claim
should not wait behind something that cannot start.

Point spike 003's existing harness at a real RDS instance and re-run the ladder. Also measure what
localhost cannot show: Multi-AZ synchronous replication cost per commit, and behaviour across an
instance-class range an adopter might plausibly choose.

**Done when:** there is a measured, reproducible number for a named instance class and
configuration, with the method published alongside it — and only then does any throughput figure
go in a README. ADR-0007 is explicit that we publish no number before this.

## M5 · Bitemporal reads

Shaped by [ADR-0003](./decisions/0003-bitemporal-balances.md): **two axes, two mechanisms.**
Current and recorded-axis balances come from `balance_after`; business-date balances are an
aggregate over `effective_at`. Every reporting function names its axis explicitly.

**Blocked on [ADR-0005](./decisions/0005-reproducible-as-of.md), which is still `proposed`.**
`recorded_at` defaults to transaction *start* time and is therefore not monotonic with commit
order, so the same as-of query can return different answers when re-run. A reproducible cursor
must be commit-ordered rather than a wall clock. Spike 001 found Formance has no such ordering
anywhere in their schema — which raises confidence the problem is real and lowers confidence that
a clever fix exists. **Decide ADR-0005 before writing code against `recorded_at <= :as_of`.**

**Done when:** an as-of query at instant T returns the same answer when re-run later under
concurrent writes, and the backdating case from ADR-0003 (insertion order ≠ effective order)
returns the correct number on both axes.

## M6 · Drop it into AWS

The adoption surface. Unremarkable engineering, and the milestone that decides whether any of the
above gets used.

- A container image and a migration runner that an adopter can run against RDS or Aurora without
  reading our source.
- `docker compose up` for local development, already half-done.
- A worked deployment example — the smallest thing that stands up a working ledger.
- Documentation stating **which throughput lever applies to which write path**. Batching for
  streams we control; striping for independent arrivals. Recommending both is actively harmful:
  spike 003 measured the combination at 3× *worse* than either alone. Users will apply both
  otherwise, and conclude the ledger is slow.

**Done when:** someone who has never seen this repository can stand up a working ledger against
RDS from the README alone.

---

# Phase 2 — the reference implementation

Only after Phase 1 holds. This is what proves the core is real and gives adopters a worked example
of a non-trivial product built on it — but it is a *consumer* of the ledger, not part of it.

## M7 · The reference product: cards

`credit_lines`, `spend_controls`, `card_holds` — the transaction from
[v1-vision §03](./v1-vision.md), against a fake processor. Read-only with respect to the ledger:
an authorization writes no entry.

The old M0 fixture lands here. The vision doc's balance table — 12 accounts × 11 columns, plus
three branch cases, with the accounting equation checking out at every column — is the acceptance
test for this milestone.

Includes the edge cases that decide whether you have built this before: over-capture clamping,
forced posts, negative available credit as a **legal state**, and duplicate auths returning the
**stored** decision rather than re-evaluating against a limit that may have moved.

**Done when:** the golden trace replays end to end and every column matches, including the three
branch cases.

## M8 · Durable timers

Temporal enters here and not before — hold expiry and the ACH return window are the first two
things that genuinely need it. Activities must be idempotent, which M3 already provides.

Worth stating plainly given it came up: **Temporal is not a throughput mechanism.** A contended
row lock is held for the duration of a transaction; making the write asynchronous relocates who
waits rather than removing the wait. Temporal's place here is owning the *sweep* that consolidates
per-writer suspense accounts, and draining event streams in batches — both genuinely workflow-shaped.

---

## Newly known work, not yet scheduled

- **Per-row hash chaining** for tamper evidence. Nearly free at our volume; never build Formance's
  block-hashing layer. Deferred in [ADR-0004](./decisions/0004-event-log.md) because it needs a
  total order — decide it alongside [ADR-0005](./decisions/0005-reproducible-as-of.md).
- **The suspense sweep.** Worker-affinity striping needs a periodic consolidation of per-writer
  suspense accounts into the real house account. Workflow-shaped, so it wants M8.
- **The auth path has never been measured.** It writes no ledger entry and serializes per company,
  so it should scale far better than the clearing path — but it has a latency deadline rather than
  a throughput target, and no claim should be made about it until it has its own spike.
- **Metadata history**, if any metadata feeds reporting an adopter depends on. Cheapest path is
  making metadata changes *be* event-log entries rather than adding revision tables.
- **Primary key / replica identity on every table**, if reporting will ever be fed by CDC.
  Formance shipped releases without them and needed a migration to add them back.

## Open questions

- **Does v0.1 need an HTTP API, or is a Go library plus migrations enough to adopt?** Previously
  an easy defer — the API follows the domain, and leading with it inverts the correctness
  pressure. Under ADR-0007 it is a real question, because the API *is* the adoption surface for
  anyone not writing Go. Deferred, but no longer obviously so.
- **How much of the card product belongs in this repository at all?** A reference implementation
  argues for keeping it; a clean core argues for a separate module. Not urgent until M7.

## Deliberately not now

- **Sharding across instances.** Note this bullet's reasoning has changed: it used to rest on
  "the sizing says one Postgres instance." We have now measured the ceiling instead of assuming
  it, and striping *within* one instance is in scope precisely because it is the lever that
  matters. Splitting the ledger across instances remains out.
- **Read replicas and caching.** `posted` is read straight off the ledger by construction, so
  there is no second copy to drift. Revisit only with a measured read bottleneck.
- **Multi-currency FX.** The schema carries `currency` and balances per-currency; conversion is a
  separate problem with its own ADR.
- **Statements, disputes, AP/AR, wallet.** All real, all after the core holds.
