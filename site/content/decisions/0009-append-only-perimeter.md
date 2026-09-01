# 0009 — The append-only perimeter: where it ends, and what closes at the edge

**Status:** accepted
**Evidence:** [spike 010](/spikes/010-append-only-perimeter). Amends
[0004](/decisions/0004-where-logic-lives)'s *"what the database still cannot enforce"* table in three
rows and corrects the fix it proposed for a fourth.

## The decision

**What we guarantee: posted history cannot be rewritten or deleted, and the database itself enforces
that.** The tables that record what happened — the **journal** — are *append-only*: rows are only ever
added, never changed or removed. Two **triggers** (rules the database runs automatically on every
attempted write) sit on each of those tables — the journal trio, the chart's history
([0012](/decisions/0012-chart-governance)), the attestation log and the period record
([0011](/decisions/0011-period-close-and-report-axes)). `refuse_mutation` rejects any `UPDATE` or
`DELETE`; `refuse_truncate` rejects `TRUNCATE` (the bulk "empty this table" command) — and both reject
it for **every role, including the table's owner**. They are marked `ENABLE ALWAYS`, so they fire even
on the replication and restore paths (`session_replication_role='replica'`, `pg_restore
--disable-triggers`) where ordinary triggers are skipped. Two things extend that edge: an account
cannot be silently reclassified — a **foreign key** plus a column-level `GRANT` freeze its owner columns
(channel E below) — and three more triggers, this time **event triggers** (the same idea, but watching
for commands that change the *shape* of the database rather than its rows), act as a **speed-bump**
against the naive rewrite, inheritance or drop of a journal table.

**What is out of scope: someone who owns the database and uses its schema-changing powers.** Those
shape-changing statements are called **DDL** (data-definition language, as opposed to the DML that
writes rows), and the event triggers are a speed-bump against them, not a guarantee. An owner walks
around the triggers with a whole enumerated class of DDL — `ALTER TABLE … RENAME`/`SET SCHEMA`, `DROP
CONSTRAINT`/`DROP INDEX`, `CREATE RULE … DO INSTEAD NOTHING`, `DISABLE ROW LEVEL SECURITY`, `DROP
SCHEMA public CASCADE`, a `CREATE OR REPLACE VIEW`/`DROP VIEW` of a report view, or `UPDATE
account_types SET is_perimeter …`/`mirror_type …` (each enumerated with its reproduction in the
evidence below). That class is deliberately **not** chased with more runtime guards. **The backstop for
it is the CI schema-snapshot test ([0007](/decisions/0007-schema-conventions-and-chart) §2) plus the
role split** — a build-time check that diffs the whole live schema against a committed copy, together
with running migrations as a role that is *not* the database owner — **not the triggers.** We can make
our own code unable to rewrite history; we cannot make that true of whoever owns the database, so we
draw the line where it actually holds and say so plainly. No schema in this field claims otherwise, and
this one does not either.

## The evidence

### A — the proposed fix cannot be written, and would not be worth writing

The decision log said *"the fix is one `ALTER TABLE … ENABLE ALWAYS TRIGGER` each"*. A foreign key's
four internal triggers are named `RI_ConstraintTrigger_c_25632` — **OID-derived, different in every
database** — so naming the constraint is a syntax-level miss (`trigger "fk_entries__txn" for table
"ledger_entries" does not exist`), and the `ALL`/`USER` shorthands that would sidestep the naming are
accepted after `ENABLE TRIGGER` but are a **syntax error** after `ENABLE ALWAYS`. What works is a
catalog-driven `DO` loop at apply time, which does close the hole (36 promoted; three replica-role
inserts that previously committed now refuse) and which is procedural DDL in a file whose whole
doctrine is declarative.

**The reason not to ship it is not the awkwardness.** Promoting an internal constraint trigger
*"requires superuser privileges"*, and so does the channel — `session_replication_role` is a
superuser-context GUC, verified: a plain database owner gets `permission denied to set parameter`.
And PostgreSQL practice is against it for these triggers specifically. Laurenz Albe, on why the
default is what it is: logical replication can replay changes in an order that *"might conflict with
foreign key constraints on the subscriber"*, and `ENABLE ALWAYS` on foreign keys *"is neither the
default nor a commendable setting."* Jan Wieck named the mechanism on pgsql-general in 2018.

So the disposition is a **deployment rule, not a schema clause**: this database is not a logical
replication subscriber for its own journal, and if it ever is, `spikes/012-append-only-perimeter/03_enable_always_fk.sql`
is the promotion loop, with its costs written down beside it.

### B — the restore path is worse than the log recorded, and it is the argument for the snapshot test

`pg_dump -a` warns unprompted that the circular `fk_txn__resolves`/`fk_txn__reverses` pair needs
`--disable-triggers`. The manual says only that *"the commands emitted for `--disable-triggers` must
be done as superuser"*; the dump itself, and `pg_backup_archiver.c`, say what they are:

```
ALTER TABLE public.ledger_entries DISABLE TRIGGER ALL;    -- ck_entries__append_only: A -> D
…restore…                                                  -- DELETE 7, UPDATE 4, no error
ALTER TABLE public.ledger_entries ENABLE TRIGGER ALL;     -- ck_entries__append_only: D -> O
```

**`ENABLE TRIGGER ALL` restores triggers to `ENABLE ORIGIN`, not to what they were.** After one
ordinary data-only restore, all eighteen append-only and no-truncate triggers are `O`, `session_replication_role='replica';
DELETE FROM ledger_entries` succeeds, and nothing in this repository would notice. `ENABLE ALWAYS`
does not help — `D` is `D`.

**The damage is a two-character diff in one catalog column, and a snapshot diff is the only thing
that reads that column.** [0007](/decisions/0007-schema-conventions-and-chart) §2 already mandates the
test; this ADR adds one requirement to it: **it must dump `pg_trigger.tgenabled` and
`pg_event_trigger.evtenabled`, not only the trigger definitions.** That single column catches this,
catches a mis-applied migration, and catches a hand-edited production database.

### C and D — what the event trigger is, and the two candidates it beat

One function, three events, all `ENABLE ALWAYS`:

```sql
CREATE EVENT TRIGGER ck_journal__no_rewrite ON table_rewrite  EXECUTE FUNCTION refuse_journal_ddl();
CREATE EVENT TRIGGER ck_journal__no_drop    ON sql_drop       EXECUTE FUNCTION refuse_journal_ddl();
CREATE EVENT TRIGGER ck_journal__no_inherit ON ddl_command_end
    WHEN TAG IN ('CREATE TABLE','ALTER TABLE')                EXECUTE FUNCTION refuse_journal_ddl();
```

`table_rewrite` is the purpose-built event — *"occurs just before a table is rewritten by some
actions of the commands `ALTER TABLE` and `ALTER TYPE`"* — so the guard refuses exactly the class of
statement that rewrites rows and waves through `CREATE INDEX`, `ADD COLUMN`, `ADD CONSTRAINT`,
`SET (fillfactor=…)` and `VACUUM FULL`. The inheritance half is a **state assertion, not a command
parse**: it asks `pg_inherits` whether a journal table has acquired a child, so `CREATE TABLE …
INHERITS` and `ALTER TABLE … INHERIT` are both refused without the guard knowing either grammar.
`ENABLE ALWAYS` is load-bearing and the counterfactual proves it: left at the default, the same
rewrite under `session_replication_role='replica'` succeeds and `account_seq` goes 1 → 10.

**Inheritance is a removal channel, and the register's version of it understated the mechanism.**
The child carries three inherited `CHECK`s and **nothing else** — no key, no unique index, no foreign
key, no trigger. `INSERT … SELECT * FROM ONLY ledger_entries` took the seed 8 → 16 and revenue 300.00
→ 600.00; `DELETE FROM ledger_entries` was refused by the parent's trigger with the child untouched;
`DELETE FROM shadow_entries` took it back to 8 with no error. It is also a way to write rows no key
constrains — an entry against a non-existent transaction, in a currency its account does not hold,
with a duplicate `account_seq`, dated 1999, was accepted and counted by every report — and
`DROP TABLE shadow_entries` then removed five rows of reported history.

| The candidate refused | Why |
| --- | --- |
| **`SELECT … ONLY` in the three views** | It works, and it is a time bomb. `ONLY` excludes **partitions** exactly as it excludes children: measured on a two-row list-partitioned table, `FROM p` returns 2 and `FROM ONLY p` returns **0**. `tenant_id` leads every key in this schema so that partitioning stays available ([0002](/decisions/0002-scaling)); the day someone takes it, three financial statements report zero, balanced, every check green — this project's worst failure class, planted years in advance by a defence against a different bug |
| **Revoking `CREATE ON SCHEMA` from the app role** | Already true, and not the gate. With the shipped grants the app role gets `permission denied for schema public`; **granted `CREATE` by mistake it still gets `must be owner of table ledger_entries`**, because `CREATE TABLE … INHERITS` requires ownership of the parent. The channel was never the app role's |

### E — a foreign key, not another trigger

`UPDATE ledger_accounts SET owner_type='house', owner_id=NULL` still succeeds on the baseline and
leaves the balance sheet **byte-identical** — Cash 800.00, Customer funds payable 500.00 — because no
report reads the owner. `uq_accounts__owned` and `uq_accounts__house` do bind updates, and what they
catch is a **collision, not a move**: reassigning the wallet to `initech`, whom nobody else is, was
accepted.

**The fix is the device already in this schema twice.** `currency` and `effective_at` are denormalised
copies held honest by composite foreign keys; the half usually overlooked is that a foreign key's
default `NO ACTION` also **refuses an `UPDATE` of the referenced columns while a dependent row points
at the old value** — which [0007](/decisions/0007-schema-conventions-and-chart) already records for
`fk_accounts__type`. That is a column freeze, spelled declaratively. Applied to the owner, on
`ledger_account_balances` (one row per account, currency and stripe — not one per entry), the four two-statement directions
are refused **as the database owner** — owned → house, owned → another owner, `company` → `platform`,
and house → owned — while `metadata` stays editable. Two details cost a round each: a composite foreign
key is `MATCH SIMPLE`, so one NULL and it is **not checked at all** (hence a `GENERATED ALWAYS`
`coalesce` for the NULLable `owner_id`), and `owner_type::text` is refused as a generation expression —
*"generation expression is not immutable"*, the enum cast being stable rather than immutable.

**Two residuals qualify "refused", and both are accepted rather than closed.** First, `NO ACTION`
(and `RESTRICT`) is checked at **end of statement**, so a *single* statement — a CTE that rewrites the
account row and its denormalised copy on the balance table together — passes the freeze. The naive
two-statement repair is refused; a deliberate one-statement CTE is not. This is the same caveat the
[A2 identity freeze](/decisions/0007-schema-conventions-and-chart) (`uq_accounts__id_purpose` +
`fk_balances__account_purpose`) carries — both freezes are two-statement freezes. Closing it fully
needs a trigger, declined here on the same reasoning as the owner-accident DDL class: it is an owner
threat, and the backstop is the snapshot test, not more triggers. Second, the freeze is composite-FK
based and therefore **absent until the account has its first balance row** — an account that has never
been posted to has no denormalised copy for the key to bind, so it can be freely reclassified until
its first posting. `fk_entries__stripe` guarantees a balance row exists for any account *with history*,
so the freeze is total exactly where it matters and vacuous only where there is nothing yet to protect.

The app role holds table-wide `UPDATE` on the balance cache and could otherwise launder its own copy
first. A **column-level grant** closes that and is declarative: `GRANT UPDATE (input, output,
last_seq, updated_at)`. The [0002](/decisions/0002-scaling) upsert is unaffected — verified, returning
`input 50800, last_seq 3`.

### The neighbours ship none of this

Read from source at pinned commits. **Formance** (`335bd03`): zero event triggers, zero `ENABLE
ALWAYS`, zero `session_replication_role`, zero `GRANT`, zero `REVOKE` — and **six of its own
migrations `UPDATE` `logs`**, its append-only hash-chained log, with no rehash and no `BEFORE UPDATE`
guard. One of its migration comments records the constraint they actually live under: *"cannot disable
triggers at session level on Azure Postgres with no superuser privileges."* **pgMemento** (`f09c44c`)
runs six event triggers and **no `table_rewrite`** — zero hits repo-wide — so it learns that an
`ALTER TABLE` ran, never that a rewrite happened, and sets `ENABLE ALWAYS` nowhere. **pgAudit**
(`52a3253`) uses two and disclaims prevention outright, and its own README disclaims durability:
*"Audit logging is best-effort and not transactional."*

**Nobody in this field prevents DDL against posted history.** That is a reason to be honest about
what this buys, not a reason to skip it: [0004](/decisions/0004-where-logic-lives) already accepted
being alone on the eighteen DML triggers, for the same argument, against the same population.

### Why the event trigger exists, and what it does not cover

The rule applies to an event trigger as much as to a row trigger, and the default is none:

| | |
| --- | --- |
| **The invariant** | Posted history is not editable by DDL either. A rewrite of `ledger_entries` destroys gaplessness, which is what makes *"no entry is missing"* a checkable claim; a child table adds and removes parent-visible rows that no key constrains; `DROP TABLE` removes the lot |
| **Why nothing declarative holds it** | There is no `CHECK`, key or `GRANT` whose subject is a DDL statement. Withholding the privilege means withholding ownership, and the owner is who runs migrations. `SELECT … ONLY` in the views hides the child from three reports and from nothing else — and excludes **partitions** identically, so it fails silently the day [0002](/decisions/0002-scaling)'s partitioning option is taken |
| **What it does NOT protect against** | The whole owner-accident DDL class enumerated below (an accepted, out-of-model limitation per the decision to lean on the snapshot test rather than chase DDL with more triggers). Plus `TRUNCATE` — PostgreSQL refuses an event trigger for it outright, which is why [0004](/decisions/0004-where-logic-lives)'s three statement-level triggers stay. And itself: the manual says the event *"does not occur for commands targeting event triggers themselves"*, so a superuser removes it in one statement |

An owner with DDL rights — determined, or merely fat-fingering a migration — can disarm or route
around the three event triggers by a class of statements the schema deliberately does **not** chase
with more runtime guards. This is a *stated limitation*, accepted on the decision that the guarantee
against this owner is the CI schema-snapshot test ([0007](/decisions/0007-schema-conventions-and-chart)
§2) plus the role split, not an ever-growing perimeter of event triggers that a rename walks past.
Each has a concrete reproduction; the shape, not a fix, is what is recorded:

| The statement | What it does | Why the trigger misses it |
| --- | --- | --- |
| **`ALTER TABLE … RENAME` / `SET SCHEMA`** | Renames a protected table out from under the guard, then rewrites/drops/inherits the posted history invisibly | The protected list is keyed on **name**; the renamed table is no longer on it |
| **`DROP CONSTRAINT` / `DROP INDEX`** on a protected table | Drops `ck_entries__amount_positive`, then posts a negative amount; or drops a unique index and doubles a row | The `sql_drop` branch filters `object_type = 'table'` and throws away a dropped *constraint* or *index* whose parent is protected |
| **`CREATE RULE … DO INSTEAD NOTHING`** | Silently swallows every append to a protected table — the writes return success and land nowhere | No `CREATE RULE` tag is matched |
| **`DISABLE ROW LEVEL SECURITY`** | Total cross-tenant leak; every reader sees every tenant | Only `pg_class.relrowsecurity` flips — invisible to the trigger and to the snapshot's originally-charged columns |
| **`DROP SCHEMA public CASCADE`** | Removes the lot, guard included, in one self-disarming statement | The guard lives in the schema it protects (mitigated only by the role split putting the guard's owner beyond the migrator) |
| **`CREATE OR REPLACE VIEW` / `DROP VIEW`** of the report views | `CREATE OR REPLACE VIEW reconciliation AS SELECT 0` makes every check green forever; the reports are the only place the guarantee is observable | Views are not on the protected list, and no `CREATE VIEW` viewdef assertion exists |
| **`UPDATE account_types SET is_perimeter … / mirror_type …`** | Silences a perimeter account's own attestation check, or breaks a mirror pairing | `account_types` is not under `refuse_mutation`; both columns are freely `UPDATE`able |

**The snapshot-test charge is extended to cover exactly this class**, so that a build-time diff catches
it even with no runtime guard. Beyond `pg_trigger.tgenabled` and `pg_event_trigger.evtenabled`
(charged in §B for the restore path), [0007](/decisions/0007-schema-conventions-and-chart) §2's snapshot
must also dump: **`pg_class.relrowsecurity` and `relforcerowsecurity`** (catches `DISABLE ROW LEVEL
SECURITY`); **`pg_get_viewdef` for every view** (catches a replaced or dropped report view, and a
`RENAME`/`SET SCHEMA` that moves a base table); **`account_types.is_perimeter` and `mirror_type`**
(catches the identity `UPDATE`); and **the full `pg_constraint` set — names and definitions**
(catches a dropped constraint and a dropped index). A diff over that set is what actually makes the
owner-accident class detectable; the event triggers are the speed-bump in front of it.

## What we considered

| | Why not |
| --- | --- |
| **`ENABLE ALWAYS` on the 36 internal foreign-key triggers** | Above. Not writable as static DDL, superuser on both sides, against PostgreSQL's own recommendation for foreign keys, and it does not close the restore path that routes through the same hole |
| **`ddl_command_start` instead of `table_rewrite`** | Fires before the command is parsed into an object, so it cannot tell *which* table an `ALTER TABLE` targets without re-parsing the statement text. `table_rewrite` hands you `pg_event_trigger_table_rewrite_oid()` and fires only when rows are actually about to be rewritten — narrower and non-guessing |
| **Blanket refusal of `ALTER TABLE` on the journal** | Refuses `CREATE INDEX`-adjacent work, `ADD CONSTRAINT`, `SET (fillfactor)` and every non-rewriting change. Expand/contract migrations become impossible on the three tables that most need them, and a guard that blocks legitimate work is a guard someone disables |
| **`SELECT … ONLY` in the views** | Above. The partitioning measurement is the whole answer |
| **Another trigger, for the owner columns** | It would clear [0004](/decisions/0004-where-logic-lives)'s bar — there is no `CHECK` for *"this column may not change"* — and it is not needed, because a composite foreign key does the same thing declaratively, is visible in `\d`, and needs no test. Preferring the key to the trigger is [0004](/decisions/0004-where-logic-lives)'s own move, made twice already |
| **A column-level `GRANT` on `ledger_accounts` instead** | Nothing to narrow: the app role holds **`INSERT, SELECT`** there and no `UPDATE` at all. Verified. The column-level grant is still used, on `ledger_account_balances`, where there really is an `UPDATE` to narrow |
| **Recording E as out-of-perimeter** | The honest fallback if no declarative shape had existed. One does |
| **Leaving all of it to the CI snapshot test** | The snapshot test is mandatory either way and catches strictly more (a dropped column rewrites nothing and is invisible to `table_rewrite`). It catches it **after** the migration ran, on a build, against a schema — not against production. *Prefer a constraint that makes a state unreachable to a check that looks for it afterwards*, and use both |

## What it costs

| | |
| --- | --- |
| **`migrations/00001_baseline.sql` needs an event-trigger-capable account, which not every managed PostgreSQL gives** | *"Only superusers can create event triggers"*, and `ALTER EVENT TRIGGER … ENABLE ALWAYS` needs one too. The DDL is unconditional on purpose — **a guard that silently declines to install is worse than no guard**, because it reads as covered. The failure is loud and at migrate time. [Spike 015](/spikes/015-managed-postgres-event-triggers) answers the managed-Postgres question that was open: **AWS RDS and Aurora PostgreSQL 18 (the RDS target) do clear the bar** — AWS's own feature page documents the master `postgres` account, though `NOSUPERUSER`, as able to *"create, modify, rename, and delete event triggers"*, so all three `CREATE EVENT TRIGGER` and their `ENABLE ALWAYS` apply, and the eighteen `ALTER TABLE … ENABLE ALWAYS TRIGGER` never needed superuser (they act on ordinary user triggers, which need only table ownership). **GCP Cloud SQL and Azure Flexible Server do NOT permit customer event triggers** — on either, this DDL perimeter reverts to the CI snapshot test alone. The residual on RDS is the role split below, not the provider |
| **The deployment model gains a second role** | The migrator must own the tables and **not** the database, or the guard is one `DROP FUNCTION … CASCADE` away — measured. That is a real operational requirement, it is not in `docker-compose.yml`, and `make reset` does not do it |
| **The balance row gets 5 bytes wider on the contended accounts** | `pg_column_size`: 80 → **85** for a house account (`owner_id_key` empty), 89 with a 4-character owner, **121 with a 36-character UUID owner**. The hot account of [0002](/decisions/0002-scaling)'s contention story is a *house* account, so the +51% case is cold rows; the row [0007](/decisions/0007-schema-conventions-and-chart) §7 calls the most performance-critical thing in the schema pays 6%. **Not measured against throughput** — that is a [network-benchmark question](/roadmap#if-this-ever-wants-a-production-story) and localhost is not a benchmark |
| **The writer must supply the owner on the balance upsert** | One more column pair on the balance write path. The foreign key is checked on `INSERT` and on an `UPDATE` that changes the key columns; the per-posting upsert changes neither |
| **A volatile `DEFAULT` on a new column is refused** | `ADD COLUMN n int NOT NULL DEFAULT (random()*100)::int` → `rewrite reason 2`. It is a true positive — a volatile default writes a new value into every posted row — and it will still surprise somebody |
| **Four holes stay open, by name** | `TRUNCATE` (event triggers refused for it outright, so the three statement-level triggers stay and this ADR does not consolidate them); `ALTER TABLE … DROP COLUMN`, which rewrites nothing; `ALTER TABLE … DISABLE TRIGGER USER`, which the plain table owner still runs and which sets the eighteen append-only and no-truncate triggers to `D`; and the superuser, who removes the whole apparatus in one statement |
| **The restore path has no schema-side answer** | The operational rule is: restore schema-and-data, never data-only; and if `--disable-triggers` is ever used, re-assert the eighteen `ENABLE ALWAYS` clauses afterwards, because `ENABLE TRIGGER ALL` will not |
| **The schema's own census moves** | the merged baseline now carries **25** foreign keys and **100** internal foreign-key triggers where [0004](/decisions/0004-where-logic-lives) and the decision log both say nine and 36 — this ADR's `fk_balances__account_owner` is one of them, alongside the identity-freeze, close-typing and stripe keys the rest of the merge added — and `pg_event_trigger` stops being empty. [The database page](/database#what-the-schema-enforces-today) is the canonical count and has to be re-run, not edited from here |
| **`ledger_accounts` gains a stored generated column and a unique constraint** | `owner_id_key`, plus `uq_accounts__id_owner`. Written once per account; the register is not a hot table. It is also the third `GENERATED ALWAYS` column in the schema and the pattern is now load-bearing enough to be a convention rather than a trick |
