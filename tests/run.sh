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

# `set -o pipefail` above is what actually propagates a psql failure through the
# sed filter. An earlier version also tested ${PIPESTATUS[0]}, which was dead code
# -- PIPESTATUS is rewritten by the next command, so it always read 0, and dropping
# pipefail made a hard-failing test file report PASS. Removed rather than left as a
# safety net that isn't one.
# A MANIFEST, not just a glob. Deleting bitemporal.sql and query_plans.sql left
# the build printing PASS -- a dropped or renamed file is silently no coverage,
# which is the same class of failure as a test that asserts nothing.
EXPECTED_SUITES="bitemporal.sql card_holds.sql golden_trace.sql negative_controls.sql query_plans.sql"
missing=""
for want in $EXPECTED_SUITES; do
    [ -f "tests/$want" ] || missing="$missing $want"
done
# concurrency.sh was outside the manifest AND outside the floor -- the one file
# that cannot be a .sql, and the only one whose body could be replaced with
# `exit 0` while this script still printed PASS. It carries the only evidence for
# four guards that exist solely for concurrency.
[ -x tests/concurrency.sh ] || missing="$missing concurrency.sh"
if [ -n "$missing" ]; then
    echo "── MISSING SUITE(S):$missing"
    echo "FAIL"; exit 1
fi

# ...and a FLOOR on how much each file asserts. The manifest checks existence, not
# content: deleting bitemporal.sql fails the build, and truncating it to zero bytes
# did not. Same class of failure, one keystroke apart.
floor_for() {
    case "$1" in
        *bitemporal.sql)        echo 20 ;;
        *card_holds.sql)        echo 125 ;;
        *golden_trace.sql)      echo 30 ;;
        *negative_controls.sql) echo 110 ;;
        *query_plans.sql)       echo  7 ;;
        *)                      echo  1 ;;
    esac
}

fail=0
for f in tests/*.sql; do
    echo "── $f"
    out=$(psql "$URL" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1) || fail=1
    echo "$out" | sed 's/^psql:[^ ]* //;s/^NOTICE:  //;s/^/   /'
    # psql prefixes diagnostics with "psql:<file>:<line>: " -- the same trap that
    # made concurrency.sh's error counter permanently zero.
    n=$(echo "$out" | grep -cE '(^|: )NOTICE:  +(ok|refused)') || true
    floor=$(floor_for "$f")
    if [ "$n" -lt "$floor" ]; then
        echo "   FAIL $f made $n assertions, below its floor of $floor"
        fail=1
    fi
    # ...AND the file must have run to its last line. The floor counts OUTPUT, not
    # assertions: prepending a loop that raises N fake `ok` notices and then a
    # backslash-q satisfied the manifest, the floor and the build -- for all five
    # files. Truncation with noise is one keystroke past the truncation the floor
    # was written to catch, and a sentinel on the last line is what tells them apart.
    base=$(basename "$f" .sql)
    if ! echo "$out" | grep -q "SUITE-COMPLETE $base"; then
        echo "   FAIL $f did not run to its last line -- no completion sentinel"
        fail=1
    fi
done

# The concurrency suite needs many sessions, so it cannot be a .sql file.
echo "── tests/concurrency.sh"
cout=$(./tests/concurrency.sh "$URL" 2>&1) || fail=1
echo "$cout"
cn=$(echo "$cout" | grep -cE '^ +ok  ') || true
if [ "$cn" -lt 34 ]; then
    echo "   FAIL tests/concurrency.sh made $cn assertions, below its floor of 34"
    fail=1
fi
if ! echo "$cout" | grep -q "SUITE-COMPLETE concurrency"; then
    echo "   FAIL tests/concurrency.sh did not run to its last line"
    fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
