#!/usr/bin/env bash
# THE ORACLE THE SUITE CANNOT AUTHOR.
#
# Every other guard in run.sh counts assertions: the manifest counts files, the
# floor counts notices, the call-site floor counts lines of source, the sentinel
# looks for a string. All of them read something the suite says ABOUT ITSELF, and
# an audit showed what that is worth: SIX ONE-LINE EDITS to three helper bodies --
# must_fail's two RAISE EXCEPTIONs to NULL, eq() to a bare notice, chk() to an
# echo -- left every call site byte-for-byte intact, every count unchanged, every
# sentinel present, and carried a live journal-truncation mutant to a green build.
# The call-site floor's premise ("to forge this you have to write the assertions")
# holds for the assertions and not for the VERDICT, which is one function per file.
#
# So: break the schema on purpose, in ways the suite demonstrably catches, and
# require it to go RED. A suite whose helpers have been neutered goes green here
# and fails this script. That is a verdict from outside the file.
#
# Each canary runs ONE suite against ONE deliberately broken schema, so this costs
# about as much as a single extra suite run, not a whole extra build.
set -euo pipefail
cd "$(dirname "$0")/.."

ADMIN="${1:-${ADMIN_URL:-postgres://openledger:openledger@localhost:5433/postgres?sslmode=disable}}"
BASE="${ADMIN%/postgres*}"
WORK="$(mktemp -d)"
DBS=""
cleanup() {
    for d in $DBS; do psql "$ADMIN" -q -c "DROP DATABASE IF EXISTS $d" >/dev/null 2>&1 || true; done
    rm -rf "$WORK"
}
trap cleanup EXIT

fail=0

# canary <name> <suite> <file-to-break> <sed-expression> <expected-failure-text>
#   The sed expression must make the schema WRONG in a way the named suite has a
#   control for. If the suite still passes, either that control or the helper it
#   reports through has stopped working.
#
#   THE LAST ARGUMENT IS WHY THIS IS AN ORACLE AND NOT A COIN FLIP. Checking only
#   that a suite goes RED is checkable by the suite: a gutted file that recognises
#   the canary's schema -- the mutations are a fixed, public set -- can raise on
#   cue and stay green everywhere else. Demonstrated: a 157-line stub with a
#   `prosrc LIKE '%RETURN NULL%'` tripwire passed the whole build with the entry
#   seal dead. Requiring the suite's own control MESSAGE means the stub has to
#   reproduce the control, which is the control.
canary() {
    local name="$1" suite="$2" target="$3" expr="$4" want="$5"
    local db="ol_canary_$$_${name}"
    DBS="$DBS $db"
    rm -rf "$WORK/m"; cp -r migrations "$WORK/m"
    sed -i "$expr" "$WORK/m/$target"
    if cmp -s "migrations/$target" "$WORK/m/$target"; then
        echo "   FAIL canary '$name' did not change $target -- the mutation no longer applies,"
        echo "        so this canary has been silently testing nothing"
        fail=1; return
    fi
    psql "$ADMIN" -v ON_ERROR_STOP=1 -q -c "CREATE DATABASE $db" >/dev/null
    local url="$BASE/$db?sslmode=disable"
    # ...AND THE BROKEN SCHEMA MUST STILL LOAD. Applying it with `|| true` meant a
    # mutation that turned a migration into a syntax error left an EMPTY database,
    # every suite went red because there were no tables, and the canary reported
    # `ok` -- testing nothing. run.sh fixed exactly this shape for its empty-ledger
    # pre-check ("it must fail for the RIGHT REASON") and the lesson was not carried
    # one file over.
    for f in "$WORK"/m/*.sql "$WORK"/m/seed/*.sql; do
        if ! psql "$url" -v ON_ERROR_STOP=1 -q -f "$f" >"$WORK/apply.err" 2>&1; then
            echo "   FAIL canary '$name': the mutated schema does not load, so the"
            echo "        suite would go red for the wrong reason: $(head -1 "$WORK/apply.err")"
            fail=1; return
        fi
    done
    local out
    if out=$(psql "$url" -v ON_ERROR_STOP=1 -q -f "tests/$suite" 2>&1); then
        echo "   FAIL canary '$name': $suite PASSED against a schema that is deliberately"
        echo "        broken. Either its control for this is gone, or the helper it reports"
        echo "        through no longer raises."
        fail=1
    elif ! printf '%s' "$out" | grep -qF "$want"; then
        echo "   FAIL canary '$name': $suite went red, but not for its own reason."
        echo "        wanted: $want"
        echo "        got:    $(printf '%s' "$out" | grep -iE 'ERROR|FAIL' | head -1)"
        fail=1
    else
        echo "   ok  canary '$name' -- $suite goes red, and for its own reason"
    fi
}

# 1. The journal becomes truncatable. negative_controls has six TRUNCATE controls;
#    all of them report through must_fail.
# The mutation inserts a RETURN before the RAISE rather than replacing it. An
# earlier version replaced the RAISE line and left its `USING ERRCODE` clause
# dangling, so 0001 failed to parse, the database came up EMPTY, and
# negative_controls went red because there were no tables -- the canary reported
# `ok` while testing nothing. The load check above is what caught it.
canary truncatable negative_controls.sql 0001_ledger_core.sql \
    "s|    RAISE EXCEPTION 'the ledger cannot be truncated|    RETURN NULL;\\n    RAISE EXCEPTION 'the ledger cannot be truncated|" \
    "NOT CAUGHT -- truncating the entries"

# 2. Pending transactions are reported as if posted. golden_trace asserts the
#    lifecycle through eq-style DO blocks, not through must_fail -- a different
#    helper, deliberately.
canary pending_counted golden_trace.sql 0002_chart_of_accounts.sql \
    "s|AND x.status = 'posted'|AND true|g" \
    "a PENDING transaction was recognised as revenue"

# 3. A cumulative total becomes re-groupable, which under-reserves credit.
#    card_holds reports through its own must_fail and eq.
canary regroup_total card_holds.sql 0003_card_holds.sql \
    "s|    IF v_is_total THEN|    IF false THEN|" \
    "NOT CAUGHT -- re-grouping a cumulative-total event"

# ...and the three suites the canary did not cover, because an uncovered suite can
# be gutted without touching canary.sh at all.
canary recorded_axis bitemporal.sql 0002_chart_of_accounts.sql \
    "s|en.recorded_at  <= p_as_of|en.recorded_at  < p_as_of|" \
    "recorded axis, as of now: everything"

canary balance_index query_plans.sql 0001_ledger_core.sql \
    "s|ix_entries__balance_lookup|ix_entries__balance_lookup_renamed|g" \
    "index(es) gone"

# ...and concurrency.sh, which is a shell script rather than a psql file, and which
# is the ONLY evidence for four locks. It gets the same treatment: break a lock,
# require its own named assertion to be the thing that fails.
canary_sh() {
    local name="$1" target="$2" expr="$3" want="$4"
    local db="ol_canary_$$_${name}"
    DBS="$DBS $db"
    rm -rf "$WORK/m"; cp -r migrations "$WORK/m"
    sed -i "$expr" "$WORK/m/$target"
    if cmp -s "migrations/$target" "$WORK/m/$target"; then
        echo "   FAIL canary '$name' did not change $target -- it is testing nothing"
        fail=1; return
    fi
    psql "$ADMIN" -v ON_ERROR_STOP=1 -q -c "CREATE DATABASE $db" >/dev/null
    local url="$BASE/$db?sslmode=disable"
    for f in "$WORK"/m/*.sql "$WORK"/m/seed/*.sql; do
        if ! psql "$url" -v ON_ERROR_STOP=1 -q -f "$f" >"$WORK/apply.err" 2>&1; then
            echo "   FAIL canary '$name': the mutated schema does not load: $(head -1 "$WORK/apply.err")"
            fail=1; return
        fi
    done
    local out
    if out=$(./tests/concurrency.sh "$url" 2>&1); then
        echo "   FAIL canary '$name': concurrency.sh PASSED against a broken lock"
        fail=1
    elif ! printf '%s' "$out" | grep -qF "$want"; then
        echo "   FAIL canary '$name': concurrency.sh went red, but not for its own reason."
        echo "        wanted: $want"
        echo "        got:    $(printf '%s' "$out" | grep -iE 'FAIL' | head -1)"
        fail=1
    else
        echo "   ok  canary '$name' -- concurrency.sh goes red, and for its own reason"
    fi
}

canary_sh ingest_lock 0003_card_holds.sql \
    "s|         WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group FOR UPDATE;|         WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group;|" \
    "concurrent identical totals converge on that total"

echo "   ok  SUITE-COMPLETE canary"
exit "$fail"
