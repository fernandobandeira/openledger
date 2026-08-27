#!/usr/bin/env bash
# 03 -- Three candidate cursors on ONE interleaving. Two admit a row after the report
# was issued. One does not, and it is the one ADR-0011 builds on.
#
# THE INTERLEAVING is an ordinary Tuesday: a batched posting run A starts FIRST and
# finishes LAST; an ordinary posting B starts later and commits sooner; a report R runs
# in between. A's transaction id is LOWER than B's and A's commit is LATER, so every
# scheme that reads "the highest thing I can see" is wrong here.
set -euo pipefail
cd "$(dirname "$0")/../.."
. spikes/014-period-close/_session.sh

$PG -q -o /dev/null <<'SQL'
-- The candidate ADR-0006 proposed: a gapless global sequence on the event log plus the
-- transaction that wrote each row, watermarked at
--     W = min(seq) - 1  over rows whose xid >= pg_snapshot_xmin(pg_current_snapshot())
-- Isolated on its own table so the mechanism is the only thing under test.
CREATE TABLE sp_watermark_demo (
    seq bigserial PRIMARY KEY, who text NOT NULL,
    xact_id xid8 NOT NULL DEFAULT pg_current_xact_id());

SELECT sp_post('t1','fee','2026-02-01 12:00+00','operating_cash','fee_revenue', 11000000);
SQL
echo "-- committed before either writer starts: 110,000.00 of revenue"

session_open "INSERT INTO sp_watermark_demo (who) VALUES ('A -- batched posting run');
              SELECT sp_post('t1','fee','2026-02-11 12:00+00','operating_cash','fee_revenue', 5000000);"

# B POSTS TO DIFFERENT ACCOUNTS THAN A. On the same accounts it does not interleave at
# all -- it blocks on A's balance-row lock until A commits, which is the write path
# working as designed and is not the case under test here.
$PG -q -o /dev/null -c "INSERT INTO sp_watermark_demo (who) VALUES ('B -- ordinary posting'); SELECT sp_post('t1','fee','2026-02-12 12:00+00','fbo_cash','interchange_revenue', 2000000);"

read -r W NAIVE XMIN <<<"$($PG -Atq -F' ' -c "SELECT COALESCE(min(seq) FILTER (WHERE xact_id >= pg_snapshot_xmin(pg_current_snapshot())), max(seq)+1) - 1, (SELECT COALESCE(max(xact_id::text::bigint),0)+1 FROM ledger_entries), pg_snapshot_xmin(pg_current_snapshot())::text::bigint FROM sp_watermark_demo")"
echo "-- A open, B committed. Three cursors captured at this instant:"
echo "--   (a) ADR-0006 sequence watermark   W = $W"
echo "--   (b) naive max(xact_id) + 1          = $NAIVE"
echo "--   (c) pg_snapshot_xmin                = $XMIN"

REV="SELECT to_char(SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END)/100.0,'FM999,999,990.00') FROM ledger_entries e JOIN ledger_accounts a ON a.tenant_id=e.tenant_id AND a.id=e.account_id AND a.currency=e.currency JOIN account_types t ON t.code=a.purpose WHERE t.category='revenue'"
BOTH="SELECT (SELECT count(*) FROM sp_watermark_demo WHERE seq <= $W) AS a_rows_at_or_below_W,
             ($REV AND e.xact_id::text::bigint < $NAIVE)              AS b_revenue_naive_max,
             ($REV AND e.xact_id < '$XMIN'::xid8)                     AS c_revenue_xmin_cursor"

echo "-- ISSUED, while A is open:"; $PG -c "$BOTH"
session_commit
echo "-- A committed. Nothing backdated. Same three cursors, same three queries:"; $PG -c "$BOTH"

echo "-- who wrote what, and in which order:"
$PG -c "SELECT seq, who, xact_id FROM sp_watermark_demo ORDER BY seq;"
echo "-- the cost, stated: the cursor LAGS the newest commits. Captured now, nothing running:"
$PG -c "SELECT report_cursor() AS cursor_now, ($REV AND e.xact_id < report_cursor()) AS revenue_at_cursor_now;"
