-- The PRE-FIX (buggy) balance_sheet_at: max(ends_at) watermark plug, effective_at <= p_asof.
-- Installed into a golden clone to reproduce finding F-M/fresh-2 (A3), so recon_equation_breaks
-- (A6) can be shown firing on it. See 20-verify.sh.
CREATE OR REPLACE FUNCTION balance_sheet_at(p_tenant text, p_asof timestamptz, p_cursor xid8,
                                 p_chart_version int DEFAULT NULL)
RETURNS TABLE (tenant_id text, currency char(3), chart_version int, fs_line text,
               caption text, sort_order int, amount_minor bigint, side text)
LANGUAGE sql STABLE AS $$
WITH cv AS (
    SELECT COALESCE(p_chart_version, (SELECT c.chart_version FROM chart_version_current c)) AS chart_version
), scopes AS (
    SELECT DISTINCT l.tenant_id, l.currency FROM ledger_accounts l WHERE l.tenant_id = p_tenant
), pos AS (
    SELECT e.tenant_id, e.currency, e.account_id, p.category, p.counterparty_scope, p.fs_line, p.fs_line_contra,
           SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END) AS v
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
    JOIN ledger_accounts a ON a.tenant_id=e.tenant_id AND a.id=e.account_id AND a.currency=e.currency
    CROSS JOIN cv JOIN chart_presentation p ON p.chart_version=cv.chart_version AND p.type_code=a.purpose
    WHERE e.tenant_id=p_tenant AND e.effective_at <= p_asof AND e.xact_id < p_cursor
    GROUP BY e.tenant_id,e.currency,e.account_id,p.category,p.counterparty_scope,p.fs_line,p.fs_line_contra
), dp AS (
    SELECT tenant_id,currency,category,
           CASE WHEN counterparty_scope='per_shard' AND ((category='asset' AND v<0) OR (category='liability' AND v>0))
                THEN fs_line_contra ELSE fs_line END AS fs_line, v FROM pos
), lines AS (
    SELECT s.tenant_id,s.currency,cv.chart_version,f.code AS fs_line,f.caption,f.sort_order,f.side,
           COALESCE(SUM(CASE WHEN f.side='asset' THEN d.v ELSE -d.v END),0)::bigint AS amount_minor
    FROM scopes s CROSS JOIN cv JOIN fs_lines f ON f.chart_version=cv.chart_version
    LEFT JOIN dp d ON d.tenant_id=s.tenant_id AND d.currency=s.currency AND d.fs_line=f.code
    WHERE f.statement='balance_sheet'
    GROUP BY s.tenant_id,s.currency,cv.chart_version,f.code,f.caption,f.sort_order,f.side
), open_from AS (
    SELECT s.tenant_id,s.currency,
           (SELECT max(c.ends_at) FROM ledger_period_closes c WHERE c.tenant_id=s.tenant_id AND c.currency=s.currency AND c.ends_at<=p_asof) AS since
    FROM scopes s
)
SELECT l.tenant_id,l.currency,l.chart_version,l.fs_line,l.caption,l.sort_order,l.amount_minor,l.side FROM lines l
UNION ALL
SELECT o.tenant_id,o.currency,cv.chart_version,'current_year_earnings',
       CASE WHEN o.since IS NULL THEN 'Undistributed earnings (since inception)' ELSE 'Earnings since last close' END,
       9000,(-COALESCE(SUM(d.v),0))::bigint,'equity'
FROM open_from o CROSS JOIN cv
LEFT JOIN (
    SELECT e.tenant_id,e.currency,p.category,e.effective_at,
           SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END) AS v
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
    JOIN ledger_accounts a ON a.tenant_id=e.tenant_id AND a.id=e.account_id AND a.currency=e.currency
    CROSS JOIN cv JOIN chart_presentation p ON p.chart_version=cv.chart_version AND p.type_code=a.purpose
    WHERE e.tenant_id=p_tenant AND e.effective_at<=p_asof AND e.xact_id<p_cursor AND p.category IN ('revenue','expense')
      AND NOT EXISTS (SELECT 1 FROM ledger_period_closes c WHERE c.tenant_id=x.tenant_id AND c.transaction_id=x.id)
    GROUP BY e.tenant_id,e.currency,p.category,e.effective_at
) d ON d.tenant_id=o.tenant_id AND d.currency=o.currency AND (o.since IS NULL OR d.effective_at>=o.since)
GROUP BY o.tenant_id,o.currency,cv.chart_version,o.since
ORDER BY 1,2,6;
$$;
