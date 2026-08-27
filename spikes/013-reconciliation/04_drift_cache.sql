-- DRIFT 1 -- the balance cache against the journal.
--
-- "Using only the app role's granted UPDATE, the cache was moved from 1,000.00 to
-- 100.00 with last_seq forged; the balance sheet was unchanged and every check
-- stayed green." Reproduced here on the account a customer is actually shown:
-- t1's wallet, 99,491.00 rewritten to 9,491.00.
--
-- `last_seq` is written too, to the value it already held -- which is what "forged"
-- means here. A check that watched only the counter would see nothing, and the
-- balance-drift class is what catches it.
--
-- Everything is rolled back at the end, so the negative control still holds after.

\pset footer off
BEGIN;

\echo '=== before: the fast-path read, and what the balance sheet says'
SELECT b.input - b.output AS cache_balance_minor, b.last_seq
FROM ledger_account_balances b
JOIN ledger_accounts a ON a.tenant_id = b.tenant_id AND a.id = b.account_id AND a.currency = b.currency
WHERE b.tenant_id = 't1' AND a.purpose = 'customer_wallet' AND b.currency = 'USD';

SELECT tenant_id, currency, fs_line, amount_minor FROM balance_sheet
WHERE tenant_id = 't1' AND currency = 'USD' AND fs_line = 'customer_funds';

\echo '=== the forgery: nothing but the grant the baseline hands openledger_app'
SET ROLE openledger_app;
UPDATE ledger_account_balances b
   SET output = 1000000, last_seq = 3
  FROM ledger_accounts a
 WHERE a.tenant_id = b.tenant_id AND a.id = b.account_id AND a.currency = b.currency
   AND b.tenant_id = 't1' AND a.purpose = 'customer_wallet' AND b.currency = 'USD';
RESET ROLE;

\echo '=== after: the fast-path read moved, the balance sheet did not'
SELECT b.input - b.output AS cache_balance_minor, b.last_seq
FROM ledger_account_balances b
JOIN ledger_accounts a ON a.tenant_id = b.tenant_id AND a.id = b.account_id AND a.currency = b.currency
WHERE b.tenant_id = 't1' AND a.purpose = 'customer_wallet' AND b.currency = 'USD';

SELECT tenant_id, currency, fs_line, amount_minor FROM balance_sheet
WHERE tenant_id = 't1' AND currency = 'USD' AND fs_line = 'customer_funds';

\echo '=== what the reconciliation layer says'
SELECT * FROM reconciliation ORDER BY check_name;
SELECT tenant_id, currency, cache_balance_minor, journal_balance_minor, drift_minor,
       cache_last_seq, max_seq, entry_count, reasons
FROM recon_balance_breaks;

ROLLBACK;

\echo '=== rolled back: clean again'
SELECT * FROM reconciliation ORDER BY check_name;
