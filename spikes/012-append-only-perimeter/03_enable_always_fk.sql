-- 03 -- CHANNEL A, and why the fix the decision log proposed does not exist.
--
-- The proposal was "one `ALTER TABLE ... ENABLE ALWAYS TRIGGER` per foreign key".
-- That statement cannot be written. Three findings, in order:

\echo '=== (i) the four internal triggers of a foreign key are NOT named after it ==='
SELECT c.conname, t.tgrelid::regclass AS on_table, t.tgname, t.tgenabled
FROM pg_constraint c JOIN pg_trigger t ON t.tgconstraint = c.oid
WHERE c.conname = 'fk_entries__txn' ORDER BY 2,3;

\set ON_ERROR_STOP 0
\echo '=== (ii) so naming the constraint is a syntax-level miss ==='
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER fk_entries__txn;

\echo '=== (iii) ...and ALL / USER are not accepted after ALWAYS. The grammar is'
\echo '===       ENABLE ALWAYS TRIGGER <name> only. ==='
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ALL;
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER USER;
\set ON_ERROR_STOP 1

\echo '=== so the only spelling that works names the generated, OID-derived name ==='
\echo '=== -- which is different in every database, so it cannot be written into a'
\echo '=== migration file. It has to be generated from the catalog at apply time. ==='
DO $$
DECLARE r record; n int := 0;
BEGIN
    FOR r IN
        SELECT t.tgrelid::regclass AS tbl, t.tgname
        FROM pg_constraint c JOIN pg_trigger t ON t.tgconstraint = c.oid
        WHERE c.contype = 'f' AND c.connamespace = 'public'::regnamespace
          AND t.tgenabled = 'O'
    LOOP
        EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER %I', r.tbl, r.tgname);
        n := n + 1;
    END LOOP;
    RAISE NOTICE 'promoted % internal FK triggers to ENABLE ALWAYS', n;
END $$;

SELECT tgisinternal, tgenabled, count(*) FROM pg_trigger GROUP BY 1,2 ORDER BY 1,2;

\echo '=== the three replica-role writes from 02, re-run against the fixed schema ==='
\set ON_ERROR_STOP 0
BEGIN;
SET LOCAL session_replication_role = 'replica';
INSERT INTO ledger_entries (tenant_id, id, transaction_id, account_id, direction,
                            amount_minor, currency, account_seq, effective_at)
VALUES ('t1','dead0000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-0000deadbeef',
        '11111111-1111-1111-1111-111111111111',
        'debit', 5000000, 'EUR', 99, '1999-01-01T00:00:00Z');
ROLLBACK;

BEGIN;
SET LOCAL session_replication_role = 'replica';
INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
VALUES ('t1','dead0000-0000-0000-0000-00000000000f',
        '00000000-0000-0000-0000-00000000beef','clearing','posted','2026-03-01T00:00:00Z');
ROLLBACK;

BEGIN;
SET LOCAL session_replication_role = 'replica';
INSERT INTO ledger_accounts (tenant_id, id, owner_type, owner_id, purpose, category, normal_balance, currency)
VALUES ('t1','dead0000-0000-0000-0000-0000000000aa','house',NULL,
        'interchange_revenue','asset','debit','EUR');
ROLLBACK;
\set ON_ERROR_STOP 1

\echo '=== an ordinary write is unaffected ==='
INSERT INTO ledger_transactions (tenant_id, id, kind, status, effective_at)
VALUES ('t1','aaaaaaaa-0000-0000-0000-000000000003','clearing','posted','2026-03-15T00:00:00Z');
INSERT INTO ledger_entries (tenant_id, id, transaction_id, account_id, direction, amount_minor, currency, account_seq, effective_at)
VALUES ('t1','e1000000-0000-0000-0000-000000000005','aaaaaaaa-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111','debit', 100,'USD',3,'2026-03-15T00:00:00Z'),
       ('t1','e1000000-0000-0000-0000-000000000006','aaaaaaaa-0000-0000-0000-000000000003','22222222-2222-2222-2222-222222222222','credit',100,'USD',3,'2026-03-15T00:00:00Z');
SELECT count(*) AS entries FROM ledger_entries;

\echo '=== WHAT ENABLE ALWAYS DOES NOT DO: pg_restore --disable-triggers still wins ==='
BEGIN;
ALTER TABLE ledger_entries DISABLE TRIGGER ALL;
SET LOCAL session_replication_role = 'replica';
INSERT INTO ledger_entries (tenant_id, id, transaction_id, account_id, direction,
                            amount_minor, currency, account_seq, effective_at)
VALUES ('t1','dead0000-0000-0000-0000-000000000002',
        '00000000-0000-0000-0000-0000deadbeef',
        '11111111-1111-1111-1111-111111111111',
        'debit', 5000000, 'EUR', 97, '1999-01-01T00:00:00Z');
SELECT count(*) AS accepted_anyway FROM ledger_entries
 WHERE id = 'dead0000-0000-0000-0000-000000000002';
ROLLBACK;
