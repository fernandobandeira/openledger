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

# THE EMPTY DATABASE IS ITSELF A TEST, and it can only be run here. Both report
# functions must REFUSE to report on a ledger with no accounts: zero rows means
# `bool_and(balanced)` is NULL, and a report that printed nothing at all reads as a
# report that found nothing wrong. No suite file can check this -- each one creates
# accounts in order to have something to break.
# ...and it must fail for the RIGHT REASON. Testing only the exit status meant a
# function that did not exist, or one with a syntax error, counted as "refused".
for fn in "accounting_equation()" "balance_sheet_balances()"; do
    why=$(psql "$URL" -qAt -c "SELECT count(*) FROM $fn" 2>&1) && why=""
    case "$why" in
        *"no accounts exist"*) : ;;
        "")  echo "── empty-ledger guard"
             echo "   FAIL $fn reported on a ledger with no accounts instead of refusing"
             echo "FAIL"; exit 1 ;;
        *)   echo "── empty-ledger guard"
             echo "   FAIL $fn failed, but not as the empty-ledger guard: $why"
             echo "FAIL"; exit 1 ;;
    esac
done
echo "── empty-ledger guard"
echo "   ok  both report functions refuse a ledger with no accounts"

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
#
# THE FLOOR AND THE SENTINEL ARE BOTH FORGEABLE BY THE FILE THEY POLICE, and an
# audit proved it: card_holds.sql -- 1,146 lines, the sole evidence for the entire
# hold flow -- was replaced by FIVE LINES that raise 160 notices in a loop and then
# print the sentinel, and this script said PASS. Every guard here reads output the
# file prints about itself.
#
# `sites_for` is the guard that reads something the file cannot cheaply fake: how
# many assertion CALL SITES its source actually contains. A stub that prints 160
# `ok` lines from one loop has two. To forge this you have to write the
# assertions, at which point you have written the test.
#
# COMMENTS ARE STRIPPED FIRST, because they are not call sites. Counting raw
# grep matches meant a file of 200 lines reading `-- must_fail(  fake site` and
# one loop raising 200 notices satisfied the manifest, both floors and the
# sentinel: 1,756 lines of controls replaced by 204 lines of nothing, build green.
sites_for() {
    case "$1" in
        *.sh) grep -v '^[[:space:]]*#' "$1" | grep -cE 'chk "|echo "   ok' ;;
        *)    grep -v '^[[:space:]]*--' "$1" \
                | grep -cE "must_fail\(|SELECT eq\(|SELECT eqv\(|no_drift\(|expect_state\(|plan_uses\(|on_origin\(|RAISE NOTICE 'ok" ;;
    esac
}
# EXACT, not slack. Seven assertions of headroom on negative_controls.sql was
# exactly enough to delete the last 88 lines -- the three most recently added
# controls -- re-emit the sentinel, and walk a live mutant back in with the build
# green. A floor with room in it is room to delete the newest thing you learned.
# These numbers are what the suite emits today; adding assertions means raising
# them, which is the point.
floor_for() {
    case "$1" in
        *bitemporal.sql)        echo 23 ;;
        *card_holds.sql)        echo 164 ;;
        *golden_trace.sql)      echo 35 ;;
        *negative_controls.sql) echo 139 ;;
        *query_plans.sql)       echo  9 ;;
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
    sites=$(sites_for "$f")
    if [ "$sites" -lt "$floor" ]; then
        echo "   FAIL $f contains $sites assertion call sites, below its floor of $floor"
        echo "        -- output can be printed in a loop; call sites have to be written"
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
if [ "$cn" -lt 50 ]; then
    echo "   FAIL tests/concurrency.sh made $cn assertions, below its floor of 50"
    fail=1
fi
csites=$(sites_for tests/concurrency.sh)
if [ "$csites" -lt 50 ]; then
    echo "   FAIL tests/concurrency.sh contains $csites assertion call sites, below 50"
    fail=1
fi
if ! echo "$cout" | grep -q "SUITE-COMPLETE concurrency"; then
    echo "   FAIL tests/concurrency.sh did not run to its last line"
    fail=1
fi

# ...and finally, a verdict from OUTSIDE the suite. Everything above counts what
# the suite says about itself; canary.sh breaks the schema on purpose and requires
# the suite to notice. See its header for what that is worth.
echo "── tests/canary.sh"
if ! ./tests/canary.sh "$ADMIN"; then fail=1; fi

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
