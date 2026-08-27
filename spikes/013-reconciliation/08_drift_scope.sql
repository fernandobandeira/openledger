-- DRIFT 5 -- the two sides of a cross-scope obligation.
--
-- "A tenant booking 100,000.00 of due_from_treasury against an operator booking
-- 60,000.00 of due_to_tenants leaves every scope balanced, every check green, and
-- 40,000.00 of asset owed by nobody. No view compares the two sides."
--
-- Reproduced exactly: the operator writes back 40,000.00 of what it owes -- a
-- balanced, ordinary, correctly-keyed transaction in its own book -- and the tenant
-- never hears about it. Tenant-locality is what makes this invisible: no
-- transaction may span two scopes, so there is no row anywhere that has both
-- numbers in it.

\pset footer off

-- ----------------------------------------------------------------------
\echo '=== 5a - 40,000.00 written back on one side only'
BEGIN;
SET ROLE openledger_app;
DO $$
DECLARE v uuid; BEGIN
    v := seed_txn('op','treasury_adjustment','posted','2026-06-10');
    PERFORM seed_post('op', v, seed_acct('op','due_to_tenants','USD'), 'debit',  4000000, 'USD','2026-06-10');
    PERFORM seed_post('op', v, seed_acct('op','fbo_cash','USD'),       'credit', 4000000, 'USD','2026-06-10');
END $$;
RESET ROLE;

\echo '--- both scopes balance, both trial balances foot, both balance sheets are'
\echo '--- internally consistent. Every check that exists today is green.'
SELECT tenant_id, currency, sum(debits) AS tb_debits, sum(credits) AS tb_credits
FROM trial_balance WHERE currency = 'USD' GROUP BY tenant_id, currency ORDER BY tenant_id;

SELECT count(*) AS unbalanced, (SELECT count(*) FROM recon_balance_breaks) AS cache_breaks,
       (SELECT count(*) FROM recon_entry_breaks) AS orphans
FROM recon_transaction_breaks;

\echo '--- the two sides, compared'
SELECT near_type, far_type, currency, near_minor, far_minor, gap_minor,
       near_scopes, far_scopes, net_of_counterparties
FROM recon_scope_breaks;

SELECT * FROM reconciliation ORDER BY check_name;

-- ----------------------------------------------------------------------
\echo '=== 5b - ...and what this comparison CANNOT see, on the same book.'
\echo '===      A third scope holding an offsetting position of the same size'
\echo '===      makes the pair sum to zero and the view go quiet, while t1 is'
\echo '===      still owed 100,000.00 that the operator acknowledges 60,000.00 of.'
SELECT seed_open('t3','due_from_treasury','USD','house',NULL);
SELECT seed_open('t3','customer_wallet','USD','company','cust-3');
SET ROLE openledger_app;
DO $$
DECLARE v uuid; BEGIN
    v := seed_txn('t3','treasury_draw','posted','2026-06-10');
    PERFORM seed_post('t3', v, seed_acct('t3','customer_wallet','USD'),   'debit',  4000000, 'USD','2026-06-10');
    PERFORM seed_post('t3', v, seed_acct('t3','due_from_treasury','USD'), 'credit', 4000000, 'USD','2026-06-10');
END $$;
RESET ROLE;

SELECT tenant_id, purpose, currency, balance_debit_positive
FROM trial_balance WHERE purpose IN ('due_from_treasury','due_to_tenants') AND currency = 'USD'
ORDER BY tenant_id;

\echo '--- the pair now sums to zero. The view is silent and both scopes are wrong.'
SELECT * FROM recon_scope_breaks;
SELECT * FROM reconciliation ORDER BY check_name;
ROLLBACK;

\echo '=== rolled back: clean again'
SELECT * FROM reconciliation ORDER BY check_name;
