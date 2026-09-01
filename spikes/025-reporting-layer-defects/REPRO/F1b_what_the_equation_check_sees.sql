-- F1, part 3 -- BOUNDING the finding: what recon_equation_breaks CAN still catch.
--
-- Runs after F1_equation_identity.sql, on the same book and the same chart
-- version 4. It appends the one shape the check demonstrably sees -- a
-- transaction that does not foot -- and states the class that follows from the
-- algebra: gap_minor is the sum of every presented position, so the only way to
-- move it is to remove a position from that sum or to put one in that has no
-- opposite. Both are journal-level, not presentation-level.
\set ON_ERROR_STOP off

\echo '=== A. one posted leg with no opposite -- the class the shipped suite tests'
\echo '--- (crates/e2e/tests/e2e/reconcile.rs: a_single_posted_leg_breaks_the_equation'
\echo '---  _and_the_transaction_check -- whose own doc comment says the equation check'
\echo '---  exists for presentation bugs "which live in the statement functions this'
\echo '---  suite cannot honestly mutate")'
INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                           idempotency_hash, payload, effective_at)
VALUES ('t1','02500000-0000-7000-8000-000000000001','fee','internal','f1b-single-leg',
        decode('00','hex'),'{}'::jsonb,'2026-08-27T13:00:00Z');
INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
VALUES ('t1','02500000-0000-7000-8000-000000000002',
        '02500000-0000-7000-8000-000000000001','fee','posted','2026-08-27T13:00:00Z');
INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, account_seq, effective_at)
SELECT 't1','02500000-0000-7000-8000-000000000002', a.id, 'credit', 250, 'USD', 2,
       '2026-08-27T13:00:00Z'
FROM ledger_accounts a WHERE a.tenant_id='t1' AND a.purpose='fee_revenue';
UPDATE ledger_account_balances b SET output = b.output + 250, last_seq = 2
FROM ledger_accounts a
WHERE a.tenant_id=b.tenant_id AND a.id=b.account_id AND a.currency=b.currency
  AND b.tenant_id='t1' AND a.purpose='fee_revenue';

\echo '--- wait for the cluster horizon to retire the new leg, then read'
DO $$ BEGIN
  FOR i IN 1..600 LOOP
    EXIT WHEN (SELECT coalesce(max(xact_id) <= pg_snapshot_xmin(pg_current_snapshot()), true)
               FROM ledger_entries);
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;

SELECT * FROM recon_equation_breaks(report_cursor(),'infinity');
SELECT * FROM reconciliation;

\echo
\echo '=== B. the identity, evaluated directly: gap IS the journal imbalance'
\echo '--- the sum of every posted, presented, in-scope position at this cursor'
WITH cv AS (SELECT max(version) AS v FROM chart_versions)
SELECT e.tenant_id, e.currency,
       SUM(CASE WHEN e.direction='debit' THEN e.amount_minor::numeric
                ELSE -e.amount_minor::numeric END) AS sum_of_every_presented_position
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id
                          AND x.status='posted'
JOIN ledger_accounts a ON a.tenant_id=e.tenant_id AND a.id=e.account_id
                      AND a.currency=e.currency
CROSS JOIN cv
JOIN chart_presentation p ON p.chart_version=cv.v AND p.type_code=a.purpose
WHERE e.xact_id < report_cursor()
GROUP BY e.tenant_id, e.currency ORDER BY 1,2;
