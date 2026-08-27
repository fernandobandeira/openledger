-- 06_rls.sql -- tenant isolation as row-level security, and the three things that
-- break if you enable it naively.
--
-- ADR-0001 asserts "tenant isolation IS row-level security". `migrations/` contains
-- no CREATE POLICY. This file is the policy set and the measurements that decide
-- which roles are subject to it.
--
-- THE ASSUMPTION THIS FILE OVERTURNS: the decision log and the roadmap both say
-- RLS and bulk batching are mutually exclusive, because Postgres refuses COPY FROM
-- on an RLS table and coalesced batching uses COPY. The first half is true and is
-- measured below. The second half is measured in 10_copy_vs_insert.py and is
-- FALSE on this table: INSERT ... SELECT FROM unnest(...) is within 1-5% of COPY
-- at every batch size from 25 to 10,000, because ledger_entries carries three
-- composite foreign keys and a unique index and per-row constraint checking
-- dominates the wire format. So nothing has to bypass RLS.
--
-- Run after 00_seed.sql and 03_idempotency.sql, BEFORE 07_striping.sql.

\set ON_ERROR_STOP off
\pset pager off

-- ======================================================================
-- 0. the roles. The writer already exists (the baseline creates it). The reader
--    is new: SELECT only, and it is the role the tenant policies are FOR.
-- ======================================================================
DROP ROLE IF EXISTS openledger_read;
CREATE ROLE openledger_read NOLOGIN;
GRANT USAGE ON SCHEMA public TO openledger_read;
GRANT SELECT ON ledger_accounts, ledger_events, ledger_transactions, ledger_entries,
                ledger_account_balances, account_types, fs_lines,
                trial_balance, balance_sheet, income_statement TO openledger_read;

-- ======================================================================
-- 1. THE POLICY SET, proposed for migrations/00002.
--
--    Five tables. The chart -- fs_lines and account_types -- gets none: it is
--    deployment-global and carries no tenant_id at all, a limitation the decision
--    log already records.
--
--    The tenant policy is written the one way spike 004 measured:
--      * the scalar subquery forces a once-per-statement InitPlan rather than a
--        per-row re-evaluation of a STABLE function;
--      * the TWO-argument current_setting returns NULL when the GUC is unset, and
--        `tenant_id = NULL` matches nothing, so an unscoped session FAILS CLOSED.
--    The one-argument form ERRORS when unset, which is also closed but turns a
--    forgotten SET LOCAL into a 500 rather than an empty result.
--
--    The writer gets a policy that admits everything. That is deliberate: it is
--    what BYPASSRLS would have given it, minus COPY, which 10 shows we do not
--    need -- and it keeps the writer's semantics identical on a platform that will
--    not grant BYPASSRLS at all, which is every RDS and Aurora instance.
-- ======================================================================
\set ON_ERROR_STOP on

ALTER TABLE ledger_accounts         ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_events           ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_transactions     ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_entries          ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_account_balances ENABLE ROW LEVEL SECURITY;

CREATE POLICY rls_accounts__tenant ON ledger_accounts
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));
CREATE POLICY rls_events__tenant ON ledger_events
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));
CREATE POLICY rls_txn__tenant ON ledger_transactions
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));
CREATE POLICY rls_entries__tenant ON ledger_entries
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));
CREATE POLICY rls_balances__tenant ON ledger_account_balances
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));

CREATE POLICY rls_accounts__writer ON ledger_accounts
    FOR ALL TO openledger_app USING (true) WITH CHECK (true);
CREATE POLICY rls_events__writer ON ledger_events
    FOR ALL TO openledger_app USING (true) WITH CHECK (true);
CREATE POLICY rls_txn__writer ON ledger_transactions
    FOR ALL TO openledger_app USING (true) WITH CHECK (true);
CREATE POLICY rls_entries__writer ON ledger_entries
    FOR ALL TO openledger_app USING (true) WITH CHECK (true);
CREATE POLICY rls_balances__writer ON ledger_account_balances
    FOR ALL TO openledger_app USING (true) WITH CHECK (true);

-- A view runs with its OWNER's rights unless this is set, and the owner is the
-- migration role, which no policy applies to. Without it the five tenant policies
-- above are decoration on every read that goes through a report. See 2f.
ALTER VIEW trial_balance     SET (security_invoker = true);
ALTER VIEW balance_sheet     SET (security_invoker = true);
ALTER VIEW income_statement  SET (security_invoker = true);

\set ON_ERROR_STOP off

-- ======================================================================
-- 2. READS
-- ======================================================================
\echo ''
\echo '=== 2a. the reader, scoped to t1, sees t1 only'
SET ROLE openledger_read;
SET app.tenant_id = 't1';
SELECT tenant_id, count(*) AS accounts FROM ledger_accounts GROUP BY tenant_id ORDER BY 1;
SELECT tenant_id, count(*) AS entries  FROM ledger_entries  GROUP BY tenant_id ORDER BY 1;

\echo ''
\echo '=== 2b. ...and a cross-tenant read is not an error, it is empty. Refused by absence.'
SELECT count(*) AS t2_rows_visible_to_t1 FROM ledger_accounts WHERE tenant_id='t2';

\echo ''
\echo '=== 2c. with the GUC unset the reader sees NOTHING. Fails closed.'
RESET app.tenant_id;
SELECT count(*) AS rows_visible_with_no_tenant_set FROM ledger_accounts;

\echo ''
\echo '=== 2d. the GUC IS the scope, so the session that sets it is the trust'
\echo '===     boundary. That is a connection-management property, not a schema one.'
SET app.tenant_id = 't2';
SELECT tenant_id, count(*) FROM ledger_accounts GROUP BY tenant_id;
RESET ROLE;

\echo ''
\echo '=== 2e. the report views, through the reader, with security_invoker'
SET ROLE openledger_read;
SET app.tenant_id = 't1';
SELECT tenant_id, count(*) AS trial_balance_rows FROM trial_balance GROUP BY tenant_id;
RESET ROLE;

\echo ''
\echo '=== 2f. ...and WITHOUT it: every policy bypassed, every tenant leaked.'
ALTER VIEW trial_balance SET (security_invoker = false);
SET ROLE openledger_read;
SET app.tenant_id = 't1';
SELECT tenant_id, count(*) AS trial_balance_rows FROM trial_balance GROUP BY tenant_id ORDER BY 1;
RESET ROLE;
ALTER VIEW trial_balance SET (security_invoker = true);

\echo ''
\echo '=== 2g. the policy is an InitPlan, not a per-row call'
SET ROLE openledger_read;
SET app.tenant_id = 't1';
EXPLAIN (COSTS OFF) SELECT count(*) FROM ledger_entries WHERE account_id='11111111-0000-0000-0000-000000000003';
RESET ROLE;

-- ======================================================================
-- 3. WRITES
-- ======================================================================
\echo ''
\echo '=== 3a. the WHOLE write path as openledger_app, with RLS enabled and the'
\echo '===     writer policy applying to it. Event, transaction, balance upsert,'
\echo '===     entry -- one transaction, exactly as the writer will issue it.'
GRANT INSERT ON ledger_events TO openledger_app;
SET ROLE openledger_app;
BEGIN;
INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
VALUES ('t1','0f0f0f0f-0000-0000-0000-000000000001','probe','internal','rls-probe','\x00','{}','2026-08-20T00:00:00Z');
INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
VALUES ('t1','0f0f0f0f-0000-0000-0000-000000000002','0f0f0f0f-0000-0000-0000-000000000001','probe','posted','2026-08-20T00:00:00Z');
INSERT INTO ledger_account_balances AS b (tenant_id, account_id, currency, input, output, last_seq)
VALUES ('t1','11111111-0000-0000-0000-000000000001','USD',7,0,1)
ON CONFLICT (tenant_id, account_id, currency) DO UPDATE
   SET input = b.input + excluded.input, last_seq = b.last_seq + 1
RETURNING b.last_seq, b.input - b.output;
INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction, amount_minor, currency, account_seq, effective_at)
VALUES ('t1','0f0f0f0f-0000-0000-0000-000000000002','11111111-0000-0000-0000-000000000001','credit',7,'USD',2,'2026-08-20T00:00:00Z');
\echo '--- the upsert RETURNING above is the serialization point, under RLS, unchanged.'
ROLLBACK;
RESET ROLE;

\echo ''
\echo '=== 3b. ...and a batched entry insert, the shape that replaces COPY (see 10):'
SET ROLE openledger_app;
BEGIN;
INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
VALUES ('t1','0f0f0f0f-0000-0000-0000-000000000003','probe','internal','rls-probe-2','\x00','{}','2026-08-20T00:00:00Z');
INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
VALUES ('t1','0f0f0f0f-0000-0000-0000-000000000004','0f0f0f0f-0000-0000-0000-000000000003','probe','posted','2026-08-20T00:00:00Z');
INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction, amount_minor, currency, account_seq, effective_at)
SELECT 't1','0f0f0f0f-0000-0000-0000-000000000004','11111111-0000-0000-0000-000000000001','credit',1,'USD', s,'2026-08-20T00:00:00Z'
FROM unnest(ARRAY[100,101,102,103,104]::bigint[]) s;
SELECT count(*) AS batched_entries FROM ledger_entries WHERE account_seq >= 100;
ROLLBACK;
RESET ROLE;

\echo ''
\echo '=== 3c. COPY FROM as the writer, with a policy that admits EVERYTHING.'
\echo '===     Refused anyway: the restriction is about RLS being APPLIED to the'
\echo '===     role, not about what the policy would have allowed.'
SET ROLE openledger_app;
BEGIN;
\copy ledger_events (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at) FROM '06_copy_probe.csv' WITH (FORMAT csv)
ROLLBACK;
RESET ROLE;

\echo ''
\echo '=== 3d. and the role matters more than the table. check_enable_rls returns'
\echo '===     RLS_NONE for a superuser, for a BYPASSRLS role, and for the table'
\echo '===     OWNER unless FORCE is set -- and the COPY refusal is keyed on that.'
\echo '===     `openledger` in this repository IS a superuser, so probing as'
\echo '===     `openledger` would measure nothing. A NOSUPERUSER owner, then:'
DROP ROLE IF EXISTS wse_owner;
CREATE ROLE wse_owner NOLOGIN NOSUPERUSER;
GRANT wse_owner TO CURRENT_USER;
GRANT USAGE ON SCHEMA public TO wse_owner;
ALTER TABLE ledger_events OWNER TO wse_owner;
\echo '--- owner, RLS enabled, NOT forced:'
SET ROLE wse_owner;
BEGIN;
\copy ledger_events (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at) FROM '06_copy_probe.csv' WITH (FORMAT csv)
SELECT count(*) AS copied FROM ledger_events WHERE kind='copyprobe';
ROLLBACK;
RESET ROLE;
\echo '--- ...the same owner, with FORCE ROW LEVEL SECURITY:'
ALTER TABLE ledger_events FORCE ROW LEVEL SECURITY;
SET ROLE wse_owner;
BEGIN;
\copy ledger_events (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at) FROM '06_copy_probe.csv' WITH (FORMAT csv)
ROLLBACK;
RESET ROLE;
ALTER TABLE ledger_events NO FORCE ROW LEVEL SECURITY;

\echo ''
\echo '=== 3e. BYPASSRLS on the writer restores COPY -- and is unavailable on RDS and'
\echo '===     Aurora, whose master user is NOSUPERUSER without it, so it cannot be'
\echo '===     granted there at all. Recorded as the option, not as the answer.'
ALTER ROLE openledger_app BYPASSRLS;
SET ROLE openledger_app;
BEGIN;
\copy ledger_events (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at) FROM '06_copy_probe.csv' WITH (FORMAT csv)
SELECT count(*) AS copied FROM ledger_events WHERE kind='copyprobe';
ROLLBACK;
RESET ROLE;
ALTER ROLE openledger_app NOBYPASSRLS;

-- ======================================================================
-- 4. Does being subject to RLS -- or bypassing it -- touch append-only? No.
--    Policies, grants and triggers are three independent layers.
-- ======================================================================
\echo ''
\echo '=== 4a. the writer has no UPDATE or DELETE on the journal, policy or no policy'
SET ROLE openledger_app;
DELETE FROM ledger_entries;
UPDATE ledger_transactions SET kind = 'forged';
TRUNCATE ledger_events;
RESET ROLE;

\echo ''
\echo '=== 4b. ...and even WITH the grant, and with a policy that permits the row,'
\echo '===     the append-only trigger still refuses it.'
GRANT UPDATE, DELETE ON ledger_entries TO openledger_app;
SET ROLE openledger_app;
DELETE FROM ledger_entries;
RESET ROLE;
REVOKE UPDATE, DELETE ON ledger_entries FROM openledger_app;

\echo ''
\echo '=== 4c. what the writer policy DOES cost, stated plainly: the writer sees'
\echo '===     every tenant. RLS here is a read-path control. Tightening the writer'
\echo '===     to WITH CHECK (tenant_id = current_setting(...)) is available and'
\echo '===     would bind a transaction to one tenant -- which the treasury'
\echo '===     due-from/due-to pair (spike 004) would then have to honour.'
SET ROLE openledger_app;
SELECT count(DISTINCT tenant_id) AS tenants_visible_to_writer FROM ledger_accounts;
RESET ROLE;

-- ======================================================================
-- 5. teardown -- the baseline is not this file's to change.
-- ======================================================================
\echo ''
\echo '=== 5. teardown'
ALTER TABLE ledger_events OWNER TO CURRENT_USER;
DROP OWNED BY wse_owner;
DROP ROLE IF EXISTS wse_owner;
DROP POLICY rls_accounts__tenant ON ledger_accounts;
DROP POLICY rls_events__tenant   ON ledger_events;
DROP POLICY rls_txn__tenant      ON ledger_transactions;
DROP POLICY rls_entries__tenant  ON ledger_entries;
DROP POLICY rls_balances__tenant ON ledger_account_balances;
DROP POLICY rls_accounts__writer ON ledger_accounts;
DROP POLICY rls_events__writer   ON ledger_events;
DROP POLICY rls_txn__writer      ON ledger_transactions;
DROP POLICY rls_entries__writer  ON ledger_entries;
DROP POLICY rls_balances__writer ON ledger_account_balances;
ALTER TABLE ledger_accounts         DISABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_events           DISABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_transactions     DISABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_entries          DISABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_account_balances DISABLE ROW LEVEL SECURITY;
ALTER VIEW trial_balance    SET (security_invoker = false);
ALTER VIEW balance_sheet    SET (security_invoker = false);
ALTER VIEW income_statement SET (security_invoker = false);
REVOKE INSERT ON ledger_events FROM openledger_app;
