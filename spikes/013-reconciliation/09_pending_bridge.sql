-- DRIFT 6 -- the one that is not a drift.
--
-- "All three copies of every balance count pending transactions and no report
-- does, so a customer served from the cache can be shown 500.00 while the balance
-- sheet shows 0.00, and nothing reconciles the two. Arguably available-versus-posted
-- by design; nothing says so, and no view surfaces the pending population."
--
-- database.md's table, rebuilt here on a scope of its own: one posted 100.00 and
-- one pending 500.00.

\pset footer off
BEGIN;

SELECT seed_open('t4','customer_wallet','USD','company','cust-4');
SELECT seed_open('t4','fbo_cash','USD','house',NULL);

DO $$
DECLARE v uuid; BEGIN
    v := seed_txn('t4','deposit','posted','2026-06-11');
    PERFORM seed_post('t4', v, seed_acct('t4','fbo_cash','USD'),        'debit',  10000, 'USD','2026-06-11');
    PERFORM seed_post('t4', v, seed_acct('t4','customer_wallet','USD'), 'credit', 10000, 'USD','2026-06-11');
    v := seed_txn('t4','deposit','pending','2026-06-11');
    PERFORM seed_post('t4', v, seed_acct('t4','fbo_cash','USD'),        'debit',  50000, 'USD','2026-06-11');
    PERFORM seed_post('t4', v, seed_acct('t4','customer_wallet','USD'), 'credit', 50000, 'USD','2026-06-11');
END $$;

\echo '=== four reads of one balance, in one instant (signs flipped to the'
\echo '=== account normal balance, which is credit for a wallet)'
SELECT 'cache row (input - output)' AS read, -(b.input - b.output) AS answer
FROM ledger_account_balances b
WHERE b.tenant_id = 't4' AND b.account_id = seed_acct('t4','customer_wallet','USD')
UNION ALL
SELECT 'recompute from ledger_entries',
       -SUM(CASE WHEN e.direction = 'debit' THEN e.amount_minor ELSE -e.amount_minor END)
FROM ledger_entries e
WHERE e.tenant_id = 't4' AND e.account_id = seed_acct('t4','customer_wallet','USD')
UNION ALL
SELECT 'recompute joined to status = posted',
       -SUM(CASE WHEN e.direction = 'debit' THEN e.amount_minor ELSE -e.amount_minor END)
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
WHERE e.tenant_id = 't4' AND e.account_id = seed_acct('t4','customer_wallet','USD')
  AND x.status = 'posted'
UNION ALL
SELECT 'trial_balance', SUM(balance_minor) FROM trial_balance
WHERE tenant_id = 't4' AND purpose = 'customer_wallet'
UNION ALL
SELECT 'balance_sheet (customer_funds)', -SUM(amount_minor) FROM balance_sheet
WHERE tenant_id = 't4' AND fs_line = 'customer_funds';

\echo '=== the bridge: available = posted + pending, and the population named'
SELECT tenant_id, purpose, currency, available_balance_minor, posted_balance_minor,
       pending_balance_minor, pending_txns, oldest_pending_effective_at, reconciles
FROM recon_pending_bridge WHERE tenant_id = 't4';

\echo '=== zero breaks: this book is healthy and the two numbers still differ'
SELECT * FROM reconciliation ORDER BY check_name;

\echo '=== and why the naive check does not work. "Three lines of SQL would'
\echo '=== surface it" -- a raw journal-minus-report difference is nonzero on a'
\echo '=== perfectly healthy book, once for every pending transaction on it.'
SELECT tenant_id, currency, journal_debits, tb_debits,
       journal_minus_report_debits AS naive_gap,
       pending_debits, orphan_debits,
       unexplained_debits AS actual_break
FROM recon_journal_to_reports ORDER BY tenant_id, currency;

ROLLBACK;
