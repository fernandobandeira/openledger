#!/usr/bin/env bash
# Spike 024 -- Q1.3: does the TENANT-WIDE statement have an index for the two
# tails? Plain EXPLAIN only -- the queries are planned, never executed, so nothing
# here is a timing run. Cost numbers are the planner's ESTIMATES and are labelled
# as such wherever they are quoted.
set -euo pipefail
cd "$(dirname "$0")"
export PGPASSWORD=openledger
PGH="-h localhost -p 5433 -U openledger"
ROOT=../..
DB=spike024plan
Q="psql $PGH -d $DB -q -v ON_ERROR_STOP=1"
mkdir -p out

psql $PGH -d postgres -qc \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid<>pg_backend_pid();" >/dev/null 2>&1 || true
psql $PGH -d postgres -qc "DROP DATABASE IF EXISTS $DB WITH (FORCE);" -qc "CREATE DATABASE $DB;" >/dev/null
DATABASE_URL="postgres://openledger:openledger@localhost:5433/$DB?sslmode=disable" \
    "$ROOT/target/debug/openledger" migrate >/dev/null
$Q --single-transaction -f "$ROOT/schema/chart.sql" >/dev/null 2>&1
$Q -f sql/00_helpers.sql >/dev/null
$Q -f sql/80_bulk_seed.sql >/dev/null
echo "== seeded:"
psql $PGH -d $DB -c "SELECT (SELECT count(*) FROM ledger_entries) AS entries,
                            (SELECT count(*) FROM ledger_accounts) AS accounts,
                            pg_size_pretty(pg_total_relation_size('ledger_entries')) AS entries_size;"

echo "== THE GATE"
psql $PGH -d $DB -c "SELECT * FROM reconciliation WHERE breaks <> 0 ORDER BY check_name;"
BREAKS=$(psql $PGH -d $DB -tAc "SELECT COALESCE(SUM(breaks),0) FROM reconciliation;")
echo "total breaks = $BREAKS"

wait_for_horizon() {
    local i
    for i in $(seq 1 400); do
        if [ "$(psql $PGH -d $DB -tAc "SELECT pg_snapshot_xmin(pg_current_snapshot())
                    > COALESCE((SELECT max(xact_id) FROM ledger_entries), '0'::xid8)")" = t ]; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}
for m in $(seq -w 1 12); do
    wait_for_horizon || true
    $Q -c "SELECT spike_close_mode('big','2026-$m','USD','identity');" >/dev/null
done
$Q -c "ANALYZE;" >/dev/null
$Q -f sql/26_recon_identity.sql >/dev/null
$Q -f sql/20_candidates.sql >/dev/null
$Q -f sql/25_candidates_identity.sql >/dev/null
$Q -f sql/31_disagreement_fns.sql >/dev/null
$Q -v idterm="ci.k" -f sql/50_bounded_recon.sql >/dev/null

echo
echo "== THE GATE, after twelve closes"
psql $PGH -d $DB -c "SELECT * FROM reconciliation WHERE breaks <> 0 ORDER BY check_name;"
psql $PGH -d $DB -tAc "SELECT 'total breaks = ' || COALESCE(SUM(breaks),0) FROM reconciliation;"
psql $PGH -d $DB -tAc "SELECT 'checkpoint rows = ' || count(*) FROM ledger_period_balances;"

echo
echo "== and the reader still agrees on this book (60-point grid is on the small one;"
echo "   here it is the four instants that matter)"
psql $PGH -d $DB -c "
SELECT ao.asof::text AS as_of,
       (SELECT count(*) FROM bs_disagreements('big', ao.asof, report_cursor())) AS bs_disagreements,
       (SELECT count(*) FROM tb_disagreements('big', '-infinity', ao.asof, report_cursor())) AS tb_disagreements
FROM (VALUES ('2026-07-01 00:00+00'::timestamptz), ('2026-07-15 00:00+00'),
             ('2027-01-01 00:00+00'), ('infinity')) ao(asof) ORDER BY 1;"

psql $PGH -d $DB -v ON_ERROR_STOP=1 -f sql/85_plans.sql
