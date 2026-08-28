# OpenLedger

An open-source **double-entry ledger** — Postgres for storage, Rust for the service. A single
binary and a database you already know how to operate.

**This is a personal design project. Nobody has run it in production, and it is not asking to be.**
The schema, the command that applies it, and the first slice of the service — one HTTP endpoint,
`POST /v1/transactions` — are built.

**The documentation is the deliverable, and it lives in [`site/content/`](./site/content/).** It is
ordinary markdown, readable straight from that directory, and it is also a site:

```sh
make docs         # read it at localhost:3000 — sidebar, the ERD
make docs-build   # or build it to site/out/ and host that anywhere
```

(Search works only on a built site — the index is generated from `site/out/` — so the `make docs`
dev server renders the search box and finds nothing.)

Start with [`site/content/index.md`](./site/content/index.md) for what this is,
[`database.md`](./site/content/database.md) for the schema drawn and explained, and
[`decisions/`](./site/content/decisions/) for why every piece has the shape it has.

## Running it

```sh
make up        # PostgreSQL 18 in Docker
make migrate   # openledger migrate — applies the baseline, then exits
make chart     # seed an EXAMPLE chart of accounts; yours will differ
make test      # every test, the e2e suite included, against that postgres
```

The service is the same binary: `openledger serve` — in development,
`DATABASE_URL=… cargo run -- serve` — checks the schema is current and then serves the one
endpoint, `POST /v1/transactions`, on `127.0.0.1:8080`
([the service page](./site/content/service.md)).

## Layout

```
site/content/     THE DELIVERABLE — vision, glossary, the database page, the
                  service page, the decision log, the roadmap, the spike
                  write-ups.
site/             the viewer over it: `make docs`.
migrations/       the schema, as one numbered migration, with the reasoning
                  in comments beside each object.
schema/           chart.sql: an EXAMPLE chart of accounts, seeded separately
                  by `make chart`. No migration owns it.
parked/card/      the card product's schema, written and not deployed.
crates/           the workspace: `ledger` (the domain and the writer, no
                  sqlx), its `postgres` adapter, `db` (connections and
                  migrations), `api` (HTTP), `openledger` (the one binary:
                  `migrate` and `serve`), and `e2e` (the suite that spawns
                  the binary and posts over the wire).
scripts/          check-migrations-immutable.sh — the CI guard that keeps
                  committed migrations immutable.
deny.toml         the dependency policy CI and `make deny` enforce.
spikes/           timeboxed investigations, one directory each: the code
                  stays here, the write-up is in site/content/spikes/.
```

**What exists and what does not** is the [roadmap](./site/content/roadmap.md); what the database
does not enforce yet is the decision log's *Still open* list.

## Licence

[MIT](./LICENSE).
