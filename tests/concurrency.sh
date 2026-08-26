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

# ---------------------------------------------------------------- workload D
# THE INGEST LOCK, actually raced.
#
# Workload B uses is_total => false, where the surviving `UPDATE ... SET total =
# total + delta` is row-atomic on its own, so removing FOR UPDATE changes nothing.
# A cumulative total is the case that needs the lock: the conversion READS
# authorized_minor and writes a delta derived from it.
#
# A LADDER OF RISING TOTALS DOES NOT DETECT IT EITHER, which is why this workload
# was rewritten. A lost update there makes the base too LOW, the delta too large,
# and the next rung then refuses anything below the inflated subtotal -- the ladder
# self-corrects and the final total converges on the top rung whether or not the
# lock is there. Verified: with FOR UPDATE deleted, the old workload still printed
# `ok cumulative totals converge on the highest total = 1500`.
#
# So every worker sends THE SAME total, under a different message id, at once.
# With the lock: the first converts 100 -> 5000 and every other sees
# authorized_minor already at 5000, computes a delta of zero, and is a no-op.
# Without it: several read 100 concurrently and each apply 4900.
psql "$URL" -q -v ON_ERROR_STOP=1 -c \
  "DO \$d\$ BEGIN PERFORM record_auth_event('cc','tot_seed','GT','co1','c1','authorization',100,'USD',true,now()); END \$d\$;"
same_total() {
    : > "$TMP/d$1.sql"
    for i in $(seq 1 "$PER"); do
        echo "SELECT record_auth_event('cc','t${1}_${i}','GT','co1','c1','incremental',5000,'USD',true,now());" >> "$TMP/d$1.sql"
    done
    psql "$URL" -qAt -f "$TMP/d$1.sql" >/dev/null 2>"$TMP/d$1.err"
}
for w in $(seq 1 "$WORKERS"); do same_total "$w" & done
wait
chk "concurrent identical totals converge on that total" \
    "$(q "select total_minor from card_hold_groups where tenant_id='cc' and group_key='GT'")" 5000
chk "...and the authorized subtotal matches" \
    "$(q "select authorized_minor from card_hold_groups where tenant_id='cc' and group_key='GT'")" 5000
# the seed is excluded: it legitimately converts 0 -> 100
chk "...with exactly one racing conversion having moved anything" \
    "$(q "select count(*) from card_auth_events e join card_auth_event_group m on m.tenant_id=e.tenant_id and m.event_id=e.id where e.tenant_id='cc' and m.group_key='GT' and e.amount_delta > 0 and e.processor_msg_id <> 'tot_seed'")" 1
chk "...with no drift" "$(q "select count(*) from card_hold_drift where tenant_id='cc'")" 0

# ---------------------------------------------------------------- expiry idempotence
# `expire_hold_group` carries `AND expired_at IS NULL`, and dropping it is
# invisible inside a single transaction, because now() is transaction-start time.
# Across two sessions it is not: a sweep that runs every minute would otherwise
# reset the release time and the snapshot the post-expiry alarm measures against,
# blinding it to everything added in between.
psql "$URL" -q -v ON_ERROR_STOP=1 -c \
  "DO \$d\$ BEGIN PERFORM record_auth_event('cc','ex_a','GEX','co1','c1','authorization',2000,'USD',false,now()); END \$d\$;"
psql "$URL" -q -c "SELECT expire_hold_group('cc','co1','GEX')" -o /dev/null
first_exp=$(q "select expired_at from card_hold_groups where tenant_id='cc' and group_key='GEX'")
psql "$URL" -q -c "SELECT expire_hold_group('cc','co1','GEX')" -o /dev/null
chk "re-expiring in a later transaction does not move the release time" \
    "$(q "select expired_at from card_hold_groups where tenant_id='cc' and group_key='GEX'")" \
    "$first_exp"

# ---------------------------------------------------------------- workload C
# Re-grouping races. All three of these were LIVE defects found by adversarial
# review, and none is reachable from a single session.
TMPD="$TMP"

# C1: two operators shuttling events between the SAME two groups in opposite
# directions. regroup locks the destination, then recompute locks the source --
# opposite orders, so they deadlocked (198 of them under mixed load). Both groups
# are now locked up front in group_key order.
psql "$URL" -q -v ON_ERROR_STOP=1 <<'SQL'
DO $$ DECLARE i int; BEGIN
  FOR i IN 1..40 LOOP
    PERFORM record_auth_event('rg','ea'||i,'gA','co1','c1','incremental',10,'USD',false,now());
    PERFORM record_auth_event('rg','eb'||i,'gB','co1','c1','incremental',10,'USD',false,now());
  END LOOP;
END $$;
SQL
shuttle() {  # dir, n, worker
    local from to pfx; if [ "$1" = AB ]; then from=gA; to=gB; pfx=ea; else from=gB; to=gA; pfx=eb; fi
    : > "$TMPD/c$3.sql"
    for i in $(seq 1 "$2"); do
        echo "SELECT regroup_auth_event('rg',(SELECT m.event_id FROM card_auth_event_group m JOIN card_auth_events e ON e.tenant_id=m.tenant_id AND e.id=m.event_id WHERE m.tenant_id='rg' AND m.group_key='$from' AND m.superseded_at IS NULL AND e.processor_msg_id LIKE '$pfx%' LIMIT 1),'$to','op$3');" >> "$TMPD/c$3.sql"
    done
    psql "$URL" -qAt -f "$TMPD/c$3.sql" >/dev/null 2>"$TMPD/c$3.err"
}
dl_before=$(q "select deadlocks from pg_stat_database where datname=current_database()")
for w in 1 2 3; do shuttle AB 12 "$w" & done
for w in 4 5 6; do shuttle BA 12 "$w" & done
wait
dl_after=$(q "select deadlocks from pg_stat_database where datname=current_database()")
chk "regroup deadlocks"          "$(( dl_after - dl_before ))" 0
chk "regroup conserves the total" "$(q "select sum(total_minor) from card_hold_groups where tenant_id='rg'")" 800
chk "regroup leaves no drift"     "$(q "select count(*) from card_hold_drift where tenant_id='rg'")" 0

# C2/C3: the destination group's guards must hold even when the destination is
# being CREATED by another transaction. regroup used to read it FOR UPDATE before
# materialising it, so mid-creation the row was invisible, FOUND was false, and
# both guards were skipped -- a USD event joined a EUR group, and a live
# authorization joined a group being expired (held_for_company then reported 0
# against real exposure, invisible to the drift alarm because the clamp lives in
# held_minor while the alarm compares total_minor).
race_guard() {  # tenant, setup-sql-in-open-txn, event-msg, dest, expect-substring, label
    local t="$1" setup="$2" msg="$3" dest="$4" expect="$5" label="$6"
    local fifo="$TMPD/f_$t"; rm -f "$fifo"; mkfifo "$fifo"
    ( psql "$URL" -qAt -f "$fifo" >/dev/null 2>&1 ) &
    exec 9>"$fifo"
    echo "BEGIN;" >&9; echo "$setup" >&9
    sleep 1
    # BACKGROUND, deliberately: the racing regroup blocks on the row lock the open
    # transaction holds, so running it synchronously would wait for a COMMIT that
    # is issued after it. It has to be in flight when the other side commits --
    # that IS the race.
    ( psql "$URL" -qAt -c "SELECT regroup_auth_event('$t',(SELECT id FROM card_auth_events WHERE tenant_id='$t' AND processor_msg_id='$msg'),'$dest','operator')" \
        >"$TMPD/g_$t.out" 2>&1 ) &
    local racer=$!
    sleep 1
    echo "COMMIT;" >&9; exec 9>&-
    wait "$racer" 2>/dev/null
    if grep -qi "$expect" "$TMPD/g_$t.out"; then echo "   ok  $label refused under the race"
    else echo "   FAIL $label was ALLOWED under the race: $(head -1 "$TMPD/g_$t.out")"; fail=1; fi
}
psql "$URL" -q -c "SELECT record_auth_event('xg','m-usd','gU','co1','c1','authorization',500,'USD',false,now())" -o /dev/null
race_guard xg "SELECT record_auth_event('xg','m-eur','gN','co1','c1','authorization',1000,'EUR',false,now());" \
    m-usd gN "one currency" "cross-currency regroup"
psql "$URL" -q -c "SELECT record_auth_event('xe','m-live','gU','co1','c1','authorization',900,'USD',false,now())" -o /dev/null
race_guard xe "SELECT record_auth_event('xe','m-seed','gX','co1','c1','authorization',100,'USD',false,now()); SELECT expire_hold_group('xe','co1','gX');" \
    m-live gX "expired at" "regroup into an expiring group"
chk "no hidden exposure after the races" "$(q "select count(*) from card_hold_drift where tenant_id in ('xg','xe')")" 0

exit "$fail"
