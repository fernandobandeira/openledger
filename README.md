# openledger

An open-source double-entry ledger. Postgres for storage, Go for the service — a single binary
and a database you already know how to operate.

The bet: most teams that need a real ledger do not need a fast one, but every one of them needs
a correct one. Every cent accounted for, no manual fixes, and any number reproducible as of any
date, forever. Those properties are cheap to build in and painful to retrofit.

Its **reference implementation** is an embedded B2B charge card funded by a credit line. That
product exists to prove the core carries something real without forking, and to give the core a
demanding acceptance test — it is not the project.

**Status:** pre-implementation. The schema exists and is verified, but lives in a spike until M1
graduates it. See [docs/roadmap.md](./docs/roadmap.md).

## Start here

| | |
| --- | --- |
| [docs/vision.md](./docs/vision.md) | What this is, who it is for, and what is non-negotiable. **Read this first.** |
| [docs/roadmap.md](./docs/roadmap.md) | What gets built, in what order, and why that order |
| [docs/decisions/](./docs/decisions/) | ADRs — every architectural decision and its reasoning |
| [spikes/](./spikes/) | Timeboxed investigations — brief, findings, and code together |
| [docs/v1-vision.md](./docs/v1-vision.md) | The reference product spec ([original design board](./docs/v1-vision.html)) |

## The core

| | |
| --- | --- |
| Accounts | typed by category and normal balance, multi-tenant, multi-currency |
| Transactions | the unit of atomicity; status never mutates |
| Entries | immutable, append-only, balanced per currency |
| Balances | O(1) current balance, plus as-of reads on two time axes |
| Bitemporal reads | recorded axis and effective axis, never conflated |
| Event log | the idempotency spine and audit trail |

Four properties of the core are not settings: **append-only** (enforced by revoking `UPDATE` and
`DELETE` from the app role), **balanced per currency** (enforced by the database), **bitemporal**,
and **event-logged**. [Spike 001](./spikes/001-formance/README.md) documents what happens when a
ledger makes historization configurable — point-in-time queries that silently return empty
results. We do not offer that trade.

## Performance

[Spike 003](./spikes/003-throughput-ceiling/README.md) measured the design rather than assuming
it, with durability on throughout. The full ladder, the two tuning levers, and the reasons they
cancel each other unless you choose correctly are all there.

**No headline number here on purpose.** Everything measured so far ran on localhost, where a
round trip costs 0.05ms. On RDS it costs roughly 0.5ms, and the clearing path takes six of them
against 1.3ms of real work — which reorders the tuning levers rather than merely scaling the
result. Nothing has been measured over a network, so nothing is published.

What the measurements do support: the bottleneck is contention on a single shared row rather than
hardware, and throughput is close to insensitive to table size (unchanged at 5M entries and 2 GB
against 128 MB of cache) because the workload is append-only.

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
docs/             vision, roadmap, decisions, reference product spec
spikes/           timeboxed investigations: brief + findings + throwaway code,
                  one directory each. Separate Go modules, not built by CI.
```
