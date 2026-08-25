# openledger

A double-entry ledger for embedded B2B spend management — a charge card funded by a credit
line, where the same table is simultaneously the system of record for customer funds, a
lender's collateral, and the financial statements.

**Status:** pre-implementation. Schema not written yet. See [docs/roadmap.md](./docs/roadmap.md).

## Start here

| | |
| --- | --- |
| [docs/v1-vision.md](./docs/v1-vision.md) | The design. Read this first. ([original board](./docs/v1-vision.html)) |
| [docs/roadmap.md](./docs/roadmap.md) | What gets built, in what order, and why that order |
| [docs/decisions/](./docs/decisions/) | ADRs — why the stack is what it is |
| [spikes/](./spikes/) | Timeboxed investigations — brief, findings, and code together |

## The shape of it, in four sentences

Throughput is not the constraint — under 1 TPS average, so one Postgres instance, no cache, no
sharding. Correctness and auditability are the constraints: every cent, and any number
reproducible as of any date, forever. An authorization writes **no ledger entry** — it records
a hold; the ledger first hears about a purchase at clearing. Everything with a timer runs as a
durable workflow over idempotent activities.

## Local development

Requires Go 1.26+, Docker, and `psql`.

```sh
make up        # start postgres on :5433
make migrate   # apply migrations
make test
make help      # everything else
```

## Layout

```
cmd/openledger/   entrypoint
internal/ledger/  the ledger core — accounts, transactions, entries, posting
internal/pg/      database plumbing
migrations/       ordered .sql, applied by `make migrate`
docs/             vision, roadmap, decisions, spike briefs
spikes/           timeboxed investigations: brief + findings + throwaway code,
                  one directory each. Separate Go modules, not built by CI.
```
