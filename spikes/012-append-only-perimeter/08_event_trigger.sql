-- 08 -- THE PROPOSED GUARD, in the exact form proposed for the baseline.
--
-- One function, three events, three event-trigger objects.
--
-- It is a STATE assertion, not a command parse. The inheritance half asks
-- pg_inherits whether a journal table has acquired a child, so it catches
-- `CREATE TABLE ... INHERITS` and `ALTER TABLE ... INHERIT` and anything else that
-- reaches the same state, without knowing the grammar of either.
--
-- The journal is named as TEXT, not as regclass. An earlier version used a
-- `regclass[]` constant and the sql_drop branch died initialising it -- by the time
-- sql_drop fires the relation is already gone, so `'ledger_entries'::regclass`
-- raises `relation does not exist`. The DROP was still refused, by the wrong error.
--
-- ENABLE ALWAYS on all three, for the same reason the six DML triggers are: an
-- event trigger in the default ENABLE ORIGIN state does not fire under
-- session_replication_role = 'replica'. Counterfactual in 09.

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
        SELECT format('%s.%s', schema_name, object_name) INTO victim
        FROM pg_event_trigger_dropped_objects()
        WHERE object_type = 'table'
          AND format('%s.%s', schema_name, object_name) = ANY (journal)
        LIMIT 1;
        IF victim IS NOT NULL THEN
            RAISE EXCEPTION '% is posted history and may not be dropped', victim
              USING ERRCODE = '23514';
        END IF;

    ELSE  -- ddl_command_end
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
