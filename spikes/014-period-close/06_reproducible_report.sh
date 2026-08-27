#!/usr/bin/env bash
# 06 -- An issued statement must re-run identically. Post, issue, backdate, re-issue.
#
# The register's row: "an issued statement cannot be reproduced after any backdated
# posting -- legal, append-only, every check green." Both halves are needed: the
# EFFECTIVE range says which business dates the statement covers, the COMMIT CURSOR says
# what was known when it was issued. Either alone is not enough.
set -euo pipefail
cd "$(dirname "$0")/../.."
. spikes/014-period-close/_session.sh

$PG -q -o /dev/null -c "
  INSERT INTO ledger_periods (tenant_id, code, starts_at, ends_at, tz)
  VALUES ('t1','2026-02', '2026-02-01 00:00+00', '2026-03-01 00:00+00', 'UTC');
  SELECT sp_post('t1','fee','2026-02-15 00:00+00','operating_cash','fee_revenue', 50000);"

$PG -Atqc "SELECT sp_wait_for_cursor()" | sed 's/^/-- /'
C1=$($PG -Atqc "SELECT report_cursor()")
echo "-- ISSUED. The report's identity is its parameters, and they are stored with it:"
echo "--   effective range [2026-02-01, 2026-03-01)   commit cursor $C1"
FEB="SELECT caption, to_char(amount_minor/100.0,'FM999,990.00') AS amount
     FROM income_statement_for('t1','2026-02-01 00:00+00','2026-03-01 00:00+00','$C1'::xid8)
     WHERE amount_minor <> 0"
$PG -c "$FEB"

echo "-- A LATE CLEARING ARRIVES, carrying the network's February business date."
$PG -q -o /dev/null -c "SELECT sp_post('t1','clearing','2026-02-20 00:00+00','operating_cash','fee_revenue', 16600);"

echo "-- AND THE SEAL HOLE: a balanced pair of legs appended to the ALREADY-COMMITTED"
echo "-- February transaction, using nothing but the app role's INSERT grant."
$PG -q -o /dev/null <<'SQL'
INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction, amount_minor,
                            currency, account_seq, effective_at)
SELECT 't1', x.id, sp_acct('t1','operating_cash'), 'debit'::ledger_direction, 50000, 'USD', 900001, x.effective_at
FROM ledger_transactions x WHERE x.kind='fee' AND x.effective_at='2026-02-15 00:00+00'
UNION ALL
SELECT 't1', x.id, sp_acct('t1','fee_revenue'), 'credit'::ledger_direction, 50000, 'USD', 900002, x.effective_at
FROM ledger_transactions x WHERE x.kind='fee' AND x.effective_at='2026-02-15 00:00+00';
SQL

echo "-- RE-ISSUED with the SAME two parameters. Nothing was mutated; two things were added:"
$PG -c "$FEB"
echo "-- ...and the baseline's parameterless view, over the same book:"
$PG -c "SELECT caption, to_char(amount_minor/100.0,'FM999,990.00') AS amount
        FROM income_statement WHERE tenant_id='t1' AND amount_minor <> 0"
echo "-- A NEW report, at a NEW cursor, restates February -- visibly, as a new document:"
$PG -Atqc "SELECT sp_wait_for_cursor()" | sed 's/^/-- /'
$PG -c "SELECT report_cursor() AS cursor_now;"
$PG -c "SELECT caption, to_char(amount_minor/100.0,'FM999,990.00') AS amount
        FROM income_statement_for('t1','2026-02-01 00:00+00','2026-03-01 00:00+00', report_cursor())
        WHERE amount_minor <> 0"
echo "-- and every check the project has is green throughout:"
$PG -c "SELECT (SELECT SUM(CASE WHEN direction='debit' THEN amount_minor ELSE -amount_minor END) FROM ledger_entries)=0 AS balanced,
               (SELECT count(*) FROM ledger_entries) AS entries;"

echo
echo "-- WHY A FUNCTION AND NOT A WHERE CONTRACT ON THE VIEW."
echo "-- A view takes no parameter, and a predicate written outside an AGGREGATING view"
echo "-- applies to its output, where the column it would need does not exist:"
psql -h localhost -p 5433 -U openledger -X -d spike_wsc \
     -c "SELECT * FROM income_statement WHERE effective_at < '2026-03-01'" 2>&1 | head -3 || true
echo "-- ...and the columns it DOES expose cannot carry a date bound:"
psql -h localhost -p 5433 -U openledger -X -d spike_wsc \
     -Atc "SELECT string_agg(attname, ', ' ORDER BY attnum) FROM pg_attribute
           WHERE attrelid='income_statement'::regclass AND attnum > 0"
echo "-- The function form still plans as a single-table index scan -- the SQL-language"
echo "-- SRF is inlined, so the parameters do not cost a plan:"
$PG -c "EXPLAIN (COSTS OFF)
        SELECT * FROM trial_balance_at('t1','2026-02-01+00','2026-03-01+00', report_cursor());" | head -14
