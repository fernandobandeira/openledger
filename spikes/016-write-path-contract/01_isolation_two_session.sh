#!/usr/bin/env bash
# 01_isolation_two_session.sh -- the property, deterministically, with two sessions.
#
# Two writers hit the SAME balance row with the balance upsert from
# `site/content/database.md`. Session A wins the lock; session B blocks; A commits;
# B is released and we record what it does.
#
# READ COMMITTED: B re-reads the updated row and applies its own update on top.
# REPEATABLE READ / SERIALIZABLE: B is aborted with 40001 could not serialize access.
#
# No sleeps: the handshake polls pg_stat_activity, so the ordering is enforced
# rather than hoped for.
#
#   ./01_isolation_two_session.sh 'read committed'
#   ./01_isolation_two_session.sh 'repeatable read'
#   ./01_isolation_two_session.sh 'serializable'
set -uo pipefail

LEVEL="${1:-read committed}"
: "${PGHOST:=localhost}" "${PGPORT:=5433}" "${PGUSER:=openledger}" "${PGDATABASE:=spike_wse}"
export PGHOST PGPORT PGUSER PGDATABASE
export PGPASSWORD="${PGPASSWORD:-openledger}"

ACCT='22222222-0000-0000-0000-000000000001'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

q() { psql -X -q -t -A -c "$1"; }

UPSERT="INSERT INTO ledger_account_balances AS b (tenant_id, account_id, currency, input, output, last_seq)
VALUES ('t2','$ACCT','USD', 0, %AMT%, 1)
ON CONFLICT (tenant_id, account_id, currency) DO UPDATE
   SET input    = b.input  + excluded.input,
       output   = b.output + excluded.output,
       last_seq = b.last_seq + 1
RETURNING b.last_seq, b.input - b.output;"

# a clean slate for this run
q "UPDATE ledger_account_balances SET input = 0, output = 0, last_seq = 0
    WHERE tenant_id='t2' AND account_id='$ACCT';" >/dev/null

# wait until session $1 is in state $2 (and, if given, waiting on $3)
wait_for() {
  local app="$1" st="$2" wev="${3:-}" n=0
  while :; do
    local got
    got=$(q "SELECT count(*) FROM pg_stat_activity
              WHERE application_name='$app' AND state='$st'
                $( [ -n "$wev" ] && echo "AND wait_event_type='$wev'" )")
    [ "$got" = "1" ] && return 0
    n=$((n+1)); [ "$n" -gt 100 ] && { echo "TIMED OUT waiting for $app/$st/$wev" >&2; return 1; }
    q "SELECT pg_sleep(0.05)" >/dev/null
  done
}

mkfifo "$TMP/a.in" "$TMP/b.in"
PGAPPNAME=sess_a psql -X -e -a --set=ON_ERROR_STOP=0 < "$TMP/a.in" > "$TMP/a.out" 2>&1 &
PGAPPNAME=sess_b psql -X -e -a --set=ON_ERROR_STOP=0 < "$TMP/b.in" > "$TMP/b.out" 2>&1 &
exec 3>"$TMP/a.in" 4>"$TMP/b.in"

echo "=== isolation level: $LEVEL ==="

# --- A: take the row
{ echo "BEGIN ISOLATION LEVEL $LEVEL;"; echo "${UPSERT/\%AMT\%/100}"; } >&3
wait_for sess_a 'idle in transaction'

# --- B: same row. Blocks on A's row lock.
{ echo "BEGIN ISOLATION LEVEL $LEVEL;"; echo "${UPSERT/\%AMT\%/7}"; } >&4
wait_for sess_b 'active' 'Lock'
echo "-- B is blocked on A's row lock (pg_stat_activity.wait_event_type = Lock)"

# --- A: release it
echo "COMMIT;" >&3
wait_for sess_a 'idle'

# --- B: whatever it did, then finish
echo "COMMIT;" >&4
echo "\q" >&4; echo "\q" >&3
exec 3>&- 4>&-
wait

echo "--- session A ---"; cat "$TMP/a.out"
echo "--- session B ---"; cat "$TMP/b.out"
echo "--- the row afterwards ---"
psql -X -c "SELECT input, output, last_seq FROM ledger_account_balances
             WHERE tenant_id='t2' AND account_id='$ACCT';"
