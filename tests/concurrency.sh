#!/usr/bin/env bash
# The defect class the SQL suites structurally cannot see.
#
# Every other file here runs in one psql session, so it cannot observe a lost
# update, a lock-ordering deadlock, or a torn read. Mutation testing made the gap
# concrete: deleting `FOR UPDATE` from record_auth_event -- the lock migration 0003
# calls the fix for its root cause -- changed no assertion anywhere.
#
# Two workloads, both run against a database this script is handed:
#   A. N writers posting multi-leg transactions over the same accounts, half of
#      them with the legs in REVERSE order. Before post() sorted its legs by
#      account id this produced 138 deadlocks and 138 rollbacks out of 320
#      postings; every failure was a deadlock.
#   B. N writers calling record_auth_event on ONE hold group, which is where the
#      ingest lock either serialises the read-modify-write or does not.
set -uo pipefail
URL="${1:?usage: concurrency.sh <database-url>}"
WORKERS="${WORKERS:-6}"
PER="${PER:-15}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0

q() { psql "$URL" -qAt -c "$1"; }

# ---------------------------------------------------------------- fixtures
psql "$URL" -q -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO ledger_accounts (tenant_id,owner_type,owner_id,purpose,category,normal_balance,currency)
SELECT 'c1','company','acme',code,category,normal_balance,'USD'
  FROM account_types WHERE code='customer_receivable';
INSERT INTO ledger_accounts (tenant_id,owner_type,owner_id,purpose,category,normal_balance,currency)
SELECT 'c1','house',NULL,code,category,normal_balance,'USD'
  FROM account_types WHERE code='interchange_revenue';
DO $d$ BEGIN PERFORM record_auth_event('c1','seed','hot','co1','card1','authorization',0,'USD',false,now()); END $d$;
SQL

# post() is defined by the golden trace; reuse it rather than a second copy that
# could drift from the one under test.
sed -n '/^CREATE FUNCTION post(/,/^END \$\$;/p' "$(dirname "$0")/golden_trace.sql" \
  | psql "$URL" -q -v ON_ERROR_STOP=1 -f - || { echo "   could not install post()"; exit 1; }

before_dl=$(q "select deadlocks from pg_stat_database where datname=current_database()")

# ---------------------------------------------------------------- workload A
for w in $(seq 1 "$WORKERS"); do
    : > "$TMP/a$w.sql"
    for i in $(seq 1 "$PER"); do
        if (( w % 2 == 0 )); then
            echo "SELECT post('c1','a${w}_${i}',ARRAY['customer_receivable','debit','10','interchange_revenue','credit','10']);" >> "$TMP/a$w.sql"
        else
            echo "SELECT post('c1','a${w}_${i}',ARRAY['interchange_revenue','credit','10','customer_receivable','debit','10']);" >> "$TMP/a$w.sql"
        fi
    done
done
for w in $(seq 1 "$WORKERS"); do
    psql "$URL" -qAt -f "$TMP/a$w.sql" >/dev/null 2>"$TMP/a$w.err" &
done
wait

# ---------------------------------------------------------------- workload B
for w in $(seq 1 "$WORKERS"); do
    : > "$TMP/b$w.sql"
    for i in $(seq 1 "$PER"); do
        echo "SELECT record_auth_event('c1','b${w}_${i}','hot','co1','card1','incremental',10,'USD',false,now());" >> "$TMP/b$w.sql"
    done
done
for w in $(seq 1 "$WORKERS"); do
    psql "$URL" -qAt -f "$TMP/b$w.sql" >/dev/null 2>"$TMP/b$w.err" &
done
wait

after_dl=$(q "select deadlocks from pg_stat_database where datname=current_database()")
errs=$(cat "$TMP"/*.err 2>/dev/null | grep -c "^ERROR" || true)
expected=$(( WORKERS * PER ))

chk() {  # label, actual, expected
    if [ "$2" = "$3" ]; then echo "   ok  $1 = $2"
    else echo "   FAIL $1 -- expected $3, got $2"; fail=1; fi
}

echo "   ($WORKERS workers x $PER postings, half with legs reversed)"
chk "deadlocks"                     "$(( after_dl - before_dl ))" 0
chk "failed statements"             "$errs" 0
chk "postings committed"            "$(q "select count(*) from ledger_transactions where kind='trace'")" "$expected"
chk "auth events recorded"          "$(q "select count(*) from card_auth_events where processor_msg_id like 'b%'")" "$expected"
chk "hold total matches the log"    "$(q "select total_minor from card_hold_groups where group_key='hot'")" "$(( expected * 10 ))"
chk "ledger drift rows"             "$(q "select count(*) from ledger_balance_drift")" 0
chk "hold drift rows"               "$(q "select count(*) from card_hold_drift")" 0
chk "every account_seq gapless"     "$(q "select bool_and(mx=n and dc=n) from (select max(account_seq) mx, count(*) n, count(distinct account_seq) dc from ledger_entries group by tenant_id,account_id) q")" "t"
chk "every transaction balanced"    "$(q "select bool_and(dr=cr) from (select transaction_id, sum(amount_minor) filter (where direction='debit') dr, sum(amount_minor) filter (where direction='credit') cr from ledger_entries group by transaction_id) q")" "t"
chk "accounting equation holds"     "$(q "select bool_and(balanced) from accounting_equation()")" "t"

exit "$fail"
