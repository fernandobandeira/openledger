#!/usr/bin/env bash
# Q5 · what an inception scan costs, and where the 30 s statement_timeout sits.
#
# INDICATIVE, NOT A BENCHMARK. This machine had another agent's spike running
# against the same PostgreSQL for the whole of spike 023 — a session in
# `spike024arms` held a transaction open and pinned the cluster's xmin
# horizon — so the 1-minute loadavg is recorded either side of every run and
# the absolute numbers are SHAPE ONLY. What is claimed is the growth in the
# scan against the book's size and the order of magnitude at which it meets
# 30 s; nothing about a millisecond.
#
# Three books, one tenant each, so each measurement is one tenant's whole
# history: 10k, 100k and 1M entries over the same three years of business
# dates, on 8 stripes.
set -euo pipefail
cd "$(dirname "$0")"

DB="${DB:-postgres://openledger:openledger@localhost:5433/spike023?sslmode=disable}"
la() { cut -d' ' -f1 /proc/loadavg; }

build() {   # build <tenant> <transactions>
  local tenant="$1" n="$2"
  if [ "$(psql "$DB" -tAqc "SELECT count(*) FROM ledger_entries WHERE tenant_id='$tenant'")" = "0" ]; then
    echo "-- building $tenant: $n transactions (loadavg $(la))"
    psql "$DB" -v ON_ERROR_STOP=1 -q -v tenant="$tenant" -v n="$n" -v stripes=8 \
         -f sql/10-bulk-book.sql > /dev/null
  fi
}

# Five passes per cell; the median is what the write-up quotes and the spread
# is what says whether to trust it. `EXPLAIN (ANALYZE, BUFFERS)` rather than
# \timing, so the number excludes psql's own round trip and carries the plan's
# buffer counts with it.
time_it() {   # time_it <label> <sql>
  local label="$1" sql="$2" ms=()
  for _ in 1 2 3 4 5; do
    ms+=("$(psql "$DB" -tAqc "EXPLAIN (ANALYZE, TIMING OFF, BUFFERS) $sql" \
            | grep -oP 'Execution Time: \K[0-9.]+')")
  done
  local sorted; sorted=$(printf '%s\n' "${ms[@]}" | sort -g)
  local median; median=$(echo "$sorted" | sed -n 3p)
  local lo hi; lo=$(echo "$sorted" | head -1); hi=$(echo "$sorted" | tail -1)
  printf '%-46s median %10s ms   range %s–%s   loadavg %s\n' "$label" "$median" "$lo" "$hi" "$(la)"
}

for pair in "big10k:5000" "big100k:50000" "big1m:500000"; do
  build "${pair%%:*}" "${pair##*:}"
done

echo
echo "== the books =="
psql "$DB" -c "SELECT tenant_id, count(*) AS entries,
                      count(DISTINCT transaction_id) AS transactions,
                      count(DISTINCT (account_id, stripe)) AS balance_rows
               FROM ledger_entries GROUP BY 1 ORDER BY 2"
psql "$DB" -c "SELECT pg_size_pretty(pg_total_relation_size('ledger_entries')) AS entries_size,
                      pg_size_pretty(pg_total_relation_size('ledger_transactions')) AS txn_size"

echo
echo "== the inception scan, per book (loadavg at start: $(la)) =="
for t in big10k big100k big1m; do
  n=$(psql "$DB" -tAqc "SELECT count(*) FROM ledger_entries WHERE tenant_id='$t'")
  echo "---- $t ($n entries) ----"
  time_it "trial_balance_at, since inception" \
    "SELECT * FROM trial_balance_at('$t','-infinity','infinity', report_cursor())"
  time_it "balance_sheet_at, as at infinity" \
    "SELECT * FROM balance_sheet_at('$t','infinity', report_cursor(), 3)"
  time_it "income_statement_for, since inception" \
    "SELECT * FROM income_statement_for('$t','-infinity','infinity', report_cursor(), 3)"
  time_it "one account's CURRENT balance (SUM over stripes)" \
    "SELECT sum(input - output) FROM ledger_account_balances
     WHERE tenant_id='$t'
       AND account_id=(SELECT id FROM ledger_accounts
                       WHERE tenant_id='$t' AND purpose='customer_receivable')
       AND currency='USD'"
  time_it "one account, as of a business date (mid-book)" \
    "SELECT * FROM trial_balance_at('$t','-infinity','2024-07-01', report_cursor())"
done

echo
echo "== the row counts the three reports RETURN (the result is small; the scan is not) =="
psql "$DB" -c "SELECT 'trial_balance_at' AS f, count(*) FROM trial_balance_at('big1m','-infinity','infinity', report_cursor())
               UNION ALL SELECT 'balance_sheet_at', count(*) FROM balance_sheet_at('big1m','infinity', report_cursor(), 3)
               UNION ALL SELECT 'income_statement_for', count(*) FROM income_statement_for('big1m','-infinity','infinity', report_cursor(), 3)"

echo
echo "== the plan at 1M, to say WHAT is being scanned =="
psql "$DB" -c "EXPLAIN (ANALYZE, TIMING OFF, BUFFERS)
               SELECT * FROM trial_balance_at('big1m','-infinity','infinity', report_cursor())"
psql "$DB" -c "EXPLAIN (ANALYZE, TIMING OFF, BUFFERS)
               SELECT * FROM balance_sheet_at('big1m','infinity', report_cursor(), 3)" | head -40

echo
echo "== does the checkpoint exist to be read? (ADR-0011 §3, roadmap M5) =="
psql "$DB" -c "SELECT count(*) AS period_rows FROM ledger_periods"
psql "$DB" -c "SELECT count(*) AS checkpoint_rows FROM ledger_period_balances"
psql "$DB" -tAqc "SELECT 'ledger_period_balances is referenced by: ' ||
   coalesce(string_agg(DISTINCT p.proname, ', '), '<no function>')
   FROM pg_proc p WHERE pg_get_functiondef(p.oid) LIKE '%ledger_period_balances%'
     AND p.pronamespace = 'public'::regnamespace"
psql "$DB" -tAqc "SELECT 'and by these views: ' ||
   coalesce(string_agg(DISTINCT c.relname, ', '), '<none>')
   FROM pg_class c
   WHERE c.relkind = 'v'
     AND pg_get_viewdef(c.oid) LIKE '%ledger_period_balances%'"

echo
echo "== loadavg at end: $(cut -d' ' -f1-3 /proc/loadavg) =="
