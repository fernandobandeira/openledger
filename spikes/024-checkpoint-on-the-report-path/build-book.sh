#!/usr/bin/env bash
# Spike 024 -- build the book, drop and recreate `spike024` from scratch.
#
#   ./build-book.sh
#
# Everything except the close goes through the COMPILED BINARY over HTTP
# (`openledger serve`), because the point of the correctness work is agreement
# on a book the shipped writer actually produced: pending -> posted, the void
# and the derived reversal mirror are writer semantics, and re-implementing them
# in a SQL fixture would be testing the fixture. The close is the one operation
# POST /v1/transactions cannot express -- no `kind` on the wire, and
# fk_closes__txn_kind demands kind='period_close' -- so it stays SQL, exactly as
# spike 020 left it.
#
# NO TIMING ANYWHERE IN THIS FILE. Another spike holds this machine.
set -euo pipefail
cd "$(dirname "$0")"
export PGPASSWORD=openledger
PGH="-h localhost -p 5433 -U openledger"
DB="${DB:-spike024}"
MODE="${MODE:-xmin_strict}"
URL="postgres://openledger:openledger@localhost:5433/$DB?sslmode=disable"
ROOT=../..
Q="psql $PGH -d $DB -q -v ON_ERROR_STOP=1"
OUT=out
mkdir -p "$OUT"

# ---------------------------------------------------------------- the database
psql $PGH -d postgres -qc \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid<>pg_backend_pid();" >/dev/null 2>&1 || true
psql $PGH -d postgres -qc "DROP DATABASE IF EXISTS $DB WITH (FORCE);" -qc "CREATE DATABASE $DB;" >/dev/null
echo "== mode=$MODE db=$DB"
echo "== schema: the compiled binary, DATABASE_URL not --database-url"
DATABASE_URL="$URL" "$ROOT/target/debug/openledger" migrate
$Q --single-transaction -f "$ROOT/schema/chart.sql" 2>&1 | grep -v "WARNING:  there is" || true
$Q -f sql/00_helpers.sql
$Q -f sql/10_accounts.sql | tee "$OUT/accounts.txt" >/dev/null
echo "   chart + helpers + accounts loaded"

# ---------------------------------------------------------------- the server
"$ROOT/target/debug/openledger" serve --bind 127.0.0.1:0 >"$OUT/serve.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
export DATABASE_URL="$URL"
# serve reads DATABASE_URL from the environment; it was exported after the
# background start, so restart it properly under the env instead.
kill $SERVER 2>/dev/null || true
wait $SERVER 2>/dev/null || true
DATABASE_URL="$URL" "$ROOT/target/debug/openledger" serve --bind 127.0.0.1:0 >"$OUT/serve.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 100); do
    BASE=$(sed -n 's/^listening on //p' "$OUT/serve.log" | head -1)
    [ -n "$BASE" ] && break
    sleep 0.1
done
[ -n "${BASE:-}" ] || { echo "server did not announce; log:"; cat "$OUT/serve.log"; exit 1; }
echo "== server on $BASE"

# ---------------------------------------------------------------- posting
acct() {  # tenant name currency -> the uuid spike_account derived
    printf '%s' "$1:$2:$3" | md5sum | awk '{ h=$1;
        print substr(h,1,8)"-"substr(h,9,4)"-"substr(h,13,4)"-"substr(h,17,4)"-"substr(h,21,12) }'
}

LAST_TXN=""
post() {  # $1 = json body -- sets LAST_TXN
    local body=$1 resp code
    resp=$(curl -sS -o /tmp/spike024.resp -w '%{http_code}' \
        -H 'Content-Type: application/json' -X POST "$BASE/v1/transactions" -d "$body")
    code=$resp
    if [ "$code" != "201" ] && [ "$code" != "200" ]; then
        echo "POST refused ($code): $(cat /tmp/spike024.resp)"; echo "  body: $body"; exit 1
    fi
    LAST_TXN=$(python3 -c 'import json,sys;print(json.load(open("/tmp/spike024.resp"))["transaction_id"])')
}

simple() {  # tenant currency key effective source dest amount [status]
    local t=$1 c=$2 k=$3 eff=$4 src=$5 dst=$6 amt=$7 st=${8:-}
    local extra=""
    [ -n "$st" ] && extra=",\"status\":\"$st\""
    post "{\"tenant_id\":\"$t\",\"idempotency_key\":\"$k\",\"effective_at\":\"$eff\",
           \"postings\":[{\"source\":\"$(acct "$t" "$src" "$c")\",
                          \"destination\":\"$(acct "$t" "$dst" "$c")\",
                          \"amount_minor\":$amt,\"currency\":\"$c\"}]$extra}"
}

cursor() { psql $PGH -d $DB -tAc "SELECT report_cursor();"; }

# The cluster horizon is per SERVER, and another spike writes to another database
# on it: a close taken while the horizon is pinned below our own writes stores a
# checkpoint of NOTHING (proven in run-cursor-arms.sh). Poll until our book is
# below the horizon, then close.
wait_for_horizon() {
    local i
    for i in $(seq 1 400); do
        if [ "$(psql $PGH -d $DB -tAc "SELECT pg_snapshot_xmin(pg_current_snapshot())
                    > COALESCE((SELECT max(xact_id) FROM ledger_entries), '0'::xid8)")" = t ]; then
            return 0
        fi
        sleep 0.25
    done
    echo "!! horizon never caught up"; return 1
}
close_period() { wait_for_horizon || true
    $Q -c "SELECT spike_close_mode('$1','$2','$3','$MODE');" >/dev/null; }

declare -A TXN   # TXN[tenant/currency/label] = transaction id

for T in bk nc; do
  for C in USD EUR; do
    # ---- A: January, before any close
    simple $T $C "$T-$C-A1" '2026-01-05T00:00:00Z' pic      recv_1 10000 ; TXN[$T/$C/A1]=$LAST_TXN
    simple $T $C "$T-$C-A2" '2026-01-10T00:00:00Z' fee      recv_1   500 ; TXN[$T/$C/A2]=$LAST_TXN
    simple $T $C "$T-$C-A3" '2026-01-12T00:00:00Z' wallet_1 loss     100 ; TXN[$T/$C/A3]=$LAST_TXN
    simple $T $C "$T-$C-A4" '2026-01-15T00:00:00Z' fee      recv_2   700 pending ; TXN[$T/$C/A4]=$LAST_TXN
    simple $T $C "$T-$C-A5" '2026-01-16T00:00:00Z' fee      recv_2   300 pending ; TXN[$T/$C/A5]=$LAST_TXN
    simple $T $C "$T-$C-A6" '2026-01-17T00:00:00Z' inter    recv_2   250 pending ; TXN[$T/$C/A6]=$LAST_TXN
  done
done

# The cursor an "issued" report is pinned at, captured BEFORE any close exists.
# The whole reproducibility claim of ADR-0011 is about re-running at this value
# after the book has moved -- and it is the case a checkpoint reader can get
# wrong, because the checkpoint was computed at a HIGHER cursor.
P0=$(cursor); echo "== P0 (pre-close cursor) = $P0"

# ---- B: close 2026-01. bk only; nc is the no-close arm.
close_period bk 2026-01 USD
close_period bk 2026-01 EUR
echo "== closed bk/2026-01 in USD and EUR"

for T in bk nc; do
  for C in USD EUR; do
    # ---- C: February, plus three arrivals dated INTO the closed January
    simple $T $C "$T-$C-C1" '2026-02-10T00:00:00Z' fee recv_1 400 ; TXN[$T/$C/C1]=$LAST_TXN
    # the resolution of A5, effective 2026-01-20: pending -> posted as a NEW
    # transaction, backdated into a period bk has already closed.
    post "{\"tenant_id\":\"$T\",\"idempotency_key\":\"$T-$C-C2\",
           \"effective_at\":\"2026-01-20T00:00:00Z\",\"resolves_id\":\"${TXN[$T/$C/A5]}\",
           \"postings\":[{\"source\":\"$(acct $T fee $C)\",
                          \"destination\":\"$(acct $T recv_2 $C)\",
                          \"amount_minor\":300,\"currency\":\"$C\"}]}"
    TXN[$T/$C/C2]=$LAST_TXN
    # the void of A6: a posted, ZERO-ENTRY marker reversing a pending target.
    post "{\"tenant_id\":\"$T\",\"idempotency_key\":\"$T-$C-C3\",\"reverses_id\":\"${TXN[$T/$C/A6]}\"}"
    TXN[$T/$C/C3]=$LAST_TXN
    # the reversal of A3, a POSTED January transaction: the mirror is derived
    # server-side and takes the target's own effective_at, so it too is
    # backdated into closed January.
    post "{\"tenant_id\":\"$T\",\"idempotency_key\":\"$T-$C-C4\",\"reverses_id\":\"${TXN[$T/$C/A3]}\"}"
    TXN[$T/$C/C4]=$LAST_TXN
  done
done
P1=$(cursor); echo "== P1 (after the January close and its three backdated arrivals) = $P1"

# ---- D: close 2026-02 -- USD ONLY. EUR stays closed through January, so the
# two currencies have different boundaries and a per-tenant boundary is wrong.
close_period bk 2026-02 USD
echo "== closed bk/2026-02 in USD only"

for T in bk nc; do
  for C in USD EUR; do
    simple $T $C "$T-$C-E1" '2026-03-05T00:00:00Z' inter recv_1 900 ; TXN[$T/$C/E1]=$LAST_TXN
    # an ordinary posting dated into January, arriving after TWO closes
    simple $T $C "$T-$C-E2" '2026-01-10T00:00:00Z' fee   recv_1  60 ; TXN[$T/$C/E2]=$LAST_TXN
  done
done

# ---- F: close 2026-03, USD
close_period bk 2026-03 USD
echo "== closed bk/2026-03 in USD"

for T in bk nc; do
  for C in USD EUR; do
    simple $T $C "$T-$C-G1" '2026-04-10T00:00:00Z' fee      recv_1 250 ; TXN[$T/$C/G1]=$LAST_TXN
    simple $T $C "$T-$C-G2" '2026-02-05T00:00:00Z' fee      recv_2 130 ; TXN[$T/$C/G2]=$LAST_TXN
    simple $T $C "$T-$C-G3" '2026-04-12T00:00:00Z' wallet_1 loss    70 ; TXN[$T/$C/G3]=$LAST_TXN
  done
done
P2=$(cursor); echo "== P2 (now) = $P2"

kill $SERVER 2>/dev/null || true; wait $SERVER 2>/dev/null || true; trap - EXIT

# ---------------------------------------------------------------- the cursors
$Q -c "CREATE TABLE spike_cursors (name text PRIMARY KEY, cur xid8);" \
   -c "INSERT INTO spike_cursors VALUES ('P0','$P0'),('P1','$P1'),('P2','$P2');"

# ---------------------------------------------------------------- the gate
echo
echo "############ THE GATE: ten checks, zero breaks, or nothing below is a finding"
psql $PGH -d $DB -c "SELECT * FROM reconciliation ORDER BY check_name;" | tee "$OUT/gate.txt"
BREAKS=$(psql $PGH -d $DB -tAc "SELECT COALESCE(SUM(breaks),0) FROM reconciliation;")
echo "total breaks = $BREAKS"
[ "$BREAKS" = "0" ] || { echo "!! the book does not reconcile -- stop"; exit 1; }

echo
echo "############ what the book contains"
psql $PGH -d $DB -c "
SELECT e.tenant_id, e.currency, count(*) AS entries,
       count(*) FILTER (WHERE x.status='pending') AS pending_entries
FROM ledger_entries e JOIN ledger_transactions x
  ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id
GROUP BY 1,2 ORDER BY 1,2;" \
 -c "SELECT tenant_id, kind, status, count(*) FROM ledger_transactions
     GROUP BY 1,2,3 ORDER BY 1,2,3;" \
 -c "SELECT tenant_id, period_code, currency, computed_at_xid, ends_at
     FROM ledger_period_closes ORDER BY 1,3,2;" \
 -c "SELECT tenant_id, period_code, currency, count(*) AS checkpoint_rows,
            sum(input) AS input, sum(output) AS output
     FROM ledger_period_balances GROUP BY 1,2,3 ORDER BY 1,3,2;" \
 -c "SELECT count(*) AS close_disclosure_rows FROM close_disclosures;" \
 | tee "$OUT/book.txt"
