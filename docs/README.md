# Documentation

**Start with the design board: [`design-board.html`](./design-board.html).** Open it in a browser.
It is the whole system in six sections — sizing, architecture, the auth hot path, the data model,
state machines, and a row-by-row trace of one $500 purchase. Everything else here exists to record
*decisions* the board assumes.

| | |
| --- | --- |
| [design-board.html](./design-board.html) | **The system design.** Read this first — with the note below. |
| [glossary.md](./glossary.md) | Every term, defined for someone who has never built a ledger. |
| [vision.md](./vision.md) | Why this exists when Formance already does, and what it deliberately does not do. |
| [decisions/](./decisions/) | One file per decision, with the evidence. [decisions/README](./decisions/README.md) is the index and carries what is still open. |
| [reference-product.md](./reference-product.md) | The embedded charge card the ledger is designed against: the chart of accounts, and the lifecycle in text. |
| [roadmap.md](./roadmap.md) | What gets built next, and why in that order. |

> **Where the board and the decisions differ.** The board is the design as first drawn, and three
> decisions have moved since. It says **Temporal** in seven places — [0008](./decisions/0008-durable-timers.md)
> chose River on Postgres. Its §04 models a hold as a **mutable `card_holds` row** with a running
> `cleared_minor`, keyed on `auth_id`; [0010](./decisions/0010-authorization-holds.md) rejects that by
> name and derives the hold as a sum over an append-only event log, because a clearing has no reliable
> key back to its authorization. And its §04 says append-only is enforced by revoking `UPDATE` —
> [0012](./decisions/0012-where-logic-lives.md) shows a grant binds the application role and nothing
> else, so it is enforced by trigger.
>
> Four smaller divergences, all in §04 and §06: the board puts `idempotency_key` on
> `ledger_transactions`, where [0004](./decisions/0004-event-log.md) moved it to the event log and
> the shipped table has no such column; **no key in the board carries `tenant_id`**, which
> [the roadmap](./roadmap.md) calls the one irreversible decision on the list; the board has no
> `account_types`/`fs_lines` layer, so `category` and `normal_balance` sit as free columns rather
> than behind the two composite foreign keys [0009](./decisions/0009-chart-and-completeness.md)
> put them behind; and its §03 says "no cache anywhere" while `ledger_account_balances` ships as
> the write-side serialisation point. Three account names in the lifecycle trace are not in
> `schema/chart.sql`: `ach_pull_unsettled` (the chart says `ach_pull_returnable`),
> `outbound_transfer_in_transit`, and `unapplied_receipts`.
>
> The board's **sizing, the auth-deadline budget, and the shape of the lifecycle** are unaffected
> and remain the clearest statement of them anywhere in this repo.

## What a ledger is, in one paragraph

A **ledger** answers one question — *who is owed what* — in a way that cannot quietly go wrong. It
does that with **double entry**: every amount is written twice, once as a debit and once as a
credit, and the two sides must sum to zero. The rest is consequences. Entries are never updated or
deleted, because a correction that edits history is indistinguishable from a lie; you post a new,
opposite entry instead. Balances are derived from entries, never the other way round.

This project is that ledger, in Go and PostgreSQL, with an **embedded B2B charge card** as the
reference product. The card is not a demo — it is what forced the hard parts: authorizations that
reserve money without moving it, clearings that move it, and processor messages that arrive out of
order, twice, or never.

## Two rules run through everything

- **Correctness is not configurable.** No flag turns an invariant off. *Where* each one is enforced
  is itself a decision — some in the schema, some by construction in the writer — and
  [decisions/README](./decisions/README.md#what-the-schema-enforces-today) keeps the honest
  inventory of which is which today.
- **A claim needs evidence next to it.** Where a document states a number it should be reproducible
  from this tree, and where it is not, the document says so.

## Status

**Design stage.** The Go service is not built. `schema/schema.sql` exists to show the shape the
decisions describe is expressible in PostgreSQL, and it loads:

```sh
make up       # PostgreSQL 18 in Docker
make schema   # load schema/schema.sql + the seed chart
make test     # go test ./...  (covers nothing yet)
```
