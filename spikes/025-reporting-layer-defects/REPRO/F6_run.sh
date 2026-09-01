#!/usr/bin/env bash
# F6 end to end, against a freshly restored spike025_f6.
#
# The reproduction has to drive the SHIPPED WRITER over HTTP -- "the shipped
# writer can reach it" and "only the owner can reach it" are different severities,
# and every append below except the last stage's is a POST -- so the ordering
# lives here rather than in one .sql file. It starts the compiled binary itself,
# on a port of its own, and stops it again.
#
# THE POSTS THAT BUILD THE STATE ARE SEQUENTIAL AND THAT IS LOAD-BEARING. A
# sequential post is dispatched to one writer, and each writer stripes on the
# index it holds for its lifetime (ADR-0018 §1), so consecutive calls land on
# consecutive stripes -- which is how one account ends up with one ceiling-sized
# entry on each of six of them. Two SIMULTANEOUS ceiling-sized postings are a
# different matter and are probed separately, in a book of their own: whether
# they ride one shared batched statement is not deterministic, and if they do,
# that statement's cross-member coalesce re-adds at bigint and the whole batch is
# refused with `bigint out of range` before anything commits.
set -euo pipefail

BASE="${BASE:-postgres://openledger:openledger@localhost:5455}"
DB="${DB:-spike025_f6}"
URL="$BASE/$DB?sslmode=disable"
PORT="${PORT:-8126}"
BIN="${BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/target/debug/openledger}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The largest legal entry: bigint, and ck_entries__amount_positive bounds it
# only below.
M=9223372036854775807
C1=00000000-0000-4000-8000-0000000000c1
D1=00000000-0000-4000-8000-0000000000d1
A1=00000000-0000-4000-8000-0000000000a1
A2=00000000-0000-4000-8000-0000000000a2
B1=00000000-0000-4000-8000-0000000000b1
B2=00000000-0000-4000-8000-0000000000b2
E1=00000000-0000-4000-8000-0000000000e1
F1=00000000-0000-4000-8000-0000000000f1

echo "########## F6 stage 0: the ceiling"
psql "$URL" -q -f "$HERE/F6_00_ceiling.sql"

echo
echo "########## F6 stage 1: the books, opened as openledger_app"
psql "$URL" -q -v ON_ERROR_STOP=1 -f "$HERE/F6_10_provision.sql"

echo
echo "########## F6 stage 2: the shipped writer, over HTTP on :$PORT"
# Never --database-url: it would be visible in ps.
OPENLEDGER_BIND="127.0.0.1:$PORT" DATABASE_URL="$URL" "$BIN" serve &
SERVE_PID=$!
trap 'kill "$SERVE_PID" 2>/dev/null || true' EXIT
until curl -s -o /dev/null "http://127.0.0.1:$PORT/v1/transactions" -X POST \
        -H 'content-type: application/json' -d '{}'; do :; done

post() { # $1 = a jq-free JSON body
    curl -s -w ' HTTP %{http_code}\n' -X POST "http://127.0.0.1:$PORT/v1/transactions" \
         -H 'content-type: application/json' -d "$1"
}
one_posting() { # tenant, key, source, destination, amount, extra fields
    printf '{"tenant_id":"%s","idempotency_key":"%s","effective_at":"2026-06-15T00:00:00Z"%s,"postings":[{"source":"%s","destination":"%s","amount_minor":%s,"currency":"USD"}]}' \
        "$1" "$2" "$6" "$3" "$4" "$5"
}

echo
echo "--- 2a: the writer's own refusals and the batching probe"
echo "  two ceiling-sized debit legs on ONE account in one transaction:"
echo "  coalesce() in crates/ledger/src/postings.rs adds with checked_add."
post "{\"tenant_id\":\"t3\",\"idempotency_key\":\"f6-coalesce\",\"effective_at\":\"2026-06-15T00:00:00Z\",\"postings\":[{\"source\":\"$B1\",\"destination\":\"$A1\",\"amount_minor\":$M,\"currency\":\"USD\"},{\"source\":\"$B2\",\"destination\":\"$A1\",\"amount_minor\":$M,\"currency\":\"USD\"}]}"

echo
echo
echo "  ...and two ceiling-sized postings sent SIMULTANEOUSLY, in t5. Whichever"
echo "  outcome shows here is a real one: dispatched to two writers they commit on"
echo "  two stripes, and collected into ONE batch they are both refused with"
echo "  \`bigint out of range\` -- the batched statement's cross-member coalesce"
echo "  re-adds at bigint (crates/ledger/postgres/src/repository.rs)."
# Waited on by pid, not by a bare `wait`: the server is a background job of this
# same shell and a bare wait would never return.
post "$(one_posting t5 f6-concurrent-1 "$F1" "$E1" "$M" '')" & P1=$!
post "$(one_posting t5 f6-concurrent-2 "$F1" "$E1" "$M" '')" & P2=$!
wait "$P1" "$P2"

echo
echo "--- 2b: one t3 transaction whose DEBIT legs sum to 2 * (2^63-1)"
echo "  two debit accounts, because the coalesce above refuses one."
post "{\"tenant_id\":\"t3\",\"idempotency_key\":\"f6-txn\",\"effective_at\":\"2026-06-15T00:00:00Z\",\"postings\":[{\"source\":\"$B1\",\"destination\":\"$A1\",\"amount_minor\":$M,\"currency\":\"USD\"},{\"source\":\"$B2\",\"destination\":\"$A2\",\"amount_minor\":$M,\"currency\":\"USD\"}]}"

echo
echo "--- 2c: two PENDING t3 transactions, both debiting one account at the ceiling"
for k in 1 2; do
    post "{\"tenant_id\":\"t3\",\"idempotency_key\":\"f6-pending-$k\",\"effective_at\":\"2026-06-1${k}T00:00:00Z\",\"status\":\"pending\",\"postings\":[{\"source\":\"$B1\",\"destination\":\"$A1\",\"amount_minor\":$M,\"currency\":\"USD\"}]}"
done

echo
echo "--- 2d: six SEQUENTIAL t4 postings at the ceiling, one per writer, one per stripe"
for k in 1 2 3 4 5 6; do
    post "$(one_posting t4 "f6-striped-$k" "$D1" "$C1" "$M" '')"
done

kill "$SERVE_PID" 2>/dev/null || true
wait "$SERVE_PID" 2>/dev/null || true
trap - EXIT

echo
echo "########## F6 stage 3: the three aggregates at that state"
# NO ON_ERROR_STOP: one statement in this file is expected to raise
# (trial_balance_at, the numeric-summing FUNCTION), and the file must carry on to
# show that the bare-bigint views around it do not.
psql "$URL" -q -f "$HERE/F6_20_probe.sql"

echo
echo "########## F6 stage 3b: the compiled sweep"
DATABASE_URL="$URL" "$BIN" reconcile; echo "exit=$?"

echo
echo "########## F6 stage 4: a break row that CARRIES a value past bigint"
psql "$URL" -q -v ON_ERROR_STOP=1 -f "$HERE/F6_30_emit.sql"

echo
echo "########## F6 stage 4b: the compiled sweep, with the forged imbalance"
DATABASE_URL="$URL" "$BIN" reconcile || echo "exit=$?"

echo
echo "F6 done. The book is dirty and forward-only; restore before re-running:"
echo "  psql \"\$BASE/postgres?sslmode=disable\" -c 'DROP DATABASE IF EXISTS $DB WITH (FORCE);' -c 'CREATE DATABASE $DB TEMPLATE spike025_clean;'"
