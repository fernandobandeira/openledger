# Decisions (ADRs)

One file per decision, numbered, never deleted. A decision that turns out wrong gets a new
ADR that supersedes it — the old one stays, with its status changed, so the reasoning trail
survives.

Status: `proposed` · `accepted` · `superseded by NNNN` · `rejected`

| # | Decision | Status | Amended by 0007 |
| --- | --- | --- | --- |
| [0001](./0001-go-and-postgres.md) | Go + Postgres, no ORM | accepted | sizing superseded; **Temporal dependency flagged** |
| [0002](./0002-data-access-layer.md) | Data access: native pgxpool + sqlc | accepted — reversed its own proposal, see [spike 002](../../spikes/002-sqlc-vs-jet/README.md) | strengthened |
| [0003](./0003-bitemporal-balances.md) | Balances on two time axes: aggregate-on-read for the effective axis | accepted | **read-path cost now unmeasured** |
| [0004](./0004-event-log.md) | An append-only event log — the idempotency spine | accepted | strengthened; replay requirement added |
| [0005](./0005-reproducible-as-of.md) | A reproducible as-of cursor | **proposed** — blocks M4 | open question 4 answered |
| [0006](./0006-schema-conventions.md) | Schema conventions: naming, snapshot test, FKs, enums | accepted | strengthened |
| [0007](./0007-open-source-positioning.md) | Positioning: a general open-source ledger | **proposed** | — |

## The 0007 audit

[ADR-0007](./0007-open-source-positioning.md) reframes the project from a purpose-built
single-product ledger into a general open-source one, which invalidates reasoning several earlier
ADRs relied on — most of it variations of *"we are one product, at under 1 TPS."* Every ADR above
has been audited against it and amended in place; **no decision was reversed**, and every
amendment is marked as such so the original reasoning stays readable.

Three outcomes are worth reading directly rather than trusting the table:

- **[0001 — Temporal](./0001-go-and-postgres.md#amendment--temporal-is-an-unexamined-dependency-for-the-open-source-goal).**
  Half of 0001's case for Go is Temporal SDK quality. Temporal is a server cluster, not a
  library, and 0007's "drop into AWS" goal never accounts for it. Needs its own ADR before M6.
- **[0003 — the read path](./0003-bitemporal-balances.md#amendment--the-read-path-assumption-is-now-unsafe).**
  Aggregate-on-read was justified by "thousands of rows, not millions." Spike 003 measured the
  *write* path only, and the accounts it identified as hottest are exactly those that accumulate
  the most entries. The decision stands; its cost is unmeasured. Needs a spike before M4.
- **[0004 — hash chaining](./0004-event-log.md#deferred-deliberately).** "At our volume the
  serialization is free" is measurably false for a general engine: a per-write chain lock is a
  *global* contention point, so it nullifies every throughput lever 0007 depends on.

Where the pivot **strengthened** a decision, that is recorded too — 0002, 0004, 0005, and 0006
all now rest on measurement from [spike 003](../../spikes/003-throughput-ceiling/README.md)
rather than on an assumption about volume.
