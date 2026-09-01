-- THE NEGATIVE CONTROL. Ten rows, zero breaks. Every reproduction below runs
-- this first (or cites the run above it), because a red that was already red
-- proves nothing -- spike 011's own rule.
\set ON_ERROR_STOP on
\echo '--- reconciliation: every check, clean book'
SELECT * FROM reconciliation;
\echo '--- the balance sheet as at infinity, current chart version'
SELECT currency, chart_version, fs_line, side, amount_minor
FROM balance_sheet_at('t1','infinity', report_cursor()) ORDER BY sort_order;
\echo '--- the income statement, August 2026'
SELECT currency, chart_version, fs_line, side, amount_minor
FROM income_statement_for('t1','2026-08-01T00:00:00Z','2026-09-01T00:00:00Z', report_cursor())
ORDER BY sort_order;
\echo '--- the accounting-equation check at the current cursor (must be EMPTY)'
SELECT * FROM recon_equation_breaks(report_cursor(),'infinity');
\echo '--- the journal-to-reports statement (unexplained must be 0)'
SELECT tenant_id, currency, journal_debits, pending_debits, superseded_debits,
       out_of_window_debits, orphan_debits, reported_debits, tb_debits,
       unexplained_debits
FROM recon_journal_to_reports ORDER BY tenant_id, currency;
