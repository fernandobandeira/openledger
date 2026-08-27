#!/usr/bin/env bash
# Spike 014 -- period close, report parameters and the two time axes.
# Rebuilds spike_wsc from the repository's own schema and runs every experiment.
#
#   ./spikes/014-period-close/run.sh          # everything
#   ./spikes/014-period-close/run.sh 03       # one step
#
# PostgreSQL 18 at localhost:5433. Never touches the `openledger` database.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PGPASSWORD=openledger
PG="psql -h localhost -p 5433 -U openledger -X -v ON_ERROR_STOP=1"
DB=spike_wsc

reset() {
  $PG -d postgres -q -c "DROP DATABASE IF EXISTS $DB WITH (FORCE);" -c "CREATE DATABASE $DB;"
  $PG -d $DB -q -f migrations/00001_baseline.sql   > /dev/null
  $PG -d $DB -q -f schema/chart.sql                > /dev/null
  $PG -d $DB -q -f spikes/014-period-close/00_overlay.sql > /dev/null
  $PG -d $DB -q -f spikes/014-period-close/01_book.sql    > /dev/null
  echo "-- spike_wsc rebuilt: baseline + chart + proposed overlay + posting helper"
}

only="${1:-}"
# EVERY STEP RUNS ON A FRESH DATABASE. The experiments contradict each other on purpose
# -- 04 declares calendar-year periods and 05 declares quarterly ones over the same
# tenant, which ex_periods__no_overlap correctly refuses -- so each file must be
# reproducible on its own rather than as part of a sequence.
run() { # run <nn> <file> ; a .sh step drives its own sessions
  [[ -n "$only" && "$only" != "$1" ]] && return 0
  echo; echo "=============================================================== $2"
  reset
  case "$2" in
    *.sh)  bash "spikes/014-period-close/$2" ;;
    *)     $PG -d $DB -f "spikes/014-period-close/$2" ;;
  esac
}

run 02 02_cursor_instability.sh
run 03 03_cursor_stable.sh
run 04 04_period_close.sql
run 05 05_checkpoint_cost.sql
run 06 06_reproducible_report.sh
run 07 07_timezone.sql
