-- Q3 -- the reconciliation sweep cost at scale, and its SHAPE in the number of
-- closes. A prior adversary measured recon_checkpoint_breaks as O(entries x closes),
-- not linear. This confirms or refutes it.
--
-- recon_checkpoint_breaks joins EACH close to every entry with
-- effective_at < that close's ends_at. With C closes over a book that grows each
-- period, close k re-scans the whole prefix up to period k, so the total work is
-- SUM_k (entries before period k) ~ O(entries x closes / 2): quadratic in the
-- number of closes on a book whose history grows with them.
--
-- Called by run.sh at milestones (after k closes exist) so the growth is visible.
\set ON_ERROR_STOP on
\timing off

SELECT (SELECT count(*) FROM ledger_period_closes WHERE tenant_id='q') AS closes,
       (SELECT count(*) FROM ledger_entries WHERE tenant_id='q')       AS entries,
       (SELECT count(*) FROM ledger_period_balances WHERE tenant_id='q') AS checkpoint_rows;

\echo '--- recon_checkpoint_breaks (must be 0 on a healthy book), timed x2 ---'
\timing on
SELECT count(*) AS checkpoint_breaks FROM recon_checkpoint_breaks;
SELECT count(*) AS checkpoint_breaks FROM recon_checkpoint_breaks;
\timing off

\echo '--- the whole reconciliation sweep, timed x2 ---'
\timing on
SELECT COALESCE(SUM(breaks),0) AS total_breaks FROM reconciliation;
SELECT COALESCE(SUM(breaks),0) AS total_breaks FROM reconciliation;
\timing off
