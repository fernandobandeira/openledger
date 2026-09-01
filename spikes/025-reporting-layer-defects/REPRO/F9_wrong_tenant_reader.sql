-- F9, half one -- a wrong or unauthorised p_tenant is answered with silence.
--
-- All five reporting functions are SECURITY INVOKER and none of them checks that
-- p_tenant names anything. A chart version that does not exist RAISES; a tenant
-- that does not exist, or that this session may not read, returns ZERO ROWS. The
-- two error classes are handled oppositely, and zero rows is also the honest
-- answer for a real tenant that has opened no accounts -- so the caller cannot
-- tell "no such tenant", "not your tenant" and "empty tenant" apart.
--
-- Run as spike025_read_login (see F9_read_login_role.sql), scoped to t1. It
-- writes nothing. F9_wrong_tenant_owner.sql runs the same calls as the OWNER,
-- whom RLS does not bind, to separate the two mechanisms.

\set ON_ERROR_STOP off
\pset null '(null)'

SELECT current_user AS connected_as;
SET app.tenant_id = 't1';

\echo
\echo '=== 1. the reader is authorised for t1, and t1 answers -- the real face'
SELECT tenant_id, currency, fs_line, side, amount_minor
FROM balance_sheet_at('t1', 'infinity', report_cursor()) ORDER BY sort_order;

\echo
\echo '=== 2. t2 EXISTS and carries a posted 100,000 charge. The reader is not'
\echo '===    scoped to it, and gets zero rows -- no error, no warning, no NULL'
SELECT * FROM balance_sheet_at('t2', 'infinity', report_cursor());

\echo
\echo '=== 3. t_does_not_exist has never existed. IDENTICAL answer to 2'
SELECT * FROM balance_sheet_at('t_does_not_exist', 'infinity', report_cursor());

\echo
\echo '=== 4. ...and the two are the same result set, proven rather than eyeballed'
SELECT (SELECT count(*) FROM balance_sheet_at('t2','infinity',report_cursor()))
         AS unauthorised_rows,
       (SELECT count(*) FROM balance_sheet_at('t_does_not_exist','infinity',report_cursor()))
         AS nonexistent_rows,
       NOT EXISTS (
           SELECT * FROM balance_sheet_at('t2','infinity',report_cursor())
           EXCEPT ALL
           SELECT * FROM balance_sheet_at('t_does_not_exist','infinity',report_cursor())
       ) AND NOT EXISTS (
           SELECT * FROM balance_sheet_at('t_does_not_exist','infinity',report_cursor())
           EXCEPT ALL
           SELECT * FROM balance_sheet_at('t2','infinity',report_cursor())
       ) AS identical;

\echo
\echo '=== 5. THE ASYMMETRY: a chart version that does not exist RAISES (A13)'
SELECT * FROM balance_sheet_at('t1', 'infinity', report_cursor(), 999);

\echo
\echo '=== 6. income_statement_for, the same four cases, the same asymmetry'
\echo '--- 6a. t1: the real statement'
SELECT tenant_id, currency, fs_line, side, amount_minor
FROM income_statement_for('t1','2026-08-01Z','2026-09-01Z', report_cursor())
ORDER BY sort_order;
\echo '--- 6b. t2: unauthorised, zero rows'
SELECT * FROM income_statement_for('t2','2026-08-01Z','2026-09-01Z', report_cursor());
\echo '--- 6c. t_does_not_exist: nonexistent, zero rows'
SELECT * FROM income_statement_for('t_does_not_exist','2026-08-01Z','2026-09-01Z', report_cursor());
\echo '--- 6d. chart version 999: RAISES'
SELECT * FROM income_statement_for('t1','2026-08-01Z','2026-09-01Z', report_cursor(), 999);

\echo
\echo '=== 7. trial_balance_at carries no guards at all, so all three tenants'
\echo '===    -- mine, not mine, and imaginary -- differ only in row count'
SELECT 't1'               AS asked, count(*) FROM trial_balance_at('t1','-infinity','infinity',report_cursor())
UNION ALL
SELECT 't2',                          count(*) FROM trial_balance_at('t2','-infinity','infinity',report_cursor())
UNION ALL
SELECT 't_does_not_exist',            count(*) FROM trial_balance_at('t_does_not_exist','-infinity','infinity',report_cursor());

\echo
\echo '=== 8. THE MECHANISM, from the reader side: RLS has already removed t2'
\echo '===    from every table the function reads, so the function is not being'
\echo '===    told "no" -- it is being handed an empty book'
SELECT DISTINCT tenant_id FROM trial_balance;
SELECT count(*) AS accounts_visible FROM ledger_accounts;
SELECT count(*) AS t2_accounts_visible FROM ledger_accounts WHERE tenant_id = 't2';
SELECT count(*) AS entries_visible FROM ledger_entries;

\echo
\echo '=== 9. EXECUTE is PUBLIC on all five (proacl NULL = default privileges ='
\echo '===    EXECUTE TO PUBLIC for a function), and prosecdef f = SECURITY INVOKER'
SELECT p.proname, p.prosecdef, p.proacl,
       p.proacl IS NULL AS default_privileges_so_execute_is_public
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('trial_balance_at','income_statement_for','balance_sheet_at',
                    'report_cursor','recon_equation_breaks')
ORDER BY 1;

\echo
\echo '=== 10. ...so what does PUBLIC EXECUTE actually buy? The reader is NOT'
\echo '===     granted the reconciliation view, but recon_equation_breaks is a'
\echo '===     SECURITY INVOKER function, so it runs -- under the reader''s own'
\echo '===     RLS scope. It answers GREEN over one tenant out of two.'
SELECT * FROM reconciliation;                       -- permission denied for view
SELECT * FROM recon_equation_breaks(report_cursor(), 'infinity');
SELECT count(*) AS breaks_seen_by_a_t1_scoped_reader
FROM recon_equation_breaks(report_cursor(), 'infinity');

\echo
\echo '=== 11. and with the GUC unset the same call is still GREEN, over NO'
\echo '===     tenants at all -- the "green check that did not execute" shape.'
\echo '===     RLS fails closed for rows; the function has no way to say so.'
RESET app.tenant_id;
SELECT count(*) AS accounts_visible FROM ledger_accounts;
SELECT count(*) AS breaks_seen_by_an_unscoped_reader
FROM recon_equation_breaks(report_cursor(), 'infinity');
SELECT count(*) AS t1_balance_sheet_rows
FROM balance_sheet_at('t1', 'infinity', report_cursor());
