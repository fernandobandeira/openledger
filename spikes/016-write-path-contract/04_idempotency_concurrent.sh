#!/usr/bin/env bash
# 04_idempotency_concurrent.sh -- the replay path when two callers race the SAME key.
#
# The interesting case is not the sequential retry (03 covers that). It is the one a
# retry loop actually produces: two attempts in flight at once. Session A claims the
# key and holds its transaction open; session B runs the same claim and BLOCKS on
# A's uncommitted index tuple; A commits; B is released with zero rows and has to
# find A's outcome.
#
# Three variants of B, one argument:
#   two-stmt-rc   INSERT..DO NOTHING then a SEPARATE SELECT, READ COMMITTED  -> works
#   two-stmt-rr   the same, REPEATABLE READ                                  -> blind
#   one-stmt-cte  INSERT..DO NOTHING and the SELECT in ONE statement, RC     -> blind
set -uo pipefail

VARIANT="${1:-two-stmt-rc}"
: "${PGHOST:=localhost}" "${PGPORT:=5433}" "${PGUSER:=openledger}" "${PGDATABASE:=spike_wse}"
export PGHOST PGPORT PGUSER PGDATABASE
export PGPASSWORD="${PGPASSWORD:-openledger}"

KEY="k-race-$VARIANT"
BODY='{"amt":500}'
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
q() { psql -X -q -t -A -c "$1"; }

CLAIM="INSERT INTO ledger_events AS e (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
VALUES ('t1','clearing','processor','$KEY', sha256('$BODY'), '$BODY', '2026-08-20T00:00:00Z')
ON CONFLICT (tenant_id, idempotency_key) DO NOTHING"

LOOKUP="SELECT e.id AS event_id, e.idempotency_hash = sha256('$BODY') AS body_matches
FROM ledger_events e WHERE e.tenant_id='t1' AND e.idempotency_key='$KEY'"

case "$VARIANT" in
  two-stmt-rc) ISO='read committed';  B_SQL=$(printf '%s RETURNING e.id;\n%s;\n' "$CLAIM" "$LOOKUP") ;;
  two-stmt-rr) ISO='repeatable read'; B_SQL=$(printf '%s RETURNING e.id;\n%s;\n' "$CLAIM" "$LOOKUP") ;;
  one-stmt-cte) ISO='read committed'
     B_SQL=$(printf 'WITH attempt AS (\n%s RETURNING e.id\n)\nSELECT id AS event_id, false AS replayed FROM attempt\nUNION ALL\n%s AND NOT EXISTS (SELECT 1 FROM attempt);\n' "$CLAIM" "${LOOKUP/e.idempotency_hash = sha256(\'$BODY\') AS body_matches/true AS replayed}") ;;
  *) echo "unknown variant $VARIANT" >&2; exit 2 ;;
esac

wait_for() {
  local app="$1" st="$2" wev="${3:-}" n=0 got
  while :; do
    got=$(q "SELECT count(*) FROM pg_stat_activity WHERE application_name='$app' AND state='$st'
             $( [ -n "$wev" ] && echo "AND wait_event_type='$wev'" )")
    [ "$got" = "1" ] && return 0
    n=$((n+1)); [ "$n" -gt 200 ] && { echo "TIMED OUT $app/$st/$wev" >&2; return 1; }
    q "SELECT pg_sleep(0.05)" >/dev/null
  done
}

q "DELETE FROM ledger_events WHERE tenant_id='t1' AND idempotency_key='$KEY';" >/dev/null 2>&1 || true

mkfifo "$TMP/a.in" "$TMP/b.in"
PGAPPNAME=sess_a psql -X -e -a < "$TMP/a.in" > "$TMP/a.out" 2>&1 &
PGAPPNAME=sess_b psql -X -e -a < "$TMP/b.in" > "$TMP/b.out" 2>&1 &
exec 3>"$TMP/a.in" 4>"$TMP/b.in"

echo "=== variant: $VARIANT   (session B isolation: $ISO)"
{ echo "BEGIN ISOLATION LEVEL read committed;"; echo "$CLAIM RETURNING e.id;"; } >&3
wait_for sess_a 'idle in transaction'

{ echo "BEGIN ISOLATION LEVEL $ISO;"; echo "$B_SQL"; } >&4
wait_for sess_b 'active' 'Lock'
echo "-- B blocked on A's uncommitted index tuple"

echo "COMMIT;" >&3; wait_for sess_a 'idle'
echo "COMMIT;" >&4
echo "\q" >&4; echo "\q" >&3
exec 3>&- 4>&-
wait

echo "--- session B (the replaying caller) ---"; sed -n '/BEGIN ISOLATION/,$p' "$TMP/b.out"
echo "--- committed truth ---"
psql -X -c "SELECT id AS event_id FROM ledger_events WHERE tenant_id='t1' AND idempotency_key='$KEY';"
