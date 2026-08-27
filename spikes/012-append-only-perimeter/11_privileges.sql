-- 11 -- the privilege boundary. Every guard in this spike lives on one side of it.
\set ON_ERROR_STOP 0
\echo '=== the APPLICATION role reaches none of the five channels ==='
SET ROLE openledger_app;
\echo '-- A. session_replication_role --'
SET session_replication_role = 'replica';
\echo '-- B. DISABLE TRIGGER --'
ALTER TABLE ledger_entries DISABLE TRIGGER USER;
\echo '-- C. inheritance --'
CREATE TABLE shadow_entries () INHERITS (ledger_entries);
\echo '-- D. the rewrite --'
ALTER TABLE ledger_entries ALTER COLUMN account_seq TYPE bigint USING (account_seq * 10);
\echo '-- E. the register --'
UPDATE ledger_accounts SET owner_type='house', owner_id=NULL;
RESET ROLE;

\echo '=== ...and what the shipped grants actually are ==='
SELECT table_name, string_agg(privilege_type, ',' ORDER BY privilege_type) AS privs
FROM information_schema.role_table_grants
WHERE grantee = 'openledger_app' GROUP BY 1 ORDER BY 1;

\echo '=== the OWNER reaches all five. Both proposed guards need MORE than owner. ==='
\echo '-- (run 11_privileges_nosuper.sh for the non-superuser-owner half) --'
