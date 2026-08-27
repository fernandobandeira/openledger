-- 06 -- CHANNEL E. An account's owner can be nulled.
-- The register (ledger_accounts) is not the journal and carries no append-only
-- trigger, deliberately: a chart is edited. But owner_type/owner_id are not chart
-- metadata -- they say WHOSE the balance is.

\echo '=== a customer wallet with money in it ==='
INSERT INTO ledger_accounts (tenant_id,id,owner_type,owner_id,purpose,category,normal_balance,currency)
VALUES ('t1','55555555-5555-5555-5555-555555555555','company','acme','customer_wallet','liability','credit','USD');
INSERT INTO ledger_transactions (tenant_id,id,kind,status,effective_at)
VALUES ('t1','aaaaaaaa-0000-0000-0000-00000000000a','deposit','posted','2026-01-20T00:00:00Z');
INSERT INTO ledger_entries (tenant_id,id,transaction_id,account_id,direction,amount_minor,currency,account_seq,effective_at)
VALUES ('t1','e1000000-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-00000000000a','11111111-1111-1111-1111-111111111111','debit',50000,'USD',3,'2026-01-20T00:00:00Z'),
       ('t1','e1000000-0000-0000-0000-00000000000b','aaaaaaaa-0000-0000-0000-00000000000a','55555555-5555-5555-5555-555555555555','credit',50000,'USD',1,'2026-01-20T00:00:00Z');

SELECT owner_type, owner_id, purpose FROM ledger_accounts WHERE id='55555555-5555-5555-5555-555555555555';
SELECT tenant_id, currency, caption, amount_minor FROM balance_sheet
 WHERE tenant_id='t1' AND amount_minor <> 0;

\echo '=== 1. THE APP ROLE CANNOT REACH IT. It holds INSERT and SELECT, nothing else. ==='
SELECT grantee, string_agg(privilege_type, ',' ORDER BY privilege_type) AS privs
FROM information_schema.role_table_grants
WHERE table_name='ledger_accounts' AND grantee='openledger_app' GROUP BY 1;
\set ON_ERROR_STOP 0
SET ROLE openledger_app;
UPDATE ledger_accounts SET owner_type='house', owner_id=NULL WHERE id='55555555-5555-5555-5555-555555555555';
RESET ROLE;
\set ON_ERROR_STOP 1

\echo '=== 2. what the unique indexes DO bind, checked rather than assumed ==='
INSERT INTO ledger_accounts (tenant_id,id,owner_type,owner_id,purpose,category,normal_balance,currency)
VALUES ('t1','66666666-6666-6666-6666-666666666666','company','globex','customer_wallet','liability','credit','USD');
\set ON_ERROR_STOP 0
\echo '-- reassigning a wallet onto an owner who already has one: refused --'
BEGIN;
UPDATE ledger_accounts SET owner_id='globex' WHERE id='55555555-5555-5555-5555-555555555555';
ROLLBACK;
\echo '-- collapsing one house account onto another: refused by uq_accounts__house --'
BEGIN;
UPDATE ledger_accounts SET purpose='interchange_revenue', category='revenue', normal_balance='credit'
 WHERE id='22222222-2222-2222-2222-222222222222';
UPDATE ledger_accounts SET purpose='interchange_revenue', category='revenue', normal_balance='credit'
 WHERE id='11111111-1111-1111-1111-111111111111';
ROLLBACK;
\set ON_ERROR_STOP 1
\echo '-- ...but reassigning to an owner nobody else has: ACCEPTED --'
BEGIN;
UPDATE ledger_accounts SET owner_id='initech' WHERE id='55555555-5555-5555-5555-555555555555';
SELECT owner_type, owner_id FROM ledger_accounts WHERE id='55555555-5555-5555-5555-555555555555';
ROLLBACK;

\echo '=== 3. THE OWNER-NULLING CHANNEL, as the database owner ==='
UPDATE ledger_accounts SET owner_type='house', owner_id=NULL
 WHERE id='55555555-5555-5555-5555-555555555555';
SELECT owner_type, owner_id, purpose FROM ledger_accounts WHERE id='55555555-5555-5555-5555-555555555555';

\echo '=== the balance sheet is byte-identical: 500.00 of customer funds, owed to nobody ==='
SELECT tenant_id, currency, caption, amount_minor FROM balance_sheet
 WHERE tenant_id='t1' AND amount_minor <> 0;
\echo '=== and no view in the schema reads owner_type or owner_id except trial_balance, ==='
\echo '=== which prints owner_id and nothing that depends on it ==='
SELECT c.relname, pg_get_viewdef(c.oid) ~ 'owner_' AS mentions_owner
FROM pg_class c WHERE c.relkind='v' AND c.relnamespace='public'::regnamespace ORDER BY 1;
SELECT owner_id, purpose, balance_minor FROM trial_balance WHERE tenant_id='t1' ORDER BY 2;
