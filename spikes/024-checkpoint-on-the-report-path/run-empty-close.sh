#!/usr/bin/env bash
# Spike 024 -- found by the correctness gate while building the partitioning book,
# and kept because it is a defect in its own right:
#
#   A PERIOD WITH NO TEMPORARY-ACCOUNT MOVEMENT CANNOT BE CLOSED WITHOUT BREAKING
#   THE SWEEP. The close sweeps one posting per temporary account with a non-zero
#   balance (ADR-0011 §2, and the HAVING in every implementation of it), so a
#   period in which no revenue or expense moved produces a `period_close`
#   transaction with ZERO entries -- and recon_transaction_breaks reports every
#   entryless transaction as `no_entries`, the ADR-0004 TRUNCATE scar's class.
#   Migration 00003 carved out the VOID and nothing else.
#
# NO TIMING.
set -euo pipefail
cd "$(dirname "$0")"
export PGPASSWORD=openledger
PGH="-h localhost -p 5433 -U openledger"
ROOT=../..
DB=spike024empty
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
SELECT spike_account('e','recv_1','co_1','customer_receivable','asset','debit','per_shard','USD'),
       spike_account('e','pic',NULL,'paid_in_capital','equity','credit','none','USD'),
       spike_retained_earnings('e','USD');
INSERT INTO ledger_periods VALUES
  ('e','2026-01','2026-01-01 00:00+00','2026-02-01 00:00+00','UTC');
-- A capital injection and nothing else: a real book, with a real balance sheet,
-- and NO revenue or expense at all. There is nothing for the close to sweep.
SELECT spike_post_raw('e','USD', md5('e:pic:USD')::uuid, md5('e:recv_1:USD')::uuid,
                      10000, '2026-01-05 00:00+00', 'e-1');
SQL
echo "############ before the close -- a clean book"
psql $PGH -d $DB -tAc "SELECT 'breaks = ' || COALESCE(SUM(breaks),0) FROM reconciliation;"

$Q -c "SELECT spike_close('e','2026-01','USD');" >/dev/null
echo
echo "############ after closing a period with nothing to sweep"
psql $PGH -d $DB -c "SELECT * FROM reconciliation WHERE breaks <> 0 ORDER BY check_name;"
psql $PGH -d $DB -c "SELECT transaction_id, kind, status, leg_count, reason
                     FROM recon_transaction_breaks;"
echo "--- the close itself is entirely well-formed otherwise:"
psql $PGH -d $DB -c "SELECT period_code, currency, computed_at_xid,
                            (SELECT count(*) FROM ledger_period_balances b
                              WHERE b.tenant_id=c.tenant_id AND b.period_code=c.period_code
                                AND b.currency=c.currency) AS checkpoint_rows
                     FROM ledger_period_closes c;"
psql $PGH -d $DB -tAc "SELECT 'openledger reconcile would exit ' ||
       CASE WHEN COALESCE(SUM(breaks),0) = 0 THEN '0' ELSE '1' END FROM reconciliation;"

echo
echo "############ the candidate carve-out, as a predicate over the same book"
psql $PGH -d $DB -c "
SELECT count(*) AS breaks_with_the_close_carve_out
FROM recon_transaction_breaks b
JOIN ledger_transactions x ON x.tenant_id=b.tenant_id AND x.id=b.transaction_id
WHERE NOT (b.reason = 'no_entries'
           AND x.kind = 'period_close'
           AND EXISTS (SELECT 1 FROM ledger_period_closes c
                        WHERE c.tenant_id = x.tenant_id AND c.transaction_id = x.id));"
