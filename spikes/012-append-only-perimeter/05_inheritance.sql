-- 05 -- CHANNEL C. Table inheritance: a doubling channel AND a DELETE channel.
--
-- A child of ledger_entries inherits the CHECK constraints and NOTHING else -- no
-- primary key, no unique index, no foreign key, no trigger -- and is visible
-- through the parent to every query that does not say ONLY. Every view in the
-- shipped schema reads `FROM ledger_entries`, without ONLY.

\echo '=== 1. who can open this channel ==='
\echo '-- the app role, with the shipped grants: no CREATE on the schema --'
SET ROLE openledger_app;
\set ON_ERROR_STOP 0
CREATE TABLE shadow_entries () INHERITS (ledger_entries);
RESET ROLE;
\echo '-- ...and with CREATE granted by mistake: ownership of the PARENT is the gate --'
GRANT CREATE ON SCHEMA public TO openledger_app;
SET ROLE openledger_app;
CREATE TABLE shadow_entries () INHERITS (ledger_entries);
RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM openledger_app;
\set ON_ERROR_STOP 1

\echo '=== 2. as the OWNER, which is who runs a migration ==='
SELECT count(*) AS entries_via_parent FROM ledger_entries;
SELECT tenant_id, currency, fs_line, amount_minor FROM income_statement WHERE amount_minor <> 0;

CREATE TABLE shadow_entries () INHERITS (ledger_entries);

\echo '-- what the child carries: 3 CHECKs, no key, no FK, no unique index, no trigger --'
SELECT
  (SELECT count(*) FROM pg_constraint WHERE conrelid='shadow_entries'::regclass AND contype='c') AS checks,
  (SELECT count(*) FROM pg_constraint WHERE conrelid='shadow_entries'::regclass AND contype='p') AS pkeys,
  (SELECT count(*) FROM pg_constraint WHERE conrelid='shadow_entries'::regclass AND contype='f') AS fkeys,
  (SELECT count(*) FROM pg_index      WHERE indrelid='shadow_entries'::regclass) AS indexes,
  (SELECT count(*) FROM pg_trigger    WHERE tgrelid ='shadow_entries'::regclass) AS triggers;

\echo '=== 3. THE DOUBLING CHANNEL ==='
INSERT INTO shadow_entries SELECT * FROM ONLY ledger_entries;
SELECT count(*) AS entries_via_parent FROM ledger_entries;
SELECT tenant_id, currency, fs_line, amount_minor FROM income_statement WHERE amount_minor <> 0;

\echo '=== 4. THE DELETE CHANNEL -- the same child, the other direction ==='
\echo '-- a DELETE naming the PARENT reaches the child, and the parent has an'
\echo '-- ENABLE ALWAYS append-only trigger. The child has none, so the trigger'
\echo '-- refuses the parent rows and the child rows go. --'
\set ON_ERROR_STOP 0
DELETE FROM ledger_entries;
\set ON_ERROR_STOP 1
SELECT count(*) AS entries_via_parent FROM ledger_entries;
\echo '-- ...and naming the CHILD deletes without even an error --'
DELETE FROM shadow_entries;
SELECT count(*) AS entries_via_parent FROM ledger_entries;

\echo '=== 5. and this is genuinely a REMOVAL of posted history, not only of copies ==='
\echo '-- put the child back, this time with rows that exist ONLY in the child --'
INSERT INTO shadow_entries SELECT * FROM ONLY ledger_entries;
DELETE FROM ONLY shadow_entries WHERE tenant_id = 't1';
SELECT count(*) AS entries_via_parent FROM ledger_entries;
SELECT tenant_id, currency, fs_line, amount_minor FROM income_statement WHERE amount_minor <> 0;

\echo '=== 6. the child also accepts rows NO KEY constrains, and every report counts them ==='
INSERT INTO shadow_entries (tenant_id,id,transaction_id,account_id,direction,amount_minor,currency,account_seq,effective_at)
VALUES ('t1','ffff0000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-0000deadbeef',            -- no such transaction
        '11111111-1111-1111-1111-111111111111','credit',
        900000,'EUR',                                       -- the account holds USD
        1,                                                  -- duplicate account_seq
        '1999-01-01T00:00:00Z');                            -- 27 years off
SELECT count(*) AS parent_visible FROM ledger_entries;

\echo '=== 7. ...and DROP TABLE removes reported history with no trigger and no error ==='
DROP TABLE shadow_entries;
SELECT count(*) AS parent_visible FROM ledger_entries;
