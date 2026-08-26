# Documentation

Read in this order.

| | |
| --- | --- |
| [vision.md](./vision.md) | What this is, who it is for, and what it deliberately does not do. **Start here.** |
| [glossary.md](./glossary.md) | Every term used in the rest of these documents, defined for someone who has never built a ledger. |
| [reference-product.md](./reference-product.md) | The embedded B2B charge card built on the ledger — the worked example the schema is shaped around. |
| [decisions/](./decisions/) | One file per decision, with the evidence. [decisions/README.md](./decisions/README.md) is the index and carries what is still open. |
| [roadmap.md](./roadmap.md) | What gets built next, and why in that order. |
| [diagrams/](./diagrams/) | Architecture, data flow, state machines. |

## The shortest possible summary

A **ledger** answers one question — *who is owed what* — in a way that cannot quietly go wrong.
It does that with **double entry**: every amount is written twice, once as a debit and once as a
credit, and the two sides must sum to zero. If they ever do not, something is broken, and the
database refuses the write rather than storing a number nobody can trust.

This project is that ledger, in Go and PostgreSQL, with a **B2B charge card** built on top of it as
the reference product. The card is not a demo: it is the thing that forced the hard parts —
authorizations that hold money without moving it, clearings that move it, messages that arrive out
of order or twice or never.

Two rules run through everything here:

- **Correctness is not configurable.** The invariants are enforced by the database, on every write,
  for every caller, including the replication apply path. There is no flag that turns them off.
- **A claim needs evidence next to it.** Where a document states a number, it should be
  reproducible from this tree. Where it is not, the document says so. See
  [decisions/README.md](./decisions/README.md#on-sourcing).

## Running it

```
make up        # PostgreSQL 18 in Docker
make migrate   # apply migrations/ and the seed chart
make test-sql  # the whole suite: tests/run.sh
```

`tests/run.sh` prints one line per assertion and `PASS` or `FAIL` on the last line. There is no
partial credit — a suite that does not run to its own last line is a failure.
