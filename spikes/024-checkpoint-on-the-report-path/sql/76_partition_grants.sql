-- Does parent-routed DML need privileges on the partitions? And does the
-- baseline's belt-and-braces REVOKE still bind?
\set ON_ERROR_STOP off
\echo '--- the grant lists, parent and partitions:'
SELECT c.relname || ': ' || COALESCE(r.rolname,'PUBLIC') || ' ' || x.privilege_type AS grant_line
FROM pg_class c
CROSS JOIN LATERAL aclexplode(c.relacl) x
LEFT JOIN pg_roles r ON r.oid = x.grantee
WHERE c.relname LIKE 'ledger_period_balance%'
  AND (COALESCE(r.rolname,'') LIKE 'openledger%' OR r.rolname IS NULL)
ORDER BY 1;

\echo '--- as openledger_app: INSERT through the PARENT, routed into a partition it'
\echo '    holds no grant on. Must succeed.'
BEGIN;
SET LOCAL ROLE openledger_app;
INSERT INTO ledger_period_balances
SELECT 't1','2026-02','USD', md5('re:t1:USD')::uuid, 0, 0
WHERE NOT EXISTS (SELECT 1 FROM ledger_period_balances
                   WHERE tenant_id='t1' AND period_code='2026-02' AND currency='USD'
                     AND account_id = md5('re:t1:USD')::uuid);
SELECT 'insert through parent: OK' AS result;
ROLLBACK;

\echo '--- as openledger_app: UPDATE must still be refused (the REVOKE)'
BEGIN;
SET LOCAL ROLE openledger_app;
UPDATE ledger_period_balances SET input = input + 1;
ROLLBACK;

\echo '--- as openledger_app: DELETE must still be refused'
BEGIN;
SET LOCAL ROLE openledger_app;
DELETE FROM ledger_period_balances;
ROLLBACK;

\echo '--- as openledger_app: TRUNCATE must still be refused'
BEGIN;
SET LOCAL ROLE openledger_app;
TRUNCATE ledger_period_balances;
ROLLBACK;

\echo '--- as openledger_app: and a PARTITION addressed directly -- no grant there'
BEGIN;
SET LOCAL ROLE openledger_app;
SELECT count(*) FROM ledger_period_balances_p2026_01;
ROLLBACK;

\echo '--- as openledger_app: UPDATE on a partition directly, which the parent REVOKE'
\echo '    does NOT cover -- if this succeeds the REVOKE has a hole'
BEGIN;
SET LOCAL ROLE openledger_app;
UPDATE ledger_period_balances_p2026_01 SET input = input + 1;
ROLLBACK;
