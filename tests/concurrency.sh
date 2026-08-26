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
# A single worker means no opposing lock order and no race, and the file would
# still print every "ok" -- a serial smoke test wearing a concurrency suite's
# output. Refuse rather than mislead.
if [ "$WORKERS" -lt 2 ] || [ "$PER" -lt 2 ]; then
    echo "   FAIL concurrency needs WORKERS>=2 and PER>=2 (got $WORKERS/$PER)"; exit 1
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0

q() { psql "$URL" -qAt -c "$1"; }

# ---------------------------------------------------------------- fixtures
psql "$URL" -q -v ON_ERROR_STOP=1 <<'SQL'
-- SIX accounts, not two. With two, the planner drives a Nested Loop from an index
-- scan on ledger_accounts, so post()'s legs emerge in account-id order whether or
-- not it sorts them -- and the deadlock this workload exists to detect could not be
-- produced by removing the sort. The property was attested by accident.
INSERT INTO ledger_accounts (tenant_id,owner_type,owner_id,purpose,category,normal_balance,currency)
SELECT 'c1','company','acme',code,category,normal_balance,'USD'
  FROM account_types WHERE code='customer_receivable';
INSERT INTO ledger_accounts (tenant_id,owner_type,owner_id,purpose,category,normal_balance,currency)
SELECT 'c1','house',NULL,code,category,normal_balance,'USD'
  FROM account_types
 WHERE code IN ('interchange_revenue','fee_revenue','network_settlement_payable',
                'facility_borrowings','accrued_interest_payable');
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
        # four legs over four of the six accounts, and half the workers submit them
        # in the exact reverse order -- so without a deterministic sort two writers
        # take the same four row locks backwards
        if (( w % 2 == 0 )); then
            echo "SELECT post('c1','a${w}_${i}',ARRAY['customer_receivable','debit','10','interchange_revenue','credit','10','facility_borrowings','credit','10','accrued_interest_payable','debit','10']);" >> "$TMP/a$w.sql"
        else
            echo "SELECT post('c1','a${w}_${i}',ARRAY['accrued_interest_payable','debit','10','facility_borrowings','credit','10','interchange_revenue','credit','10','customer_receivable','debit','10']);" >> "$TMP/a$w.sql"
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
# `grep -c "^ERROR"` NEVER MATCHED: psql -f prefixes every diagnostic with
# "psql:<file>:<line>: ". Injecting SELECT 1/0 into every worker left this printing
# "failed statements = 0" and the suite printing PASS. Counted after ALL workloads,
# too -- it used to be computed before D and C wrote their .err files at all.
count_errs() { cat "$TMP"/*.err 2>/dev/null | grep -cE '(^|: )ERROR:' || true; }
expected=$(( WORKERS * PER ))

chk() {  # label, actual, expected
    if [ "$2" = "$3" ]; then echo "   ok  $1 = $2"
    else echo "   FAIL $1 -- expected $3, got $2"; fail=1; fi
}

echo "   ($WORKERS workers x $PER postings, half with legs reversed)"
chk "deadlocks"                     "$(( after_dl - before_dl ))" 0
chk "failed statements (workload A)" "$(count_errs)" 0
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
# Conservation alone is not liveness: 400 + 400 = 800 holds just as well if every
# regroup raised. Assert that the work actually happened.
chk "regroup actually moved events" \
    "$(q "select count(*) > 0 from card_auth_event_group where tenant_id='rg' and superseded_at is not null")" "t"
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
    #
    # And the elapsed time is ASSERTED below. Without that, this function cannot
    # distinguish "the guard held under contention" from "there was no contention":
    # move the COMMIT before the racer starts and both checks still print ok,
    # because the guards refuse serially too. Two sleeps were the whole mechanism.
    ( psql "$URL" -qAt -c "SELECT regroup_auth_event('$t',(SELECT id FROM card_auth_events WHERE tenant_id='$t' AND processor_msg_id='$msg'),'$dest','operator')" \
        >"$TMPD/g_$t.out" 2>&1 ) &
    local racer=$!
    # PROVE THE RACE. Wall-clock timing cannot: it measures this function's own
    # sleep, not the racer's block. Ask the server instead -- while the racer is in
    # flight it must be visibly WAITING ON A LOCK. Without this the function cannot
    # tell "the guard held under contention" from "there was no contention", because
    # the guards refuse serially too.
    sleep 0.6
    local blocked
    blocked=$(psql "$URL" -qAt -c "select count(*) from pg_stat_activity
        where datname = current_database() and wait_event_type = 'Lock'
          and query like '%regroup_auth_event%'")
    sleep 0.5
    echo "COMMIT;" >&9; exec 9>&-
    wait "$racer" 2>/dev/null
    if ! grep -qi "$expect" "$TMPD/g_$t.out"; then
        echo "   FAIL $label was ALLOWED under the race: $(head -1 "$TMPD/g_$t.out")"; fail=1
    elif [ "${blocked:-0}" -lt 1 ]; then
        echo "   FAIL $label refused, but no backend was ever seen waiting on a lock"
        echo "        -- it was refused SERIALLY and this proved nothing about concurrency"
        fail=1
    else
        echo "   ok  $label refused under the race (racer observed blocked on a lock)"
    fi
}
psql "$URL" -q -c "SELECT record_auth_event('xg','m-usd','gU','co1','c1','authorization',500,'USD',false,now())" -o /dev/null
race_guard xg "SELECT record_auth_event('xg','m-eur','gN','co1','c1','authorization',1000,'EUR',false,now());" \
    m-usd gN "one currency" "cross-currency regroup"
psql "$URL" -q -c "SELECT record_auth_event('xe','m-live','gU','co1','c1','authorization',900,'USD',false,now())" -o /dev/null
race_guard xe "SELECT record_auth_event('xe','m-seed','gX','co1','c1','authorization',100,'USD',false,now()); SELECT expire_hold_group('xe','co1','gX');" \
    m-live gX "expired at" "regroup into an expiring group"
chk "no hidden exposure after the races" "$(q "select count(*) from card_hold_drift where tenant_id in ('xg','xe')")" 0

# ---------------------------------------------------------------- workload E
# THE REPAIR RACING INGEST. `recompute_hold_group` takes `PERFORM 1 ... FOR UPDATE`
# between materialising the group and summing its log. That line was load-bearing
# and completely untested -- no workload here ever ran the repair against a
# concurrent write -- and it took three tries to test it, so the two failures are
# worth more than the fix.
#
# A HAND-SEQUENCED RACE WITH THE INGEST FIRST PROVES NOTHING. The repair's own
# `INSERT ... ON CONFLICT DO NOTHING` already waits on a concurrent ingest holding
# that row's lock, so with the FOR UPDATE deleted the repair still blocked, still
# summed after the commit, and still printed the right total. It looked like a
# passing test of a lock that was not there.
#
# NEITHER DOES HAMMERING. Repairs and ingests in parallel on the same group killed
# the mutant one run in three -- and seeding a bigger log to widen the window made
# it WORSE, zero in six, because extra repairs just queue on the row lock. A
# control that fires a third of the time is not a control.
#
# The losing interleaving is specific: the repair sums, an ENTIRE ingest commits,
# and only then does the repair's UPDATE land and overwrite it. So make the sum
# slow enough to aim at. At 50,000 events in one group it takes ~90 ms, which is
# an eternity from a shell: start the repair, wait 30 ms, run one ingest to
# completion inside the gap.
#   with FOR UPDATE: the repair holds the row from the start, the ingest waits,
#                    and applies its delta on top of the repaired total
#   without it:      the ingest commits inside the gap and the repair's UPDATE
#                    erases it -- verified, 500100 becomes 500000
psql "$URL" -q -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO card_auth_events (tenant_id,processor_msg_id,company_id,card_id,kind,
                              amount_delta,raw_amount,raw_is_total,currency,occurred_at)
SELECT 'rc','seed_'||i,'co1','c1','incremental',10,10,false,'USD',now()
  FROM generate_series(1,50000) i;
INSERT INTO card_hold_groups (tenant_id,company_id,group_key,currency)
VALUES ('rc','co1','GR','USD') ON CONFLICT DO NOTHING;
INSERT INTO card_auth_event_group (tenant_id,event_id,group_key,method,assigned_by)
SELECT 'rc', id, 'GR', 'manual', 'seed' FROM card_auth_events WHERE tenant_id='rc';
SELECT recompute_hold_group('rc','co1','GR');
SQL
chk "the seeded group sums to its log" \
    "$(q "select total_minor from card_hold_groups where tenant_id='rc' and group_key='GR'")" 500000

( psql "$URL" -qAt -c "SELECT recompute_hold_group('rc','co1','GR')" >"$TMPD/rc.out" 2>&1 ) &
rc_pid=$!
sleep 0.03
psql "$URL" -qAt -c "SELECT record_auth_event('rc','rc_live','GR','co1','c1','incremental',100,'USD',false,now())" \
    >"$TMPD/rc_ing.out" 2>&1
wait "$rc_pid" 2>/dev/null
chk "the repair does not erase an event committed while it was summing" \
    "$(q "select total_minor from card_hold_groups where tenant_id='rc' and group_key='GR'")" 500100
chk "...and the log agrees" \
    "$(q "select coalesce(sum(e.amount_delta),0) from card_auth_event_group m join card_auth_events e on e.tenant_id=m.tenant_id and e.id=m.event_id where m.tenant_id='rc' and m.group_key='GR' and m.superseded_at is null")" 500100
chk "...with no drift" "$(q "select count(*) from card_hold_drift where tenant_id='rc'")" 0

# ...and once more, now that every workload has written its .err files.
chk "failed statements (all workloads)" "$(count_errs)" 0

# ---------------------------------------------------------------- workload F
# THE NOT-YET-EXISTING DESTINATION. regroup_auth_event materialises the
# destination INSIDE its sorted lock loop, at that group's place in the order.
# Hoisting the INSERT above the loop -- which reads as a harmless tidy-up, and is
# how the function was originally written -- passed the entire suite, because
# workload C shuttles between two groups that ALREADY EXIST and never races the
# creation of one.
#
# That is verbatim the defect the function's own comment describes as measured:
# "an adapter processing a webhook batch deadlocked against an operator splitting
# an event into a not-yet-existing group, and the whole batch rolled back."
#
# `INSERT ... ON CONFLICT DO NOTHING` IS a lock acquisition, so putting it before
# the sort puts one lock outside the ordering the sort exists to impose. Named so
# that gFa < gFb: the adapter takes gFa then gFb; a correct regroup takes them in
# the same order and QUEUES, a hoisted one takes gFb first and closes the cycle.
psql "$URL" -q -v ON_ERROR_STOP=1 -c \
  "DO \$d\$ BEGIN PERFORM record_auth_event('fx','f_seed','gFa','co1','c1','authorization',1000,'USD',false,now()); END \$d\$;"
f_dl_before=$(q "select deadlocks from pg_stat_database where datname=current_database()")
ffifo="$TMPD/f_fx"; rm -f "$ffifo"; mkfifo "$ffifo"
( psql "$URL" -qAt -f "$ffifo" >"$TMPD/fx_adapter.out" 2>&1 ) &
exec 8>"$ffifo"
echo "BEGIN;" >&8
# the adapter takes gFa first...
echo "SELECT record_auth_event('fx','f_a2','gFa','co1','c1','incremental',10,'USD',false,now());" >&8
sleep 0.7
# ...the operator starts moving the seeded event gFa -> gFb, which does not exist
( psql "$URL" -qAt -c "SELECT regroup_auth_event('fx',(SELECT id FROM card_auth_events WHERE tenant_id='fx' AND processor_msg_id='f_seed'),'gFb','operator')" \
    >"$TMPD/fx_op.out" 2>&1 ) &
fx_op=$!
sleep 0.7
# ...and only then does the adapter reach gFb, closing the cycle if the operator
# grabbed it out of order
echo "SELECT record_auth_event('fx','f_b1','gFb','co1','c1','authorization',20,'USD',false,now());" >&8
echo "COMMIT;" >&8; exec 8>&-
wait "$fx_op" 2>/dev/null
sleep 0.3
f_dl_after=$(q "select deadlocks from pg_stat_database where datname=current_database()")
chk "adapter vs operator on a not-yet-existing destination: deadlocks" \
    "$(( f_dl_after - f_dl_before ))" 0
chk "...and nothing was lost" "$(q "select count(*) from card_hold_drift where tenant_id='fx'")" 0
chk "...and the event did move" \
    "$(q "select m.group_key from card_auth_event_group m join card_auth_events e on e.tenant_id=m.tenant_id and e.id=m.event_id where e.processor_msg_id='f_seed' and m.superseded_at is null")" \
    gFb

# ---------------------------------------------------------------- workload G
# THE SAME MESSAGE, TWICE, AT ONCE. `record_auth_event` inserts the event with
# `ON CONFLICT DO NOTHING ... RETURNING`, so the loser of that race gets NO ROW
# back and must re-run to attach against the row the winner committed. Replacing
# that branch with `RETURN 0` passed the whole suite: every concurrent workload
# here gives each worker its own message ids, so the branch was never taken.
#
# The code comment names the outcome: "800.00 sat in the unmatched queue and
# held_for_company said 0" -- and 0 is what the adapter authorises against.
psql "$URL" -q -v ON_ERROR_STOP=1 -c "SELECT 1" -o /dev/null
for w in $(seq 1 8); do
    ( psql "$URL" -qAt -c "SELECT record_auth_event('rd','same_msg','gRD','co1','c1','authorization',80000,'USD',false,now())" \
        >"$TMPD/rd$w.out" 2>"$TMPD/rd$w.err" ) &
done
wait
rd_true=$(q "select total_minor from card_hold_groups where tenant_id='rd' and group_key='gRD'")
chk "one message delivered eight times at once is stored once" \
    "$(q "select count(*) from card_auth_events where tenant_id='rd' and processor_msg_id='same_msg'")" 1
chk "...and is attached exactly once" \
    "$(q "select count(*) from card_auth_event_group m join card_auth_events e on e.tenant_id=m.tenant_id and e.id=m.event_id where e.processor_msg_id='same_msg' and m.superseded_at is null")" 1
chk "...and the group holds it" "$rd_true" 80000
rd_bad=0
for w in $(seq 1 8); do
    got=$(tr -d ' \n' < "$TMPD/rd$w.out")
    if [ "$got" != "$rd_true" ]; then
        echo "   .. worker $w was told '$got' against a true exposure of $rd_true"
        rd_bad=$((rd_bad+1))
    fi
done
chk "...and every racing caller was told the true exposure" "$rd_bad" 0
chk "...with nothing left unmatched" \
    "$(q "select count(*) from card_auth_unmatched where tenant_id='rd'")" 0

# ---------------------------------------------------------------- workload H
# TWO OPERATORS, ONE EVENT. `regroup_auth_event` locks the event row FOR UPDATE
# before reading which group it is currently in, and that lock was completely
# untested: workload C shuttles events picked with `ORDER BY random() LIMIT 1`
# between two groups, so it essentially never puts two operators on the SAME
# event -- which is the only case the lock exists for. Deleting it left a phantom
# hold in 40 of 40 trials, and the shipped suite found it 0 times in 40.
#
# X -> Y and X -> Z at once. Whichever loses must see the event has already moved
# and recompute the group it actually left, not the one it read before waiting.
psql "$URL" -q -v ON_ERROR_STOP=1 -c \
  "DO \$d\$ BEGIN PERFORM record_auth_event('tw','tw_e','gX','co1','c1','authorization',10000,'USD',false,now()); END \$d\$;"
tw_id=$(q "select id from card_auth_events where tenant_id='tw' and processor_msg_id='tw_e'")
for dst in gY gZ; do
    ( psql "$URL" -qAt -c "SELECT regroup_auth_event('tw','$tw_id','$dst','operator')" \
        >"$TMPD/tw_$dst.out" 2>&1 ) &
done
wait
chk "two operators moving one event: exactly one live membership" \
    "$(q "select count(*) from card_auth_event_group where tenant_id='tw' and event_id='$tw_id' and superseded_at is null")" 1
chk "...and the exposure is counted once, not twice" \
    "$(q "select coalesce(sum(held_minor),0) from card_hold_groups where tenant_id='tw'")" 10000
chk "...and no group is left holding a phantom" \
    "$(q "select count(*) from card_hold_drift where tenant_id='tw'")" 0

# ---------------------------------------------------------------- workload I
# THE ATTACH PATH TAKES TWO LOCKS, AND A FOREIGN KEY TAKES ONE OF THEM FOR YOU.
# `record_auth_event`'s re-delivery attach took the card_hold_groups row FOR
# UPDATE and then, through fk_event_group__event, an implicit FOR KEY SHARE on the
# event when inserting the membership. `regroup_auth_event` takes those two in the
# OPPOSITE order. A matcher attaching a queued event against an operator moving
# the same event deadlocked in 18 of 20 trials -- each one aborting the adapter's
# whole webhook transaction. ADR-0010 claimed a single-group ingest "cannot
# deadlock -- it takes exactly one row lock".
psql "$URL" -q -v ON_ERROR_STOP=1 -c \
  "DO \$d\$ BEGIN PERFORM record_auth_event('at','at_e',NULL,'co1','c1','authorization',7000,'USD',false,now());
            PERFORM record_auth_event('at','at_seed','gH','co1','c1','authorization',100,'USD',false,now()); END \$d\$;"
at_id=$(q "select id from card_auth_events where tenant_id='at' and processor_msg_id='at_e'")
at_dl_before=$(q "select deadlocks from pg_stat_database where datname=current_database()")
for i in $(seq 1 10); do
    ( psql "$URL" -qAt -c "SELECT record_auth_event('at','at_e','gH','co1','c1','authorization',7000,'USD',false,now())" \
        >"$TMPD/at_a$i.out" 2>&1 ) &
    ( psql "$URL" -qAt -c "SELECT regroup_auth_event('at','$at_id','gH$i','operator')" \
        >"$TMPD/at_r$i.out" 2>&1 ) &
done
wait
at_dl_after=$(q "select deadlocks from pg_stat_database where datname=current_database()")
chk "matcher against operator on one event: deadlocks" "$(( at_dl_after - at_dl_before ))" 0
chk "...still exactly one live membership" \
    "$(q "select count(*) from card_auth_event_group where tenant_id='at' and event_id='$at_id' and superseded_at is null")" 1
chk "...and no drift" "$(q "select count(*) from card_hold_drift where tenant_id='at'")" 0

# ---------------------------------------------------------------- workload J
# EIGHT RE-DELIVERIES OF ONE UNMATCHED EVENT, ALL NAMING THE SAME GROUP. Workload
# G covers the FRESH-insert race, where the event does not yet exist. This is the
# other one -- the case the thirty-line "THE RE-DELIVERY ATTACH" comment block
# exists for -- and it was uncovered: all eight callers read the membership with
# no lock held, all eight saw NULL, and seven got a raw
# `duplicate key value violates unique constraint "uq_event_group__current"`
# instead of the exposure they asked for.
psql "$URL" -q -v ON_ERROR_STOP=1 -c \
  "DO \$d\$ BEGIN PERFORM record_auth_event('rj','rj_e',NULL,'co1','c1','authorization',81000,'USD',false,now()); END \$d\$;"
for w in $(seq 1 8); do
    ( psql "$URL" -qAt -c "SELECT record_auth_event('rj','rj_e','gJ','co1','c1','authorization',81000,'USD',false,now())" \
        >"$TMPD/rj$w.out" 2>"$TMPD/rj$w.err" ) &
done
wait
rj_true=$(q "select total_minor from card_hold_groups where tenant_id='rj' and group_key='gJ'")
chk "eight concurrent attaches of one unmatched event: one live membership" \
    "$(q "select count(*) from card_auth_event_group m join card_auth_events e on e.tenant_id=m.tenant_id and e.id=m.event_id where e.tenant_id='rj' and e.processor_msg_id='rj_e' and m.superseded_at is null")" 1
chk "...and the group holds it once" "$rj_true" 81000
rj_bad=0
for w in $(seq 1 8); do
    got=$(tr -d ' \n' < "$TMPD/rj$w.out")
    if [ "$got" != "$rj_true" ]; then
        echo "   .. attacher $w was told '$got' against a true exposure of $rj_true"
        rj_bad=$((rj_bad+1))
    fi
done
chk "...and every racing attacher was told the true exposure, not a constraint error" "$rj_bad" 0
chk "...with nothing left in the review queue" \
    "$(q "select count(*) from card_auth_unmatched where tenant_id='rj'")" 0

echo "   ok  SUITE-COMPLETE concurrency"
exit "$fail"
