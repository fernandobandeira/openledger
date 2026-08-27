# Spike 015 — Can the append-only perimeter's event triggers be applied on managed PostgreSQL?

**Status:** closed. **AWS RDS and Aurora PostgreSQL 18 clear the bar via the master account; GCP
Cloud SQL and Azure Flexible Server do not.** Flips the pessimistic assumption in
[ADR-0009](/decisions/0009-append-only-perimeter) and closes the decision log's "event triggers on
managed Postgres are untested" row. Feeds [ADR-0009](/decisions/0009-append-only-perimeter).

**Question.** [ADR-0009](/decisions/0009-append-only-perimeter) folds three `CREATE EVENT TRIGGER`
statements plus three matching `ALTER EVENT TRIGGER … ENABLE ALWAYS` and eighteen
`ALTER TABLE … ENABLE ALWAYS TRIGGER` into `migrations/00001_baseline.sql`. Standard PostgreSQL says
*"Only superusers can create event triggers."* ADR-0009 recorded the AWS master role as `NOSUPERUSER`
and listed event triggers as **untested** on managed Postgres — the question that gated whether the
baseline is installable on the RDS target at all. The full evidence, with primary-source URLs
and the unrun confirmatory script, is in the repository at
`spikes/019-managed-postgres-event-triggers/NOTES.md`. The RDS target is PostgreSQL 18.

**Ran** 2026-08-27 · desk research against AWS / GCP / Azure and PostgreSQL primary docs. No managed
instance was available, so the confirmatory `test_managed.sh` is written but **unrun** — it needs a
real RDS/Aurora endpoint to mean anything; `localhost` is self-managed and does not reproduce the
restriction.

## The answer

**On AWS RDS for PostgreSQL 18 — the RDS target — the whole baseline is appliable, using the master
`postgres` account.** AWS special-cases event triggers: although the master role is `NOSUPERUSER`, a
dedicated AWS feature page documents that *"You can use the main user account (default, `postgres`)
to create, modify, rename, and delete event triggers."* "Create" covers `CREATE EVENT TRIGGER`;
"modify" covers `ALTER EVENT TRIGGER … ENABLE ALWAYS`. It is a capability attached to the master
account, not a `rds.*` parameter to flip. **Amazon Aurora PostgreSQL** (same managed master model)
behaves the same. This flips ADR-0009's reasoning: it had argued from the `rds_superuser` role page,
which does not mention event triggers, and missed AWS's separate feature-support page that does.

**The eighteen `ALTER TABLE … ENABLE ALWAYS TRIGGER` never needed a superuser anywhere.** They act on
*ordinary user-defined* triggers (`ck_*__append_only`, `ck_*__no_truncate`, …), for which PostgreSQL
requires only table ownership — superuser is required only for internally generated constraint
triggers. So those clauses apply as the plain table owner on RDS, Aurora and self-managed alike. The
only superuser-gated statements are the three `CREATE EVENT TRIGGER` and their three
`ENABLE ALWAYS` — exactly what RDS/Aurora bless for the master account.

**GCP Cloud SQL and Azure Flexible Server do NOT permit customer event triggers.** Neither exposes a
true superuser, and neither lists event triggers among its exceptions (Cloud SQL allows only
`CREATE EXTENSION` and `CREATE`/`DROP CAST`; Azure's official answer is *"an event trigger is not
supported"*). On either, this DDL perimeter reverts to [ADR-0009](/decisions/0009-append-only-perimeter)'s
own fallback: the CI schema-snapshot test alone.

**`session_replication_role`** — needed by the replication-apply and data-only-restore cost rows, not
by 0009's chosen design — is reachable by the RDS/Aurora customer on PG 15+ via
`GRANT SET ON PARAMETER session_replication_role TO <role>`.

**The residual gate is the role split, not the provider.** ADR-0009 requires a migrator that owns the
*tables* and not the *database*. On RDS the master `postgres` account is both a `NOSUPERUSER` owner
*and* the account AWS blesses for event-trigger DDL, so the split has to be arranged **within** the
RDS role model — a deployment-shape task, unchanged by this finding.
