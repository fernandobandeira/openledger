\echo '=== A14 guard (the EXISTS that refuses an unpresented type) ==='
EXPLAIN (ANALYZE, TIMING OFF, BUFFERS, SUMMARY ON)
SELECT EXISTS (
    SELECT 1 FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id AND x.status='posted'
    JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id AND a.currency = e.currency
    WHERE e.tenant_id='big1m' AND e.effective_at < 'infinity' AND e.xact_id < report_cursor()
      AND NOT EXISTS (SELECT 1 FROM chart_presentation p WHERE p.chart_version=3 AND p.type_code=a.purpose));

\echo '=== pos (the per-account position) ==='
EXPLAIN (ANALYZE, TIMING OFF, BUFFERS, SUMMARY ON)
SELECT e.tenant_id, e.currency, e.account_id, p.category, p.fs_line,
       SUM(CASE WHEN e.direction='debit' THEN e.amount_minor::numeric ELSE -e.amount_minor::numeric END) AS v
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id AND x.status='posted'
JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id AND a.currency = e.currency
JOIN chart_presentation p ON p.chart_version=3 AND p.type_code=a.purpose
WHERE e.tenant_id='big1m' AND e.effective_at < 'infinity' AND e.xact_id < report_cursor()
GROUP BY e.tenant_id, e.currency, e.account_id, p.category, p.fs_line;

\echo '=== plug (the un-closed-earnings correlated subquery, per scope row) ==='
EXPLAIN (ANALYZE, TIMING OFF, BUFFERS, SUMMARY ON)
SELECT s.tenant_id, s.currency,
       (-COALESCE((
           SELECT SUM(CASE WHEN e.direction='debit' THEN e.amount_minor::numeric ELSE -e.amount_minor::numeric END)
           FROM ledger_entries e
           JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id AND x.status='posted'
           JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id AND a.currency = e.currency
           JOIN chart_presentation p ON p.chart_version=3 AND p.type_code=a.purpose
           WHERE e.tenant_id = s.tenant_id AND e.currency = s.currency
             AND e.effective_at < 'infinity' AND e.xact_id < report_cursor()
             AND p.category IN ('revenue','expense')
       ), 0))::bigint
FROM (SELECT DISTINCT l.tenant_id, l.currency FROM ledger_accounts l WHERE l.tenant_id='big1m') s;
