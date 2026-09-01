#!/usr/bin/env bash
# The book, written through the SHIPPED WRITER over HTTP -- the front door,
# so a defect below is a defect of the artefact and not of a hand-written
# INSERT that the writer would never emit. Six transactions on t1 (one of
# them pending, so the pending bridge has a real population, as spike 011's
# clean book does) and one on t2, so the tenant-scoping findings have a
# second book to be silent about.
set -euo pipefail
: "${DATABASE_URL:?set DATABASE_URL}"
BIND="${BIND:-127.0.0.1:8125}"
BIN="${BIN:-./target/debug/openledger}"

id() { psql "$DATABASE_URL" -At -c "SELECT id FROM ledger_accounts WHERE tenant_id='$1' AND purpose='$2'"; }
AR1=$(id t1 customer_receivable); W1=$(id t1 customer_wallet)
REV=$(id t1 fee_revenue);         EXP=$(id t1 platform_rev_share_expense)
PAY=$(id t1 platform_rev_share_payable); TRN=$(id t1 outbound_transfer_in_transit)
CAP=$(id t1 paid_in_capital)
AR2=$(id t2 customer_receivable); REV2=$(id t2 fee_revenue)

OPENLEDGER_BIND="$BIND" "$BIN" serve >/tmp/spike025-serve.log 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
until curl -s -o /dev/null "http://$BIND/v1/transactions" -X POST -d '{}' -H 'content-type: application/json'; do :; done

post() { curl -sS -w ' -> %{http_code}\n' "http://$BIND/v1/transactions" \
           -H 'content-type: application/json' -d "$1"; }

# 1. equity subscribed: DR customer_receivable / CR paid_in_capital
post "{\"tenant_id\":\"t1\",\"idempotency_key\":\"fund-1\",\"effective_at\":\"2026-08-02T00:00:00Z\",
       \"postings\":[{\"source\":\"$CAP\",\"destination\":\"$AR1\",\"amount_minor\":1000000,\"currency\":\"USD\"}]}"
# 2. a fee: DR customer_receivable / CR fee_revenue
post "{\"tenant_id\":\"t1\",\"idempotency_key\":\"fee-1\",\"effective_at\":\"2026-08-05T00:00:00Z\",
       \"postings\":[{\"source\":\"$REV\",\"destination\":\"$AR1\",\"amount_minor\":250000,\"currency\":\"USD\"}]}"
# 3. wallet credited on account: DR customer_receivable / CR customer_wallet
post "{\"tenant_id\":\"t1\",\"idempotency_key\":\"wallet-1\",\"effective_at\":\"2026-08-10T00:00:00Z\",
       \"postings\":[{\"source\":\"$W1\",\"destination\":\"$AR1\",\"amount_minor\":500000,\"currency\":\"USD\"}]}"
# 4. rev-share accrual: DR platform_rev_share_expense / CR platform_rev_share_payable
post "{\"tenant_id\":\"t1\",\"idempotency_key\":\"revshare-1\",\"effective_at\":\"2026-08-20T00:00:00Z\",
       \"postings\":[{\"source\":\"$PAY\",\"destination\":\"$EXP\",\"amount_minor\":30000,\"currency\":\"USD\"}]}"
# 5. a PENDING withdrawal: DR customer_wallet / CR outbound_transfer_in_transit
post "{\"tenant_id\":\"t1\",\"idempotency_key\":\"withdraw-1\",\"status\":\"pending\",\"effective_at\":\"2026-08-25T00:00:00Z\",
       \"postings\":[{\"source\":\"$TRN\",\"destination\":\"$W1\",\"amount_minor\":50000,\"currency\":\"USD\"}]}"
# 6. t2's own book
post "{\"tenant_id\":\"t2\",\"idempotency_key\":\"fee-1\",\"effective_at\":\"2026-08-05T00:00:00Z\",
       \"postings\":[{\"source\":\"$REV2\",\"destination\":\"$AR2\",\"amount_minor\":100000,\"currency\":\"USD\"}]}"
