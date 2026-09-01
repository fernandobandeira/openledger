-- Q2 · the hazard a shared pool actually carries: RLS policies are PERMISSIVE
-- and therefore OR'd, and `pg_has_role` — not equality — is what decides which
-- of them apply.
--
-- The three policies per tenant-keyed table (migrations/00001_baseline.sql:2601+)
-- are one per role: `TO openledger_read` scoped by app.tenant_id, `TO
-- openledger_app` with USING (true), `TO openledger_recon` with USING (true).
-- A policy applies to a role the current_user is a MEMBER of, not only to the
-- role it names. So a single login that is a member of both openledger_app and
-- openledger_read gets `tenant_id = current_setting(...)` OR `true`.
--
-- Run this as each login in turn (psql -U); the driver script is
-- RUN.sh, and the captured output is out/02-policy-union.txt.

\pset format aligned
\echo '=== who am I, and which policies apply to me ==='
SELECT current_user,
       pg_has_role(current_user, 'openledger_read', 'USAGE')  AS is_read,
       pg_has_role(current_user, 'openledger_app',  'USAGE')  AS is_app,
       pg_has_role(current_user, 'openledger_recon','USAGE')  AS is_recon;

\echo '=== A · no GUC at all: does the fence hold? ==='
SELECT count(*) AS entries,
       coalesce(string_agg(DISTINCT tenant_id, ','), '<none>') AS tenants
FROM ledger_entries;

\echo '=== B · scoped to t1 through an inherited membership (no SET ROLE) ==='
BEGIN READ ONLY;
SELECT set_config('app.tenant_id', 't1', true) AS applied;
SELECT count(*) AS entries,
       coalesce(string_agg(DISTINCT tenant_id, ','), '<none>') AS tenants
FROM ledger_entries;
COMMIT;

\echo '=== C · the same read behind SET LOCAL ROLE openledger_read ==='
BEGIN READ ONLY;
SET LOCAL ROLE openledger_read;
SELECT set_config('app.tenant_id', 't1', true) AS applied;
SELECT current_user AS current_user_inside,
       count(*) AS entries,
       coalesce(string_agg(DISTINCT tenant_id, ','), '<none>') AS tenants
FROM ledger_entries;
COMMIT;

\echo '=== D · and through the report surfaces, which is what a caller reaches ==='
BEGIN READ ONLY;
SET LOCAL ROLE openledger_read;
SELECT set_config('app.tenant_id', 't1', true) AS applied;
SELECT 'trial_balance' AS surface, count(*) AS rows,
       coalesce(string_agg(DISTINCT tenant_id, ','), '<none>') AS tenants
FROM trial_balance
UNION ALL
SELECT 'trial_balance_at(t2)', count(*),
       coalesce(string_agg(DISTINCT tenant_id, ','), '<none>')
FROM trial_balance_at('t2', '-infinity', 'infinity', report_cursor());
COMMIT;
