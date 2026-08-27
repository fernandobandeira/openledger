#!/usr/bin/env bash
# 02 -- Reproduce ADR-0006's failure: the same recorded-axis report, the same literal
# instant T, re-run either side of ONE concurrent commit, returns two answers.
#
# Two writers and one slow transaction. That is all it takes. Nothing is backdated,
# nothing is mutated, and every check stays green through both runs.
set -euo pipefail
cd "$(dirname "$0")/../.."
. spikes/014-period-close/_session.sh

$PG -q -o /dev/null -c "SELECT sp_post('t1','fee','2026-02-10 12:00+00','operating_cash','fee_revenue', 11000000);"
echo "-- committed history: 110,000.00 of fee revenue"

# A: a batched posting run. Open, 50,000.00 written, not committed.
session_open "SELECT sp_post('t1','fee','2026-02-11 12:00+00','operating_cash','fee_revenue', 5000000);"

# B: a reporting run that overlaps it, choosing its instant AFTER A wrote its rows.
T=$($PG -Atqc "SELECT clock_timestamp()")
echo "-- writer A is open (asserted, not slept for). Report instant T = $T"

REPORT="SELECT to_char(SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END)/100.0,'FM999,999,990.00') AS revenue_as_recorded
        FROM ledger_entries e
        JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
        JOIN ledger_accounts a ON a.tenant_id=e.tenant_id AND a.id=e.account_id AND a.currency=e.currency
        JOIN account_types t ON t.code=a.purpose
        WHERE t.category='revenue' AND e.recorded_at <= '$T'::timestamptz"
CHECKS="SELECT (SELECT SUM(CASE WHEN direction='debit' THEN amount_minor ELSE -amount_minor END) FROM ledger_entries)=0 AS balanced,
               (SELECT count(*) FROM ledger_account_balances b
                WHERE (b.input - b.output) <> COALESCE((SELECT SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END)
                                                        FROM ledger_entries e
                                                        WHERE e.tenant_id=b.tenant_id AND e.account_id=b.account_id),0)) AS drift_rows"

echo "-- FIRST RUN, while A is still open:"; $PG -c "$REPORT" -c "$CHECKS"
session_commit
echo "-- A committed. SECOND RUN. Same T, same query, nothing backdated:"; $PG -c "$REPORT" -c "$CHECKS"

echo "-- why: recorded_at is now(), which is TRANSACTION-START time --"
$PG -c "SELECT to_char(e.recorded_at,'HH24:MI:SS.US') AS recorded_at,
               to_char(x.recorded_at,'HH24:MI:SS.US') AS txn_recorded_at,
               e.recorded_at <= '$T'::timestamptz AS in_range_of_T, e.xact_id
        FROM ledger_entries e JOIN ledger_transactions x ON x.id=e.transaction_id
        ORDER BY e.recorded_at, e.xact_id;"
