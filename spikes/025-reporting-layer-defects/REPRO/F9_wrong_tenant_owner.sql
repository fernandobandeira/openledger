-- F9, half one -- the same calls as the OWNER, to name the mechanism.
--
-- FORCE ROW LEVEL SECURITY is deliberately not set (baseline, RLS section), so
-- the owner is not bound by the tenant policies. The owner therefore separates
-- the two things a zero-row answer can mean:
--
--   * balance_sheet_at('t2', ...) as the OWNER returns t2's real face. The
--     function is WILLING; RLS is what silenced it for the reader. That is an
--     AUTHORISATION result: a reader asking for a tenant it may not read gets
--     the same answer as a reader asking for an empty one.
--   * balance_sheet_at('t_does_not_exist', ...) as the OWNER returns zero rows
--     too, with RLS out of the picture entirely. That is a DIAGNOSTICS result:
--     the WHERE l.tenant_id = p_tenant predicate in the scopes CTE simply finds
--     nothing, and nothing anywhere checks that it should have.
--
-- Run as the OWNER. It writes nothing.

\set ON_ERROR_STOP off
\pset null '(null)'

SELECT current_user AS connected_as,
       current_setting('app.tenant_id', true) AS app_tenant_id;

\echo
\echo '=== 1. t2 as the OWNER: the real face. The function was never unwilling.'
SELECT tenant_id, currency, fs_line, side, amount_minor
FROM balance_sheet_at('t2', 'infinity', report_cursor()) ORDER BY sort_order;

\echo
\echo '=== 2. t_does_not_exist as the OWNER: still zero rows, with no RLS in play.'
\echo '===    A typo is silence for the owner too -- this half is a usability'
\echo '===    defect that exists independently of any policy.'
SELECT * FROM balance_sheet_at('t_does_not_exist', 'infinity', report_cursor());

\echo
\echo '=== 3. the same pair through income_statement_for'
SELECT tenant_id, currency, fs_line, side, amount_minor
FROM income_statement_for('t2','2026-08-01Z','2026-09-01Z', report_cursor())
ORDER BY sort_order;
SELECT * FROM income_statement_for('t_does_not_exist','2026-08-01Z','2026-09-01Z', report_cursor());

\echo
\echo '=== 4. and the chart-version guard raises for the owner as it does for the'
\echo '===    reader, so the asymmetry is a property of the functions, not of RLS'
SELECT * FROM balance_sheet_at('t1', 'infinity', report_cursor(), 999);

\echo
\echo '=== 5. the sweep''s own check, run as the owner: BOTH tenants, both green.'
\echo '===    Compare with the reader''s one-tenant green in the reader script.'
SELECT tn.tenant_id, count(*) AS balance_sheet_rows
FROM (SELECT DISTINCT tenant_id FROM ledger_accounts) tn
CROSS JOIN LATERAL balance_sheet_at(tn.tenant_id, 'infinity', report_cursor()) b
GROUP BY 1 ORDER BY 1;
SELECT * FROM recon_equation_breaks(report_cursor(), 'infinity');
