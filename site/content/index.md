# OpenLedger

An open-source **double-entry ledger** — Postgres for the schema, Rust for the service that will
sit on it.

**This is a personal design project. Nobody has run it in production, and it is not asking to be.**
The schema and the command that applies it are built; the ledger service is not. If you need a
ledger in production, [use Formance](https://github.com/formancehq/ledger); [the vision](/vision)
says why, and what this does differently.

| | |
| --- | --- |
| [Vision](/vision) | Why this exists when Formance already does |
| [The database](/database) | The schema drawn and explained, assuming nothing |
| [Decisions](/decisions) | One file per decision, with its evidence and its cost |
| [Roadmap](/roadmap) | What gets built next, and why in that order |

## What a ledger is

A **ledger** answers one question — *who is owed what* — in a way that cannot quietly go wrong. It
does that with **double entry**: every amount is written twice, once as a debit and once as a
credit, and the two sides must sum to the same amount. [The database](/database) teaches the rest
from scratch, with the [glossary](/glossary) to dip into while you read it.

The bet: most teams that need a real ledger do not need a fast one, but every one of them needs a
correct one. Every cent accounted for, no manual fixes, and any number reproducible as of any date,
forever — cheap to build in, painful to retrofit.

## Running it

```sh
make up        # PostgreSQL 18 in Docker
make migrate   # openledger migrate -- the same subcommand a deploy runs
make chart     # seed an example chart of accounts
make docs      # read all of this at localhost:3000
```

`migrations/00001_baseline.sql` is the ledger core. It creates the chart-of-accounts tables and
leaves them **empty**: the chart is data, seeded separately, and yours will differ
([ADR-0007](/decisions/0007-schema-conventions-and-chart)).

[**The database**](/database) has the diagram, every table, and why each one has the shape it has.
Read it before the SQL.

**What exists today** is the [roadmap](/roadmap); what the database does not hold yet is a roadmap
milestone, and every limitation a decision accepted is in that ADR's own *"What it costs"*.

## Two rules run through everything

- **Correctness is not configurable.** No flag turns an invariant off. *Where* each one is enforced
  is itself a decision — some in the schema, some by construction in the writer — and the decision
  log keeps the [inventory](/database#what-the-schema-enforces-today) of which is which today.
- **A claim needs evidence next to it.** Where a document states a number it should be reproducible
  from this tree, and where it is not, the document says so.

## Performance

**No number here is a benchmark, and several in-repo documents quote figures that are only shapes.**
[Spike 003](/spikes/003-throughput-ceiling) measured the design with durability on, but everything
so far ran on localhost, which reorders the tuning levers rather than merely scaling the result, so
nothing gets published until it is measured over a real network.
[The vision](/vision#performance) has the figures and what they are worth.
