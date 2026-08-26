# openledger

An open-source **double-entry ledger** — Postgres for storage, Go for the service. A single
binary and a database you already know how to operate.

Double-entry means every money movement is recorded as debits and credits that sum to the same
amount, so the books cannot silently drift. A $500 card purchase looks like this:

```
DR  customer_receivable         500.00    the customer owes us $500
CR  network_settlement_payable  491.00    we owe the card network $491
CR  interchange_revenue           9.00    we keep $9 as our fee
```

The bet: most teams that need a real ledger do not need a fast one, but every one of them needs a
correct one. Every cent accounted for, no manual fixes, and any number reproducible as of any
date, forever — cheap to build in, painful to retrofit.

Its **reference implementation** is an embedded B2B charge card funded by a credit line. That
product exists to prove the core carries something real without forking, and to give the core a
demanding acceptance test. It is not the project.

**Status: design stage.** The deliverable is [`docs/decisions/`](./docs/decisions/).
`schema/schema.sql` holds the ledger core, the chart of accounts and the card hold model — it exists
to show that shape is expressible, and it loads. **There is no test suite and no Go service yet**: a
SQL implementation and its harness were deleted, and why is [ADR-0012](./docs/decisions/0012-where-logic-lives.md).

## Start here

**[docs/design-board.html](./docs/design-board.html) — the system design, in six sections.** Open it
in a browser. Sizing, architecture, the auth hot path, the data model, state machines, and a
row-by-row trace of one $500 purchase through every account it touches.

| | |
| --- | --- |
| [docs/design-board.html](./docs/design-board.html) | **The design.** Read this first. |
| [docs/glossary.md](./docs/glossary.md) | Every term, for someone who has never built a ledger |
| [docs/vision.md](./docs/vision.md) | Why this exists when Formance already does |
| [docs/roadmap.md](./docs/roadmap.md) | What gets built next, and why in that order |
| [docs/decisions/](./docs/decisions/) | One file per decision, and what is still open |
| [schema/schema.sql](./schema/schema.sql) | The schema the decisions describe — it loads |
| [spikes/](./spikes/) | Timeboxed investigations: brief, findings, sources |

## Layout

```
docs/             THE DELIVERABLE — design board, decisions, vision, glossary,
                  roadmap, reference product.
schema/           the design schema: 11 tables, CHECKs, foreign keys, 5 views and
                  8 triggers over 2 functions -- each justified in place, per
                  decisions/0012. chart.sql seeds an example chart of accounts.
spikes/           timeboxed investigations, one directory each. Separate Go
                  modules; there is no CI.
cmd/openledger/   entrypoint. Prints "nothing to run yet".
internal/         empty. Where the Go service will go.
```

## Performance

**No number here is a benchmark, and several in-repo documents quote figures that are only
shapes.** Spike 003's own banner says so: re-auditing the same configurations moved its baseline
from 833 to 482 clearings/s. Treat every throughput figure in `docs/` accordingly. [Spike 003](./spikes/003-throughput-ceiling/README.md)
measured the design with durability on, but everything so far ran on localhost — where a network
round trip costs 0.05 ms against roughly 0.5 ms on RDS. That reorders the tuning levers rather
than merely scaling the result, so nothing goes in a README until it is measured over a real
network. See [the vision doc](./docs/vision.md#performance).

## Licence

[MIT](./LICENSE).
