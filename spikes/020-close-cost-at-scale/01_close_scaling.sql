-- Q1 -- the close WRITE cost as the account population grows.
--
-- One tenant, one currency (USD), ONE period, :apc customer accounts each with a
-- deposit, plus 1,000 revenue and 1,000 expense postings so the closing-entry loop
-- has temporary balances to zero. Seed under session_replication_role=replica --
-- the data is correct by construction, and this is a SHAPE spike about the CLOSE,
-- not the seed. Then run the close EXACTLY as the write path does it and time it,
-- count the checkpoint rows, and size the two tables the close writes.
--
-- localhost PostgreSQL 18, not a benchmark: the SHAPE (linear? per-currency? what
-- dominates?) is the finding, never the absolute millisecond.
\set ON_ERROR_STOP on
\timing off

INSERT INTO ledger_periods (tenant_id, code, starts_at, ends_at, tz)
VALUES ('t','2026-01','2026-01-01 00:00+00','2026-02-01 00:00+00','UTC');

SET session_replication_role = replica;
SELECT spike_seed('t','USD','2026-01','2026-01-01 00:00+00','2026-02-01 00:00+00', :apc, 1000, 0);
SET session_replication_role = default;

ANALYZE ledger_entries, ledger_transactions, ledger_accounts, ledger_account_balances;

SELECT :apc AS wallets,
       (SELECT count(*) FROM ledger_accounts) AS accounts,
       (SELECT count(*) FROM ledger_entries)  AS entries,
       pg_size_pretty(pg_total_relation_size('ledger_entries')) AS journal_size;

-- what the checkpoint INSERT ... SELECT actually does: the aggregation scan over
-- every entry in the period, and the insert of one row per account. This is the
-- claim ADR-0011 makes -- "one INSERT ... SELECT per currency over every account".
\echo '=== EXPLAIN (ANALYZE, BUFFERS) of the checkpoint aggregation (the dominant term) ==='
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, SUMMARY ON)
SELECT e.account_id,
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'), 0),
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'),0)
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
WHERE e.tenant_id='t' AND e.currency='USD'
  AND e.effective_at < '2026-02-01 00:00+00' AND e.xact_id < report_cursor()
GROUP BY e.account_id;

\echo '=== the close, timed (checkpoint + closing entries, one transaction) ==='
\timing on
SELECT spike_close('t','2026-01','USD') IS NOT NULL AS closed;
\timing off

SELECT spike_attest('t','USD');

SELECT (SELECT count(*) FROM ledger_period_balances) AS checkpoint_rows,
       pg_size_pretty(pg_total_relation_size('ledger_period_balances')) AS checkpoint_size,
       pg_size_pretty(pg_total_relation_size('ledger_period_closes'))   AS closes_size;

\echo '=== the book is clean: reconciliation foots to zero ==='
SELECT COALESCE(SUM(breaks),0) AS total_breaks FROM reconciliation;
