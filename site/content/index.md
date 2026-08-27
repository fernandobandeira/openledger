# openledger

An open-source **double-entry ledger** — Postgres for storage, Rust for the service. A single
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

**Status: design stage, with the first thing built.** The deliverable is still
[the decision log](/decisions) — but the database now has a real migration and a real
command that applies it. `migrations/00001_baseline.sql` is the ledger core, `openledger migrate`
applies it, and it seeds nothing: it *creates* the chart-of-accounts tables and leaves them empty —
after `migrate` alone, `fs_lines` has 0 rows. The example chart is `schema/chart.sql`, loaded
separately by `make chart` (13 statement lines, 20 account types).
[**The database page**](/database) draws it and explains every table. **There is still no test suite and no service**: a SQL implementation and
its harness were deleted, and why is [ADR-0004](/decisions/0004-where-logic-lives).

## Start here

**Never built a ledger? Start with [the glossary](/glossary).** It defines every term
the rest of this uses, so nothing else has to stop and re-explain.

| | |
| --- | --- |
| [the glossary](/glossary) | Every term, for someone who has never built a ledger |
| [Vision](/vision) | Why this exists when Formance already does |
| [Roadmap](/roadmap) | What gets built next, and why in that order |
| [Decisions](/decisions) | One file per decision, and what is still open |
| [The database](/database) | **The database, drawn and explained** — start here for the schema |
| [migrations/00001_baseline.sql](/source/baseline) | The schema itself, with the reasoning in comments |
| [spikes/](/spikes) | Timeboxed investigations: brief, findings, sources |

## Layout

```
site/content/     THE DELIVERABLE — this page, the vision, the glossary, the
                  database page, the decision log, the roadmap, the spike
                  write-ups. Plain markdown, and also the site.
site/             the viewer over it: `make docs`.
migrations/       the schema, as one numbered migration, every object justified
                  in place per decisions/0004. The counted inventory lives in
                  "what the schema enforces today" in the decision log and is
                  deliberately not repeated here.
schema/           chart.sql: an EXAMPLE chart of accounts, seeded separately
                  by `make chart` -- no migration owns it. Yours will differ;
                  that is the point (decisions/0007).
parked/card/      the card product's schema, written and not deployed.
src/              the binary. `openledger migrate` is the only command it has.
                  build.rs exists so a new migration invalidates the build.
spikes/           timeboxed investigations, one directory each: the code stays
                  there, the write-up is in site/content/spikes/.
```

## Performance

**No number here is a benchmark, and several in-repo documents quote figures that are only
shapes.** Spike 003's own banner says so: re-auditing the same configurations moved its baseline
from 833 to 482 clearings/s. Treat every throughput figure here accordingly. [Spike 003](/spikes/003-throughput-ceiling)
measured the design with durability on, but everything so far ran on localhost — where a network
round trip costs 0.05 ms against roughly 0.5 ms on RDS. That reorders the tuning levers rather
than merely scaling the result, so nothing goes in a README until it is measured over a real
network. See [the vision doc](/vision#performance).

## Licence

`MIT` (`LICENSE`).
