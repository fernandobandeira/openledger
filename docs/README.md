# Documentation

**Start with the design board: [`design-board.html`](./design-board.html).** Open it in a browser.
It is the whole system in six sections — sizing, architecture, the auth hot path, the data model,
state machines, and a row-by-row trace of one $500 purchase. Everything else here exists to record
*decisions* the board assumes.

| | |
| --- | --- |
| [design-board.html](./design-board.html) | **The system design.** Read this first. |
| [glossary.md](./glossary.md) | Every term, defined for someone who has never built a ledger. |
| [vision.md](./vision.md) | Why this exists when Formance already does, and what it deliberately does not do. |
| [decisions/](./decisions/) | One file per decision, with the evidence. [decisions/README](./decisions/README.md) is the index and carries what is still open. |
| [reference-product.md](./reference-product.md) | The embedded charge card the ledger is designed against: the chart of accounts, and the lifecycle in text. |
| [roadmap.md](./roadmap.md) | What gets built next, and why in that order. |

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
