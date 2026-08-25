# Decisions (ADRs)

One file per decision, numbered, never deleted. A decision that turns out wrong gets a new
ADR that supersedes it — the old one stays, with its status changed, so the reasoning trail
survives.

Status: `proposed` · `accepted` · `superseded by NNNN` · `rejected`

| # | Decision | Status |
| --- | --- | --- |
| [0001](./0001-go-and-postgres.md) | Go + Postgres, no ORM | accepted |
| [0002](./0002-data-access-layer.md) | Data access: native pgxpool + sqlc | accepted — reversed its own proposal, see [spike 002](../spikes/002-sqlc-vs-jet.md) |
