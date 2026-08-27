# 019 — Can the append-only perimeter's event triggers be applied on managed PostgreSQL?

**Question.** [ADR-0009](/decisions/0009-append-only-perimeter) folds three `CREATE EVENT TRIGGER`
statements (on `table_rewrite`, `sql_drop`, `ddl_command_end`) plus three matching
`ALTER EVENT TRIGGER … ENABLE ALWAYS` and eighteen `ALTER TABLE … ENABLE ALWAYS TRIGGER` into
`migrations/00001_baseline.sql`. Standard PostgreSQL says *"Only superusers can create event
triggers."* ADR-0009 records that the AWS master role is `NOSUPERUSER` and lists event triggers as
**untested** on managed Postgres — Still-open row 2, gating whether the baseline is installable on
the M4 (RDS) target at all. This spike answers it from primary sources. The M4 target is PG 18.

**Ran.** 2026-08-27. Desk research against AWS / GCP / Azure and PostgreSQL primary docs (URLs and
quoted operative sentences below, all accessed 2026-08-27). No managed instance was available;
`localhost:5433` is self-managed and does **not** reproduce the managed restriction, so the
confirmatory test (`test_managed.sh`, in this directory) is written but **unrun** — it needs a real
RDS/Aurora endpoint to mean anything. Spike 010's `11_privileges_nosuper.sh` already establishes the
self-managed non-superuser-owner baseline: a plain database owner installs the event triggers **not
at all**.

---

## The answer

**On AWS RDS for PostgreSQL 18 — the M4 target — the whole baseline IS appliable, using the master
`postgres` account.** AWS special-cases event triggers: although the master role is `NOSUPERUSER`,
AWS documents in a dedicated page that *"You can use the main user account (default, `postgres`) to
create, modify, rename, and delete event triggers."* "Create" covers `CREATE EVENT TRIGGER`;
"modify" covers `ALTER EVENT TRIGGER … ENABLE ALWAYS`. This is a documented mechanism, not a
parameter — there is no `rds.*` GUC to flip; the capability is attached to the master account
itself. The same holds for **Amazon Aurora PostgreSQL** (same managed `rds_superuser`/`postgres`
master model; Aurora PG 18 exists as of 18.3).

**This flips ADR-0009's stated assumption.** 0009 reasoned from the `rds_superuser` role page —
which lists what the role allows and does **not** mention event triggers — and concluded the answer
was probably no. It did not find AWS's **separate** feature-support page that documents event
triggers as explicitly available to the master account. The pessimistic "What it costs" line
("Whether a managed PostgreSQL clears the bar is untested… M4 is where this gets answered") is now
answered: **for RDS/Aurora, yes.**

**The eighteen `ALTER TABLE … ENABLE ALWAYS TRIGGER` never needed a superuser anywhere.** They act
on *ordinary user-defined* triggers (`ck_entries__append_only`, `ck_*__no_truncate`, …), and
PostgreSQL requires only table ownership for those — superuser is required *only* for internally
generated constraint triggers. So those clauses apply as the plain table owner on RDS, Aurora, and
self-managed alike. The only superuser-gated statements in the baseline are the three
`CREATE EVENT TRIGGER` / three `ALTER EVENT TRIGGER … ENABLE ALWAYS` — and RDS/Aurora clear exactly
those for the master account.

**GCP Cloud SQL and Azure Flexible Server do NOT permit customer event triggers.** Both withhold
true superuser; neither lists event triggers among its superuser exceptions (Cloud SQL allows only
`CREATE EXTENSION` and `CREATE/DROP CAST`; Azure allows none, official answer: *"an event trigger is
not supported"*). On either of those a future deployment would hit ADR-0009's own fallback: the DDL
perimeter reverts to being covered by the CI schema-snapshot test alone.

**`session_replication_role` (needed by the replication-apply and data-only-restore open rows, not
by 0009's chosen design) is available to the RDS/Aurora customer on PG 18** via
`GRANT SET ON PARAMETER session_replication_role TO <role>` (PG 15+); on PG 14 and earlier it needed
`rds_superuser`.

**The residual gate is not the managed provider — it is the role split.** ADR-0009 already requires
a migrator that owns the *tables* and not the *database*. On RDS the master `postgres` account is
both a `NOSUPERUSER` owner *and* the account AWS blesses for event-trigger DDL, so the split has to
be arranged **within** the RDS role model (master creates the guard and the tables' owner role;
the guard's owner sits beyond the migrator). That is an M4 deployment-shape task, unchanged by this
finding.

---

## The evidence

### PostgreSQL 18 — the superuser rule the baseline runs into

- `CREATE EVENT TRIGGER`, Notes: **"Only superusers can create event triggers."**
  <https://www.postgresql.org/docs/current/sql-createeventtrigger.html> (accessed 2026-08-27)
- `ALTER EVENT TRIGGER`: **"You must be superuser to alter an event trigger."** — so
  `ALTER EVENT TRIGGER … ENABLE ALWAYS` is superuser-gated on standard PostgreSQL too.
  <https://www.postgresql.org/docs/current/sql-altereventtrigger.html> (accessed 2026-08-27)
- `ALTER TABLE`: **"You must own the table to use `ALTER TABLE`."** and, for the enable/disable of
  triggers, superuser is required only **"if any of the triggers are internally generated constraint
  triggers, such as those that are used to implement foreign key constraints or deferrable uniqueness
  and exclusion constraints."** The baseline's eighteen `ENABLE ALWAYS` clauses target ordinary
  user triggers, so **table ownership alone suffices** — not superuser.
  <https://www.postgresql.org/docs/current/sql-altertable.html> (accessed 2026-08-27)

So exactly six statements in the baseline are superuser-gated on stock PostgreSQL (3× CREATE EVENT
TRIGGER, 3× ALTER EVENT TRIGGER ENABLE ALWAYS). Everything else applies as table owner.

### AWS RDS for PostgreSQL — event triggers are documented as available to the master account

Dedicated feature-support page, *Event triggers for RDS for PostgreSQL*:

> **"All current PostgreSQL versions support event triggers, and so do all available versions of RDS
> for PostgreSQL. You can use the main user account (default, `postgres`) to create, modify, rename,
> and delete event triggers. Event triggers are at the DB instance level, so they can apply to all
> databases on an instance."**

Limitations quoted from the same page (both relevant to M4 operations):

> "You can't create event triggers on read replicas. You can, however, create event triggers on a
> read replica source. The event triggers are then copied to the read replica. The event triggers on
> the read replica don't fire on the read replica when changes are pushed from the source. However,
> if the read replica is promoted, the existing event triggers fire when database operations occur."

> "To perform a major version upgrade to a PostgreSQL DB instance that uses event triggers, make sure
> to delete the event triggers before you upgrade the instance."

<https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.FeatureSupport.EventTriggers.html>
(accessed 2026-08-27)

The master account is genuinely `NOSUPERUSER` — this is the page ADR-0009 reasoned from, and it is
correct as far as it goes; it just is not the whole story:

> `CREATE ROLE postgres WITH LOGIN NOSUPERUSER INHERIT CREATEDB CREATEROLE NOREPLICATION VALID UNTIL 'infinity'`
>
> "In the `CREATE ROLE postgres...` statement, you can see that the `postgres` user role specifically
> disallows PostgreSQL `superuser` permissions. RDS for PostgreSQL is a managed service, so you can't
> access the host OS, and you can't connect using the PostgreSQL `superuser` account."

<https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Roles.rds_superuser.html>
(accessed 2026-08-27)

**The reconciliation:** RDS grants the master `postgres` account the *specific* right to run
event-trigger DDL that would otherwise require superuser, and documents that grant on the
feature-support page rather than the role page. No `rds.*` parameter is involved; there is nothing to
enable. This has held across RDS PG versions ("all available versions of RDS for PostgreSQL"), so it
is not a PG-18-only capability.

### Amazon Aurora PostgreSQL — same managed model, same master account

Aurora uses the identical `rds_superuser`/master-account arrangement:

> "The `rds_superuser` role is the most privileged role on an Aurora PostgreSQL DB cluster. This role
> is created automatically, and it's granted to the user that creates the DB cluster (the master user
> account, `postgres` by default)."

<https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraPostgreSQL.Security.html>
(accessed 2026-08-27; the same page confirms Aurora PostgreSQL major version 18 exists — 18.3 cipher
parameters are listed.)

AWS's event-trigger feature-support text ("You can use the main user account… to create, modify,
rename, and delete event triggers") is shared PostgreSQL feature-support documentation across the RDS
and Aurora engines. **Residual:** I could not fetch a distinct Aurora-namespace copy of the
event-triggers page (a guessed AuroraUserGuide URL 404'd); the Aurora answer rests on the identical
managed role model plus the shared feature-support page. If M4 ever targets Aurora rather than RDS,
run `test_managed.sh` against an Aurora endpoint to confirm — the mechanism is the same, but this is
the one claim without an Aurora-namespace page in hand.

### `ALTER TABLE … ENABLE ALWAYS TRIGGER` and `session_replication_role` on RDS/Aurora

- The eighteen `ENABLE ALWAYS` clauses on user triggers: table-owner only (PostgreSQL `ALTER TABLE`,
  above). The master account owns the tables it created, so these apply. This is unrelated to the
  event-trigger question and works on self-managed too.
- `session_replication_role` — a superuser-context GUC on stock PostgreSQL (spike 010 measured a
  plain owner getting `permission denied to set parameter`). On RDS/Aurora the customer's top role
  **can** be granted it. From AWS re:Post, *Turn off foreign keys on an RDS for PostgreSQL instance*:
  > "For PostgreSQL 15 or later, run the following command to grant users or roles access to set the
  > `session_replication_role` parameter: `GRANT SET ON PARAMETER session_replication_role TO your-user;`"
  > "If you use PostgreSQL 14 or earlier, then you can't run the preceding command and must use
  > `rds_superuser` permissions."

  <https://repost.aws/knowledge-center/rds-postgresql-foreign-keys> (accessed 2026-08-27)

  M4 is PG 18, so `session_replication_role` is reachable by the customer. This matters for two
  Still-open rows — replication-apply and data-only-restore — both of which turn on it. It does **not**
  change ADR-0009's chosen design, which needs neither.

### Breadth check — the other two managed providers

**GCP Cloud SQL for PostgreSQL — no.** Cloud SQL withholds true superuser and enumerates its
superuser exceptions; event triggers are not among them. The features page states superuser-requiring
features are unsupported *"with the following exceptions"*, and the exceptions are `CREATE EXTENSION`
(for supported extensions) and, for the `cloudsqlsuperuser` role, `CREATE CAST` / `DROP CAST`.
`CREATE EVENT TRIGGER` is not listed, so it falls under the general prohibition. (The public Cloud SQL
discussion group has long-standing threads confirming event triggers are rejected on Cloud SQL for
the same reason.)
<https://cloud.google.com/sql/docs/postgres/features> (redirects to
<https://docs.cloud.google.com/sql/docs/postgres/features>; accessed 2026-08-27)

**Azure Database for PostgreSQL – Flexible Server — no.** The admin belongs to `azure_pg_admin`,
which is not a superuser; the superuser attribute belongs to the managed service (`azure_superuser`),
not the customer. Official Microsoft Q&A answer (accepted): *"Yes, an event trigger is not supported,
you can use the `pg_notify` and integrate it with the event grid… for real-time event processing."*
<https://learn.microsoft.com/en-us/answers/questions/1378108/is-it-possible-to-create-event-triggers-in-azure-p>
(accessed 2026-08-27)

---

## What it means for ADR-0009 and M4

1. **The gate is cleared for the target.** On RDS PG 18 (and Aurora PG 18) the baseline's DDL
   perimeter — three event triggers, three `ENABLE ALWAYS` on them, eighteen `ENABLE ALWAYS` on
   user triggers — installs via the master `postgres` account. The baseline **is** appliable on M4.
   ADR-0009's "untested / documented `NOSUPERUSER`, therefore probably not" framing was too
   pessimistic because it read the role page and missed the feature-support page.

2. **No fallback is triggered on AWS.** ADR-0009's fallback — "if event triggers are not installable,
   the DDL perimeter reverts to being covered only by the CI schema-snapshot test" — does **not**
   fire for the RDS/Aurora target. (The snapshot test remains mandatory anyway: it catches strictly
   more, including the whole owner-accident DDL class the triggers only speed-bump, and the
   `tgenabled`/`evtenabled` downgrade from a data-only restore.)

3. **A self-managed vs managed split exists, and it runs the other way from the usual worry.**
   Self-managed EC2 Postgres with a real superuser installs everything trivially. Managed RDS/Aurora
   installs it too, but only through the **master account**, via a documented capability rather than
   a role you can hand to an arbitrary migrator. Cloud SQL and Azure Flexible Server install the
   event triggers **not at all** — so "managed Postgres" is not one answer: AWS yes, GCP/Azure no.

4. **The real open item is the role split, not the provider.** ADR-0009 requires a migrator that owns
   the tables and not the database. On RDS the event-trigger-capable account (master) is also the
   database-owning account, so M4 must construct the split inside the RDS role model rather than
   assume a separate superuser hands out ownership. Two operational caveats from the RDS docs feed
   M4's runbook: event triggers must be **deleted before a major version upgrade** and cannot be
   created on a read replica (they copy from the source and fire only on promotion).

5. **`session_replication_role` is reachable on RDS PG 18** (`GRANT SET ON PARAMETER …`), which
   unblocks the design work in the replication-apply and data-only-restore Still-open rows whenever
   those are taken up. It is not needed by 0009 itself.

### Proposed one-line update to Still-open row 2 (for the doc pass — not applied here)

Replace the current row-2 body (`site/content/decisions/index.md`, "The perimeter's guards need a
superuser, and nobody has tried a managed one") with:

> [0009](/decisions/0009-append-only-perimeter) puts three event triggers in the schema, and stock
> PostgreSQL says *"Only superusers can create event triggers"* — a plain non-superuser owner
> installs them not at all (spike 010). But **AWS documents the RDS/Aurora master `postgres` account
> — `NOSUPERUSER` — as able to *"create, modify, rename, and delete event triggers"*** ([spike
> 019](/spikes/019-managed-postgres-event-triggers)), so the baseline **is** appliable on the M4
> (RDS PG 18) target through the master account, with no `rds.*` parameter to set; the eighteen
> `ALTER TABLE … ENABLE ALWAYS TRIGGER` need only table ownership. **GCP Cloud SQL and Azure Flexible
> Server permit no customer event triggers**, so a non-AWS managed target would fall back to the CI
> snapshot test as 0009 provides. The live residual is the **role split** (0009 already requires a
> migrator that owns the tables and not the database), which on RDS must be built inside the master
> account's role model — and the operational caveats that event triggers block a major-version
> upgrade and cannot be created on a read replica.

Row 2 could reasonably be marked **resolved for the RDS target** and reframed as a role-split /
runbook item rather than an open feasibility question. ADR-0009's own "What it costs" line ("Whether
a managed PostgreSQL clears the bar is untested… M4 is where this gets answered") should be updated
to cite this spike and record: RDS/Aurora yes via the master account; Cloud SQL/Azure no.
