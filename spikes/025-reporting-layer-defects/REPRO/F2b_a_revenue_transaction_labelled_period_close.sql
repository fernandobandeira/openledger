-- F2(b) -- ledger_transactions.kind is free `text` with no CHECK, and it is in
-- the app role's column-level INSERT grant.
--
-- ADR-0011 records the defect this was meant to close: "The app role could name a
-- REVENUE transaction and erase it from the income statement, green." Three keys
-- were added -- fk_closes__txn_kind, fk_closes__txn_effective and
-- recon_close_breaks. They constrain what a close row may NAME. None of them
-- constrains what the named transaction may CONTAIN: `kind` is the only thing
-- fk_closes__txn_kind checks, and `kind` is a caller-supplied string.
--
-- So the defect is unchanged in substance and only narrower in reach: a revenue
-- transaction labelled kind='period_close', dated inside the period, named by a
-- fully valid close row with a correct cursor and a correct checkpoint, is erased
-- from the income statement while the balance sheet stays right and all ten
-- checks stay green.
--
-- One transaction, because computed_at_xid must be this transaction's own commit
-- position for recon_close_breaks to pass and for the checkpoint to be
-- self-consistent.
\set ON_ERROR_STOP off

\echo '=== 0. the negative control, and August as it will really be'
SELECT * FROM reconciliation;

BEGIN;
SET LOCAL ROLE openledger_app;
SELECT current_user;

-- A 700,000.00 FEE. Ordinary revenue in every respect except the label.
INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                           idempotency_hash, payload, effective_at)
VALUES ('t1','02500000-0000-7000-8000-0000000000b1','posting','internal',
        'big-fee-1', decode('00','hex'), '{}'::jsonb, '2026-08-28T00:00:00Z');
INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
VALUES ('t1','02500000-0000-7000-8000-0000000000b2',
        '02500000-0000-7000-8000-0000000000b1','period_close','posted','2026-08-28T00:00:00Z');
INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, stripe, account_seq, effective_at)
SELECT 't1','02500000-0000-7000-8000-0000000000b2', a.id,
       v.direction::ledger_direction, 700000, 'USD', 0, v.seq, '2026-08-28T00:00:00Z'
FROM (VALUES ('customer_receivable','debit',4::bigint),
             ('fee_revenue','credit',2))
     AS v(purpose, direction, seq)
JOIN ledger_accounts a ON a.tenant_id='t1' AND a.purpose = v.purpose;
UPDATE ledger_account_balances b SET input = b.input + 700000, last_seq = 4
FROM ledger_accounts a WHERE a.tenant_id=b.tenant_id AND a.id=b.account_id
  AND a.currency=b.currency AND b.tenant_id='t1' AND a.purpose='customer_receivable';
UPDATE ledger_account_balances b SET output = b.output + 700000, last_seq = 2
FROM ledger_accounts a WHERE a.tenant_id=b.tenant_id AND a.id=b.account_id
  AND a.currency=b.currency AND b.tenant_id='t1' AND a.purpose='fee_revenue';

-- ...and the close record that erases it. Every key is satisfied:
-- fk_closes__txn_kind (kind is 'period_close'), fk_closes__txn_effective and
-- ck_closes__txn_in_period (2026-08-28 is inside August), and computed_at_xid is
-- this transaction's own commit position, so recon_close_breaks passes.
INSERT INTO ledger_periods (tenant_id, code, starts_at, ends_at, tz)
VALUES ('t1','2026-08','2026-08-01T00:00:00Z','2026-09-01T00:00:00Z','UTC');
INSERT INTO ledger_period_closes (tenant_id, period_code, currency, starts_at, ends_at,
                                  transaction_id, txn_effective_at, computed_at_xid)
VALUES ('t1','2026-08','USD','2026-08-01T00:00:00Z','2026-09-01T00:00:00Z',
        '02500000-0000-7000-8000-0000000000b2','2026-08-28T00:00:00Z',
        pg_current_xact_id());

-- ...and a checkpoint that reconciles, computed exactly as
-- recon_checkpoint_breaks recomputes it. The close's own entries carry this
-- transaction's xact_id, so `e.xact_id < computed_at_xid` excludes them from both
-- sides and the checkpoint is self-consistent.
INSERT INTO ledger_period_balances (tenant_id, period_code, currency, account_id,
                                    input, output)
SELECT c.tenant_id, c.period_code, c.currency, e.account_id,
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'), 0),
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'), 0)
FROM ledger_period_closes c
JOIN ledger_entries e ON e.tenant_id=c.tenant_id AND e.currency=c.currency
                     AND e.effective_at < c.ends_at AND e.xact_id < c.computed_at_xid
JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id
                          AND x.status='posted'
GROUP BY c.tenant_id, c.period_code, c.currency, e.account_id;
COMMIT;

\echo '--- wait for the horizon, then read'
DO $$ BEGIN
  FOR i IN 1..600 LOOP
    EXIT WHEN (SELECT coalesce(max(xact_id) <= pg_snapshot_xmin(pg_current_snapshot()), true)
               FROM ledger_entries);
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;

\echo
\echo '=== 1. the journal says 950,000.00 of fee revenue in August'
SELECT purpose, credits FROM trial_balance WHERE tenant_id='t1' AND purpose='fee_revenue';

\echo '=== 2. the income statement says 250,000.00'
SELECT fs_line, side, amount_minor FROM
  income_statement_for('t1','2026-08-01T00:00:00Z','2026-09-01T00:00:00Z', report_cursor())
ORDER BY sort_order;

\echo '=== 3. the balance sheet carries all of it, and foots'
SELECT fs_line, side, amount_minor FROM balance_sheet_at('t1','infinity', report_cursor())
ORDER BY sort_order;

\echo '=== 4. all ten checks'
SELECT * FROM reconciliation;

\echo
\echo '=== 5. THE BOUND: only one such transaction per (tenant, period, currency),'
\echo '--- and only where no genuine close row already holds the slot.'
SELECT 'a second erasure in the same period' AS attempt;
INSERT INTO ledger_period_closes (tenant_id, period_code, currency, starts_at, ends_at,
                                  transaction_id, txn_effective_at, computed_at_xid)
VALUES ('t1','2026-08','USD','2026-08-01T00:00:00Z','2026-09-01T00:00:00Z',
        '02500000-0000-7000-8000-0000000000b2','2026-08-28T00:00:00Z', pg_current_xact_id());
SELECT 'a close row naming a transaction whose kind is not period_close' AS attempt;
-- On t2, whose August is still open. fk_closes__txn_kind DOES hold; what it
-- cannot check is what the named transaction CONTAINS, and `kind` is a
-- caller-supplied string with no CHECK on the column and the column in the app
-- role's INSERT grant.
INSERT INTO ledger_periods (tenant_id, code, starts_at, ends_at, tz)
VALUES ('t2','2026-08','2026-08-01T00:00:00Z','2026-09-01T00:00:00Z','UTC');
INSERT INTO ledger_period_closes (tenant_id, period_code, currency, starts_at, ends_at,
                                  transaction_id, txn_effective_at, computed_at_xid)
SELECT 't2','2026-08','USD','2026-08-01T00:00:00Z','2026-09-01T00:00:00Z',
       x.id, x.effective_at, pg_current_xact_id()
FROM ledger_transactions x WHERE x.tenant_id='t2';

\echo '--- ...and there is no CHECK on ledger_transactions.kind at all'
SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conrelid='ledger_transactions'::regclass AND contype='c' ORDER BY conname;
\echo '--- ...and `kind` is one of the columns the app role may INSERT'
SELECT string_agg(column_name, ', ' ORDER BY column_name) AS app_insertable_columns
FROM information_schema.column_privileges
WHERE grantee='openledger_app' AND table_name='ledger_transactions'
  AND privilege_type='INSERT';
