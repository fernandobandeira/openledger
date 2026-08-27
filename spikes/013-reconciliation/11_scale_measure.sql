-- Time the sweep. Five runs of each view; the first is discarded as the cold one.
--
-- The whole sweep is ONE transaction at REPEATABLE READ, which is how it must be
-- run and not merely how it is convenient to measure: six views read the journal
-- separately, and under READ COMMITTED each takes its own snapshot, so a break
-- reported by the summary can be absent from the list that enumerates it. That is
-- demonstrated in 12_snapshot.sql. It is safe here in a way it is not on the write
-- path -- ADR-0002's serialization failures come from `ON CONFLICT DO UPDATE`, and
-- this transaction writes nothing.

\timing on
\pset footer off

SELECT count(*) AS entries FROM ledger_entries;
SHOW work_mem;

BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;

\echo '=== recon_balance_breaks'
SELECT count(*) FROM recon_balance_breaks \watch c=5

\echo '=== recon_entry_breaks'
SELECT count(*) FROM recon_entry_breaks \watch c=5

\echo '=== recon_transaction_breaks'
SELECT count(*) FROM recon_transaction_breaks \watch c=5

\echo '=== recon_scope_breaks'
SELECT count(*) FROM recon_scope_breaks \watch c=5

\echo '=== recon_journal_to_reports'
SELECT count(*) FROM recon_journal_to_reports \watch c=5

-- ...and this one is NOT count(*), because count(*) does not measure it. Both of
-- the bridge's LEFT JOINs are on keys the right side is provably unique on -- a
-- primary key and a GROUP BY -- so the planner removes them when nothing selects
-- their columns. Measured: 21 ms with them removed against 259 ms with them, at
-- 1,000,000 entries. A count(*) over a view is not a measurement of the view.
\echo '=== recon_pending_bridge'
SELECT count(*) FROM recon_pending_bridge WHERE NOT reconciles \watch c=5

\echo '=== the whole sweep, as an operator runs it'
SELECT * FROM reconciliation \watch c=5

COMMIT;
