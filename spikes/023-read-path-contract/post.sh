#!/usr/bin/env bash
# Post one transaction through the COMPILED BINARY over HTTP — the only writer
# this spike uses for the reproducibility questions, because a read-path spike
# that writes with hand-built SQL is measuring a schema and not a system.
#
#   post.sh <tenant> <key> <effective_at> <src> <dst> <amount_minor>
set -euo pipefail
BASE="${BASE:-http://127.0.0.1:8123}"
curl -sS -X POST "$BASE/v1/transactions" \
  -H 'content-type: application/json' \
  -d "{\"tenant_id\":\"$1\",\"idempotency_key\":\"$2\",\"effective_at\":\"$3\",
       \"postings\":[{\"source\":\"$4\",\"destination\":\"$5\",\"amount_minor\":$6,\"currency\":\"USD\"}]}"
echo
