#!/usr/bin/env bash
# Spike 013 -- chart-of-accounts governance. Runs end to end against a scratch
# database and prints every number in site/content/spikes/013-chart-governance.md.
#
#   ./run.sh            # uses spike_wsd
#   DB=foo ./run.sh
#
# Recreates the database from migrations/00001_baseline.sql every time. It never
# touches `openledger`, and nothing here ships (ADR-0007: validation code must not
# become the product).
set -euo pipefail

DB=${DB:-spike_wsd}
HOST=${PGHOST:-localhost}; PORT=${PGPORT:-5433}; USER=${PGUSER:-openledger}
export PGPASSWORD=${PGPASSWORD:-openledger}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
psql() { command psql -h "$HOST" -p "$PORT" -U "$USER" "$@"; }

echo "== recreating $DB from $ROOT/migrations/00001_baseline.sql"
psql -d postgres -q -c "DROP DATABASE IF EXISTS $DB WITH (FORCE);" -c "CREATE DATABASE $DB;"
psql -d "$DB" -q -v ON_ERROR_STOP=1 -f "$ROOT/migrations/00001_baseline.sql"
psql -d "$DB" -q -v ON_ERROR_STOP=1 -f "$ROOT/schema/chart.sql"

echo "== 00 fixture"
psql -d "$DB" -q -v ON_ERROR_STOP=1 -f "$(dirname "$0")/00_fixture.sql"
echo "== 10 reproductions against the shipped baseline"
psql -d "$DB" -f "$(dirname "$0")/10_repro_baseline.sql"
echo "== 20/21/22/30 proposed DDL"
for f in 20_versioned_chart 21_scope_and_perimeter 22_chart_v1 30_reports; do
  psql -d "$DB" -q -v ON_ERROR_STOP=1 -f "$(dirname "$0")/$f.sql"
done
echo "== 40 verification"
psql -d "$DB" -f "$(dirname "$0")/40_verify.sql"
echo "== 50 IAS 1.41"
psql -d "$DB" -f "$(dirname "$0")/50_ias1_41.sql"
