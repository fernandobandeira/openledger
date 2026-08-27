-- 50 -- a reclassification done the legitimate way, and IAS 1.41 satisfied.
--
-- IAS 1 paragraph 41, quoted from the EU's endorsement of IFRS -- Commission
-- Regulation (EC) No 1126/2008, consolidated text 02008R1126-20230101, the only
-- freely readable authoritative English text of the standard:
--
--   "If an entity changes the presentation or classification of items in its
--    financial statements, it shall reclassify comparative amounts unless
--    reclassification is impracticable. When an entity reclassifies comparative
--    amounts, it shall disclose (including as at the beginning of the preceding
--    period): (a) the nature of the reclassification; (b) the amount of each item
--    or class of items that is reclassified; and (c) the reason for the
--    reclassification."
--
-- Two obligations, and the shipped schema could meet neither. "Reclassify
-- comparative amounts" means the SAME PRIOR PERIOD, presented under the NEW
-- mapping, ALONGSIDE the old presentation -- so the mapping cannot be a function
-- of the entry's date, which is why effective-dating account_types is the wrong
-- shape. And (b) requires the amount of each item reclassified, which is exactly
-- the difference between the two presentations of one period.
--
-- THE RECLASSIFICATION ITSELF is the `ach_pull_returnable` correction: customer
-- cash inside an ACH return window presented as a trade payable. Same class as
-- the outbound_transfer_in_transit line the chart already fixed, and fixed the
-- same way -- the money is the customer's until the return window closes, so
-- presenting it under operator trade payables understates "Customer funds
-- payable" and overstates what the operator owes its own suppliers.

BEGIN;

INSERT INTO chart_versions (version, note) VALUES
  (2, 'Reclassify ach_pull_returnable from `payables` to `customer_funds`. '
      'ACH-collected customer cash inside the R01 return window is customer '
      'money, not a trade payable; presenting it under "Accounts payable and '
      'accrued" understates customer funds payable and overstates what the '
      'operator owes its suppliers. Mirror of the outbound_transfer_in_transit '
      'correction already in the chart.');

-- A VERSION IS A COMPLETE CHART, not a diff -- otherwise "which line was this
-- presented under" means walking a chain of overrides, and no foreign key can
-- express that. The copy is mechanical, so the cost of completeness is one
-- INSERT ... SELECT per table and the file only spells out what CHANGED.
INSERT INTO fs_lines (chart_version, code, caption, statement, side, sort_order)
SELECT 2, code, caption, statement, side, sort_order FROM fs_lines WHERE chart_version = 1;

INSERT INTO chart_presentation (chart_version, type_code, category, counterparty_scope, fs_line, fs_line_contra)
SELECT 2, type_code, category, counterparty_scope,
       CASE WHEN type_code = 'ach_pull_returnable' THEN 'customer_funds' ELSE fs_line END,
       fs_line_contra
FROM chart_presentation WHERE chart_version = 1;

COMMIT;

-- ---------------------------------------------------------------------------
-- THE PINNED REPORT. This is balance_sheet's body with exactly one substitution:
-- the `cv` relation is the parameter instead of chart_version_current. Nothing
-- else in it changes, which is the whole claim about the interface.
--
-- It lives in this spike and is NOT proposed for the baseline. The report
-- parameters -- which chart version, and which commit-ordered cursor -- belong
-- together in one signature, and the cursor is ADR-0006's and is not designed
-- here. What is settled here is that a chart version is expressible as a
-- parameter, and that the view body has exactly one place to put it.
CREATE FUNCTION balance_sheet_at(p_chart_version int)
RETURNS TABLE (tenant_id text, currency char(3), chart_version int, fs_line text,
               caption text, sort_order int, amount_minor bigint, side text)
LANGUAGE sql STABLE AS $$
WITH cv AS (SELECT p_chart_version AS chart_version),
pos AS (
    SELECT e.tenant_id, e.currency, e.account_id,
           p.category, p.counterparty_scope, p.fs_line, p.fs_line_contra,
           SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END) AS v
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                              AND x.status = 'posted'
    JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                          AND a.currency  = e.currency
    CROSS JOIN cv
    JOIN chart_presentation p ON p.chart_version = cv.chart_version AND p.type_code = a.purpose
    GROUP BY e.tenant_id, e.currency, e.account_id,
             p.category, p.counterparty_scope, p.fs_line, p.fs_line_contra
), dp AS (
    SELECT tenant_id, currency, category,
           CASE WHEN counterparty_scope = 'per_shard'
                     AND ((category = 'asset'     AND v < 0)
                       OR (category = 'liability' AND v > 0))
                THEN fs_line_contra ELSE fs_line END AS fs_line,
           v
    FROM pos
), scopes AS (SELECT DISTINCT ledger_accounts.tenant_id, ledger_accounts.currency FROM ledger_accounts),
lines AS (
    SELECT s.tenant_id, s.currency, cv.chart_version,
           f.code AS fs_line, f.caption, f.sort_order, f.side,
           COALESCE(SUM(CASE WHEN f.side = 'asset' THEN d.v ELSE -d.v END), 0)::bigint AS amount_minor
    FROM scopes s CROSS JOIN cv
    JOIN fs_lines f ON f.chart_version = cv.chart_version
    LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency AND d.fs_line = f.code
    WHERE f.statement = 'balance_sheet'
    GROUP BY s.tenant_id, s.currency, cv.chart_version, f.code, f.caption, f.sort_order, f.side
)
SELECT lines.tenant_id, lines.currency, lines.chart_version, lines.fs_line,
       lines.caption, lines.sort_order, lines.amount_minor, lines.side FROM lines
UNION ALL
SELECT s.tenant_id, s.currency, cv.chart_version, 'current_year_earnings',
       'Undistributed earnings (since inception)', 9000,
       (-COALESCE(SUM(d.v), 0))::bigint, 'equity'
FROM scopes s CROSS JOIN cv
LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency
              AND d.category IN ('revenue','expense')
GROUP BY s.tenant_id, s.currency, cv.chart_version
ORDER BY 1, 2, 6;
$$;

\echo ''
\echo '### the SAME posted period, presented under both charts. Not a re-run after'
\echo '### an edit -- both are available at once, forever, which is what IAS 1.41'
\echo '### asks for and what an in-place UPDATE destroys.'
SELECT v1.fs_line, v1.caption AS caption_v1,
       v1.amount_minor/100 AS under_v1, v2.amount_minor/100 AS under_v2,
       (v2.amount_minor - v1.amount_minor)/100 AS reclassified
  FROM balance_sheet_at(1) v1
  JOIN balance_sheet_at(2) v2 USING (tenant_id, currency, fs_line)
 WHERE v1.tenant_id='op' AND v1.amount_minor IS DISTINCT FROM v2.amount_minor
 ORDER BY v1.sort_order;

\echo ''
\echo '### IAS 1.41(a) nature, (b) amount, (c) reason -- (b) is the query above,'
\echo '### (a) and (c) are the version note, which is NOT NULL:'
SELECT version, created_at::date, note FROM chart_versions ORDER BY version;

\echo ''
\echo '### and the live statement follows max(version) with no view redefined:'
SELECT chart_version, fs_line, caption, amount_minor/100 AS usd FROM balance_sheet
 WHERE tenant_id='op' AND fs_line IN ('payables','customer_funds') ORDER BY sort_order;
