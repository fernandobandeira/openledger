#!/usr/bin/env bash
# Spike 024 -- Q2.2: is an OUT-OF-ORDER close legal, and what does it break?
#
# Nothing in the schema orders the closes of a (tenant, currency): pk_closes is
# (tenant_id, period_code, currency), and ex_periods__no_overlap orders the
# PERIODS, not the closes over them. So February can be closed after March, and
# then February's cursor is HIGHER than March's.
#
# What that costs, tested rather than reasoned:
#   * the stored levels stop nesting, so the bounded form's DIFFERENCE is no
#     longer a difference of nested sets
#   * close_disclosures' wide NOT EXISTS carve-out stops being dead
#   * and the AT-CLOSE claim fails for the later-closed period
#
# NO TIMING.
set -euo pipefail
cd "$(dirname "$0")"
export PGPASSWORD=openledger
PGH="-h localhost -p 5433 -U openledger"
ROOT=../..
DB=spike024ooo
Q="psql $PGH -d $DB -q -v ON_ERROR_STOP=1"
mkdir -p out

psql $PGH -d postgres -qc \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid<>pg_backend_pid();" >/dev/null 2>&1 || true
psql $PGH -d postgres -qc "DROP DATABASE IF EXISTS $DB WITH (FORCE);" -qc "CREATE DATABASE $DB;" >/dev/null
DATABASE_URL="postgres://openledger:openledger@localhost:5433/$DB?sslmode=disable" \
    "$ROOT/target/debug/openledger" migrate >/dev/null
$Q --single-transaction -f "$ROOT/schema/chart.sql" >/dev/null 2>&1
$Q -f sql/00_helpers.sql >/dev/null
$Q >/dev/null <<'SQL'
SELECT spike_account('o','recv_1','co_1','customer_receivable','asset','debit','per_shard','USD'),
       spike_account('o','fee',NULL,'fee_revenue','revenue','credit','none','USD'),
       spike_account('o','pic',NULL,'paid_in_capital','equity','credit','none','USD'),
       spike_retained_earnings('o','USD');
INSERT INTO ledger_periods VALUES
  ('o','2026-01','2026-01-01 00:00+00','2026-02-01 00:00+00','UTC'),
  ('o','2026-02','2026-02-01 00:00+00','2026-03-01 00:00+00','UTC');
SELECT spike_post_raw('o','USD', md5('o:pic:USD')::uuid, md5('o:recv_1:USD')::uuid,
                      10000, '2026-01-05 00:00+00', 'o-1');
SQL
$Q -c "SELECT spike_post_raw('o','USD', md5('o:fee:USD')::uuid, md5('o:recv_1:USD')::uuid,
                             500, '2026-01-10 00:00+00', 'o-2');" >/dev/null
$Q -c "SELECT spike_post_raw('o','USD', md5('o:fee:USD')::uuid, md5('o:recv_1:USD')::uuid,
                             700, '2026-02-10 00:00+00', 'o-3');" >/dev/null

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

# FEBRUARY FIRST, then JANUARY. Both under the identity convention, so the only
# thing wrong is the order.
wait_for_horizon || true
$Q -c "SELECT spike_close_mode('o','2026-02','USD','identity');" >/dev/null
wait_for_horizon || true
$Q -c "SELECT spike_close_mode('o','2026-01','USD','identity');" >/dev/null

$Q -f sql/26_recon_identity.sql >/dev/null
$Q -v idterm="ci.k" -f sql/50_bounded_recon.sql >/dev/null
$Q -f sql/20_candidates.sql >/dev/null
$Q -f sql/25_candidates_identity.sql >/dev/null
$Q -f sql/31_disagreement_fns.sql >/dev/null

echo "############ the closes, in period order, with their cursors"
psql $PGH -d $DB -c "
SELECT c.period_code, c.ends_at, c.computed_at_xid, x.xact_id AS close_txn_xid, c.closed_at
FROM ledger_period_closes c JOIN ledger_transactions x
  ON x.tenant_id=c.tenant_id AND x.id=c.transaction_id
ORDER BY c.ends_at;"

echo "############ is it legal? -- the shipped sweep's verdict"
psql $PGH -d $DB -c "SELECT * FROM reconciliation WHERE breaks <> 0 ORDER BY check_name;"
psql $PGH -d $DB -tAc "SELECT 'shipped sweep total breaks = ' || COALESCE(SUM(breaks),0) FROM reconciliation;"

echo "############ the proposed close-order check"
psql $PGH -d $DB -c "SELECT period_code, computed_at_xid, txn_xact_id, prev_cursor,
                            prev_txn_xact_id, reason FROM recon_close_order ORDER BY 1, 6;"

echo "############ the AT-CLOSE claim for the LATER-closed period (2026-01)"
psql $PGH -d $DB -c "
SELECT b.period_code, a.purpose, b.input, b.output, b.input-b.output AS dr_pos
FROM ledger_period_balances b JOIN ledger_accounts a
  ON a.tenant_id=b.tenant_id AND a.id=b.account_id AND a.currency=b.currency
JOIN account_types t ON t.code=a.purpose
WHERE t.category IN ('revenue','expense','equity') ORDER BY 1,2;"

echo "############ the bounded (difference) form against the level form"
psql $PGH -d $DB -c "
SELECT (SELECT count(*) FROM recon_checkpoint_breaks)         AS level_form,
       (SELECT count(*) FROM recon_checkpoint_breaks_bounded) AS bounded_form,
       (SELECT COALESCE(string_agg(DISTINCT reason,',' ORDER BY reason),'-')
          FROM recon_checkpoint_breaks_bounded)               AS bounded_reasons;"

echo "############ is close_disclosures' wide NOT EXISTS carve-out still dead?"
$Q -f sql/27_carveout_dead.sql

echo "############ and does the READER still agree with the from-inception form?"
psql $PGH -d $DB -c "
SELECT ao.asof::text AS as_of,
       (SELECT count(*) FROM bs_disagreements('o', ao.asof, report_cursor())) AS disagreements
FROM (VALUES ('2026-02-01 00:00+00'::timestamptz), ('2026-02-15 00:00+00'),
             ('2026-03-01 00:00+00'), ('infinity')) ao(asof) ORDER BY 1;" 2>&1 | head -20
