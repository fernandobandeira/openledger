-- PROPOSED EDITS TO migrations/00001_baseline.sql -- NOT APPLIED.
--
-- ADR-0009 marks these applied-pending-integration. This file is the exact DDL, in
-- a form that can be tested: loaded AFTER the baseline it produces the same end
-- state as the in-place edits, except that the two new columns arrive by ALTER
-- rather than in CREATE TABLE. `13_proposed_applies.sh` loads baseline + chart +
-- seed + this file and re-runs the four attacks.
--
-- In the baseline itself the two column additions belong inside
-- CREATE TABLE ledger_account_balances, and the GRANT change replaces the existing
-- `GRANT SELECT, INSERT, UPDATE ON ledger_account_balances` line.

-- ---------------------------------------------------------------- (E) the owner freeze
-- A composite FK freezes its REFERENCED columns: NO ACTION refuses an UPDATE of
-- them while a dependent row points at the old value. Same device as
-- fk_entries__account (currency) and fk_entries__txn_effective (effective_at),
-- used for the third time and now deliberately.
--
-- owner_id is NULL on house accounts and a composite FK is MATCH SIMPLE -- one NULL
-- and the constraint is NOT CHECKED -- so the copy is a NULL-free GENERATED column.
-- owner_type travels as itself because `owner_type::text` is refused as a
-- generation expression: the enum cast is stable, not immutable.
ALTER TABLE ledger_accounts
  ADD COLUMN owner_id_key text GENERATED ALWAYS AS (coalesce(owner_id, '')) STORED;
ALTER TABLE ledger_accounts
  ADD CONSTRAINT uq_accounts__id_owner UNIQUE (tenant_id, id, owner_type, owner_id_key);

ALTER TABLE ledger_account_balances
  ADD COLUMN owner_type   account_owner_type,
  ADD COLUMN owner_id_key text;
UPDATE ledger_account_balances b SET owner_type = a.owner_type, owner_id_key = a.owner_id_key
  FROM ledger_accounts a WHERE a.tenant_id = b.tenant_id AND a.id = b.account_id;
ALTER TABLE ledger_account_balances
  ALTER COLUMN owner_type   SET NOT NULL,
  ALTER COLUMN owner_id_key SET NOT NULL,
  ADD CONSTRAINT fk_balances__account_owner
      FOREIGN KEY (tenant_id, account_id, owner_type, owner_id_key)
      REFERENCES ledger_accounts (tenant_id, id, owner_type, owner_id_key);

-- ...and the app role's UPDATE narrowed to what the writer writes. Column-level
-- grants are declarative; this replaces the table-wide UPDATE in the baseline.
REVOKE UPDATE ON ledger_account_balances FROM openledger_app;
GRANT  UPDATE (input, output, last_seq, updated_at) ON ledger_account_balances TO openledger_app;

-- ---------------------------------------------------------------- (C, D) the DDL perimeter
-- AN EVENT TRIGGER NEEDS A WRITTEN JUSTIFICATION TOO. ADR-0009 carries the long
-- form; the short form:
--
-- INVARIANT: posted history is not editable by DDL either. `ALTER TABLE
-- ledger_entries ALTER COLUMN account_seq TYPE bigint USING (account_seq * 10)`
-- rewrote every row with both DML triggers ENABLE ALWAYS and neither firing, and
-- destroyed gaplessness -- the property that makes "no entry is missing" checkable.
-- A child table carries three inherited CHECKs and no key, no index, no FK and no
-- trigger, is visible through the parent to every view, and both doubles and
-- removes parent-visible rows. DROP TABLE removes the lot.
--
-- WHY NOTHING DECLARATIVE HOLDS IT: there is no CHECK, key or GRANT whose subject
-- is a DDL statement, and withholding the privilege means withholding ownership --
-- which is the role that runs migrations. `SELECT ... ONLY` in the views hides the
-- child from three reports and from nothing else, and excludes PARTITIONS
-- identically: measured, `FROM ONLY p` returns 0 rows on a populated partitioned
-- table. tenant_id leads every key here so partitioning stays available (ADR-0002),
-- so ONLY is a silent zero-revenue report waiting on a future migration.
--
-- WHAT IT DOES NOT PROTECT AGAINST: TRUNCATE (PostgreSQL: `event triggers are not
-- supported for TRUNCATE TABLE` -- hence the three statement-level triggers above);
-- ALTER TABLE ... DROP COLUMN, which rewrites nothing; ALTER TABLE ... DISABLE
-- TRIGGER USER, which the plain table owner may still run; and itself -- the manual
-- says the event "does not occur for commands targeting event triggers themselves".
--
-- AND IT IS DECORATION IF THE MIGRATOR OWNS THE DATABASE. `public` is owned by
-- pg_database_owner, so a database-owner migrator drops this function CASCADE and
-- takes all three event triggers with it. The migrator must own the TABLES and not
-- the DATABASE. Measured both ways in spike 010.
CREATE FUNCTION refuse_journal_ddl() RETURNS event_trigger LANGUAGE plpgsql AS $$
DECLARE
    journal CONSTANT text[] := ARRAY['public.ledger_entries',
                                     'public.ledger_transactions',
                                     'public.ledger_events'];
    victim  text;
BEGIN
    IF TG_EVENT = 'table_rewrite' THEN
        victim := (SELECT format('%s.%s', n.nspname, c.relname)
                   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE c.oid = pg_event_trigger_table_rewrite_oid());
        IF victim = ANY (journal) THEN
            RAISE EXCEPTION
              '% is posted history and may not be rewritten by DDL (rewrite reason %)',
              victim, pg_event_trigger_table_rewrite_reason()
              USING ERRCODE = '23514',
                    HINT = 'Add a new column or a new table; posted rows are not editable, by DDL either.';
        END IF;

    ELSIF TG_EVENT = 'sql_drop' THEN
        -- named as TEXT, not regclass: by the time sql_drop fires the relation is
        -- gone, and 'ledger_entries'::regclass raises `relation does not exist`.
        SELECT format('%s.%s', schema_name, object_name) INTO victim
        FROM pg_event_trigger_dropped_objects()
        WHERE object_type = 'table'
          AND format('%s.%s', schema_name, object_name) = ANY (journal)
        LIMIT 1;
        IF victim IS NOT NULL THEN
            RAISE EXCEPTION '% is posted history and may not be dropped', victim
              USING ERRCODE = '23514';
        END IF;

    ELSE  -- ddl_command_end. A STATE assertion, not a command parse: it asks whether
          -- a journal table has acquired a child, so CREATE TABLE ... INHERITS and
          -- ALTER TABLE ... INHERIT are both caught without knowing either grammar.
        SELECT format('%s.%s', cn.nspname, c.relname) INTO victim
        FROM pg_inherits i
        JOIN pg_class c      ON c.oid  = i.inhrelid
        JOIN pg_namespace cn ON cn.oid = c.relnamespace
        JOIN pg_class p      ON p.oid  = i.inhparent
        JOIN pg_namespace pn ON pn.oid = p.relnamespace
        WHERE format('%s.%s', pn.nspname, p.relname) = ANY (journal)
        LIMIT 1;
        IF victim IS NOT NULL THEN
            RAISE EXCEPTION
              '% inherits from posted history: a child carries none of the parent''s keys or triggers and is visible through it to every report',
              victim USING ERRCODE = '23514';
        END IF;
    END IF;
END $$;

-- ENABLE ALWAYS on all three, for the reason the six DML triggers are: an event
-- trigger left in the default ENABLE ORIGIN state does not fire under
-- session_replication_role = 'replica'. Counterfactual measured: the same rewrite
-- succeeds, account_seq 1 -> 10.
CREATE EVENT TRIGGER ck_journal__no_rewrite ON table_rewrite
    EXECUTE FUNCTION refuse_journal_ddl();
ALTER EVENT TRIGGER ck_journal__no_rewrite ENABLE ALWAYS;

CREATE EVENT TRIGGER ck_journal__no_drop ON sql_drop
    EXECUTE FUNCTION refuse_journal_ddl();
ALTER EVENT TRIGGER ck_journal__no_drop ENABLE ALWAYS;

CREATE EVENT TRIGGER ck_journal__no_inherit ON ddl_command_end
    WHEN TAG IN ('CREATE TABLE', 'ALTER TABLE')
    EXECUTE FUNCTION refuse_journal_ddl();
ALTER EVENT TRIGGER ck_journal__no_inherit ENABLE ALWAYS;
