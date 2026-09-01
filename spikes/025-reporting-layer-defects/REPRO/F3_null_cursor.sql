-- F3 -- a NULL cursor yields a complete, all-zero, perfectly balanced statement.
--
-- No reporting function is STRICT and none guards its cursor, so `xact_id <
-- NULL` is NULL for every entry, the entry population is empty, and every
-- LEFT JOIN in the statement still produces the whole face. The A14 guard
-- carries the same predicate, so the guard is vacuous for exactly the input
-- that needs it most. Runs against the clean book; it writes nothing.
\set ON_ERROR_STOP off
\pset null '(null)'

\echo '=== 0. the control: the same statement at an honest cursor'
SELECT fs_line, side, amount_minor FROM balance_sheet_at('t1','infinity', report_cursor())
ORDER BY sort_order;

\echo '=== 1. balance_sheet_at with a NULL cursor -- the full face, at 0.00, and it BALANCES'
SELECT fs_line, side, amount_minor, pinned_cursor
FROM balance_sheet_at('t1','infinity', NULL) ORDER BY sort_order;
SELECT sum(amount_minor) FILTER (WHERE side='asset')                        AS assets,
       sum(amount_minor) FILTER (WHERE side IN ('liability','equity'))      AS liab_equity,
       sum(amount_minor) FILTER (WHERE side='asset')
         - sum(amount_minor) FILTER (WHERE side IN ('liability','equity'))  AS gap
FROM balance_sheet_at('t1','infinity', NULL);

\echo '=== 2. income_statement_for with a NULL cursor -- the same shape'
SELECT fs_line, side, amount_minor, pinned_cursor
FROM income_statement_for('t1','2026-08-01T00:00:00Z','2026-09-01T00:00:00Z', NULL)
ORDER BY sort_order;

\echo '=== 3. recon_equation_breaks(NULL, ...) -- zero rows, which is how the summary reads GREEN'
SELECT * FROM recon_equation_breaks(NULL, 'infinity');
SELECT count(*) AS breaks_reported FROM recon_equation_breaks(NULL, 'infinity');

\echo '=== 4. and the A14 guard is vacuous under a NULL cursor, where at an honest cursor it RAISEs'
\echo '--- (A14 needs an unpresented type to fire; F5 builds that state. Here: the guard predicate itself.)'
SELECT count(*) AS entries_a14_can_see_at_an_honest_cursor
FROM ledger_entries e WHERE e.tenant_id='t1' AND e.xact_id < report_cursor();
SELECT count(*) AS entries_a14_can_see_at_a_null_cursor
FROM ledger_entries e WHERE e.tenant_id='t1' AND e.xact_id < NULL;

\echo '=== 5. NULL p_asof / p_from / p_to -- the other three parameters'
SELECT fs_line, amount_minor FROM balance_sheet_at('t1', NULL, report_cursor()) ORDER BY sort_order;
SELECT fs_line, amount_minor
FROM income_statement_for('t1', NULL, NULL, report_cursor()) ORDER BY sort_order;
SELECT * FROM trial_balance_at('t1', NULL, NULL, report_cursor());
SELECT * FROM trial_balance_at('t1','2026-08-01T00:00:00Z','2026-09-01T00:00:00Z', NULL);

\echo '=== 6. NULL p_tenant'
SELECT count(*) AS rows_for_a_null_tenant FROM balance_sheet_at(NULL,'infinity', report_cursor());

\echo '=== 7. is EXECUTE really PUBLIC, and is anything STRICT?'
SELECT p.proname, p.prosecdef AS security_definer, p.proisstrict AS is_strict,
       p.proacl::text AS acl
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname='public'
  AND p.proname IN ('trial_balance_at','income_statement_for','balance_sheet_at',
                    'report_cursor','recon_equation_breaks')
ORDER BY p.proname;
