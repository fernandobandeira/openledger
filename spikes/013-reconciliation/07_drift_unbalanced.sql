-- DRIFT 4 -- debits <> credits, which nothing in the shipped artefact reports.
--
-- "The register already says nothing ENFORCES it. The sharper point: nothing
-- REPORTS it either. No view mentions balance; the only multi-row constraints on
-- ledger_entries are three single-row CHECKs. A posted transaction with one entry,
-- or zero entries, is accepted and appears in no exception list."
--
-- This does not enforce balance and is not a substitute for the writer's type
-- (ADR-0005): a caller holding an INSERT grant can still write any of the four
-- cases below. It is the exception list that says whether the claim holds of the
-- data -- which is the difference between an unverifiable design claim and a
-- checkable one.

\pset footer off

-- ----------------------------------------------------------------------
\echo '=== 4a - one leg. The app role, its ordinary INSERT grant, no FK skipped.'
BEGIN;
SET ROLE openledger_app;
DO $$
DECLARE v uuid; BEGIN
    v := seed_txn('t1','fee','posted','2026-06-09');
    PERFORM seed_post('t1', v, seed_acct('t1','fee_revenue','USD'), 'credit', 25000, 'USD','2026-06-09');
END $$;
RESET ROLE;

SELECT tenant_id, status, currency, debits, credits, imbalance_minor, leg_count, reason
FROM recon_transaction_breaks;
SELECT * FROM reconciliation ORDER BY check_name;
ROLLBACK;

-- ----------------------------------------------------------------------
\echo '=== 4b - two legs that disagree by 10.00'
BEGIN;
SET ROLE openledger_app;
DO $$
DECLARE v uuid; BEGIN
    v := seed_txn('t1','fee','posted','2026-06-09');
    PERFORM seed_post('t1', v, seed_acct('t1','customer_wallet','USD'), 'debit',  2500, 'USD','2026-06-09');
    PERFORM seed_post('t1', v, seed_acct('t1','fee_revenue','USD'),     'credit', 1500, 'USD','2026-06-09');
END $$;
RESET ROLE;

SELECT tenant_id, currency, debits, credits, imbalance_minor, leg_count, reason
FROM recon_transaction_breaks;
ROLLBACK;

-- ----------------------------------------------------------------------
\echo '=== 4c - no legs at all. This is the state TRUNCATE left behind (ADR-0004):'
\echo '===      "eleven transactions standing with zero entries, every currency'
\echo '===      balanced = t, drift at zero rows ... silence read as assent."'
BEGIN;
SET ROLE openledger_app;
SELECT seed_txn('t1','fee','posted','2026-06-09') IS NOT NULL AS written;
RESET ROLE;

SELECT tenant_id, status, currency, debits, credits, leg_count, reason
FROM recon_transaction_breaks;
ROLLBACK;

-- ----------------------------------------------------------------------
\echo '=== 4d - balanced currency-blind, balanced in neither currency.'
\echo '===      ADR-0007 rule 12: the equation is evaluated PER CURRENCY, and a'
\echo '===      currency-blind one is vacuous. Grouping decides whether this is'
\echo '===      seen at all -- currency-blind, both rows below foot to zero.'
BEGIN;
SET ROLE openledger_app;
DO $$
DECLARE v uuid; BEGIN
    v := seed_txn('op','settlement','posted','2026-06-09');
    PERFORM seed_post('op', v, seed_acct('op','fbo_cash','USD'),       'debit',  10000, 'USD','2026-06-09');
    PERFORM seed_post('op', v, seed_acct('op','due_to_tenants','EUR'), 'credit', 10000, 'EUR','2026-06-09');
END $$;
RESET ROLE;

SELECT tenant_id, currency, debits, credits, imbalance_minor, leg_count, reason
FROM recon_transaction_breaks ORDER BY currency;
ROLLBACK;

\echo '=== rolled back: clean again'
SELECT * FROM reconciliation ORDER BY check_name;
