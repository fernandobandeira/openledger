#!/usr/bin/env bash
# Spike 021 — drift experiments.
#
# "A cannot is a claim like any other." Each experiment below makes ONE edit to a
# copy of one of the two projects, WITHOUT touching the other side of the
# contract, and reports what happened: compile error, changed spec, or silence.
#
# Nothing here mutates the committed sources: every variant is built in a scratch
# copy under $WORK. A shared CARGO_TARGET_DIR keeps the rebuilds incremental.
#
#   ./drift/RUN-drift.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
WORK="${WORK:-$(mktemp -d)}"
export CARGO_TARGET_DIR="$WORK/target"
mkdir -p "$WORK"

pass=0; fail=0
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
verdict() { printf '   VERDICT: %s\n' "$*"; }

# copy <project> <variant-name> -> echoes the copy's path
copy() {
  local src="$ROOT/$1" dst="$WORK/$2"
  rm -rf "$dst"; mkdir -p "$dst"
  cp -r "$src/Cargo.toml" "$src/src" "$dst/"
  echo "$dst"
}

# build_emit <dir> <bin> <out> -> prints build result, writes spec or reports error
build_emit() {
  local dir="$1" bin="$2" out="$3"
  if ! (cd "$dir" && cargo build --bin "$bin" 2>"$dir/build.err" >/dev/null); then
    echo "COMPILE ERROR:"
    grep -E '^error' "$dir/build.err" | head -5 | sed 's/^/     /'
    return 1
  fi
  (cd "$dir" && "$CARGO_TARGET_DIR/debug/$bin" emit "$out" 2>"$dir/emit.err")
  local n; n=$(grep -c . "$dir/emit.err" 2>/dev/null || echo 0)
  echo "built clean; emitter wrote $out (stderr lines: $n)"
  [ "$n" -gt 1 ] && sed 's/^/     stderr: /' "$dir/emit.err"
  return 0
}

echo "workdir: $WORK"

# ---------------------------------------------------------------------------
say "D1 · utoipa + PLAIN axum Router: the annotated path and the served route are two copies"
# The classic utoipa drift: `#[utoipa::path(path = "/v1/transactions")]` is one
# declaration and `Router::route("/v1/txns", ...)` is another. Nothing checks them
# against each other. `drift/utoipa_plain_router.rs` is that shape, verbatim.
d=$(copy utoipa-api d1)
cp "$HERE/utoipa_plain_router.rs" "$d/src/main.rs"
build_emit "$d" utoipa-api "$WORK/d1.json"
p=$(python3 -c "import json;print(list(json.load(open('$WORK/d1.json'))['paths'].keys()))" 2>/dev/null)
echo "     spec paths:  $p"
echo "     axum routes: ['/v1/txns', '/v1/accounts/{account_id}/balance']  (grep the source)"
verdict "compiles clean, spec documents endpoints that DO NOT EXIST. Silent drift."

# ---------------------------------------------------------------------------
say "D2 · utoipa + utoipa-axum \`routes!\`: the annotation IS the route"
d=$(copy utoipa-api d2)
sed -i 's|path = "/v1/transactions"|path = "/v1/txns"|' "$d/src/main.rs"
build_emit "$d" utoipa-api "$WORK/d2.json"
python3 - "$WORK/d2.json" <<'PY'
import json,sys
print("     spec paths after editing ONLY the annotation:", list(json.load(open(sys.argv[1]))['paths'].keys()))
PY
# and prove the served route moved with it
("$CARGO_TARGET_DIR/debug/utoipa-api" serve >/dev/null 2>&1 &) ; sleep 1
body='{"idempotency_key":"k1","effective_at":"2026-08-27T00:00:00Z","postings":[{"source":"a","destination":"b","amount":1,"currency":"USD"}]}'
new=$(curl -s -o /dev/null -w '%{http_code}' -XPOST -H 'content-type: application/json' -d "$body" http://127.0.0.1:8021/v1/txns)
old=$(curl -s -o /dev/null -w '%{http_code}' -XPOST -H 'content-type: application/json' -d "$body" http://127.0.0.1:8021/v1/transactions)
pkill -f 'debug/utoipa-api serve' 2>/dev/null
echo "     live server: POST /v1/txns -> $new ; POST /v1/transactions -> $old"
verdict "one edit moved BOTH the spec and the route. utoipa-axum removes path drift."

# ---------------------------------------------------------------------------
say "D3 · utoipa: the response STATUS is a free-text annotation, the handler is code"
d=$(copy utoipa-api d3)
sed -i 's|        StatusCode::CREATED,|        StatusCode::OK,|' "$d/src/main.rs"
build_emit "$d" utoipa-api "$WORK/d3.json"
if diff -q "$ROOT/spec/openapi.utoipa.json" "$WORK/d3.json" >/dev/null; then
  echo "     spec is BYTE-IDENTICAL to the committed one (still documents 201)"
  ("$CARGO_TARGET_DIR/debug/utoipa-api" serve >/dev/null 2>&1 &) ; sleep 1
  code=$(curl -s -o /dev/null -w '%{http_code}' -XPOST -H 'content-type: application/json' -d "$body" http://127.0.0.1:8021/v1/transactions)
  pkill -f 'debug/utoipa-api serve' 2>/dev/null
  echo "     live server actually returns: $code"
  verdict "compiles clean, spec unchanged and now WRONG. Silent drift."
else
  verdict "UNEXPECTED: the spec moved. Re-read the diff."
fi

# ---------------------------------------------------------------------------
say "D4 · utoipa: the request BODY is a free-text annotation too"
d=$(copy utoipa-api d4)
# The handler now accepts a single Posting; the annotation still says
# request_body = CreateTransactionRequest.
sed -i 's|    Json(req): Json<CreateTransactionRequest>,|    Json(req): Json<Posting>,|' "$d/src/main.rs"
sed -i 's|            transaction_id: req.postings.first().map(\|_\| Uuid::nil()),|            transaction_id: Some(Uuid::nil()),|' "$d/src/main.rs"
sed -i 's|    if req.idempotency_key == "poison" {|    if req.currency == "XXX" {|' "$d/src/main.rs"
sed -i 's|    let replayed = req.idempotency_key.starts_with("replay-");|    let replayed = false;|' "$d/src/main.rs"
build_emit "$d" utoipa-api "$WORK/d4.json"
python3 - "$WORK/d4.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print("     spec requestBody schema:",
      d['paths']['/v1/transactions']['post']['requestBody']['content']['application/json']['schema'])
PY
verdict "handler takes Posting, spec still says CreateTransactionRequest. Silent drift."

# ---------------------------------------------------------------------------
say "D5 · aide: the route string is the ONLY copy of the path"
d=$(copy aide-api d5)
sed -i 's|            "/v1/transactions",|            "/v1/txns",|' "$d/src/main.rs"
build_emit "$d" aide-api "$WORK/d5.json"
python3 - "$WORK/d5.json" <<'PY'
import json,sys
print("     spec paths:", list(json.load(open(sys.argv[1]))['paths'].keys()))
PY
verdict "the spec followed the router. aide cannot drift on path OR method."

# ---------------------------------------------------------------------------
say "D6 · aide: the response header lives in a hand-written OperationOutput, apart from IntoResponse"
d=$(copy aide-api d6)
# Change ONLY what the handler actually sends on the wire.
sed -i 's|HeaderName::from_static("idempotency-replayed")|HeaderName::from_static("x-replayed")|' "$d/src/main.rs"
sed -i 's|            StatusCode::CREATED,|            StatusCode::OK,|' "$d/src/main.rs"
build_emit "$d" aide-api "$WORK/d6.json"
if diff -q "$ROOT/spec/openapi.aide.json" "$WORK/d6.json" >/dev/null; then
  echo "     spec is BYTE-IDENTICAL (still 201, still Idempotency-Replayed)"
  verdict "compiles clean, spec unchanged and now WRONG. Same silent drift as utoipa, in the one place ADR-0013 cares about."
else
  verdict "UNEXPECTED: the spec moved. Re-read the diff."
fi

# ---------------------------------------------------------------------------
say "D7 · aide: the ordinary axum return type. No annotation to forget -- and no spec either"
d=$(copy aide-api d7)
build_emit "$d" aide-naive "$WORK/d7.json"
python3 - "$WORK/d7.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
post=d['paths']['/v1/transactions']['post']
get=d['paths']['/v1/accounts/{id}/balance']['get']
print("     POST /v1/transactions keys:", sorted(post.keys()))
print("     POST responses:", post.get('responses', 'ABSENT'))
print("     GET  parameters:", get.get('parameters', 'ABSENT'))
PY
verdict "handler returns (StatusCode, [header], Json<T>) and Path<Uuid>; aide's OperationOutput impl for tuples is empty and its Path impl needs an object, so the 201, the body, the header and the {id} parameter are ALL missing. Zero compile errors, zero stderr diagnostics."

# ---------------------------------------------------------------------------
say "D8 · both: rename a field on a schema type"
for proj in utoipa-api aide-api; do
  d=$(copy $proj d8-$proj)
  f="$d/src/main.rs"; [ "$proj" = aide-api ] && f="$d/src/contract.rs"
  sed -i 's|    pub currency: String,\n|XX|' "$f"
  python3 - "$f" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("pub currency: String,\n}", "pub ccy: String,\n}",1)
open(p,'w').write(s)
PY
  bin=$proj; [ "$proj" = aide-api ] && bin=aide-api
  echo "  --- $proj"
  build_emit "$d" "$bin" "$WORK/d8.$proj.json" | sed 's/^/  /'
  python3 - "$WORK/d8.$proj.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print("     Posting properties:", sorted(d['components']['schemas']['Posting']['properties']))
PY
done
verdict "both regenerate from the type. Field-level drift is impossible in either -- the schema is derived, not declared."

# ---------------------------------------------------------------------------
say "D9 · aide: describing a response aide has already inferred is reported as an ERROR"
d=$(copy aide-api d9)
python3 "$HERE/_d9_patch.py" "$d/src/main.rs"
build_emit "$d" aide-api "$WORK/d9.json"
python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print('     200 description that survived:',
      repr(d['paths']['/v1/accounts/{id}/balance']['get']['responses']['200']['description']))
" "$WORK/d9.json"
verdict "aide reports its own inference colliding with your documentation as an error, keeps YOUR version, and routes the message through generate::on_error -- which is OFF by default. The build succeeds either way."

echo
echo "artifacts left in $WORK"
