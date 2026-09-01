\echo '=== plug with the cursor as a LITERAL (what my decomposition ran) ==='
EXPLAIN (ANALYZE, TIMING OFF, BUFFERS)
SELECT s.tenant_id, s.currency,
       (-COALESCE((SELECT SUM(CASE WHEN e.direction='debit' THEN e.amount_minor::numeric ELSE -e.amount_minor::numeric END)
           FROM ledger_entries e
           JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
           JOIN ledger_accounts a ON a.tenant_id=e.tenant_id AND a.id=e.account_id AND a.currency=e.currency
           JOIN chart_presentation p ON p.chart_version=3 AND p.type_code=a.purpose
           WHERE e.tenant_id=s.tenant_id AND e.currency=s.currency
             AND e.effective_at < 'infinity' AND e.xact_id < '16360'::xid8
             AND p.category IN ('revenue','expense')), 0))::bigint
FROM (SELECT DISTINCT l.tenant_id, l.currency FROM ledger_accounts l WHERE l.tenant_id='big1m') s;

\echo '=== the same, as a PREPARED statement with the cursor BOUND (what plpgsql does) ==='
PREPARE plug(text, timestamptz, xid8, int) AS
SELECT s.tenant_id, s.currency,
       (-COALESCE((SELECT SUM(CASE WHEN e.direction='debit' THEN e.amount_minor::numeric ELSE -e.amount_minor::numeric END)
           FROM ledger_entries e
           JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
           JOIN ledger_accounts a ON a.tenant_id=e.tenant_id AND a.id=e.account_id AND a.currency=e.currency
           JOIN chart_presentation p ON p.chart_version=$4 AND p.type_code=a.purpose
           WHERE e.tenant_id=s.tenant_id AND e.currency=s.currency
             AND e.effective_at < $2 AND e.xact_id < $3
             AND p.category IN ('revenue','expense')), 0))::bigint
FROM (SELECT DISTINCT l.tenant_id, l.currency FROM ledger_accounts l WHERE l.tenant_id=$1) s;
EXPLAIN (ANALYZE, TIMING OFF, BUFFERS) EXECUTE plug('big1m','infinity','16360'::xid8,3);
