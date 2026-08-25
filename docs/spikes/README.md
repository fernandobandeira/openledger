# Spikes

A spike is **timeboxed investigation to kill a specific uncertainty**, not exploratory coding.
Every spike brief states the question, the timebox, and what evidence would settle it — before
any code is written. Throwaway code lives in `/spikes/<nnn>-<slug>/` and is not part of the
build.

A spike ends one of three ways: it answers its question (write the finding back into an ADR),
it proves the question was wrong (say so), or it hits the timebox (record what's known and
decide with partial information — do not extend silently).

| # | Question | Blocks | Status |
| --- | --- | --- | --- |
| [001](./001-formance.md) | What can we take from Formance's open-source ledger? | produced [ADR-0003](../decisions/0003-bitemporal-balances.md) | **closed** |
| [002](./002-sqlc-vs-jet.md) | sqlc or go-jet? | [ADR-0002](../decisions/0002-data-access-layer.md) | **closed** — sqlc |
