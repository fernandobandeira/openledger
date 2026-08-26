#!/usr/bin/env bash
# WHAT THESE GUARDS ARE FOR, AND WHAT THEY ARE NOT.
#
# Seven rounds of adversarial review have each found a way to make this script
# print PASS over a suite that proves nothing, and each fix added a guard that
# reads something the thing it polices controls: the floor reads output the file
# prints, the call-site count reads the file's own source, the sentinel reads a
# string the file emits, and the canary reads whether a suite the file could
# recognise went red. Every one of those was then forged in the next round, with
# between one and five lines.
#
# So state the threat model rather than pretending the ladder ends. **These guards
# defend against EROSION -- a control quietly deleted, a helper weakened, a file
# truncated, a floor with slack in it -- and they do not defend against a
# determined author.** Nothing checked into a repository can: whoever edits the
# tests can edit the thing that checks the tests. The durable answers are outside
# this file: review, and CI running a pinned configuration the branch cannot edit.
#
# **`.github/workflows/test.yml` now exists**, which is the durable answer named
# above and the reason most of what follows is a second choice rather than the
# defence. A branch cannot edit its way past a check that runs from the default
# branch's definition on a machine the author does not control. An over-engineering
# review put it plainly: eight rounds produced nine layers of a defence this file
# documents as ineffective, in place of twenty lines of YAML that work.
#
# The one guard in this tree that a test file CANNOT forge is not in this file at
# all. `assert_type_matches_fs_line` in migrations/0002 refused two mutants at
# SEED time -- the wrong chart could not be loaded, so the wrong system could not
# be built, and no test had to notice. That is the shape worth generalising:
# prefer a constraint that makes a state unreachable over a check that looks for
# it afterwards. Every guard below is a second choice.
# Builds a throwaway database, applies every migration plus the card chart, and
# runs the SQL test files against it. A fresh database each time is not fastidious:
# the invariant suite asserts on GLOBAL state (drift, the equation over all
# scopes), so leftovers from a previous run change the answers.
set -euo pipefail
cd "$(dirname "$0")/.."

ADMIN="${ADMIN_URL:-postgres://openledger:openledger@localhost:5433/postgres?sslmode=disable}"
DB="ol_test_$$"
BASE="${ADMIN%/postgres*}"

# WITH (FORCE), because a plain DROP fails while any session is still attached and
# the `|| true` swallowed it. `timeout --foreground` does not reap grandchildren --
# it is documented not to -- so a suite killed on timeout leaves concurrency.sh's
# backgrounded psql sessions alive, holding this database open, and the drop then
# silently did nothing: one leaked database per timed-out run, accumulating.
cleanup() { psql "$ADMIN" -q -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null 2>&1 || true; }

# ...AND THIS SCRIPT MUST REACH ITS OWN LAST LINE. Every suite is required to emit a
# completion sentinel; the file that requires it had none, and it needed one: under
# `set -euo pipefail` a bare failing `x=$(...)` ended the run silently, so a red
# concurrency suite printed a header and nothing else -- no diagnosis, no floor, no
# sentinel, no verdict. Three separate rounds have now put a defect in these same
# two statements. A verdict that never printed is not a pass, and this is the only
# check that can say so about the checker.
VERDICT_REACHED=0
trap 'rc=$?
      if [ "$VERDICT_REACHED" != 1 ]; then
          echo "── tests/run.sh EXITED EARLY (rc=$rc) WITHOUT PRINTING A VERDICT."
          echo "   Everything after the failing step was skipped, including the"
          echo "   diagnosis. Treat this as FAIL."
          echo "FAIL"
      fi
      cleanup
      [ "$VERDICT_REACHED" = 1 ] || exit 1
      exit $rc' EXIT

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
# ...AND THE COMMITTED FIXTURE, in a psql invocation of its own, which is the
# entire reason it is a separate file: `recorded_at` is `now()`, i.e. transaction
# START time, so nothing a suite writes can carry a recorded_at earlier than the
# suite itself. It runs AFTER the empty-ledger pre-check above, which needs an
# empty ledger, and BEFORE any suite.
psql "$URL" -v ON_ERROR_STOP=1 -q -f tests/fixtures/recorded_axis.sql
# ...and tests/fixtures/ is a CLOSED SET for the same reason tests/ is: every file
# in it is applied with full privileges before the suites run, so an extra one
# could CREATE OR REPLACE a broken function back to correct in the database.
EXPECTED_FIXTURES="recorded_axis.sql"
for f in tests/fixtures/*.sql; do
    b=$(basename "$f")
    case " $EXPECTED_FIXTURES " in
        *" $b "*) ;;
        *) echo "── UNEXPECTED FILE IN tests/fixtures/: $b"; echo "FAIL"; exit 1 ;;
    esac
done

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
# ...and canary.sh, which was added BECAUSE the helpers inside a suite are
# forgeable -- and was then left outside every guard this script applies to the
# files it distrusts. `exit 0` in it printed PASS, which is verbatim the defect
# fixed one file above for concurrency.sh. The outermost oracle needs the same
# floor, sentinel and call-site count as everything else.
[ -x tests/canary.sh ] || missing="$missing canary.sh"
if [ -n "$missing" ]; then
    echo "── MISSING SUITE(S):$missing"
    echo "FAIL"; exit 1
fi
# ...AND THE MANIFEST IS A CLOSED SET, not a whitelist. `tests/*.sql` is applied in
# shell glob order, so a file sorting before the real ones -- `aaa_fixture.sql` --
# runs first with full privileges and can `CREATE OR REPLACE` a deliberately broken
# function back to correct IN THE DATABASE before any suite reads it. One new file
# plus one migration edit shipped a live defect with the build green, and the
# canary never noticed, because it does not run the extra file.
unexpected=""
for f in tests/*.sql; do
    b=$(basename "$f")
    case " $EXPECTED_SUITES " in
        *" $b "*) ;;
        *) unexpected="$unexpected $b" ;;
    esac
done
if [ -n "$unexpected" ]; then
    echo "── UNEXPECTED FILE(S) IN tests/:$unexpected"
    echo "   Every .sql in tests/ is applied, in glob order, with the same privileges"
    echo "   as the suites. Add it to EXPECTED_SUITES or remove it."
    echo "FAIL"; exit 1
fi
# ...and canary.sh must define its two drivers exactly once each. Appending one
# line -- `canary () { echo "   ok  canary ..."; }` -- reproduced the genuine
# output byte for byte and satisfied the call-site floor.
if [ "$(grep -cE '^canary(_sh)?\(\) \{' tests/canary.sh)" -ne 2 ] \
   || [ "$(grep -cE '^[[:space:]]*canary(_sh)?[[:space:]]*\(\)' tests/canary.sh)" -ne 2 ]; then
    echo "── tests/canary.sh must define canary() and canary_sh() exactly once each"
    echo "   Redefining either one shadows the oracle with an echo."
    echo "FAIL"; exit 1
fi

# ...and a FLOOR on how much each file asserts. The manifest checks existence, not
# content: deleting bitemporal.sql fails the build, and truncating it to zero bytes
# did not. Same class of failure, one keystroke apart.
#
# THE FLOOR AND THE SENTINEL ARE BOTH FORGEABLE BY THE FILE THEY POLICE, and an
# audit proved it twice: card_holds.sql -- the sole evidence for the entire hold
# flow -- was replaced by FIVE LINES that raise 160 notices in a loop and then print
# the sentinel, and this script said PASS; later the same was done to bitemporal.sql
# in FOUR lines, and only tests/canary.sh caught it. Every guard here reads output
# the file prints about itself. (This comment used to quote the file's line count.
# It was stale by five hundred lines. Counts of things that grow do not belong in
# prose beside them.)
#
# THE CALL-SITE FLOOR IS GONE, and this is why rather than a silent deletion.
# It reused the OUTPUT floors as its own thresholds, and those are exact only
# against emitted output: card_holds.sql carried thirty more call sites than its
# floor -- four times the seven the comment below says was already enough to gut a
# suite. Demonstrated by a reviewer: 255 lines deleted,
# sixteen named controls with them, and this script printed PASS.
#
# It is not repaired, because tests/canary.sh now covers all six suites and
# requires each to fail with its OWN control's message, which a truncated suite
# cannot produce. The floor, the call-site count and the sentinel were three
# approximations of that one check, each added when an adversary defeated the
# previous. The output floor and the sentinel stay -- cheap, and a truncated file
# is exactly the erosion they catch. The approximation with slack in it goes.
# EXACT, not slack. Seven assertions of headroom on negative_controls.sql was
# exactly enough to delete the last 88 lines -- the three most recently added
# controls -- re-emit the sentinel, and walk a live mutant back in with the build
# green. A floor with room in it is room to delete the newest thing you learned.
# These numbers are what the suite emits today; adding assertions means raising
# them, which is the point.
floor_for() {
    case "$1" in
        *bitemporal.sql)        echo 24 ;;
        *card_holds.sql)        echo 222 ;;
        *golden_trace.sql)      echo 41 ;;
        *negative_controls.sql) echo 177 ;;
        *query_plans.sql)       echo 11 ;;
        *)                      echo  1 ;;
    esac
}

fail=0
for f in tests/*.sql; do
    echo "── $f"
    # A TIMEOUT ON EVERY SUITE, WITH --kill-after AND --foreground. Every other forgery mode here is guarded and a
    # HANG was not: a workload that blocked on a named pipe whose reader had died
    # left the build running for sixteen minutes with nothing waiting on a lock.
    # An infinite CI job is worse than a red one -- it looks like progress.
    out=$(timeout --foreground --kill-after=30 300 psql "$URL" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1) || fail=1
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
# `|| crc=$?`, NOT `; crc=$?`. Two rules collide here and the file has now been
# wrong under both. `cmd || fail=1` runs an assignment, and that assignment rewrites
# PIPESTATUS -- so the `${PIPESTATUS[0]} = 124` test that used to live here always
# read 0. Moving the capture to its own line fixed that and broke something worse:
# `set -euo pipefail` is on (line 36), and a bare failing command substitution
# assignment ABORTS THE SCRIPT -- so on a red concurrency run nothing below ran: not
# the timeout message, not `echo "$cout"` (the diagnosis itself), not the floor, not
# the sentinel, not the final FAIL. `x=$(...) || rc=$?` is the one form that both
# survives `set -e` and carries the real exit status.
crc=0
cout=$(timeout --foreground --kill-after=30 600 ./tests/concurrency.sh "$URL" 2>&1) || crc=$?
[ "$crc" = 0 ] || fail=1
if [ "$crc" = 124 ] || [ "$crc" = 137 ]; then echo "   FAIL tests/concurrency.sh timed out"; fail=1; fi
echo "$cout"
cn=$(echo "$cout" | grep -cE '^ +ok  ') || true
if [ "$cn" -lt 59 ]; then
    echo "   FAIL tests/concurrency.sh made $cn assertions, below its floor of 59"
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
# `|| krc=$?` for the reason spelled out above concurrency.sh: under `set -e` a bare
# failing `x=$(...)` ends the script, taking the diagnosis and every check below it.
krc=0
kout=$(timeout --foreground --kill-after=60 900 ./tests/canary.sh "$ADMIN" 2>&1) || krc=$?
[ "$krc" = 0 ] || fail=1
if [ "$krc" = 124 ] || [ "$krc" = 137 ]; then echo "   FAIL tests/canary.sh timed out"; fail=1; fi
echo "$kout"
kn=$(echo "$kout" | grep -cE '^ +ok  canary ') || true
if [ "$kn" -lt 7 ]; then
    echo "   FAIL tests/canary.sh ran $kn canaries, below its floor of 7"
    fail=1
fi
if ! echo "$kout" | grep -q "SUITE-COMPLETE canary"; then
    echo "   FAIL tests/canary.sh did not run to its last line"
    fail=1
fi

VERDICT_REACHED=1
[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
