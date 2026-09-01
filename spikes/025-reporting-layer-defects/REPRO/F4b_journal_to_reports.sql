-- F4b -- THE COMPENSATING ERROR: two wrongs, and the detector reads zero.
--
-- This check exists to be the dropped-balanced-sub-book detector. Its header
-- says so: `reported_*` is what the journal thinks reportable and `tb_*` is the
-- population the statement functions actually enumerate, so "if the two ever
-- disagree the report has grown a filter this classification does not know
-- about, which is precisely the dropped balanced sub-book ADR-0007 is about".
--
-- Exactly two things can make the two sides disagree, and they pull in OPPOSITE
-- directions:
--
--   * an out-of-window entry is removed from `reported` and left in `tb`,
--     so it drives `unexplained` DOWN (F4a);
--   * an entry on an account type with no chart_presentation row at the current
--     version stays in `reported` and is dropped from `tb` by the presentation
--     join, so it drives `unexplained` UP -- this is the real defect the number
--     is there to name.
--
-- A single number carrying two signed error classes can be zero while both are
-- present. Below, a fat-fingered 300.00 and a reclassification that forgot the
-- rev-share pair are made equal and opposite: `unexplained_debits` and
-- `unexplained_credits` both read 0, `journal_to_reports` reads 0 breaks, and
-- `tb_debits` comes out byte-identical to the negative control's -- while a
-- whole balanced sub-book (DR platform_rev_share_expense 300.00 / CR
-- platform_rev_share_payable 300.00) is missing from the presented population.
--
-- WHAT THIS STATE DOES *NOT* DO is stay quiet everywhere, and the spike should
-- say so: chart_lint's `type_unpresented` is an error rule over every
-- account_type x chart_version pair, so it fires twice, and balance_sheet_at's
-- A14 guard RAISES -- which takes `SELECT * FROM reconciliation` with it,
-- because `accounting_equation` calls recon_equation_breaks, which calls
-- balance_sheet_at. The operator therefore sees a failed sweep naming the
-- CHART, never the missing money, and the check whose job the missing money is
-- reads zero. Section 6 shows exactly that. (The A14 raise is F5's subject; it
-- is only recorded here.)
--
-- Assumes a freshly restored spike025_f4.
-- The compiled sweep is run from a shell after this file:
--   DATABASE_URL="postgres://openledger:openledger@localhost:5455/spike025_f4?sslmode=disable" \
--     ./target/debug/openledger reconcile; echo "exit=$?"

\set ON_ERROR_STOP on

\echo
\echo '=== 1. the negative control: ten checks, zero breaks'
SELECT * FROM reconciliation;

\echo
\echo '=== 2. chart version 4, which forgets the rev-share pair'
-- A reclassification is a new version carrying a complete chart (ADR-0012), and
-- refuse_stale_chart_version only refuses a chart_version BELOW the maximum, so
-- appending a new highest version is the supported move. Version 4 is version 3
-- copied mechanically, minus two presentation rows -- the shape of a real
-- omission, since the copy is written by hand every time.
BEGIN;

INSERT INTO chart_versions (version, note) VALUES
  (4, 'Copy of version 3. The rev-share pair (platform_rev_share_expense, '
      'platform_rev_share_payable) was left out of chart_presentation -- the '
      'omission a hand-copied chart version makes.');

INSERT INTO fs_lines (chart_version, code, caption, statement, side, sort_order)
SELECT 4, code, caption, statement, side, sort_order
FROM fs_lines WHERE chart_version = 3;

INSERT INTO chart_presentation (chart_version, type_code, category,
                                counterparty_scope, fs_line, fs_line_contra)
SELECT 4, type_code, category, counterparty_scope, fs_line, fs_line_contra
FROM chart_presentation
WHERE chart_version = 3
  AND type_code NOT IN ('platform_rev_share_expense', 'platform_rev_share_payable');

COMMIT;

\echo
\echo '=== 3. one fat-fingered posted transaction, for exactly the amount that cancels'
-- 30000 is the rev-share sub-book's turnover on each side, so the out-of-window
-- item (-30000) and the unpresented item (+30000) sum to zero in both columns.
-- Nothing else about the transaction is wrong; it is F4a's injection with the
-- amount chosen.
BEGIN;

INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                           idempotency_hash, payload, effective_at)
VALUES ('t1', '01a05d75-0000-7000-8000-000000000f4a', 'fee', 'internal',
        'fat-finger-2226', decode('00', 'hex'), '{}'::jsonb, '2226-01-01T00:00:00Z');

INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
VALUES ('t1', '01a05d75-0000-7000-8000-000000000f4b',
        '01a05d75-0000-7000-8000-000000000f4a', 'fee', 'posted', '2226-01-01T00:00:00Z');

INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, account_seq, effective_at)
SELECT 't1', '01a05d75-0000-7000-8000-000000000f4b', a.id, v.dir, 30000, 'USD',
       v.seq, '2226-01-01T00:00:00Z'
FROM (VALUES ('customer_receivable', 'debit'::ledger_direction,  4::bigint),
             ('fee_revenue',         'credit'::ledger_direction, 2::bigint))
     AS v(purpose, dir, seq)
JOIN ledger_accounts a ON a.tenant_id = 't1' AND a.purpose = v.purpose;

UPDATE ledger_account_balances b SET input = b.input + 30000, last_seq = 4
 WHERE b.tenant_id = 't1'
   AND b.account_id = (SELECT id FROM ledger_accounts
                       WHERE tenant_id = 't1' AND purpose = 'customer_receivable');
UPDATE ledger_account_balances b SET output = b.output + 30000, last_seq = 2
 WHERE b.tenant_id = 't1'
   AND b.account_id = (SELECT id FROM ledger_accounts
                       WHERE tenant_id = 't1' AND purpose = 'fee_revenue');

COMMIT;

\echo
\echo '=== 4. wait for the cluster horizon to retire the new rows'
DO $$
DECLARE tries int := 0;
BEGIN
    WHILE tries < 600 LOOP
        EXIT WHEN (SELECT coalesce(max(xact_id) <= pg_snapshot_xmin(pg_current_snapshot()), true)
                   FROM ledger_entries);
        PERFORM pg_sleep(0.1);
        tries := tries + 1;
    END LOOP;
    RAISE NOTICE 'horizon retired the injection after % poll(s)', tries;
END $$;

\echo
\echo '=== 5. the statement, every column: both remainders are zero'
-- out_of_window_debits 30000 and the unpresented rev-share 30000 are both in
-- here, and neither is visible in the remainder. tb_debits is 1780000 -- the
-- same figure the negative control printed in F4a section 2.
\x on
SELECT * FROM recon_journal_to_reports WHERE tenant_id = 't1';
\x off

\echo
\echo '=== 6. what the operator actually sees'
-- The summary view cannot be read at all: accounting_equation calls
-- recon_equation_breaks -> balance_sheet_at, and the A14 guard raises. ON_ERROR_STOP
-- is lifted for this one statement so the error is part of the record.
\set ON_ERROR_STOP off
SELECT * FROM reconciliation;
\set ON_ERROR_STOP on

\echo '--- so the nine checks that touch no statement function, spelled out'
SELECT 'balance_cache' AS check_name, COUNT(*) AS breaks FROM recon_balance_breaks
UNION ALL SELECT 'orphan_entries',          COUNT(*) FROM recon_entry_breaks
UNION ALL SELECT 'unbalanced_transactions', COUNT(*) FROM recon_transaction_breaks
UNION ALL SELECT 'cross_scope_mirror',      COUNT(*) FROM recon_scope_breaks
UNION ALL SELECT 'journal_to_reports',      COUNT(*) FROM recon_journal_to_reports
                                            WHERE unexplained_debits <> 0
                                               OR unexplained_credits <> 0
UNION ALL SELECT 'checkpoint_drift',        COUNT(*) FROM recon_checkpoint_breaks
UNION ALL SELECT 'close_typing',            COUNT(*) FROM recon_close_breaks
UNION ALL SELECT 'cursor_forgery',          COUNT(*) FROM recon_cursor_breaks
UNION ALL SELECT 'chart_lint',              COUNT(*) FROM chart_lint WHERE severity = 'error';

\echo '--- and the chart_lint errors, which name the chart and not the money'
SELECT * FROM chart_lint WHERE severity = 'error';

\echo
\echo '=== 7. the balance sheet at the current version: the A14 raise, verbatim'
\set ON_ERROR_STOP off
SELECT currency, chart_version, fs_line, side, amount_minor
FROM balance_sheet_at('t1', 'infinity', report_cursor()) ORDER BY sort_order;
\set ON_ERROR_STOP on

\echo
\echo '=== 8. the same book at version 3, which presents the pair'
-- Not a workaround: it is the demonstration that the journal is intact and only
-- the presentation is missing. Note receivables 1780000 -- version 3 also
-- presents the 2226 entry, because a balance sheet as at infinity is as at
-- infinity; the window lives only in recon_journal_to_reports.
SELECT currency, chart_version, fs_line, side, amount_minor
FROM balance_sheet_at('t1', 'infinity', report_cursor(), 3) ORDER BY sort_order;

\echo
\echo '=== 9. the sub-book is in the journal and out of the presented population'
SELECT tb.purpose, tb.debits, tb.credits,
       EXISTS (SELECT 1 FROM chart_presentation p, chart_version_current cv
               WHERE p.chart_version = cv.chart_version
                 AND p.type_code = tb.purpose) AS presented_at_current_version
FROM trial_balance tb WHERE tb.tenant_id = 't1' ORDER BY tb.purpose;

\echo '--- ...and it is balanced, which is why dropping it leaves the face footing'
SELECT COALESCE(SUM(tb.debits), 0)  AS dropped_debits,
       COALESCE(SUM(tb.credits), 0) AS dropped_credits
FROM trial_balance tb
WHERE tb.tenant_id = 't1'
  AND NOT EXISTS (SELECT 1 FROM chart_presentation p, chart_version_current cv
                  WHERE p.chart_version = cv.chart_version
                    AND p.type_code = tb.purpose);
