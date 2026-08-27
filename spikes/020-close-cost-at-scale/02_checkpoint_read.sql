-- Q2 -- the checkpoint READ benefit, and the question that comes first: does the
-- as-of path actually READ the checkpoint?
--
-- ADR-0011 §3 claims a 45-49x read benefit from ledger_period_balances. But the
-- only column in the schema that reads that table is recon_checkpoint_breaks (the
-- reconciler). This file proves whether balance_sheet_at -- the as-of statement
-- function an integrator calls -- reads the checkpoint or scans from inception,
-- and measures the benefit the checkpoint COULD deliver either way.
--
-- Expects the book already built by run.sh: tenant 'r', USD, several monthly
-- periods each closed. :boundary is the last close boundary; :lastp its code.
\set ON_ERROR_STOP on
\timing off

\echo '=== 1. DOES balance_sheet_at READ THE CHECKPOINT? (static proof) ==='
-- pg_get_functiondef is the whole body. If it never names ledger_period_balances,
-- the as-of path cannot be reading the checkpoint -- it aggregates ledger_entries.
SELECT p.proname,
       (pg_get_functiondef(p.oid) LIKE '%ledger_period_balances%') AS reads_checkpoint,
       (pg_get_functiondef(p.oid) LIKE '%ledger_entries%')         AS reads_journal
FROM pg_proc p WHERE p.proname IN ('balance_sheet_at','trial_balance_at','income_statement_for')
ORDER BY 1;

SELECT 'reader_of_checkpoint' AS what, c.relname
FROM pg_depend d
JOIN pg_rewrite r ON r.oid = d.objid
JOIN pg_class c ON c.oid = r.ev_class
WHERE d.refobjid = 'ledger_period_balances'::regclass AND d.deptype = 'n'
GROUP BY c.relname ORDER BY 1;

\echo '=== 2. the inner plan of the as-of position: an Index/Seq Scan of ledger_entries ==='
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, SUMMARY OFF)
SELECT e.account_id,
       SUM(CASE WHEN e.direction='debit' THEN e.amount_minor::numeric ELSE -e.amount_minor::numeric END)
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
WHERE e.tenant_id='r' AND e.effective_at < :'boundary' AND e.xact_id < report_cursor()
GROUP BY e.account_id;

\echo '=== 3. balance_sheet_at at the last close boundary (what the integrator runs) ==='
\timing on
SELECT count(*) FROM balance_sheet_at('r', :'boundary', report_cursor());
SELECT count(*) FROM balance_sheet_at('r', :'boundary', report_cursor());
\timing off

\echo '=== 4. the from-inception aggregation the balance sheet is built on (its cost driver) ==='
\timing on
SELECT count(*) FROM (
  SELECT e.account_id,
         SUM(CASE WHEN e.direction='debit' THEN e.amount_minor::numeric ELSE -e.amount_minor::numeric END)
  FROM ledger_entries e
  JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
  WHERE e.tenant_id='r' AND e.effective_at < :'boundary' AND e.xact_id < report_cursor()
  GROUP BY e.account_id) s;
\timing off

\echo '=== 5. what a checkpoint READ would cost instead: read the stored rows for the last period ==='
-- At a close boundary the tail is empty, so a checkpoint reader returns the stored
-- per-account balances directly. This is the read the schema does NOT wire up.
\timing on
SELECT count(*) FROM (
  SELECT account_id, input, output
  FROM ledger_period_balances
  WHERE tenant_id='r' AND period_code = :'lastp' AND currency='USD') s;
SELECT count(*) FROM (
  SELECT account_id, input, output
  FROM ledger_period_balances
  WHERE tenant_id='r' AND period_code = :'lastp' AND currency='USD') s;
\timing off

\echo '=== sizes ==='
SELECT (SELECT count(*) FROM ledger_entries WHERE tenant_id='r') AS entries,
       (SELECT count(*) FROM ledger_period_balances WHERE tenant_id='r' AND period_code=:'lastp') AS checkpoint_rows_last_period,
       (SELECT count(*) FROM ledger_period_closes WHERE tenant_id='r') AS closes;
