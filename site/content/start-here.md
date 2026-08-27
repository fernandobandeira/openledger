# Documentation

**Read in this order:** [`glossary.md`](/glossary) if the vocabulary is new, then
[`vision.md`](/vision) for what this is and why, then [`decisions/`](/decisions) for how every
piece got the shape it has. [`database.md`](/database) is the entry point for the schema
itself. [`reference-product.md`](/reference-product) is the worked example
underneath all of it — one $500 purchase, traced through every account it touches.

| | |
| --- | --- |
| [glossary.md](/glossary) | Every term, defined for someone who has never built a ledger. |
| [vision.md](/vision) | Why this exists when Formance already does, and what it deliberately does not do. |
| [decisions/](/decisions) | One file per decision, with the evidence. [decisions/README](/decisions) is the index and carries what is still open. |
| [database.md](/database) | **The entry point for the schema** — every table drawn and explained, and why each one has the shape it has. |
| [reference-product.md](/reference-product) | The embedded charge card the ledger is designed against: the chart of accounts, and the lifecycle in text. |
| [roadmap.md](/roadmap) | What gets built next, and why in that order. |

## What a ledger is, in one paragraph

A **ledger** answers one question — *who is owed what* — in a way that cannot quietly go wrong. It
does that with **double entry**: every amount is written twice, once as a debit and once as a
credit, and the two sides must sum to zero. The rest is consequences. Entries are never updated or
deleted, because a correction that edits history is indistinguishable from a lie; you post a new,
opposite entry instead. Balances are derived from entries, never the other way round.

This project is that ledger, in Rust and PostgreSQL, with an **embedded B2B charge card** as the
reference product. The card is not a demo — it is what forced the hard parts: authorizations that
reserve money without moving it, clearings that move it, and processor messages that arrive out of
order, twice, or never.

## The diagrams

**There are five, in two sets.** The first three are the canonical drawings of the *system*; they
were extracted from an earlier HTML design board that has since been removed — it had drifted from
the decisions in three major ways and existed mainly to be corrected. Everything it was best at now
lives in prose: the sizing derivation in [0002](/decisions/0002-scaling), the authorization
latency budget in [0008](/decisions/0008-authorization-holds), and the lifecycle trace in
[reference-product.md](/reference-product). **04 and 05 came later and belong to
[`database.md`](/database)**, which is where they are explained; they are listed here so this
page is not the reason someone thinks there are three. An earlier version of this section called the
first three *"the only drawings of the system"*; the count moved and the sentence did not.

| | |
| --- | --- |
| ![Architecture](/diagrams/01-architecture.svg) | **01 — Architecture.** The authorization decision runs synchronously; the ledger write does not. **Read with two caveats.** The Postgres store it draws as *"availability + holds — one row per hold group"*, fed by `SELECT … FOR UPDATE` and `INSERT hold`, **is not deployed**: that DDL is parked in [`parked/card/`](/parked-card) and applied by no migration. And the mutable row it draws predates [0008](/decisions/0008-authorization-holds), which **rejected that shape** — a hold is a `SUM` over an append-only event log, never a running amount anyone updates. |
| ![The authorization hot path](/diagrams/02-auth-hot-path.svg) | **02 — The authorization hot path.** The ~1s network deadline and the 300 ms p99 budget — see [0008](/decisions/0008-authorization-holds). |
| ![State machines](/diagrams/03-state-machines.svg) | **03 — State machines.** Hold, clearing and settlement lifecycles, as decided in [0008](/decisions/0008-authorization-holds). |
| ![Database ERD](/diagrams/04-database-erd.svg) | **04 — The core ledger, drawn.** Seven tables in three layers. Belongs to [`database.md`](/database). |
| ![Report direction](/diagrams/05-report-direction.svg) | **05 — Two ways to build a report**, and the chart line that goes missing when you build it from the entries instead of the chart ([0007](/decisions/0007-schema-conventions-and-chart)). Belongs to [`database.md`](/database). |

## Two rules run through everything

- **Correctness is not configurable.** No flag turns an invariant off. *Where* each one is enforced
  is itself a decision — some in the schema, some by construction in the writer — and
  [decisions/README](/decisions#what-the-schema-enforces-today) keeps the honest
  inventory of which is which today.
- **A claim needs evidence next to it.** Where a document states a number it should be reproducible
  from this tree, and where it is not, the document says so.

## Status

**Design stage.** The service is not built. What is built is the database and the command that
applies it:

```sh
make up        # PostgreSQL 18 in Docker
make migrate   # openledger migrate -- the same command a deploy runs
make chart     # seed the EXAMPLE chart of accounts
make test      # cargo test  -- 2 tests, both about ADR-0003's rules
```

[**database.md**](/database) is the guided tour of what that leaves you with: the diagram,
every table, and why each one has the shape it has. Read it before the SQL.
