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

| | |
| --- | --- |
| [docs/vision.md](./docs/vision.md) | What this is, what is non-negotiable, and a primer if you have never built a ledger. **Read this first.** |
| [docs/roadmap.md](./docs/roadmap.md) | What gets built, in what order, and why that order |
| [docs/decisions/](./docs/decisions/) | ADRs — every architectural decision and its reasoning |
| [docs/glossary.md](./docs/glossary.md) | Every term used here, defined for someone who has never built a ledger |
| [schema/schema.sql](./schema/schema.sql) | The design schema — tables, constraints, keys, report views, and the two triggers that earn their place |
| [spikes/](./spikes/) | Timeboxed investigations — brief, findings, and code together |
| [docs/reference-product.md](./docs/reference-product.md) | The reference card product this ledger was designed against |

## Local development

Requires Go 1.26+, Docker, and `psql`. **PostgreSQL 18 or later** — `uuidv7()` is the default on
six tables and does not exist before 18.

```sh
make up        # start postgres on :5433
make schema    # load schema/schema.sql + the seed chart
make test      # go test ./...
make help      # everything else
```

**Nothing is built yet.** This repository is at the design stage: the deliverable is
[`docs/decisions/`](./docs/decisions/), and `schema/schema.sql` exists to show that the shape those
decisions describe is expressible with declarative constraints alone. `go test ./...` covers
nothing so far.

## Layout

```
docs/             THE DELIVERABLE — vision, decisions, reference product spec
schema/           the design schema: tables, CHECKs, foreign keys, 5 views, and
                  8 triggers over 2 functions -- each justified in place, per
                  decisions/0012. chart.sql seeds an example chart of accounts.
spikes/           timeboxed investigations, one directory each.
                  Separate Go modules, not built by CI.
cmd/openledger/   entrypoint. Prints "nothing to run yet".
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
