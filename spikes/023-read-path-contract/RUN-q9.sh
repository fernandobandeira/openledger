#!/usr/bin/env bash
# Q9 · isolation for a report — and specifically what it buys that the cursor
# does not.
#
# The cursor pins the ENTRY-derived branches (Q3). It cannot pin the branches
# whose tables carry no `xact_id`: `ledger_accounts` (the `scopes` enumeration),
# `chart_versions` (the default version), `chart_presentation` / `fs_lines` at
# the CURRENT version, `ledger_period_closes`, `account_types`. So the question
# is whether a snapshot covers exactly the gap the cursor leaves — and whether
# a multi-statement report needs it where a single call does not.
set -uo pipefail
cd "$(dirname "$0")"
DB="${DB:-postgres://openledger:openledger@localhost:5433/spike023?sslmode=disable}"
Q() { psql "$DB" -tAqc "$1"; }

CUR=$(Q "SELECT report_cursor()::text")
echo "cursor for the whole experiment: $CUR"
echo

echo "###### A · a MULTI-statement read under READ COMMITTED, with an account"
echo "         created between the two statements"
FIFO=$(mktemp -u /tmp/spike023q9.XXXXXX.fifo); mkfifo "$FIFO"
psql "$DB" -a < "$FIFO" > out/q9-read-committed.txt 2>&1 & R=$!
exec 8>"$FIFO"
cat >&8 <<EOF
BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY;
SELECT 'statement 1: rows = ' || count(*)
FROM balance_sheet_at('t1','infinity','$CUR'::xid8, 3);
EOF
sleep 2
psql "$DB" -qc "INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose,
                 category, normal_balance, counterparty_scope, currency)
                VALUES ('t1','house',NULL,'fee_revenue','revenue','credit','none','GBP');" >/dev/null
cat >&8 <<EOF
SELECT 'statement 2: rows = ' || count(*)
FROM balance_sheet_at('t1','infinity','$CUR'::xid8, 3);
COMMIT;
EOF
sleep 2; exec 8>&-; wait "$R" 2>/dev/null || true; rm -f "$FIFO"
grep -E "statement [12]: rows" out/q9-read-committed.txt

echo
echo "###### B · the same two statements under REPEATABLE READ READ ONLY"
FIFO=$(mktemp -u /tmp/spike023q9.XXXXXX.fifo); mkfifo "$FIFO"
psql "$DB" -a < "$FIFO" > out/q9-repeatable-read.txt 2>&1 & R=$!
exec 8>"$FIFO"
cat >&8 <<EOF
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT 'statement 1: rows = ' || count(*)
FROM balance_sheet_at('t1','infinity','$CUR'::xid8, 3);
EOF
sleep 2
psql "$DB" -qc "INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose,
                 category, normal_balance, counterparty_scope, currency)
                VALUES ('t1','house',NULL,'fee_revenue','revenue','credit','none','CHF');" >/dev/null
cat >&8 <<EOF
SELECT 'statement 2: rows = ' || count(*)
FROM balance_sheet_at('t1','infinity','$CUR'::xid8, 3);
COMMIT;
EOF
sleep 2; exec 8>&-; wait "$R" 2>/dev/null || true; rm -f "$FIFO"
grep -E "statement [12]: rows" out/q9-repeatable-read.txt

echo
echo "###### C · what a REPEATABLE READ report costs everyone else: it pins the"
echo "         horizon that report_cursor() is defined off"
FIFO=$(mktemp -u /tmp/spike023q9.XXXXXX.fifo); mkfifo "$FIFO"
psql "$DB" -a < "$FIFO" > out/q9-horizon-cost.txt 2>&1 & R=$!
exec 8>"$FIFO"
echo "before the report opens:"
psql "$DB" -c "SELECT report_cursor() AS cursor_now"
cat >&8 <<EOF
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT count(*) FROM balance_sheet_at('big1m','infinity','$CUR'::xid8, 3);
EOF
sleep 3
echo "while an 11-second REPEATABLE READ report on big1m is running:"
psql "$DB" -c "SELECT report_cursor() AS cursor_now,
                      (SELECT count(*) FROM pg_stat_activity
                       WHERE backend_xmin IS NOT NULL) AS backends_pinning_xmin"
psql "$DB" -c "SELECT pid, datname, state, backend_xmin, left(query,44) AS q
               FROM pg_stat_activity WHERE backend_xmin IS NOT NULL ORDER BY pid"
cat >&8 <<'EOF'
COMMIT;
EOF
sleep 1; exec 8>&-; wait "$R" 2>/dev/null || true; rm -f "$FIFO"

echo
echo "###### D · a SINGLE call is one snapshot at every isolation level, so the"
echo "         report function alone needs no transaction for consistency —"
echo "         but it needs one for the tenant GUC (Q1), which is what settles it"
psql "$DB" -c "EXPLAIN (COSTS OFF)
               SELECT * FROM trial_balance_at('t1','-infinity','infinity','$CUR'::xid8)" | head -8
psql "$DB" -c "EXPLAIN (COSTS OFF)
               SELECT * FROM balance_sheet_at('t1','infinity','$CUR'::xid8, 3)" | head -6

echo
echo "== loadavg: $(cut -d' ' -f1-3 /proc/loadavg) =="
