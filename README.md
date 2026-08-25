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

**Status:** pre-implementation, but the schema is real and attested. `migrations/` holds the
ledger core, the chart of accounts, and the card hold model; `tests/` replays a full card
lifecycle against them, asserts the plans of the queries the docs promise are O(1), and then tries
thirty-eight ways to break it — each of which must be refused, and refused for the stated reason.
No Go service yet.

## Start here

| | |
| --- | --- |
| [docs/vision.md](./docs/vision.md) | What this is, what is non-negotiable, and a primer if you have never built a ledger. **Read this first.** |
| [docs/roadmap.md](./docs/roadmap.md) | What gets built, in what order, and why that order |
| [docs/decisions/](./docs/decisions/) | ADRs — every architectural decision and its reasoning |
| [tests/](./tests/) | The acceptance suites — a full card lifecycle, and every way we know to break it |
| [spikes/](./spikes/) | Timeboxed investigations — brief, findings, and code together |
| [docs/reference-product.md](./docs/reference-product.md) | The reference card product this ledger was designed against |

## Local development

Requires Go 1.26+, Docker, and `psql`.

```sh
make up        # start postgres on :5433
make migrate   # apply migrations
make test-sql  # replay the golden trace + every negative control
make test      # the above, plus go test
make help      # everything else
```

## Layout

```
cmd/openledger/   entrypoint
internal/ledger/  the ledger core — accounts, transactions, entries, posting
internal/pg/      database plumbing
migrations/       ordered .sql, applied by `make migrate`
                  seed/ is example data — the card chart of accounts
tests/            acceptance suites, run by `make test-sql` against a throwaway
                  database. Mostly SQL; concurrency.sh needs many sessions
docs/             vision, roadmap, decisions, reference product spec
spikes/           timeboxed investigations, one directory each.
                  Separate Go modules, not built by CI.
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
