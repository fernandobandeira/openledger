# Decisions

Everything we've decided, on one page. Read this to know where the project stands; follow a link
only when you want the reasoning behind a particular call.

New to ledgers? Start with the [glossary](../glossary.md) — it defines every domain term used
here, so the ADRs don't each stop to re-explain them.

## The stack

- **Go** — because the interesting logic is SQL, and Go stays out of the way.
- **Postgres**, one instance — measured at ~800 **clearings**/s untuned (a clearing is one card
  transaction = 3 ledger entries), and 7,897/s with the hot account striped — far more than
  almost any adopter needs.
- **sqlc**, no ORM — we write the SQL; it generates typed Go. The hot queries stay reviewable *as
  SQL*.
- **Temporal** for durable timers — though whether it belongs in the core is still open.

## The decisions

| # | We decided | Because | Status |
| --- | --- | --- | --- |
| [0001](./0001-go-and-postgres.md) | Go + Postgres, no ORM | The load-bearing logic is SQL, so the host language's job is narrow; Postgres has measured headroom of 17–40× what we sized for | accepted |
| [0002](./0002-data-access-layer.md) | Native pgx + sqlc, over go-jet | go-jet can silently scan a money column as zero with no error, and its codegen needs a live database | accepted |
| [0003](./0003-bitemporal-balances.md) | Running balance for "now", aggregate-on-read for "as of a business date" | A backdated entry lands with a *later* sequence number, so a running balance answers business-date questions wrongly — measured 2× off | accepted |
| [0004](./0004-event-log.md) | Add an append-only `ledger_events` table | Most accepted operations write no ledger transaction, so idempotency can't live on the transactions table | accepted |
| [0005](./0005-reproducible-as-of.md) | Pin reports to a commit-ordered cursor, not a timestamp | `recorded_at` is transaction-*start* time, so the same "as of" query re-runs to a different answer | **proposed** |
| [0006](./0006-schema-conventions.md) | Naming rules, a CI schema-snapshot test, keep FKs and enums | Dropping a column silently drops its indexes — Formance lost a hot-path index that way for thirty migrations | accepted |
| [0007](./0007-open-source-positioning.md) | Reframe as a general open-source ledger; keep Postgres | The bottleneck is one contended row, not the hardware — and striping fixes it | **proposed** |

## Non-negotiable

No decision may trade these away. They are what makes the numbers trustworthy:

- **Append-only.** No `UPDATE`, no `DELETE` on entries — enforced by revoking the grants, not by
  discipline.
- **Balanced per currency**, enforced by the database on every transaction.
- **Bitemporal.** Every entry records both when it happened and when we learned about it.
- **Event-logged.** Every accepted operation is recorded, whether or not it moves money.
- **Correctness is never configurable.** Formance made historization a feature flag and got
  point-in-time queries that silently return empty — *"a green check that didn't actually
  execute."* Make the product pluggable; never the invariants.

## Still open

Undecided, listed plainly rather than buried:

- **[0005](./0005-reproducible-as-of.md) and [0007](./0007-open-source-positioning.md) are
  `proposed`**, not accepted. The as-of cursor blocks M4.
- **Row-level security conflicts with bulk loading.** Postgres refuses `COPY FROM` on a table with
  RLS enabled — and `COPY` is what makes batched posting fast. Likely resolution: post through a
  role that bypasses RLS, so RLS guards reads only. Not yet decided.
- **Historical balances get slower as history grows, and nothing bounds it yet.** Reading "the
  balance right now" is a single index lookup (0.018 ms). Reading "the balance as of last June"
  has to add up entries, which is linear — ~0.22 µs each, so ~7 ms at 30k entries but ~2 s at
  10M. The fix is the accountants' one: close each period and store its closing balance, so a
  query only has to add up the current period. Designed but not built —
  [0003](./0003-bitemporal-balances.md) has the numbers.
- **Temporal's place.** [0001](./0001-go-and-postgres.md) leans on it, but it is a server cluster,
  not a library — in tension with the "drop it into AWS" pitch. Needs its own ADR before M6.
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
