#!/usr/bin/env bash
# Rebuild the scratch database from the shipped artefacts, then seed it.
# Usage: spikes/012-append-only-perimeter/reset.sh [dbname]   (default spike_wsa)
set -euo pipefail
DB="${1:-spike_wsa}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PGPASSWORD=openledger
PSQL="psql -h localhost -p 5433 -U openledger -v ON_ERROR_STOP=1 -q"
$PSQL -d postgres -c "DROP DATABASE IF EXISTS $DB (FORCE);" -c "CREATE DATABASE $DB;"
$PSQL -d "$DB" -f "$ROOT/migrations/00001_baseline.sql"
$PSQL -d "$DB" -f "$ROOT/schema/chart.sql"
$PSQL -d "$DB" -f "$ROOT/spikes/012-append-only-perimeter/00_seed.sql"
echo "$DB rebuilt: $($PSQL -At -d "$DB" -c 'SELECT count(*) FROM ledger_entries') entries."
