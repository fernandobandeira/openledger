#!/usr/bin/env bash
# Spike 013 -- the whole run, from an empty server.
#
#   ./run.sh            the correctness run: seed, negative control, five drifts
#   ./run.sh scale      ...and the cost run at 100,000 and 1,000,000 entries
#
# Nothing here is product. The views in 01_views.sql are the proposed artefact;
# everything else exists to seed a book, break it in one specific way, show which
# view catches it, and roll back.
set -euo pipefail
cd "$(dirname "$0")"
export PGPASSWORD=openledger
HOST="-h localhost -p 5433 -U openledger"
ROOT=../..

psql $HOST -d postgres -qc "DROP DATABASE IF EXISTS spike_wsb;" -qc "CREATE DATABASE spike_wsb;"
for f in $ROOT/migrations/00001_baseline.sql $ROOT/schema/chart.sql \
         00_mirror_column.sql 01_views.sql 02_seed_clean.sql; do
    psql $HOST -d spike_wsb -q -v ON_ERROR_STOP=1 -f "$f" > /dev/null
done
echo "loaded: baseline + chart + proposed mirror column + 7 views + a clean book"

for f in 03_negative_control.sql 04_drift_cache.sql 05_drift_sequence.sql \
         06_drift_orphans.sql 07_drift_unbalanced.sql 08_drift_scope.sql \
         09_pending_bridge.sql; do
    echo; echo "################ $f"
    psql $HOST -d spike_wsb -q -f "$f"
done

echo; echo "################ 12_snapshot.sh"
./12_snapshot.sh

echo; echo "################ 03_negative_control.sql, again -- everything above rolled back"
psql $HOST -d spike_wsb -q -f 03_negative_control.sql

[ "${1:-}" = "scale" ] || exit 0

for n in 50000 500000; do
    echo; echo "################ scale: $((n * 2)) entries"
    psql $HOST -d postgres -qc "DROP DATABASE IF EXISTS spike_wsb_scale;" \
                           -qc "CREATE DATABASE spike_wsb_scale;"
    for f in $ROOT/migrations/00001_baseline.sql $ROOT/schema/chart.sql \
             00_mirror_column.sql 01_views.sql; do
        psql $HOST -d spike_wsb_scale -q -v ON_ERROR_STOP=1 -f "$f" > /dev/null
    done
    psql $HOST -d spike_wsb_scale -q -v ON_ERROR_STOP=1 -v txns=$n -f 10_scale_seed.sql
    psql $HOST -d spike_wsb_scale -q -f 11_scale_measure.sql 2>&1 \
        | grep -E "^(===|Time)" | awk '/===/{n=$0} /Time/{print n"  "$2}'
    echo "--- the whole sweep, serial (max_parallel_workers_per_gather = 0)"
    for i in 1 2 3; do
        psql $HOST -d spike_wsb_scale -q -c "SET max_parallel_workers_per_gather=0;" \
             -c "\timing on" -c "SELECT count(*) FROM reconciliation;" 2>&1 | grep -E "Time|ERROR"
    done
    ./13_sweep_cost.sh
done
