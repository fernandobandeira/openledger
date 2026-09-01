-- Is a scoped reader still scoped THROUGH the partitioned parent, and what does a
-- partition addressed DIRECTLY give it? (ADR-0013's read-path control must not be
-- quietly traded away for write throughput.)
\set ON_ERROR_STOP off
\echo '--- as openledger_read scoped to t1, through the parent:'
BEGIN;
SET LOCAL ROLE openledger_read;
SET LOCAL app.tenant_id = 't1';
SELECT tenant_id, count(*) FROM ledger_period_balances GROUP BY 1 ORDER BY 1;
ROLLBACK;

\echo '--- ...and scoped to t2:'
BEGIN;
SET LOCAL ROLE openledger_read;
SET LOCAL app.tenant_id = 't2';
SELECT tenant_id, count(*) FROM ledger_period_balances GROUP BY 1 ORDER BY 1;
ROLLBACK;

\echo '--- ...and with NO app.tenant_id set at all (must fail closed, i.e. zero rows):'
BEGIN;
SET LOCAL ROLE openledger_read;
SELECT count(*) AS rows_when_unscoped FROM ledger_period_balances;
ROLLBACK;

\echo '--- and a PARTITION addressed directly, which carries no policy of its own:'
BEGIN;
SET LOCAL ROLE openledger_read;
SET LOCAL app.tenant_id = 't1';
SELECT count(*) FROM ledger_period_balances_p2026_01;
ROLLBACK;
