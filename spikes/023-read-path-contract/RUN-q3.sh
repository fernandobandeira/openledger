#!/usr/bin/env bash
# Q3 · cursor reproducibility, end to end through the three shipped functions,
# and Q4 · backdating on both axes.
#
# The book at entry is ADR-0006's own worked table, scaled by 100 and posted
# through the compiled binary over HTTP:
#
#   effective  amount   how it arrived
#   Jan 10     +10,000  t1-a, first
#   Jan 30      +5,000  t1-b, second
#   Jan 20      +3,000  byhand-smoke, third — BACKDATED
#
# so the effective-axis answer as of Jan 25 must be 13,000 (ADR-0006's 130) and
# the since-inception answer 18,000 (its 180). Insertion order is not effective
# order, which is the M5 done-when criterion.
#
# The adversary session is a psql held open on a FIFO. It has to be direct SQL:
# the HTTP writer commits before it answers, so it cannot hold a transaction
# open across a cursor capture, and holding one open across the capture is
# exactly the interleaving ADR-0006's watermark died on.
set -euo pipefail
cd "$(dirname "$0")"

DB="${DB:-postgres://openledger:openledger@localhost:5433/spike023?sslmode=disable}"
RUN="${RUN:-$(date +%s)}"   # keys are unique per run, so a re-run posts rather than replays
Q() { psql "$DB" -v ON_ERROR_STOP=1 -tAqc "$1"; }
T1R=01a05d61-52a1-7f83-b40d-2da9d28abc8a   # t1 customer_receivable
T1V=01a05d61-52a2-7ca2-b1e5-1c3adb3edf14   # t1 fee_revenue

# The three reports, rendered as sorted text so a diff is the evidence. Every
# call passes an EXPLICIT chart version, because Q3's own branch audit says the
# default is `max(version)` read at run time.
report() {   # report <cursor> <label>
  local cur="$1" label="$2"
  {
    echo "-- trial_balance_at('t1', -infinity, infinity, $cur)"
    psql "$DB" -tAqF'|' -c "SELECT account_id, currency, debits, credits, balance_debit_positive
                            FROM trial_balance_at('t1','-infinity','infinity','$cur'::xid8)
                            ORDER BY 1,2"
    echo "-- balance_sheet_at('t1', infinity, $cur, 3)"
    psql "$DB" -tAqF'|' -c "SELECT currency, chart_version, fs_line, amount_minor, side, pinned_cursor
                            FROM balance_sheet_at('t1','infinity','$cur'::xid8, 3)
                            ORDER BY 1,3"
    echo "-- income_statement_for('t1', -infinity, infinity, $cur, 3)"
    psql "$DB" -tAqF'|' -c "SELECT currency, chart_version, fs_line, amount_minor, side, pinned_cursor
                            FROM income_statement_for('t1','-infinity','infinity','$cur'::xid8, 3)
                            ORDER BY 1,3"
  } > "out/q3-report-$label.txt"
}

echo "== loadavg at start: $(cut -d' ' -f1-3 /proc/loadavg) =="
echo

echo "########## 1 · the branch audit's two unpinned axes, named from the catalog"
Q "SELECT 'tables carrying xact_id: ' ||
         string_agg(table_name, ', ' ORDER BY table_name)
   FROM information_schema.columns
   WHERE column_name = 'xact_id' AND table_schema = 'public'
     AND table_name IN ('ledger_entries','ledger_transactions','ledger_events',
                        'ledger_accounts','ledger_period_closes','ledger_period_balances',
                        'chart_versions','chart_presentation','fs_lines','account_types')"
Q "SELECT 'tables the reports read that carry NO xact_id: ' ||
         string_agg(t, ', ' ORDER BY t)
   FROM unnest(ARRAY['ledger_accounts','ledger_period_closes','chart_versions',
                     'chart_presentation','fs_lines','account_types']) t
   WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns c
                     WHERE c.table_schema='public' AND c.table_name=t
                       AND c.column_name='xact_id')"
Q "SELECT 'none of the five report functions is STRICT: ' ||
         string_agg(proname || '=' || proisstrict, ', ' ORDER BY proname)
   FROM pg_proc
   WHERE proname IN ('report_cursor','trial_balance_at','income_statement_for',
                     'balance_sheet_at','recon_equation_breaks')"
Q "SELECT 'EXECUTE is the default (PUBLIC) on all five: ' ||
         string_agg(proname || '=' || coalesce(proacl::text,'<default>'), ', ' ORDER BY proname)
   FROM pg_proc
   WHERE proname IN ('report_cursor','trial_balance_at','income_statement_for',
                     'balance_sheet_at','recon_equation_breaks')"
echo

echo "########## 2 · the adversary: a transaction that starts BEFORE the cursor and commits AFTER"
FIFO=$(mktemp -u /tmp/spike023.XXXXXX.fifo); mkfifo "$FIFO"
psql "$DB" -v ON_ERROR_STOP=1 -a < "$FIFO" > out/q3-adversary.txt 2>&1 &
ADV=$!
exec 9>"$FIFO"

# A opens and posts, and does NOT commit. Its xact_id is taken here.
cat >&9 <<EOF
BEGIN;
\\set tenant t1
\\set key adversary-A-$RUN
\\set eff 2026-01-05T00:00:00Z
\\set src $T1V
\\set dst $T1R
\\set amt 99000
\\set stripe 1
\\i sql/post-by-hand.sql
SELECT 'A holds xid ' || pg_current_xact_id()::text AS a;
EOF
sleep 2
A_XID=$(grep -oP "A holds xid \K[0-9]+" out/q3-adversary.txt | tail -1)
echo "A's xact_id (uncommitted): $A_XID"

# B posts through the BINARY and commits, so B's xid is HIGHER than A's and
# already visible. This is what makes max(xact_id)+1 a broken watermark.
./post.sh t1 "cursor-B-$RUN" 2026-01-25T00:00:00Z "$T1V" "$T1R" 7000 > out/q3-post-B.txt
B_XID=$(Q "SELECT max(xact_id)::text FROM ledger_entries WHERE tenant_id='t1'")
echo "B's xact_id (committed, visible):        $B_XID"

# The two candidate cursors, captured at the same instant.
CURSOR=$(Q "SELECT report_cursor()::text")
WATERMARK=$(Q "SELECT (max(xact_id)::text::bigint + 1)::text::xid8::text FROM ledger_entries")
echo "report_cursor() = pg_snapshot_xmin:      $CURSOR"
echo "max(xact_id)+1  (the refuted watermark): $WATERMARK"
echo "  A below the pg_snapshot_xmin cursor?   $(Q "SELECT '$A_XID'::xid8 < '$CURSOR'::xid8")"
echo "  A below max(xact_id)+1?                $(Q "SELECT '$A_XID'::xid8 < '$WATERMARK'::xid8")"

report "$CURSOR"    "at-C-before"
report "$WATERMARK" "at-W-before"

echo
echo "########## 3 · A commits, and the same two cursors are re-run"
cat >&9 <<'EOF'
COMMIT;
SELECT 'A committed' AS a;
EOF
sleep 2
exec 9>&-
wait "$ADV" 2>/dev/null || true
rm -f "$FIFO"

report "$CURSOR"    "at-C-after"
report "$WATERMARK" "at-W-after"

echo "--- pg_snapshot_xmin cursor $CURSOR, before vs after A's commit ---"
if diff -u out/q3-report-at-C-before.txt out/q3-report-at-C-after.txt > out/q3-diff-C.txt; then
  echo "IDENTICAL — the cursor holds under a transaction that spanned it"
else
  echo "DIFFERENT — see out/q3-diff-C.txt"; cat out/q3-diff-C.txt
fi
echo "--- the refuted watermark $WATERMARK, before vs after A's commit ---"
if diff -u out/q3-report-at-W-before.txt out/q3-report-at-W-after.txt > out/q3-diff-W.txt; then
  echo "IDENTICAL (unexpected)"
else
  echo "DIFFERENT — a row appeared below a watermark already issued:"; cat out/q3-diff-W.txt
fi

echo
echo "########## 4 · the negative control, and the cluster horizon"
# A "fresh cursor" is NOT a usable control on this cluster: another agent's
# spike is holding a transaction open in a DIFFERENT DATABASE and pinning
# pg_snapshot_xmin, which is ADR-0011's stated cost happening to us unbidden.
# So the control is a cursor explicitly ABOVE everything committed.
psql "$DB" -c "SELECT pid, datname, state, xact_start, backend_xmin
               FROM pg_stat_activity WHERE backend_type='client backend'
               ORDER BY xact_start NULLS LAST"
psql "$DB" -c "SELECT report_cursor() AS cursor_now,
                      (SELECT count(*) FROM ledger_entries) AS entries_total,
                      (SELECT count(*) FROM ledger_entries WHERE xact_id <  report_cursor())
                          AS a_report_would_see,
                      (SELECT count(*) FROM ledger_entries WHERE xact_id >= report_cursor())
                          AS above_the_horizon"
ABOVE=$(Q "SELECT (max(xact_id)::text::bigint + 1)::text::xid8::text FROM ledger_entries")
report "$ABOVE" "at-above-everything"
echo "a cursor above every committed write: $ABOVE"
if diff -q out/q3-report-at-C-after.txt out/q3-report-at-above-everything.txt > /dev/null; then
  echo "IDENTICAL — the negative control FAILED: the cursor is not doing anything"
else
  echo "DIFFERENT, as it must be — the pinned cursor is WITHHOLDING the new writes"
  { diff -u out/q3-report-at-C-after.txt out/q3-report-at-above-everything.txt || true; } | head -24 || true
fi

echo
echo "########## 5 · the NULL cursor"
psql "$DB" -c "SELECT currency, fs_line, amount_minor, side, pinned_cursor
               FROM balance_sheet_at('t1','infinity', NULL, 3) ORDER BY 2" \
     -c "SELECT count(*) AS rows,
                sum(CASE WHEN side='asset' THEN amount_minor ELSE 0 END) AS assets,
                sum(CASE WHEN side<>'asset' THEN amount_minor ELSE 0 END) AS liab_eq_earnings
         FROM balance_sheet_at('t1','infinity', NULL, 3)" \
     -c "SELECT count(*) AS is_rows FROM income_statement_for('t1','-infinity','infinity',NULL,3)" \
     -c "SELECT count(*) AS tb_rows FROM trial_balance_at('t1','-infinity','infinity',NULL)" \
     -c "SELECT count(*) AS equation_breaks FROM recon_equation_breaks(NULL,'infinity')"

echo
echo "########## 6 · the range and as-of arguments are unguarded too"
psql "$DB" -c "SELECT count(*) AS rows, sum(amount_minor) AS total
               FROM balance_sheet_at('t1', NULL, report_cursor(), 3)" \
     -c "SELECT count(*) AS rows, sum(amount_minor) AS total
         FROM income_statement_for('t1', NULL, NULL, report_cursor(), 3)" \
     -c "SELECT count(*) AS rows FROM trial_balance_at('t1', NULL, NULL, report_cursor())"

echo
echo "########## 7 · the chart-version default is read at RUN time"
psql "$DB" -tAqF'|' -c "SELECT 'default resolves to version ' || max(version) FROM chart_versions"
psql "$DB" -tAqF'|' -c "SELECT 'explicit v1 vs default: ' ||
        (SELECT string_agg(DISTINCT chart_version::text, ',')
         FROM balance_sheet_at('t1','infinity', report_cursor(), 1)) || ' vs ' ||
        (SELECT string_agg(DISTINCT chart_version::text, ',')
         FROM balance_sheet_at('t1','infinity', report_cursor()))"
echo "and a frozen version cannot gain rows, while the CURRENT one can:"
echo "  rows at v3 BEFORE any append:"
psql "$DB" -tAqc "SELECT count(*) FROM balance_sheet_at('t1','infinity', report_cursor(), 3)"
echo "  appending a line to the FROZEN version 1 (must be refused):"
psql "$DB" -c "BEGIN; INSERT INTO fs_lines (chart_version, code, caption, statement, side, sort_order)
                      VALUES (1,'spike023_line','Spike 023','balance_sheet','asset',999); ROLLBACK;" 2>&1 | tail -3 || true
echo "  appending a line to the CURRENT version 3 (permitted), at a FIXED cursor:"
psql "$DB" -c "BEGIN; INSERT INTO fs_lines (chart_version, code, caption, statement, side, sort_order)
                      VALUES (3,'spike023_line','Spike 023','balance_sheet','asset',999);
               SELECT count(*) AS rows_at_v3_after_append
               FROM balance_sheet_at('t1','infinity', report_cursor(), 3); ROLLBACK;" 2>&1 | tail -6 || true

echo
echo "########## 8 · the scopes CTE: a new account changes the ROW SET at a FIXED cursor"
FIXED=$(Q "SELECT report_cursor()::text")
report "$FIXED" "scopes-before"
psql "$DB" -qc "BEGIN;
  INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose, category,
                               normal_balance, counterparty_scope, currency)
  VALUES ('t1','house',NULL,'fee_revenue','revenue','credit','none','EUR');
  COMMIT;"
report "$FIXED" "scopes-after"
echo "--- same cursor $FIXED, one new EUR account, nothing posted to it ---"
if diff -u out/q3-report-scopes-before.txt out/q3-report-scopes-after.txt > out/q3-diff-scopes.txt; then
  echo "IDENTICAL"
else
  echo "DIFFERENT — the row set moved under a fixed cursor:"
  head -40 out/q3-diff-scopes.txt || true
  echo "(amount columns unchanged on the pre-existing rows; the diff is added rows)"
fi

echo
echo "########## 9 · Q4 · backdating, both axes, and both reproducible"
echo "-- the effective axis: ADR-0006's own table, scaled 100x"
psql "$DB" -c "SELECT b.label, b.as_of,
                      (SELECT balance_debit_positive
                       FROM trial_balance_at('t1','-infinity', b.as_of, report_cursor())
                       WHERE account_id = '$T1R') AS receivable_minor
               FROM (VALUES ('as of Jan 15','2026-01-15'::timestamptz),
                            ('as of Jan 25','2026-01-25'::timestamptz),
                            ('as of Feb 01','2026-02-01'::timestamptz)) b(label, as_of)"
echo "-- the recorded axis is the SAME function with the cursor as the parameter"
psql "$DB" -c "SELECT c.label, c.cur,
                      (SELECT balance_debit_positive
                       FROM trial_balance_at('t1','-infinity','infinity', c.cur)
                       WHERE account_id = '$T1R') AS receivable_minor
               FROM (VALUES ('at the pinned cursor','$CURSOR'::xid8),
                            ('at a fresh cursor', report_cursor())) c(label, cur)"

echo
echo "########## 10 · the oracle"
DATABASE_URL="$DB" ../../target/debug/openledger reconcile || true
echo "== loadavg at end: $(cut -d' ' -f1-3 /proc/loadavg) =="
