-- DRIFT 2 -- the counter, separately from the balance.
--
-- The balance cache row is three things at once: the write lock, the source of
-- account_seq, and the cached balance. The decision log's objection is that the
-- three "all fail together". They do not have to be DETECTED together, and this
-- file is the argument: the counter is checked against MAX(account_seq), and
-- gaplessness against COUNT(*), on the same row and in separate break classes.
--
-- ADR-0004: "Gaplessness is enforced when the number is ISSUED and checked nowhere
-- afterwards." This is afterwards.

\pset footer off

-- ----------------------------------------------------------------------
\echo '=== 2a - last_seq pushed AHEAD of the journal. The balance is untouched.'
BEGIN;
SET ROLE openledger_app;
UPDATE ledger_account_balances b
   SET last_seq = b.last_seq + 48
  FROM ledger_accounts a
 WHERE a.tenant_id = b.tenant_id AND a.id = b.account_id AND a.currency = b.currency
   AND b.tenant_id = 't1' AND a.purpose = 'customer_wallet' AND b.currency = 'USD';
RESET ROLE;

SELECT tenant_id, currency, drift_minor, cache_last_seq, max_seq, entry_count, reasons
FROM recon_balance_breaks;

\echo '--- and the consequence: the next posting silently leaves a 48-wide hole'
DO $$
DECLARE v uuid; BEGIN
    v := seed_txn('t1','fee','posted','2026-06-06');
    PERFORM seed_post('t1', v, seed_acct('t1','customer_wallet','USD'), 'debit',  100, 'USD','2026-06-06');
    PERFORM seed_post('t1', v, seed_acct('t1','fee_revenue','USD'),     'credit', 100, 'USD','2026-06-06');
END $$;

SELECT account_seq FROM ledger_entries e
WHERE e.tenant_id = 't1'
  AND e.account_id = seed_acct('t1','customer_wallet','USD')
ORDER BY account_seq;

SELECT tenant_id, currency, drift_minor, cache_last_seq, max_seq, entry_count, reasons
FROM recon_balance_breaks;
ROLLBACK;

-- ----------------------------------------------------------------------
\echo '=== 2b - last_seq pulled BEHIND the journal. This one fails closed.'
BEGIN;
SET ROLE openledger_app;
UPDATE ledger_account_balances b
   SET last_seq = 1
  FROM ledger_accounts a
 WHERE a.tenant_id = b.tenant_id AND a.id = b.account_id AND a.currency = b.currency
   AND b.tenant_id = 't1' AND a.purpose = 'customer_wallet' AND b.currency = 'USD';
RESET ROLE;

SELECT tenant_id, currency, drift_minor, cache_last_seq, max_seq, entry_count, reasons
FROM recon_balance_breaks;

\echo '--- the next posting is REFUSED by uq_entries__account_seq: the journal wins'
DO $$
DECLARE v uuid; BEGIN
    v := seed_txn('t1','fee','posted','2026-06-06');
    PERFORM seed_post('t1', v, seed_acct('t1','customer_wallet','USD'), 'debit', 100, 'USD','2026-06-06');
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'refused: %', SQLERRM;
END $$;
ROLLBACK;

-- ----------------------------------------------------------------------
\echo '=== 2c - a hole opened from the other side: an INSERT that supplies its own seq'
\echo '===      (ADR-0004: "an INSERT left a 48-wide gap"). Balance and counter agree.'
BEGIN;
SET ROLE openledger_app;
INSERT INTO ledger_transactions (tenant_id, kind, status, effective_at)
VALUES ('t1','fee','posted','2026-06-06');

INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, account_seq, effective_at)
SELECT 't1', x.id, seed_acct('t1','customer_wallet','USD'), 'debit', 100, 'USD', 52, '2026-06-06'
FROM ledger_transactions x WHERE x.tenant_id = 't1' AND x.kind = 'fee'
  AND x.effective_at = '2026-06-06';

INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, account_seq, effective_at)
SELECT 't1', x.id, seed_acct('t1','fee_revenue','USD'), 'credit', 100, 'USD', 2, '2026-06-06'
FROM ledger_transactions x WHERE x.tenant_id = 't1' AND x.kind = 'fee'
  AND x.effective_at = '2026-06-06';

UPDATE ledger_account_balances b
   SET input = b.input + 100, last_seq = 52
  FROM ledger_accounts a
 WHERE a.tenant_id = b.tenant_id AND a.id = b.account_id AND a.currency = b.currency
   AND b.tenant_id = 't1' AND a.purpose = 'customer_wallet' AND b.currency = 'USD';
UPDATE ledger_account_balances b
   SET output = b.output + 100, last_seq = 2
  FROM ledger_accounts a
 WHERE a.tenant_id = b.tenant_id AND a.id = b.account_id AND a.currency = b.currency
   AND b.tenant_id = 't1' AND a.purpose = 'fee_revenue' AND b.currency = 'USD';
RESET ROLE;

\echo '--- the transaction balances, the cache agrees with the journal, and the'
\echo '--- account is missing entries 4..51. Only the gap class sees it.'
SELECT count(*) AS unbalanced_transactions FROM recon_transaction_breaks;
SELECT tenant_id, currency, drift_minor, cache_last_seq, max_seq, entry_count, reasons
FROM recon_balance_breaks;
ROLLBACK;

\echo '=== rolled back: clean again'
SELECT * FROM reconciliation ORDER BY check_name;
