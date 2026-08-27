# Spike 010 — Where does append-only actually stop?

**Status:** closed. Feeds [ADR 0009](/decisions/0009-append-only-perimeter), which draws the
perimeter and adds one event trigger and one foreign key to the schema. Amends
[0004](/decisions/0004-where-logic-lives)'s "what the database still cannot enforce" table in three
rows, and corrects the fix the decision log proposed for the fourth.

**Question.** [0004](/decisions/0004-where-logic-lives) protects the journal with six `ENABLE ALWAYS`
triggers and admits, in writing, that they cover DML only. The decision log lists five ways past
them. Which of the five are real, who can reach each one, and which can the schema close?

**Ran** 2026-08-27 · PostgreSQL 18.6 (`x86_64-pc-linux-musl`, Alpine), scratch database `spike_wsa`,
loaded from `migrations/00001_baseline.sql` + `schema/chart.sql` + `spikes/012-append-only-perimeter/00_seed.sql`.
Every command and every line of output below is in
`spikes/012-append-only-perimeter/` — `run.sh` reproduces the whole thing into `transcript.txt`. The seed is **8 entries, 4 posted transactions, 2 tenants, one currency**: revenue
t1 300.00, t2 700.00. Small on purpose, so every count can be checked by eye.
> **Note on reproducing this spike.** Its runs predate the 2026-08-27 integration that folded the
> proposed DDL of ADRs 0009–0013 into `migrations/00001_baseline.sql`
> ([0003](/decisions/0003-migrations)'s editable-until-v0.1 exception), so the overlay files in this
> spike's directory target the *pre-merge* baseline — recover it from git history to re-run them
> verbatim. The merged baseline was re-verified end to end at integration time.

Prior art read from source at pinned commits: Formance at `335bd03`, pgMemento at `f09c44c`
(v0.7.4), pgAudit at `52a3253`. PostgreSQL statements are quoted from the version 18 manual and,
where the manual is silent about what a tool emits, from `REL_18_STABLE` source.

---

## The answer

**The perimeter is the application role, and it always was. Everything below is reachable only by
the table owner — and two of the five channels can only be *closed* by a true superuser, which is
more privilege than the channel needs and more than a managed PostgreSQL will hand you.**

| The channel | Who can open it | Who can close it | Verdict |
| --- | --- | --- | --- |
| **A.** Foreign keys skipped under `session_replication_role='replica'` | superuser only | superuser only | **Do not close it in the schema.** The statement the decision log proposed does not exist; the one that does needs superuser and is not writable as static DDL |
| **B.** `pg_dump -a --disable-triggers` restore | superuser only | **nobody** | Not closable at all. And it leaves the schema permanently weaker |
| **C.** A child table of `ledger_entries` | table owner | superuser | **Close it** — one event trigger |
| **D.** `ALTER TABLE … TYPE …` rewriting posted rows, and `DROP TABLE` | table owner | superuser | **Close it** — the same event trigger |
| **E.** `UPDATE ledger_accounts SET owner_type='house', owner_id=NULL` | table owner | **table owner** | **Close it declaratively** — one composite foreign key, no trigger |

The application role reaches **none** of the five. Verified, with the shipped grants, one refusal
each:

```
-- A. SET session_replication_role = 'replica';
ERROR:  permission denied to set parameter "session_replication_role"
-- B. ALTER TABLE ledger_entries DISABLE TRIGGER USER;
ERROR:  must be owner of table ledger_entries
-- C. CREATE TABLE shadow_entries () INHERITS (ledger_entries);
ERROR:  permission denied for schema public
-- D. ALTER TABLE ledger_entries ALTER COLUMN account_seq TYPE bigint USING (account_seq * 10);
ERROR:  must be owner of table ledger_entries
-- E. UPDATE ledger_accounts SET owner_type='house', owner_id=NULL;
ERROR:  permission denied for table ledger_accounts
```

**And the event trigger is decoration unless the migrator stops being the database owner.** That is
the finding that changes the deployment model, and it is [below](#12--the-role-split-is-what-makes-the-guard-real).

## The census it starts from

```
--- internal (foreign-key) triggers, by enablement ---
 tgisinternal | tgenabled | count
--------------+-----------+-------
 f            | A         |     6      <- the six ADR-0004 kept, ENABLE ALWAYS
 t            | O         |    36      <- nine foreign keys x four, ENABLE ORIGIN
--- event triggers ---  0
--- do the views read ONLY? ---  balance_sheet f | income_statement f | trial_balance f
```

The decision log's counts are right: **36 internal triggers over nine foreign keys, all `ENABLE
ORIGIN`; six declared triggers, all `ENABLE ALWAYS`; zero event triggers; and no view says `ONLY`.**

## A — foreign keys on the replication apply path

The manual is explicit about the mechanism: *"Since foreign keys are implemented as triggers,
setting this parameter to `replica` also disables all foreign key checks, which can leave data in an
inconsistent state if improperly used."* And the apply path is not hypothetical: *"The apply process
on the subscriber database always runs with `session_replication_role` set to `replica`."*

One transaction, replica role, three inserts the schema is supposed to make unrepresentable — all
three commit:

```
BEGIN;  SET LOCAL session_replication_role = 'replica';
-- an entry in EUR against a USD account, on a transaction that does not exist,
-- dated 27 years before that transaction
INSERT 0 1
-- a transaction citing an event that does not exist
INSERT 0 1
-- an account whose category contradicts its own type
INSERT 0 1
COMMIT;
 orphan_entries | accounts_contradicting_their_type
--------------- + -----------------------------------
              1 |                                 1
```

**The interesting half is the next statement.** The row that could not legitimately be created
cannot be removed either — the append-only trigger *is* `ENABLE ALWAYS`, so it fires on the same
path that let the row in:

```
DELETE FROM ledger_entries WHERE id='dead0000-…-000000000001';
ERROR:  ledger_entries is append-only: DELETE on dead0000-… refused. Correct it with a new row.
```

**A hole that only admits, plus a guard that only refuses, is worse than either alone: it makes
corruption permanent.** Note also what replica role does *not* skip — `uq_accounts__house` refused
the third insert on the first attempt, because a unique index is not a trigger. What the apply path
turns off is precisely the constraints PostgreSQL implements as triggers, which is foreign keys.

### The fix the decision log proposed cannot be written

*"the fix is one `ALTER TABLE … ENABLE ALWAYS TRIGGER` each"*. Three findings, in order:

```
-- (i) a foreign key's four internal triggers are NOT named after the constraint
     conname     |      on_table       |            tgname            | tgenabled
-----------------+---------------------+------------------------------+-----------
 fk_entries__txn | ledger_transactions | RI_ConstraintTrigger_a_25630 | O
 fk_entries__txn | ledger_transactions | RI_ConstraintTrigger_a_25631 | O
 fk_entries__txn | ledger_entries      | RI_ConstraintTrigger_c_25632 | O
 fk_entries__txn | ledger_entries      | RI_ConstraintTrigger_c_25633 | O

-- (ii) so naming the constraint misses
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER fk_entries__txn;
ERROR:  trigger "fk_entries__txn" for table "ledger_entries" does not exist

-- (iii) and the ALL / USER shorthands do not exist after ALWAYS
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ALL;
ERROR:  syntax error at or near "ALL"
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER USER;
ERROR:  syntax error at or near "USER"
```

`ALL` and `USER` are accepted after `ENABLE TRIGGER` and `DISABLE TRIGGER` and **not** after `ENABLE
ALWAYS`. So the only spelling that works names the generated `RI_ConstraintTrigger_c_25632` — an
**OID-derived name, different in every database** (the same key came out `…_17146` in one scratch
database and `…_19938` in the next). It cannot be written into a migration file; it has to be
generated from the catalog at apply time:

```sql
FOR r IN SELECT t.tgrelid::regclass AS tbl, t.tgname
         FROM pg_constraint c JOIN pg_trigger t ON t.tgconstraint = c.oid
         WHERE c.contype='f' AND t.tgenabled='O'
LOOP EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER %I', r.tbl, r.tgname); END LOOP;
NOTICE:  promoted 36 internal FK triggers to ENABLE ALWAYS
```

That **does** close the hole — the same three inserts, same replica session, now three refusals:

```
ERROR:  insert or update on table "ledger_entries" violates foreign key constraint "fk_entries__txn"
ERROR:  insert or update on table "ledger_transactions" violates foreign key constraint "fk_txn__event"
ERROR:  insert or update on table "ledger_accounts" violates foreign key constraint "fk_accounts__type"
```

...and an ordinary origin-role write is unaffected. **And it costs more than it buys.**

| | |
| --- | --- |
| **It needs a real superuser** | *"Disabling or enabling internally generated constraint triggers requires superuser privileges."* Verified: as a plain database owner, `ERROR: permission denied: "RI_ConstraintTrigger_c_19938" is a system trigger` |
| **The channel needs a real superuser too** | `session_replication_role` is a `superuser`-context GUC. Verified: a non-superuser owner gets `permission denied to set parameter`. **A guard exactly as privileged as the channel it guards adds nothing but the appearance of coverage** |
| **PostgreSQL's own advice is against it, for these triggers specifically** | Laurenz Albe (Cybertec, 2023-12-20): logical replication can replay changes *"in an order [that] might conflict with foreign key constraints on the subscriber"*, and of `ENABLE ALWAYS` on foreign keys — *"that is neither the default nor a commendable setting for foreign key triggers."* Jan Wieck put the mechanism plainly on pgsql-general in 2018: *"under `session_replication_role='replica'` you[r] replication system can replicate things out of order with respect to foreign keys"* |
| **It does not close the restore path** | Below |

## B — the restore path, and the damage it leaves behind

`pg_dump -a` on the shipped schema warns, unprompted:

```
pg_dump: warning: there are circular foreign-key constraints on this table:
pg_dump: hint: You might not be able to restore the dump without using --disable-triggers
```

(`fk_txn__resolves` and `fk_txn__reverses` are the circle.) The manual: *"Presently, the commands
emitted for `--disable-triggers` must be done as superuser."* It does not say what they are; the
source does (`pg_backup_archiver.c`), and so does the dump:

```
ALTER TABLE public.ledger_entries DISABLE TRIGGER ALL;
ALTER TABLE public.ledger_entries ENABLE TRIGGER ALL;
```

Run the pair by hand and watch both halves:

```
-- before:        ck_entries__append_only | A        ck_entries__no_truncate | A
ALTER TABLE public.ledger_entries DISABLE TRIGGER ALL;
--                ck_entries__append_only | D        ck_entries__no_truncate | D
DELETE FROM ledger_entries WHERE tenant_id='t1';   DELETE 7
UPDATE ledger_entries SET amount_minor = 1 WHERE tenant_id='t2';   UPDATE 4
ALTER TABLE public.ledger_entries ENABLE TRIGGER ALL;
-- after:         ck_entries__append_only | O        ck_entries__no_truncate | O
```

**`DISABLE TRIGGER ALL` beats `ENABLE ALWAYS` — `D` is `D` — and `ENABLE TRIGGER ALL` puts the
triggers back as `ENABLE ORIGIN`, not as what they were.** One ordinary data-only restore therefore
downgrades all six append-only triggers permanently, silently, with no error and nothing in the
repository that would notice. After it, `SET session_replication_role='replica'; DELETE FROM
ledger_entries` succeeds — the exact counterfactual [0004](/decisions/0004-where-logic-lives) records
as proof the `ENABLE ALWAYS` clauses matter.

This is the strongest argument in the tree for [0007](/decisions/0007-schema-conventions-and-chart)
§2, the unbuilt CI schema-snapshot test: **the damage is a two-character diff in one catalog column,
and a snapshot diff is the only thing that reads that column.**

## C — inheritance, in both directions

`CREATE TABLE … INHERITS` needs ownership of the parent, not merely `CREATE` on the schema. Both
halves verified:

```
SET ROLE openledger_app;  CREATE TABLE shadow_entries () INHERITS (ledger_entries);
ERROR:  permission denied for schema public
GRANT CREATE ON SCHEMA public TO openledger_app;   -- the accident
SET ROLE openledger_app;  CREATE TABLE shadow_entries () INHERITS (ledger_entries);
ERROR:  must be owner of table ledger_entries
```

**So revoking `CREATE` on the schema is not the guard; ownership already is.** As the owner, the
child carries the manual's caveat exactly — *"indexes (including unique constraints) and foreign key
constraints only apply to single tables, not to their inheritance children"*:

```
 checks | pkeys | fkeys | indexes | triggers
--------+-------+-------+---------+----------
      3 |     0 |     0 |       0 |        0
```

Three inherited `CHECK`s and nothing else. Both directions, on the 8-entry seed:

```
INSERT INTO shadow_entries SELECT * FROM ONLY ledger_entries;      INSERT 0 8
  entries via parent 8 -> 16       revenue t1 300.00 -> 600.00, t2 700.00 -> 1,400.00

DELETE FROM ledger_entries;    -- names the parent, reaches the child
ERROR:  ledger_entries is append-only: DELETE on e1000000-… refused.
  entries via parent: still 16

DELETE FROM shadow_entries;    -- names the child; no trigger, no error
  DELETE 8       entries via parent 16 -> 8
```

A partial delete gives the asymmetric version — `DELETE FROM ONLY shadow_entries WHERE
tenant_id='t1'` took the parent-visible count 16 → 12 and left t1 revenue at 300.00 against t2's
1,400.00. **The child is not only a doubling channel and not only a delete channel; it is a way to
write rows no key constrains.** An entry with a non-existent `transaction_id`, in a currency its
account does not hold, with a duplicate `account_seq`, dated 1999, was accepted into the child and
counted by every report. And `DROP TABLE shadow_entries` then removed 5 rows of reported history
with no trigger and no error.

### `SELECT … ONLY` in the views is a time bomb, and the measurement says so

The obvious fix is to make the three views read `FROM ONLY ledger_entries`. It works, and
[0002](/decisions/0002-scaling) makes it unshippable:

```
CREATE TABLE p_demo (tenant_id text, n int) PARTITION BY LIST (tenant_id);
CREATE TABLE p_demo_t1 PARTITION OF p_demo FOR VALUES IN ('t1');
INSERT INTO p_demo VALUES ('t1', 1), ('t1', 2);
SELECT count(*) FROM p_demo;        -- 2
SELECT count(*) FROM ONLY p_demo;   -- 0
```

`ONLY` excludes **partitions** exactly as it excludes inheritance children. `tenant_id` leads every
key in this schema precisely so that partitioning by tenant stays available; the day someone takes
that option, three financial statements start reporting **zero, balanced, with every check green** —
this project's worst failure class, planted years in advance by a defence against a different bug.

## D — DDL walks straight through append-only

Re-verified against the current baseline, both triggers `ENABLE ALWAYS`, neither firing:

```
ALTER TABLE ledger_entries ALTER COLUMN account_seq TYPE bigint USING (account_seq * 10);
ALTER TABLE
-- every account_seq x10:                1,2 -> 10,20 on all four accounts
 tenant_id |              account_id              | max_seq | rows | gapless
-----------+--------------------------------------+---------+------+---------
 t1        | 11111111-…                           |      20 |    2 | f
-- ...and the balance cache still says last_seq = 2.
```

Gaplessness is what makes *"no entry is missing"* a checkable claim, and it is gone. The
`amount_minor` form — the one that changes a *reported* number — is refused while the views exist
(`cannot alter type of a column used by a view or rule`) and accepted after the `DROP VIEW` a
migrator would do anyway: journal total 2,000.00 → 20,000.00. `DROP TABLE ledger_entries CASCADE`
also succeeds, taking all three views with it in a `NOTICE`.

## The guard: one function, three events

```sql
CREATE EVENT TRIGGER ck_journal__no_rewrite ON table_rewrite   EXECUTE FUNCTION refuse_journal_ddl();
CREATE EVENT TRIGGER ck_journal__no_drop    ON sql_drop        EXECUTE FUNCTION refuse_journal_ddl();
CREATE EVENT TRIGGER ck_journal__no_inherit ON ddl_command_end
    WHEN TAG IN ('CREATE TABLE','ALTER TABLE')                 EXECUTE FUNCTION refuse_journal_ddl();
```

`table_rewrite` is the narrow, purpose-built event: *"occurs just before a table is rewritten by
some actions of the commands `ALTER TABLE` and `ALTER TYPE`."* The inheritance half is a **state
assertion, not a command parse** — it asks `pg_inherits` whether a journal table has acquired a
child — so it catches `CREATE TABLE … INHERITS` and `ALTER TABLE … INHERIT` without knowing the
grammar of either. All three are `ENABLE ALWAYS`, for the same reason the six DML triggers are.

Eight results, all reproducible from `09_guard_proof.sql`:

| Attempt | Result |
| --- | --- |
| `ALTER COLUMN account_seq TYPE bigint USING (account_seq*10)` | `ERROR: public.ledger_entries is posted history and may not be rewritten by DDL (rewrite reason 4)` |
| the same on `amount_minor`, after `DROP VIEW` | refused, same error |
| `DROP TABLE ledger_entries CASCADE` | `ERROR: public.ledger_entries is posted history and may not be dropped` |
| `CREATE TABLE shadow_entries () INHERITS (ledger_entries)` | `ERROR: public.shadow_entries inherits from posted history…` |
| `CREATE TABLE shadow2 (LIKE … INCLUDING CONSTRAINTS); ALTER TABLE shadow2 INHERIT ledger_entries` | refused, same error — different grammar, same state |
| the rewrite under `session_replication_role='replica'` | refused |
| ...with the same event trigger left `ENABLE ORIGIN` | **accepted**, `account_seq` 1 → 10 |
| `CREATE INDEX`, `ADD COLUMN note text`, `ADD COLUMN n int NOT NULL DEFAULT 0`, `SET (fillfactor=90)`, `ADD CONSTRAINT … CHECK`, `VACUUM FULL` | all accepted |

The counterfactual in row seven is the whole justification for `ALTER EVENT TRIGGER … ENABLE
ALWAYS`. The manual only cross-references it; the backend is explicit
(`src/backend/commands/event_trigger.c`, `filter_event_trigger()`): *"Filter by session replication
role… if (item->enabled == TRIGGER_FIRES_ON_ORIGIN) return false"*, and
`insert_event_trigger_tuple()` defaults `evtenabled` to `TRIGGER_FIRES_ON_ORIGIN`.

One false positive, and it is a true positive on inspection: `ADD COLUMN n int NOT NULL DEFAULT
(random()*100)::int` is refused with `rewrite reason 2`. A volatile default writes a new value into
every posted row, which is what the guard is for.

### What it does not cover

| | |
| --- | --- |
| **`TRUNCATE`** | `CREATE EVENT TRIGGER … WHEN TAG IN ('TRUNCATE TABLE')` → `ERROR: event triggers are not supported for TRUNCATE TABLE`. Covered instead by the three statement-level triggers [0004](/decisions/0004-where-logic-lives) kept, which is exactly why they are three objects and not one |
| **An `ALTER TABLE` that does not rewrite** | `ALTER TABLE ledger_entries DROP COLUMN recorded_at` is accepted. It destroys a column, not the rows — and [0007](/decisions/0007-schema-conventions-and-chart)'s snapshot test is the thing that catches it (that is the Formance defect it was written for) |
| **`ALTER TABLE … DISABLE TRIGGER USER`** | Accepted, by the plain table owner, no superuser needed — it sets `ck_entries__append_only` to `D`, and then `DELETE 4`. This is the hole [0004](/decisions/0004-where-logic-lives) already admits, and the event trigger does not narrow it |
| **`DROP EVENT TRIGGER`** | The manual: *"This event also does not occur for commands targeting event triggers themselves."* An event trigger cannot guard itself, by design. Verified: drop it, then the rewrite succeeds. **This is the whole reason the role split below matters** |

## E — an account's owner can be nulled

`ledger_accounts` is the register, not the journal, and [0004](/decisions/0004-where-logic-lives)
deliberately gives it no trigger: *"a chart is edited"*. But `owner_type` and `owner_id` are not
chart metadata; they say **whose** the balance is.

```
-- 500.00 in a wallet owned by 'acme'
UPDATE ledger_accounts SET owner_type='house', owner_id=NULL WHERE id='5555…';   UPDATE 1
 owner_type | owner_id |     purpose
------------+----------+-----------------
 house      |          | customer_wallet
```

The balance sheet before and after is **byte-identical** — Cash 800.00, Customer funds payable
500.00, Undistributed earnings 300.00 — because no report reads the owner. `trial_balance` prints
`owner_id` and nothing that depends on it; `balance_sheet` and `income_statement` never mention it.

Credit where the register already earns it, checked rather than assumed: reassigning the wallet onto
an owner who already holds one is refused by `uq_accounts__owned`, and collapsing two house accounts
by `uq_accounts__house`. **What those indexes catch is a collision, not a move** — reassigning to
`initech`, whom nobody else is, was accepted.

### Closed with a foreign key, not a seventh trigger

The device is already in this file twice. `currency` and `effective_at` are denormalised copies on
`ledger_entries`, each held honest by being part of a composite foreign key back into the row it was
copied from. The half usually overlooked is the second one: **a foreign key's default `NO ACTION`
also refuses an `UPDATE` of the *referenced* columns while a dependent row points at the old
value.** [0007](/decisions/0007-schema-conventions-and-chart) already records the effect for
`fk_accounts__type` — *"refuses a change to a type's `category` or `normal_balance` while accounts
reference it"*. That is a column freeze, spelled declaratively.

Two details had to be got right, and both cost a round:

| | |
| --- | --- |
| **A composite foreign key is `MATCH SIMPLE`** | One NULL anywhere in the referencing key and the constraint is **not checked at all**. `owner_id` is NULL on every house account, so the copy has to be NULL-free — hence a `GENERATED ALWAYS … STORED` column, the same device `account_types` already uses for `fs_statement` and `fs_side` |
| **`owner_type::text` is refused as a generation expression** | `ERROR: generation expression is not immutable` — the enum-to-text cast is stable, not immutable. So `owner_type` travels in the key as itself and only `owner_id` gets the `coalesce` |

Placement: `ledger_account_balances`, one row per (account, currency), created the first time money
touches the account. `ledger_entries` would carry the copy per row and is the biggest table here.
Four directions, all refused, as the **database owner**:

```
UPDATE ledger_accounts SET owner_type='house', owner_id=NULL   … ERROR: … violates foreign key
UPDATE ledger_accounts SET owner_id='initech'                  … ERROR: … violates foreign key
UPDATE ledger_accounts SET owner_type='platform'               … ERROR: … violates foreign key
UPDATE ledger_accounts SET owner_type='company', owner_id='acme' (a house account)
                                                                … ERROR: … violates foreign key
UPDATE ledger_accounts SET metadata = '{"note":"KYC re-verified"}'   UPDATE 1   -- still editable
```

The app role holds table-wide `UPDATE` on the balance cache today, so it could launder its own copy
first. A **column-level grant** closes that, and it is declarative:

```sql
REVOKE UPDATE ON ledger_account_balances FROM openledger_app;
GRANT  UPDATE (input, output, last_seq, updated_at) ON ledger_account_balances TO openledger_app;
```

```
SET ROLE openledger_app;
UPDATE ledger_account_balances SET owner_type='house', owner_id_key='' …
ERROR:  permission denied for table ledger_account_balances
-- ...and the writer's own upsert, the ADR-0002 shape, is unaffected:
INSERT … ON CONFLICT (tenant_id,account_id,currency) DO UPDATE
   SET input = … + EXCLUDED.input, last_seq = … + 1, updated_at = now() RETURNING input, last_seq;
 input | last_seq
-------+----------
 50800 |        3
```

**What it costs, measured.** `pg_column_size` on the balance row, which is the system's
serialization point and the one row [0007](/decisions/0007-schema-conventions-and-chart) §7 calls
the most performance-critical thing in the schema:

| Row | Bytes |
| --- | --- |
| today | **80** |
| house account (`owner_id_key = ''`) — **these are the contended rows** | **85** (+6%) |
| owned account, 4-character `owner_id` | 89 (+11%) |
| owned account, 36-character UUID `owner_id` | 121 (+51%) |

The widening lands almost entirely on cold rows: the hot account of
[0002](/decisions/0002-scaling)'s contention story is `network_settlement_payable`, which is a
**house** account and pays 5 bytes. And the new foreign key is checked on `INSERT` of the balance row
and on an `UPDATE` that changes the key columns — the per-posting upsert changes neither, so the
posting path pays nothing.

**What it does not cover:** an account with no balance row yet is not frozen (nothing has been posted
to it, so there is no posted history to restate); it says nothing about whether the owner was *right*
at open; and deleting the balance row would unfreeze it — the app role has no `DELETE` there, and the
owner is the owner.

## 12 — the role split is what makes the guard real

`DROP EVENT TRIGGER` needs superuser. So does `ALTER EVENT TRIGGER … DISABLE`, and so does `SET
event_triggers = off`. That looks like a genuine privilege gap over the migrator — and in today's
deployment shape it is not, because of `public`:

**Shape A — the migrator is the database owner (today).** `public` is owned by `pg_database_owner`,
of which the database owner is a member. One statement removes everything:

```
DROP FUNCTION refuse_journal_ddl() CASCADE;
NOTICE:  drop cascades to 3 other objects
DETAIL:  drop cascades to event trigger ck_journal__no_rewrite
         drop cascades to event trigger ck_journal__no_drop
         drop cascades to event trigger ck_journal__no_inherit
DROP FUNCTION
```

...after which the rewrite, the child table and `DROP TABLE ledger_entries` all succeed.

**Shape B — the migrator owns the tables; the database is owned elsewhere.** The guard installed
once by a superuser, the baseline applied by `wsa_migrator`:

```
DROP FUNCTION refuse_journal_ddl() CASCADE;      ERROR:  must be owner of function refuse_journal_ddl
DROP EVENT TRIGGER ck_journal__no_rewrite;       ERROR:  must be owner of event trigger …
ALTER COLUMN account_seq TYPE bigint USING …     ERROR:  … may not be rewritten by DDL
CREATE TABLE shadow_entries () INHERITS (…)      ERROR:  … inherits from posted history
DROP TABLE ledger_entries CASCADE;               ERROR:  … may not be dropped
ALTER TABLE ledger_entries DISABLE TRIGGER USER; ALTER TABLE      <- the one that still works
```

**Four of the five channels close against the role that runs migrations, and they close only in
shape B.** Two integration notes fell out of running the baseline that way, and neither is a defect:
`GRANT USAGE ON SCHEMA public TO openledger_app` and `REVOKE CREATE ON SCHEMA public FROM PUBLIC`
both emit `WARNING: no privileges were granted / could be revoked for "public"` when the applier does
not own the schema — and both are inert anyway on PostgreSQL 18, where `PUBLIC` already has `USAGE`
and does not have `CREATE` (`has_schema_privilege('public','public','CREATE') = f`).

## What the neighbours do

| | |
| --- | --- |
| **Formance** (`335bd03`) | **Zero event triggers, zero `ENABLE ALWAYS`, zero `session_replication_role`, zero `GRANT`, zero `REVOKE`** — greps over the whole repository. Its migration runner is a bare `db.ExecContext(ctx, sqlFile)`; the only lock is an advisory one against a concurrent migrator. And its own migrations do the thing this ADR is about: `logs` is its append-only hash-chained log, and **six shipped migrations `UPDATE` it** — 7, 23, 32, 33, 34, 42 — with no re-hash and no `BEFORE UPDATE` guard, the chain being enforced only by an `ENABLE ORIGIN` insert trigger. One migration comment records the constraint they actually live under: *"cannot disable triggers at session level on Azure Postgres with no superuser privileges."* |
| **pgMemento** (`f09c44c`, v0.7.4) | Six event triggers on `ddl_command_start`, `ddl_command_end` and `sql_drop` — and **no `table_rewrite`**: `grep -rin table_rewrite` returns nothing repo-wide. It brackets `ALTER TABLE` with a before/after pair instead, so it learns that an `ALTER TABLE` ran, never that a rewrite happened. **No `ENABLE ALWAYS` anywhere**, on the event triggers or the five per-table ones, so a pgMemento-audited table logs nothing on a replication apply path |
| **pgAudit** (`52a3253`) | Two event triggers, `ddl_command_end` and `sql_drop`, both `SECURITY DEFINER`. It claims only to log — and disclaims even that: *"Audit logging is best-effort and not transactional… There is no guarantee that a committed transaction will have a corresponding audit log entry."* No prevention claim anywhere in its README |

**Nobody in this set prevents DDL against posted history.** The three published mechanisms are
Formance's convention, pgMemento's after-the-fact log, and pgAudit's best-effort log. That is worth
knowing before treating one event trigger as table stakes: it is not, and this project would be
alone in shipping it.

## The proposed edits, applied and attacked

`PROPOSED_baseline.sql` is the exact DDL [ADR 0009](/decisions/0009-append-only-perimeter) marks
applied-pending-integration. Loaded onto a clean baseline + chart + seed it applies without error,
and the four channels close in one pass:

```
proposed edits applied clean
ALTER TABLE ledger_entries ALTER COLUMN account_seq TYPE bigint USING (account_seq*10);
  ERROR:  public.ledger_entries is posted history and may not be rewritten by DDL (rewrite reason 4)
CREATE TABLE shadow_entries () INHERITS (ledger_entries);
  ERROR:  public.shadow_entries inherits from posted history…
DROP TABLE ledger_entries CASCADE;
  ERROR:  public.ledger_entries is posted history and may not be dropped
UPDATE ledger_accounts SET owner_type='house', owner_id=NULL WHERE id='5555…';
  ERROR:  update or delete on table "ledger_accounts" violates foreign key constraint
          "fk_balances__account_owner" on table "ledger_account_balances"

 entries 8   |   revenue t1 300.00, t2 700.00   -- unchanged by any of it
 tgisinternal | tgenabled | count        evtname         |    evtevent     | evtenabled
 f            | A         |     6   ck_journal__no_drop    | sql_drop        | A
 t            | O         |    40   ck_journal__no_inherit | ddl_command_end | A
                                    ck_journal__no_rewrite | table_rewrite   | A
```

**36 internal foreign-key triggers becomes 40**, because the owner freeze is a tenth foreign key.
One no-op to note: `UPDATE … SET owner_type='house', owner_id=NULL` on an account that is *already*
house returns `UPDATE 1` and is correct — the referenced key does not change, so there is nothing for
the foreign key to refuse.

## On the sourcing of this spike

Every PostgreSQL quotation is from the version 18 manual, re-fetched rather than recalled; where the
manual is silent about what a tool emits (`pg_dump --disable-triggers`) or about a documented
behaviour's mechanism (event triggers under `session_replication_role`) the claim is sourced to
`REL_18_STABLE` source with the file and function named. The three repositories were cloned and
grepped at the commits given at the top; every count above came from a grep that was actually run.

**One thing could not be verified and is not asserted.** Whether a *managed* PostgreSQL will install
either superuser-requiring guard is untested: verified locally that a plain non-superuser database
owner installs neither, and AWS's own documentation says the top RDS role is created `NOSUPERUSER`
and does not list event triggers among what `rds_superuser` allows — but no RDS instance was
available to try it on. A deferred [RDS deployment](/roadmap#if-this-ever-wants-a-production-story)
is the first time this project touches one, and it is the right place to
find out.
