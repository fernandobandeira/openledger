-- F4a -- THE FALSE POSITIVE: `recon_journal_to_reports` does not foot.
--
-- The view's own header calls itself "a reconciliation statement, not a break
-- list ... every row must foot": open with the journal figure, subtract each
-- reconciling item BY NAME, and what is left unexplained is the break. A
-- reconciling item that has been named is accounted for; it must not also be
-- left in the figure it is being reconciled against.
--
-- `out_of_window` is named on the journal side and NOT removed from the report
-- side. The `classified` CTE buckets an entry OUT of `reported_debits` when its
-- effective_at is at or beyond now() + 1 year; the `r` CTE, which produces
-- `tb_debits`, carries no effective_at predicate at all. So the same amount is
-- disclosed in `out_of_window_debits`, subtracted from `reported_debits`, and
-- still counted in `tb_debits` -- and `unexplained = reported - tb` goes
-- non-zero by exactly that amount on a book where nothing is wrong.
--
-- The injection below is an honest transaction with one fat-fingered digit in
-- the year, which is the state the bucket was added for (A17): a real event row,
-- balanced legs, account_seq continued, and the balance cache advanced so
-- `balance_cache` has nothing to say. The statements themselves are correct at
-- this state -- the balance sheet foots and recon_equation_breaks is empty --
-- and the check still reads one break.
--
-- Assumes a freshly restored spike025_f4 (the negative-control book).
-- The compiled sweep, for the exit code, is run from a shell after this file:
--   DATABASE_URL="postgres://openledger:openledger@localhost:5455/spike025_f4?sslmode=disable" \
--     ./target/debug/openledger reconcile; echo "exit=$?"

\set ON_ERROR_STOP on

\echo
\echo '=== 1. the negative control: ten checks, zero breaks'
SELECT * FROM reconciliation;

\echo
\echo '=== 2. the statement on the clean book, for the before/after of every column'
\x on
SELECT * FROM recon_journal_to_reports WHERE tenant_id = 't1';
\x off

\echo
\echo '=== 3. one balanced posted transaction, effective 2226-01-01'
-- The year is the only thing wrong with it. ck_txn__effective_finite refuses
-- only +/-infinity, so 2226 is a legal effective_at and the writer would accept
-- it; the event and transaction rows are the shape the writer emits, which is
-- why no FK has to be bypassed here (no session_replication_role).
BEGIN;

INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                           idempotency_hash, payload, effective_at)
VALUES ('t1', '01a05d75-0000-7000-8000-000000000f4a', 'fee', 'internal',
        'fat-finger-2226', decode('00', 'hex'), '{}'::jsonb, '2226-01-01T00:00:00Z');

INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
VALUES ('t1', '01a05d75-0000-7000-8000-000000000f4b',
        '01a05d75-0000-7000-8000-000000000f4a', 'fee', 'posted', '2226-01-01T00:00:00Z');

-- DR customer_receivable 700.00 / CR fee_revenue 700.00. account_seq continues
-- each account's own sequence (receivable is at 3, fee_revenue at 1), because
-- uq_entries__account_seq is what recon_balance_breaks reads as max_seq.
INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, account_seq, effective_at)
SELECT 't1', '01a05d75-0000-7000-8000-000000000f4b', a.id, v.dir, 70000, 'USD',
       v.seq, '2226-01-01T00:00:00Z'
FROM (VALUES ('customer_receivable', 'debit'::ledger_direction,  4::bigint),
             ('fee_revenue',         'credit'::ledger_direction, 2::bigint))
     AS v(purpose, dir, seq)
JOIN ledger_accounts a ON a.tenant_id = 't1' AND a.purpose = v.purpose;

-- The cache is derived state and the writer advances it in the same
-- transaction; leaving it behind would light `balance_cache` and the finding
-- would be about the cache instead.
UPDATE ledger_account_balances b SET input = b.input + 70000, last_seq = 4
 WHERE b.tenant_id = 't1'
   AND b.account_id = (SELECT id FROM ledger_accounts
                       WHERE tenant_id = 't1' AND purpose = 'customer_receivable');
UPDATE ledger_account_balances b SET output = b.output + 70000, last_seq = 2
 WHERE b.tenant_id = 't1'
   AND b.account_id = (SELECT id FROM ledger_accounts
                       WHERE tenant_id = 't1' AND purpose = 'fee_revenue');

COMMIT;

\echo
\echo '=== 4. wait for the cluster horizon to retire the new rows'
-- report_cursor() is pg_snapshot_xmin, so everything pinned at it lags until
-- the horizon has passed the rows just committed (ADR-0011's honest cost). A
-- bounded server-side poll, so the reports below are read at a cursor that can
-- see the injection rather than at one that cannot.
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
\echo '=== 5. every check: which moved, which did not'
SELECT * FROM reconciliation;

\echo
\echo '=== 6. the statement for (t1, USD), every column'
-- out_of_window_debits = 70000 -- the amount is DISCLOSED,
-- reported_debits      = 1780000 -- and subtracted here,
-- tb_debits            = 1850000 -- and still counted here,
-- unexplained_debits   = -70000 -- so the remainder is the item already named.
\x on
SELECT * FROM recon_journal_to_reports WHERE tenant_id = 't1';
\x off

\echo
\echo '=== 7. ...while the reports are correct'
-- The balance sheet as at infinity includes the 2226 entry, as it must, and
-- foots: assets 1820000 = liabilities 530000 + equity 1290000.
SELECT currency, chart_version, fs_line, side, amount_minor
FROM balance_sheet_at('t1', 'infinity', report_cursor()) ORDER BY sort_order;

\echo '--- the accounting-equation check at the same cursor (must be EMPTY)'
SELECT * FROM recon_equation_breaks(report_cursor(), 'infinity');

\echo '--- and the cache agrees with the journal (must be EMPTY)'
SELECT tenant_id, account_id, drift_minor, reasons FROM recon_balance_breaks;
