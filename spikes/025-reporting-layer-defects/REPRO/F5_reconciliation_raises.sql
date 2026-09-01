-- F5 -- one unpresented account type turns the whole `reconciliation` view into
-- an error, so the operator cannot read the nine other checks.
--
-- reconciliation counts recon_equation_breaks(report_cursor(),'infinity'), which
-- CROSS JOIN LATERALs balance_sheet_at per tenant, which RAISEs on A14. A RAISE
-- inside one branch of a UNION ALL aborts the whole statement: the nine other
-- rows are never produced -- including the chart_lint row, which names the same
-- problem, as a count, without dying.
--
-- The state: an in-scope account type with posted entries that the CURRENT chart
-- version does not present. Reached by appending chart version 4 -- a complete
-- chart minus one presentation row. refuse_stale_chart_version refuses inserts
-- BELOW the maximum only, so building a new highest version is allowed; and the
-- statements COALESCE their version to max(version), so version 4 becomes what
-- every default-version report is presented through the moment it commits.
\set ON_ERROR_STOP off

\echo '=== 0. the negative control: ten rows, zero breaks'
SELECT * FROM reconciliation;

\echo
\echo '=== 1. chart version 4: complete, except that customer_wallet is not presented'
BEGIN;
INSERT INTO chart_versions (version, note) VALUES
  (4,'A chart version that omits customer_wallet''s presentation row.');
INSERT INTO fs_lines (chart_version, code, caption, statement, side, sort_order)
SELECT 4, code, caption, statement, side, sort_order FROM fs_lines WHERE chart_version = 3;
INSERT INTO chart_presentation (chart_version, type_code, category, counterparty_scope,
                                fs_line, fs_line_contra)
SELECT 4, type_code, category, counterparty_scope, fs_line, fs_line_contra
FROM chart_presentation WHERE chart_version = 3 AND type_code <> 'customer_wallet';
COMMIT;

\echo '--- customer_wallet has 500,000.00 of posted entries and no line to print on'
SELECT purpose, currency, debits, credits, balance_debit_positive
FROM trial_balance WHERE tenant_id='t1' AND purpose='customer_wallet';

\echo
\echo '=== 2. THE OPERATOR INTERFACE. `SELECT * FROM reconciliation` -- the whole thing'
SELECT * FROM reconciliation;

\echo
\echo '=== 3. ...and what it would have said. Each surviving check, read individually.'
SELECT 'balance_cache' AS check_name, COUNT(*) AS breaks FROM recon_balance_breaks
UNION ALL SELECT 'orphan_entries',          COUNT(*) FROM recon_entry_breaks
UNION ALL SELECT 'unbalanced_transactions', COUNT(*) FROM recon_transaction_breaks
UNION ALL SELECT 'cross_scope_mirror',      COUNT(*) FROM recon_scope_breaks
UNION ALL SELECT 'journal_to_reports',      COUNT(*) FROM recon_journal_to_reports
          WHERE unexplained_debits <> 0 OR unexplained_credits <> 0
UNION ALL SELECT 'checkpoint_drift',        COUNT(*) FROM recon_checkpoint_breaks
UNION ALL SELECT 'close_typing',            COUNT(*) FROM recon_close_breaks
UNION ALL SELECT 'cursor_forgery',          COUNT(*) FROM recon_cursor_breaks
UNION ALL SELECT 'chart_lint',              COUNT(*) FROM chart_lint WHERE severity='error';

\echo '--- the chart_lint rows that name the same problem, and do not die'
SELECT rule, severity, subject, detail FROM chart_lint WHERE severity='error' ORDER BY subject;

\echo
\echo '=== 4. the RAISE itself, from the function the summary calls'
SELECT * FROM recon_equation_breaks(report_cursor(),'infinity');
SELECT count(*) FROM balance_sheet_at('t1','infinity', report_cursor());
\echo '--- ...and it is version-scoped: at version 3, which presents everything, both work'
SELECT count(*) FROM balance_sheet_at('t1','infinity', report_cursor(), 3);
