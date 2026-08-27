#!/usr/bin/env bash
# 02_run.sh -- drive 02_isolation_contention.sql at K concurrent writers, over the
# cross product of {read committed, repeatable read, serializable} x {none, inline,
# restart}. Every writer hits the SAME balance row, which is the case ADR-0002 says
# is the whole ceiling.
#
#   ./02_run.sh [workers] [postings-per-worker]
set -euo pipefail

W="${1:-8}"
N="${2:-200}"
: "${PGHOST:=localhost}" "${PGPORT:=5433}" "${PGUSER:=openledger}" "${PGDATABASE:=spike_wse}"
export PGHOST PGPORT PGUSER PGDATABASE
export PGPASSWORD="${PGPASSWORD:-openledger}"

psql -X -q -c 'DROP TABLE IF EXISTS wse_bench_results;'
psql -X -q -f "$(dirname "$0")/02_isolation_contention.sql"
psql -X -q -c "TRUNCATE wse_bench_results;"

for iso in 'read committed' 'repeatable read' 'serializable'; do
  for strat in none inline restart; do
    label="$iso/$strat"
    psql -X -q -c "UPDATE ledger_account_balances SET input=0, output=0, last_seq=0
                    WHERE tenant_id='t2' AND account_id='22222222-0000-0000-0000-000000000001';"
    for w in $(seq 1 "$W"); do
      psql -X -q -v ON_ERROR_STOP=0 \
        -c "SET default_transaction_isolation = '$iso';" \
        -c "CALL wse_bench('$label', '$strat', $w, $N);" >/dev/null 2>&1 &
    done
    wait
  done
done

psql -X -c "
SELECT run_label AS \"isolation / retry\",
       sum(postings)                          AS postings,
       sum(committed)                         AS committed,
       sum(postings) - sum(committed)         AS lost,
       round(100.0 * (sum(postings)-sum(committed)) / sum(postings), 1) AS \"lost %\",
       sum(serfails)                          AS \"40001s\",
       sum(rescued)                           AS \"rescued by retry\",
       round(sum(attempts)::numeric / nullif(sum(committed),0), 2) AS \"attempts/commit\",
       round(1000.0 * sum(committed) / max(elapsed_ms), 0)         AS \"upserts/s\"
FROM wse_bench_results GROUP BY run_label ORDER BY run_label;"

psql -X -c "
SELECT 'ledger_account_balances.last_seq after the last run' AS check, last_seq
FROM ledger_account_balances
WHERE tenant_id='t2' AND account_id='22222222-0000-0000-0000-000000000001';"
