-- F2(a) -- the close is keyed in one direction only.
--
-- fk_closes__txn_kind forces a ledger_period_closes row to name a
-- kind='period_close' transaction. Nothing forces a kind='period_close'
-- transaction to have a close row -- there is no key from the journal into the
-- period record, and there could not be one: the transaction is written first.
--
-- income_statement_for excludes the closing transaction by KEY LOOKUP:
--     AND NOT EXISTS (SELECT 1 FROM ledger_period_closes c
--                     WHERE c.tenant_id = x.tenant_id AND c.transaction_id = x.id)
-- With no close row the lookup finds nothing, so the close's own sweep -- the
-- entry whose whole job is to zero revenue -- is COUNTED as operating activity,
-- and the period reports the revenue it earned net of the revenue it swept.
--
-- Written as openledger_app, the WRITER role, not the owner: `kind` is in the
-- app role's column-level INSERT grant on ledger_transactions, and
-- ledger_periods/ledger_period_closes are under a table-wide one. So this is
-- reachable by the role the deployment actually runs the write path as.
\set ON_ERROR_STOP off

\echo '=== 0. the negative control, and August as it really was'
SELECT * FROM reconciliation;
SELECT fs_line, side, amount_minor FROM
  income_statement_for('t1','2026-08-01T00:00:00Z','2026-09-01T00:00:00Z', report_cursor())
ORDER BY sort_order;

\echo
\echo '=== 1. a genuine close of August, as the app role, with NO close row'
\echo '--- The sweep is the real thing: revenue 250,000.00 out, expense 30,000.00'
\echo '--- back, the net 220,000.00 into retained_earnings, balanced, dated inside'
\echo '--- the period, kind = period_close. Only ledger_period_closes is missing.'
SET ROLE openledger_app;
SELECT current_user;

INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                           idempotency_hash, payload, effective_at)
VALUES ('t1','02500000-0000-7000-8000-0000000000a1','period_close','internal',
        'close-2026-08', decode('00','hex'), '{}'::jsonb, '2026-08-31T00:00:00Z');
INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
VALUES ('t1','02500000-0000-7000-8000-0000000000a2',
        '02500000-0000-7000-8000-0000000000a1','period_close','posted','2026-08-31T00:00:00Z');

-- retained_earnings has never posted, so its stripe row does not exist yet;
-- fk_entries__stripe requires one. The app role may INSERT it, and must supply
-- the frozen owner/identity copies -- which it can, because they are its own
-- account's.
INSERT INTO ledger_account_balances (tenant_id, account_id, currency, stripe,
        owner_type, owner_id_key, purpose, category, normal_balance,
        input, output, last_seq)
SELECT 't1', a.id, 'USD', 0, a.owner_type, a.owner_id_key, a.purpose, a.category,
       a.normal_balance, 0, 220000, 1
FROM ledger_accounts a WHERE a.tenant_id='t1' AND a.purpose='retained_earnings';

INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, stripe, account_seq, effective_at)
SELECT 't1','02500000-0000-7000-8000-0000000000a2', a.id, v.direction::ledger_direction, v.amount,
       'USD', 0, v.seq, '2026-08-31T00:00:00Z'
FROM (VALUES ('fee_revenue','debit',250000::bigint,2::bigint),
             ('platform_rev_share_expense','credit',30000,2),
             ('retained_earnings','credit',220000,1))
     AS v(purpose, direction, amount, seq)
JOIN ledger_accounts a ON a.tenant_id='t1' AND a.purpose = v.purpose;

UPDATE ledger_account_balances b SET input = b.input + 250000, last_seq = 2
FROM ledger_accounts a WHERE a.tenant_id=b.tenant_id AND a.id=b.account_id
  AND a.currency=b.currency AND b.tenant_id='t1' AND a.purpose='fee_revenue';
UPDATE ledger_account_balances b SET output = b.output + 30000, last_seq = 2
FROM ledger_accounts a WHERE a.tenant_id=b.tenant_id AND a.id=b.account_id
  AND a.currency=b.currency AND b.tenant_id='t1' AND a.purpose='platform_rev_share_expense';
RESET ROLE;

\echo '--- no close row was written:'
SELECT count(*) AS close_rows FROM ledger_period_closes;
\echo '--- and nothing refuses the transaction that should have one:'
SELECT tenant_id, kind, status, effective_at FROM ledger_transactions
WHERE kind = 'period_close';

\echo '--- wait for the horizon to retire the close, then read'
DO $$ BEGIN
  FOR i IN 1..600 LOOP
    EXIT WHEN (SELECT coalesce(max(xact_id) <= pg_snapshot_xmin(pg_current_snapshot()), true)
               FROM ledger_entries);
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;

\echo
\echo '=== 2. AUGUST REPORTS 0.00 REVENUE AND 0.00 EXPENSE, ON A PERIOD THAT EARNED'
SELECT fs_line, side, amount_minor FROM
  income_statement_for('t1','2026-08-01T00:00:00Z','2026-09-01T00:00:00Z', report_cursor())
ORDER BY sort_order;

\echo '=== 3. ...and the balance sheet is CORRECT, which is what makes it plausible'
SELECT fs_line, side, amount_minor FROM balance_sheet_at('t1','infinity', report_cursor())
ORDER BY sort_order;

\echo '=== 4. all ten checks'
SELECT * FROM reconciliation;
