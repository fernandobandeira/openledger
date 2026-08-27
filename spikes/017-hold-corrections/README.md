# Spike 017 — the card rail's recorded-not-closed hold findings

Evidence for [card ADR-0002](../../site/content/card/decisions/0002-hold-corrections.md).
Ran 2026-08-27 against PostgreSQL 18.6.

`./run.sh` builds a scratch database (baseline, then `parked/card/schema.sql`), reproduces every
finding on the parked schema as it stands, then loads the proposed DDL into a second schema
beside it and re-runs the same scenarios.

| | |
| --- | --- |
| `00-harness.sql` | the ingest path and sweep as ADR-0001 describes them. **Spike only** — the card writer does not exist, so a finding in the ingest path needs an ingest path to reproduce it. Never product code. |
| `01`…`09` | one finding each, on the unmodified parked schema |
| `08-deadlock.sh` | two concurrent sessions; 6 trials each way |
| `20-proposed-ddl.sql` | the proposed hunks against `parked/card/schema.sql` |
| `21-fixed-harness.sql` | the same ingest path under ADR-0002's rules |
| `22-proved.sql` | every scenario re-run, plus the no-regression cases |
| `23-permutations.sql` | all six arrival orders of one three-message set, before and after |

Nothing here is application machinery, and nothing here is applied by a migration.
