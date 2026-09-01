-- Spike 024 -- Q1.3. PLAIN EXPLAIN ONLY. No ANALYZE anywhere in this file: the
-- statements are planned and discarded, so nothing here consumes the machine and
-- nothing here is a measurement of speed. Costs shown are the planner's estimates.
\set ON_ERROR_STOP on

\echo '=== the indexes that exist on ledger_entries ==='
SELECT pg_get_indexdef(x.indexrelid) AS def
FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid
JOIN pg_class t ON t.oid = x.indrelid JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname='public' AND t.relname='ledger_entries' ORDER BY i.relname;

\echo
\echo '=== TAIL A, tenant-wide: entries effective in [boundary, as_of) ==='
EXPLAIN SELECT e.account_id, SUM(e.amount_minor)
FROM ledger_entries e
WHERE e.tenant_id='big' AND e.effective_at >= '2026-12-01 00:00+00'
  AND e.effective_at < '2026-12-20 00:00+00' AND e.xact_id < report_cursor()
GROUP BY e.account_id;

\echo '--- ...and with seqscan disabled, to see which index CAN serve it ---'
SET enable_seqscan = off;
EXPLAIN SELECT e.account_id, SUM(e.amount_minor)
FROM ledger_entries e
WHERE e.tenant_id='big' AND e.effective_at >= '2026-12-01 00:00+00'
  AND e.effective_at < '2026-12-20 00:00+00' AND e.xact_id < report_cursor()
GROUP BY e.account_id;
RESET enable_seqscan;

\echo
\echo '=== TAIL B, tenant-wide: entries effective below the boundary, committed above the close cursor ==='
EXPLAIN SELECT e.account_id, SUM(e.amount_minor)
FROM ledger_entries e
WHERE e.tenant_id='big' AND e.effective_at < '2026-12-01 00:00+00'
  AND e.xact_id >= (SELECT computed_at_xid FROM ledger_period_closes
                     WHERE tenant_id='big' AND period_code='2026-11' AND currency='USD')
  AND e.xact_id < report_cursor()
GROUP BY e.account_id;

\echo '--- ...and with seqscan disabled ---'
SET enable_seqscan = off;
EXPLAIN SELECT e.account_id, SUM(e.amount_minor)
FROM ledger_entries e
WHERE e.tenant_id='big' AND e.effective_at < '2026-12-01 00:00+00'
  AND e.xact_id >= (SELECT computed_at_xid FROM ledger_period_closes
                     WHERE tenant_id='big' AND period_code='2026-11' AND currency='USD')
  AND e.xact_id < report_cursor()
GROUP BY e.account_id;
RESET enable_seqscan;

\echo
\echo '=== the SINGLE-ACCOUNT form ADR-0011 §3 measured, for contrast ==='
EXPLAIN SELECT SUM(e.amount_minor) FROM ledger_entries e
WHERE e.tenant_id='big' AND e.account_id = md5('big:recv:1')::uuid
  AND e.effective_at < '2026-12-01 00:00+00'
  AND e.xact_id >= (SELECT computed_at_xid FROM ledger_period_closes
                     WHERE tenant_id='big' AND period_code='2026-11' AND currency='USD')
  AND e.xact_id < report_cursor();

\echo
\echo '=== the two CANDIDATE indexes, created and the same two plans re-taken ==='
CREATE INDEX ix_entries__tenant_effective ON ledger_entries (tenant_id, effective_at, xact_id);
CREATE INDEX ix_entries__tenant_commit    ON ledger_entries (tenant_id, xact_id, effective_at);
ANALYZE ledger_entries;

\echo '--- TAIL A ---'
EXPLAIN SELECT e.account_id, SUM(e.amount_minor)
FROM ledger_entries e
WHERE e.tenant_id='big' AND e.effective_at >= '2026-12-01 00:00+00'
  AND e.effective_at < '2026-12-20 00:00+00' AND e.xact_id < report_cursor()
GROUP BY e.account_id;

\echo '--- TAIL B ---'
EXPLAIN SELECT e.account_id, SUM(e.amount_minor)
FROM ledger_entries e
WHERE e.tenant_id='big' AND e.effective_at < '2026-12-01 00:00+00'
  AND e.xact_id >= (SELECT computed_at_xid FROM ledger_period_closes
                     WHERE tenant_id='big' AND period_code='2026-11' AND currency='USD')
  AND e.xact_id < report_cursor()
GROUP BY e.account_id;

\echo
\echo '=== what those two indexes COST: size against the table and its existing indexes ==='
SELECT i.relname, pg_size_pretty(pg_relation_size(i.oid)) AS size
FROM pg_index x JOIN pg_class i ON i.oid=x.indexrelid JOIN pg_class t ON t.oid=x.indrelid
WHERE t.relname='ledger_entries' ORDER BY pg_relation_size(i.oid) DESC;
SELECT pg_size_pretty(pg_relation_size('ledger_entries')) AS heap,
       pg_size_pretty(pg_indexes_size('ledger_entries'))  AS all_indexes;

\echo
\echo '=== the whole rewritten balance sheet, planned (not run) ==='
EXPLAIN SELECT * FROM balance_sheet_at_ckpt('big', '2027-01-01 00:00+00', report_cursor());
\echo '=== ...and the shipped one, planned ==='
EXPLAIN SELECT * FROM balance_sheet_at('big', '2027-01-01 00:00+00', report_cursor());

\echo
\echo '=== the bounded reconciliation, planned, against the shipped level form ==='
EXPLAIN SELECT count(*) FROM recon_checkpoint_breaks;
EXPLAIN SELECT count(*) FROM recon_checkpoint_breaks_bounded;
