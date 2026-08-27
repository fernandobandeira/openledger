# openledger

An open-source **double-entry ledger** — Postgres for storage, Rust for the service. A single
binary and a database you already know how to operate.

**The documentation is the deliverable, and it lives in [`site/content/`](./site/content/).** It is
ordinary markdown, readable straight from that directory, and it is also a site:

```sh
make docs         # read it at localhost:3000 — sidebar, search, the ERD
make docs-build   # or build it to site/out/ and host that anywhere
```

Start with [`site/content/index.md`](./site/content/index.md) for what this is,
[`database.md`](./site/content/database.md) for the schema drawn and explained, and
[`decisions/`](./site/content/decisions/) for why every piece has the shape it has.

## Running the database

```sh
make up        # PostgreSQL 18 in Docker
make migrate   # openledger migrate — applies the baseline, then exits
make chart     # seed an EXAMPLE chart of accounts; yours will differ
```

## Layout

```
site/content/     THE DELIVERABLE — vision, glossary, the database page,
                  the decision log, the roadmap, the spike write-ups.
site/             the viewer over it: `make docs`. Generated pages for the
                  files below land in content/source/ and are not committed.
migrations/       the schema, as one numbered migration, with the reasoning
                  in comments beside each object.
schema/           chart.sql: an EXAMPLE chart of accounts, seeded separately
                  by `make chart`. No migration owns it.
parked/card/      the card product's schema, written and not deployed.
src/              the binary. `openledger migrate` is its only command.
spikes/           timeboxed investigations, one directory each: the code
                  stays here, the write-up is in site/content/spikes/.
```

**Status: design stage, with the first thing built.** The schema and the command that applies it are
real. There is still no service and no test suite beyond the two that guard ADR-0003's rules — a SQL
implementation and its harness were deleted, and why is
[ADR-0004](./site/content/decisions/0004-where-logic-lives.md).

## Licence

[MIT](./LICENSE).
