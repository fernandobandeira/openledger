#!/usr/bin/env bash
# 08_run.sh -- drive 08_striping_bench.sql. K writers, all on one logical account,
# spread over {1, 8, 64} stripes with worker affinity.
#   ./08_run.sh [workers] [postings-per-worker]
set -euo pipefail
cd "$(dirname "$0")"
W="${1:-16}"; N="${2:-400}"
: "${PGHOST:=localhost}" "${PGPORT:=5433}" "${PGUSER:=openledger}" "${PGDATABASE:=spike_wse}"
export PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD="${PGPASSWORD:-openledger}"

psql -X -q -c 'DROP TABLE IF EXISTS wse_stripe_results;'
psql -X -q -f 08_striping_bench.sql

for s in 1 8 64; do
  for w in $(seq 1 "$W"); do
    psql -X -q -c "CALL wse_stripe_bench($s, $w, $N);" >/dev/null 2>&1 &
  done
  wait
done

psql -X -c "
SELECT stripes,
       sum(postings)                                        AS postings,
       max(elapsed_ms)                                      AS wall_ms,
       round(1000.0 * sum(postings) / max(elapsed_ms), 0)   AS \"upserts/s\",
       round((1000.0 * sum(postings) / max(elapsed_ms)) /
             (SELECT 1000.0 * sum(postings) / max(elapsed_ms)
                FROM wse_stripe_results WHERE stripes = 1), 2) AS \"vs unstriped\"
FROM wse_stripe_results GROUP BY stripes ORDER BY stripes;"

psql -X -c "
SELECT 1  AS stripes_summed, wse_time_balance_read(1,  20000) AS \"balance read µs\"
UNION ALL SELECT 8,  wse_time_balance_read(8,  20000)
UNION ALL SELECT 64, wse_time_balance_read(64, 20000);"
