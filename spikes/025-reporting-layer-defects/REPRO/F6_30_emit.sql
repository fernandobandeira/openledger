-- F6, stage 4 -- does recon_transaction_breaks EMIT a value past bigint, or only
-- compute one it then filters away?
--
-- Stage 3 left the t3 transaction balanced, so its ceiling-sized `legs` totals
-- were computed and discarded by the view's `WHERE g.debits <> g.credits`. The
-- stronger question is whether the view renders such a number in a break row it
-- actually returns, and the writer cannot produce that state: balance lives in
-- the writer's type (ADR-0005), so an unbalanced transaction has to be appended
-- around it.
--
-- APPENDED HONESTLY, the way crates/e2e/tests/e2e/reconcile.rs does it: as the
-- app role, through the INSERT grants it holds, with the balance cache advanced
-- in the same breath so recon_balance_breaks stays quiet and the forged rows are
-- not confused with cache drift. The journal is append-only -- refuse_mutation()
-- refuses UPDATE and DELETE on ledger_entries -- so this is forward-only and the
-- restore in F6_run.sh is the only way back.
--
-- ONE EXTRA DEBIT ON ONE TRANSACTION AND ONE EXTRA CREDIT ON ANOTHER, so the
-- tenant's revenue and expense still net to zero: the un-closed-earnings plug
-- stays flat and the accounting_equation check stays green. The only check that
-- moves is the one that should -- unbalanced_transactions, at two.
--
-- A FRESH STRIPE FOR EACH, because the six stripes the writer used are already
-- at 2^63-1 and one more ceiling-sized entry on any of them would overflow the
-- cache column, which is a WRITE refusal and not the read-path question F6 asks.
-- fk_entries__stripe requires the cache row to exist first.

SET ROLE openledger_app;

\echo
\echo '########## the cache rows for stripe 12, inserted before the entries that name them'
INSERT INTO ledger_account_balances
  (tenant_id, account_id, currency, stripe, owner_type, owner_id_key,
   purpose, category, normal_balance, input, output, last_seq)
SELECT 't4', a.id, 'USD', 12, a.owner_type, a.owner_id_key,
       a.purpose, a.category, a.normal_balance,
       CASE WHEN a.normal_balance = 'debit'  THEN 9223372036854775807 ELSE 0 END,
       CASE WHEN a.normal_balance = 'credit' THEN 9223372036854775807 ELSE 0 END,
       1
FROM ledger_accounts a WHERE a.tenant_id = 't4';

\echo '########## ...and the two unbalanced legs, one on each of two transactions'
INSERT INTO ledger_entries
  (tenant_id, transaction_id, account_id, direction, amount_minor, currency,
   stripe, account_seq, effective_at)
SELECT 't4', x.id,
       CASE WHEN x.rn = 1 THEN '00000000-0000-4000-8000-0000000000c1'::uuid
                          ELSE '00000000-0000-4000-8000-0000000000d1'::uuid END,
       CASE WHEN x.rn = 1 THEN 'debit'::ledger_direction
                          ELSE 'credit'::ledger_direction END,
       9223372036854775807, 'USD', 12, 1, x.effective_at
FROM (SELECT id, effective_at, row_number() OVER (ORDER BY recorded_at) AS rn
      FROM ledger_transactions WHERE tenant_id = 't4') x
WHERE x.rn <= 2;

RESET ROLE;

\echo
\echo '########## recon_transaction_breaks now emits the rows'
-- debits = 18446744073709551614 in a row the view RETURNS, with the reason it
-- exists to give. The view reports past the bigint ceiling; it does not raise.
\x on
SELECT * FROM recon_transaction_breaks;
\x off

\echo
\echo '########## the ten checks: two honest breaks, no ERROR anywhere'
SELECT * FROM reconciliation;
