#!/usr/bin/env bash
# FINDING 8. Re-grouping deadlocks against a multi-group adapter transaction.
# ADR-0001: re-grouping sorts its two locks by group_key; a single ingest takes
# its one lock in CALL order, so a batch touching ZZZ then AAA takes them backwards.
set -u
PSQL="psql -h localhost -p 5433 -U openledger -d spike_wsg -q -v ON_ERROR_STOP=0"
export PGPASSWORD=openledger

$PSQL -c "SET search_path=public; SELECT reset_all();" >/dev/null
$PSQL -c "SET search_path=public;
          SELECT ingest_current('t1','c1','k','AAA','x1','authorization',10000,false);
          SELECT ingest_current('t1','c1','k','ZZZ','x2','authorization',10000,false);" >/dev/null

run () { # $1 first group  $2 second group  $3 label
  $PSQL <<EOF 2>&1 | sed "s/^/[$3] /"
BEGIN;
SELECT group_key FROM card_hold_groups WHERE tenant_id='t1' AND company_id='c1' AND group_key='$1' FOR UPDATE;
SELECT pg_sleep(0.6);
SELECT group_key FROM card_hold_groups WHERE tenant_id='t1' AND company_id='c1' AND group_key='$2' FOR UPDATE;
COMMIT;
EOF
}

echo "=== unsorted: a re-grouping sorted by group_key (AAA then ZZZ) against a batch in call order (ZZZ then AAA) ==="
deadlocks=0
for i in 1 2 3 4 5 6; do
  out=$( { run AAA ZZZ regroup & run ZZZ AAA batch & wait; } 2>&1 )
  if grep -q 'deadlock detected' <<<"$out"; then deadlocks=$((deadlocks+1)); fi
  [ $i = 1 ] && grep 'deadlock detected' <<<"$out" | head -2
done
echo "unsorted: $deadlocks deadlocks in 6 trials"

echo "=== sorted: BOTH transactions take their locks in ascending group_key order ==="
deadlocks=0
for i in 1 2 3 4 5 6; do
  out=$( { run AAA ZZZ regroup & run AAA ZZZ batch & wait; } 2>&1 )
  if grep -q 'deadlock detected' <<<"$out"; then deadlocks=$((deadlocks+1)); fi
done
echo "sorted: $deadlocks deadlocks in 6 trials"
