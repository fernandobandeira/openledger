# Decisions

Everything we've decided, on one page. Read this to know where the project stands; follow a link
only when you want the reasoning behind a particular call.

New to ledgers? Start with the [glossary](../glossary.md) — it defines every domain term used
here, so the ADRs don't each stop to re-explain them.

## The stack

- **Go** — because the interesting logic is SQL, and Go stays out of the way.
- **Postgres**, one instance — measured at ~800 **clearings**/s untuned (a clearing is one card
  transaction = 3 ledger entries), rising to ~6,970/s with the hot account striped 64 ways and
  7,897/s striping *and* posting in a single call. Spike 003's own banner applies: re-auditing the
  same configurations moved the baseline from 833 to 482, so **treat these as shape, not as a
  benchmark**. Nothing has been measured over a network.
- **sqlc**, no ORM — we write the SQL; it generates typed Go. The hot queries stay reviewable *as
  SQL*.
- **Postgres for durable timers too** — an in-process job queue, no scheduler cluster to run.

## The decisions

| # | We decided | Because | Status |
| --- | --- | --- | --- |
| [0001](./0001-go-and-postgres.md) | Go + Postgres, no ORM | The load-bearing logic is SQL, so the host language's job is narrow; Postgres has measured headroom of 17–40× what we sized for | accepted |
| [0002](./0002-data-access-layer.md) | Native pgx + sqlc, over go-jet | go-jet can silently scan a money column as zero with no error, and its codegen needs a live database | accepted |
| [0003](./0003-bitemporal-balances.md) | Running balance for "now", aggregate-on-read for "as of a business date" | A backdated entry lands with a *later* sequence number, so a running balance answers business-date questions wrongly | accepted |
| [0004](./0004-event-log.md) | Add an append-only `ledger_events` table | Most accepted operations write no ledger transaction, so idempotency can't live on the transactions table | accepted |
| [0005](./0005-reproducible-as-of.md) | Pin reports to a commit-ordered cursor, not a timestamp | `recorded_at` is transaction-*start* time, so the same "as of" query re-runs to a different answer | **proposed** |
| [0006](./0006-schema-conventions.md) | Naming rules, a CI schema-snapshot test, keep FKs and enums | Dropping a column silently drops its indexes — Formance lost a hot-path index that way for thirty migrations | accepted |
| [0007](./0007-open-source-positioning.md) | Reframe as a general open-source ledger; keep Postgres | The bottleneck is one contended row, not the hardware — and striping fixes it | **proposed** |
| [0008](./0008-durable-timers.md) | Durable timers in Postgres, not Temporal | The need is durable *scheduling*, not workflow orchestration — and a job row commits in the same transaction as the ledger write, which Temporal cannot do | accepted |
| [0009](./0009-chart-and-completeness.md) | Chart of accounts as data; completeness is a separate invariant | A report missing one account still satisfies the accounting equation — the missing account drops out of both sides | accepted |
| [0010](./0010-authorization-holds.md) | A hold is a SUM over an append-only event log, not a mutable amount | Grouping a clearing to its authorization is a revisable inference, and processors disagree on whether an increment carries a delta or a cumulative total | accepted |

## Non-negotiable

No decision may trade these away. They are what makes the numbers trustworthy:

- **Append-only.** No `UPDATE`, no `DELETE` on entries — enforced by revoking the grants, not by
  discipline.
- **Balanced per currency**, enforced by the database on every transaction.
- **Bitemporal.** Every entry records both when it happened and when we learned about it.
- **Event-logged.** Every accepted operation is recorded, whether or not it moves money.
  *Not yet enforced:* `ledger_transactions.event_id` is nullable — see "Still open".
- **Correctness is never configurable.** Formance made historization a feature flag and got
  point-in-time queries that silently return empty — *"a green check that didn't actually
  execute."* Make the product pluggable; never the invariants.

## Still open

Undecided, listed plainly rather than buried:

- **[0005](./0005-reproducible-as-of.md) and [0007](./0007-open-source-positioning.md) are
  `proposed`**, not accepted. The as-of cursor blocks **M5**, not M4 — M4 is the RDS benchmark and
  is unblocked.
- **Row-level security conflicts with bulk loading.** Postgres refuses `COPY FROM` on a table with
  RLS enabled — and `COPY` is what makes batched posting fast. Likely resolution: post through a
  role that bypasses RLS, so RLS guards reads only. Not yet decided.
- **Historical balances get slower as history grows, and nothing bounds it yet.** Reading "the
  balance right now" is a single index lookup (0.018 ms). Reading "the balance as of last June"
  has to add up entries, which is linear — ~0.10 µs each, so ~3 ms at 30k entries and a measured 105.91 ms at 1M. The fix is the accountants' one: close each period and store its closing balance, so a
  query only has to add up the current period. Designed but not built —
  [0003](./0003-bitemporal-balances.md) has the numbers.
- **`event_id` is nullable**, so "every transaction references its causing event" is a convention
  rather than an invariant. `NOT NULL` is the fix; it is not done.
- **There is no idempotency replay path.** `idempotency_hash` is written and never read, so
  "same key + same body replays the stored result; a different body is refused" is designed and
  unbuilt. The unique index only makes the second attempt fail.
- **The write path requires READ COMMITTED.** Measured: REPEATABLE READ and SERIALIZABLE lose
  most writes to serialization failures on the balance upsert, and a retry loop does not rescue
  it. A hard deployment constraint, recorded in no ADR.
- **Hash chaining for tamper evidence is deferred, not decided.**
  [0004](./0004-event-log.md) leaves it explicitly open: it needs a total order, so it is entangled
  with [0005](./0005-reproducible-as-of.md). The cost figures quoted there are extrapolated from
  spike 003's contended-row numbers, not measured.
- **The chart of accounts is not versioned**, so changing which statement line an account reports
  under would silently restate issued statements. Currently blocked outright, which is a stopgap:
  IAS 1.41 *requires* reclassifying comparatives. See [0009](./0009-chart-and-completeness.md).
- **There is no period close and no retained earnings posting.** Un-closed earnings are presented
  as a derived `current_year_earnings` line, which is correct interim presentation but means
  nothing bounds how far back a backdated entry can restate a reported period.
- **No number has been measured on RDS.** Everything so far is localhost, where a round trip is
  ten times cheaper. Nothing gets published until that is fixed.
- **Posting rules.** A deployment declares its own accounts; it must also declare how a business
  event becomes entries. Adyen proves those templates balance at design time. We have not designed
  ours.

## How this log works

One file per decision, numbered, never deleted. A decision that turns out wrong gets a new ADR
superseding it; the old one stays, with its status changed, so the reasoning trail survives.

Where measurement later corrected a decision, the ADR states the current position **first** and
summarises what it superseded — you should never have to read a change history to learn what we
think now.
