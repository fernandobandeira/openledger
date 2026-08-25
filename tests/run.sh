#!/usr/bin/env bash
# Builds a throwaway database, applies every migration plus the card chart, and
# runs the SQL test files against it. A fresh database each time is not fastidious:
# the invariant suite asserts on GLOBAL state (drift, the equation over all
# scopes), so leftovers from a previous run change the answers.
set -euo pipefail
cd "$(dirname "$0")/.."

ADMIN="${ADMIN_URL:-postgres://openledger:openledger@localhost:5433/postgres?sslmode=disable}"
DB="ol_test_$$"
BASE="${ADMIN%/postgres*}"

cleanup() { psql "$ADMIN" -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1 || true; }
trap cleanup EXIT

psql "$ADMIN" -v ON_ERROR_STOP=1 -q -c "CREATE DATABASE $DB"
URL="$BASE/$DB?sslmode=disable"

for f in migrations/*.sql migrations/seed/*.sql; do
    psql "$URL" -v ON_ERROR_STOP=1 -q -f "$f"
done

fail=0
for f in tests/*.sql; do
    echo "── $f"
    if psql "$URL" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1 | sed 's/^psql:[^ ]* //;s/^NOTICE:  //;s/^/   /'; then :; else fail=1; fi
    [ "${PIPESTATUS[0]:-0}" -ne 0 ] && fail=1
done

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
