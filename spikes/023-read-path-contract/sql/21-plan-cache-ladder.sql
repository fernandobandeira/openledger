\echo '=== balance_sheet_at on big1m, seven consecutive calls on ONE connection ==='
\echo '(plpgsql builds a custom plan for the first five, then considers a GENERIC one)'
\echo '--- call 1'
EXPLAIN (ANALYZE, TIMING OFF, BUFFERS) SELECT count(*) FROM balance_sheet_at('big1m','infinity', report_cursor(), 3);
\echo '--- call 2'
EXPLAIN (ANALYZE, TIMING OFF, BUFFERS) SELECT count(*) FROM balance_sheet_at('big1m','infinity', report_cursor(), 3);
\echo '--- call 3'
EXPLAIN (ANALYZE, TIMING OFF, BUFFERS) SELECT count(*) FROM balance_sheet_at('big1m','infinity', report_cursor(), 3);
\echo '--- call 4'
EXPLAIN (ANALYZE, TIMING OFF, BUFFERS) SELECT count(*) FROM balance_sheet_at('big1m','infinity', report_cursor(), 3);
\echo '--- call 5'
EXPLAIN (ANALYZE, TIMING OFF, BUFFERS) SELECT count(*) FROM balance_sheet_at('big1m','infinity', report_cursor(), 3);
\echo '--- call 6'
EXPLAIN (ANALYZE, TIMING OFF, BUFFERS) SELECT count(*) FROM balance_sheet_at('big1m','infinity', report_cursor(), 3);
\echo '--- call 7'
EXPLAIN (ANALYZE, TIMING OFF, BUFFERS) SELECT count(*) FROM balance_sheet_at('big1m','infinity', report_cursor(), 3);
\echo '=== and with plan_cache_mode = force_custom_plan ==='
SET plan_cache_mode = force_custom_plan;
\echo '--- forced-custom call 1'
EXPLAIN (ANALYZE, TIMING OFF, BUFFERS) SELECT count(*) FROM balance_sheet_at('big1m','infinity', report_cursor(), 3);
\echo '--- forced-custom call 2'
EXPLAIN (ANALYZE, TIMING OFF, BUFFERS) SELECT count(*) FROM balance_sheet_at('big1m','infinity', report_cursor(), 3);
\echo '--- forced-custom call 3'
EXPLAIN (ANALYZE, TIMING OFF, BUFFERS) SELECT count(*) FROM balance_sheet_at('big1m','infinity', report_cursor(), 3);
