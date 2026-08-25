# Decisions (ADRs)

One file per decision, numbered, never deleted. A decision that turns out wrong gets a new
ADR that supersedes it — the old one stays, with its status changed, so the reasoning trail
survives.

Status: `proposed` · `accepted` · `superseded by NNNN` · `rejected`

| # | Decision | Status |
| --- | --- | --- |
| [0001](./0001-go-and-postgres.md) | Go + Postgres, no ORM | accepted |
| [0002](./0002-data-access-layer.md) | Data access: native pgxpool + sqlc | accepted — reversed its own proposal, see [spike 002](../../spikes/002-sqlc-vs-jet/README.md) |
| [0003](./0003-bitemporal-balances.md) | Balances on two time axes: aggregate-on-read for the effective axis | accepted |
| [0004](./0004-event-log.md) | An append-only event log — the idempotency spine | accepted |
| [0005](./0005-reproducible-as-of.md) | A reproducible as-of cursor | **proposed** — blocks M4 |
| [0006](./0006-schema-conventions.md) | Schema conventions: naming, snapshot test, FKs, enums | accepted |
| [0007](./0007-open-source-positioning.md) | Positioning: a general open-source ledger | **proposed** |
