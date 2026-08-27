#!/usr/bin/env bash
# WHAT THE SWEEP COSTS THE REST OF THE DATABASE WHILE IT RUNS.
#
# Two questions a background sweep has to answer before it is allowed to be a
# background sweep: does it block writers, and what does holding one snapshot for
# its whole duration cost.
#
# Run against spike_wsb_scale (10_scale_seed.sql).
set -euo pipefail
export PGPASSWORD=openledger
PSQL="psql -h localhost -p 5433 -U openledger -d spike_wsb_scale -q"

$PSQL -c "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;" \
      -c "SELECT count(*) FROM reconciliation;" \
      -c "SELECT pg_sleep(3);" -c "COMMIT;" >/dev/null &
SWEEP=$!

$PSQL -c "SELECT pg_sleep(1.2);" >/dev/null
echo "=== locks held by the sweep, while it runs"
$PSQL -c "SELECT DISTINCT l.relation::regclass AS obj, l.mode
            FROM pg_locks l JOIN pg_stat_activity a USING (pid)
           WHERE a.datname = 'spike_wsb_scale' AND a.pid <> pg_backend_pid()
             AND l.locktype = 'relation' AND l.relation::regclass::text NOT LIKE 'pg_%'
           ORDER BY 1;"

echo "=== and the transaction horizon it pins while it does"
$PSQL -c "SELECT a.state, a.backend_xmin,
                 pg_snapshot_xmin(pg_current_snapshot()) AS global_xmin,
                 now() - a.xact_start AS held_for
            FROM pg_stat_activity a
           WHERE a.backend_xmin IS NOT NULL AND a.pid <> pg_backend_pid();"

wait $SWEEP
echo "=== after it commits"
$PSQL -c "SELECT count(*) AS backends_pinning_xmin FROM pg_stat_activity
           WHERE backend_xmin IS NOT NULL AND pid <> pg_backend_pid();"
