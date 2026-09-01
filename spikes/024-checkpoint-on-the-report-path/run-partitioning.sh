#!/usr/bin/env bash
# Spike 024 -- partition ledger_period_balances by period, in a scratch database,
# by hand, and find out what it costs. Nothing here is applied to `openledger`
# and nothing outside this spike directory is touched.
#
# What is being answered (DESIGN-QUESTIONS Q3.1-Q3.4):
#   * is LIST (period_code) legal under the tenant-leading primary key
#   * do the two foreign keys survive, and still refuse a violation
#   * do the three RLS policies survive, and is a scoped reader still scoped
#   * do the grants survive, including the belt-and-braces REVOKE
#   * do the append-only and event triggers permit it
#   * what the migration actually has to do, since there is no in-place ALTER
#   * what the schema snapshot would and would NOT show
#
# NO TIMING. Q3.5 -- how much the close actually saves -- is in MEASUREMENT-PLAN.md.
set -euo pipefail
cd "$(dirname "$0")"
export PGPASSWORD=openledger
PGH="-h localhost -p 5433 -U openledger"
ROOT=../..
DB=spike024part
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
SELECT spike_account('t1','recv_1','co_1','customer_receivable','asset','debit','per_shard','USD'),
       spike_account('t1','fee',NULL,'fee_revenue','revenue','credit','none','USD'),
       spike_account('t1','pic',NULL,'paid_in_capital','equity','credit','none','USD'),
       spike_retained_earnings('t1','USD'),
       spike_account('t2','recv_1','co_9','customer_receivable','asset','debit','per_shard','USD'),
       spike_account('t2','fee',NULL,'fee_revenue','revenue','credit','none','USD'),
       spike_account('t2','pic',NULL,'paid_in_capital','equity','credit','none','USD'),
       spike_retained_earnings('t2','USD');
INSERT INTO ledger_periods VALUES
  ('t1','2026-01','2026-01-01 00:00+00','2026-02-01 00:00+00','UTC'),
  ('t1','2026-02','2026-02-01 00:00+00','2026-03-01 00:00+00','UTC'),
  ('t2','FY2026Q1','2026-01-01 00:00+00','2026-04-01 00:00+00','UTC');
SELECT spike_post_raw('t1','USD', md5('t1:pic:USD')::uuid, md5('t1:recv_1:USD')::uuid,
                      10000, '2026-01-05 00:00+00', 't1-1');
SELECT spike_post_raw('t2','USD', md5('t2:pic:USD')::uuid, md5('t2:recv_1:USD')::uuid,
                      7000, '2026-01-06 00:00+00', 't2-1');
SQL
$Q -c "SELECT spike_post_raw('t1','USD', md5('t1:fee:USD')::uuid, md5('t1:recv_1:USD')::uuid,
                             500, '2026-01-10 00:00+00', 't1-2');" >/dev/null
# Every period that gets closed must have SOMETHING to sweep. A close with no
# temporary-account movement writes an ENTRYLESS period_close transaction, which
# recon_transaction_breaks reports as `no_entries` -- a real defect, isolated in
# run-empty-close.sh rather than left to contaminate this book's gate.
$Q -c "SELECT spike_post_raw('t1','USD', md5('t1:fee:USD')::uuid, md5('t1:recv_1:USD')::uuid,
                             250, '2026-02-10 00:00+00', 't1-3');" >/dev/null
$Q -c "SELECT spike_post_raw('t2','USD', md5('t2:fee:USD')::uuid, md5('t2:recv_1:USD')::uuid,
                             300, '2026-01-11 00:00+00', 't2-2');" >/dev/null
# Wait for the cluster horizon to pass our own writes before each close: the
# horizon is per CLUSTER and another spike is writing on this server, so a close
# taken under a pinned horizon stores a checkpoint of nothing (proven in
# run-cursor-arms.sh). Polled, never slept on a fixed budget.
wait_for_horizon() {
    local i
    for i in $(seq 1 400); do
        if [ "$(psql $PGH -d $DB -tAc "SELECT pg_snapshot_xmin(pg_current_snapshot())
                    > COALESCE((SELECT max(xact_id) FROM ledger_entries), '0'::xid8)")" = t ]; then
            return 0
        fi
        sleep 0.25
    done
    echo "   !! horizon never caught up"; return 1
}
wait_for_horizon || true
$Q -c "SELECT spike_close('t1','2026-01','USD');" >/dev/null
wait_for_horizon || true
$Q -c "SELECT spike_close('t1','2026-02','USD');" >/dev/null
# t2 uses a DIFFERENT period-code vocabulary on purpose: period_code is a
# tenant-supplied label, so under LIST partitioning the partition set is the
# UNION of every tenant's vocabulary.
wait_for_horizon || true
$Q -c "SELECT spike_close('t2','FY2026Q1','USD');" >/dev/null

echo "############ 0. the book before the change"
psql $PGH -d $DB -c "SELECT tenant_id, period_code, currency, count(*) AS rows
                     FROM ledger_period_balances GROUP BY 1,2,3 ORDER BY 1,2;"
psql $PGH -d $DB -c "SELECT * FROM reconciliation WHERE breaks <> 0 ORDER BY check_name;"
psql $PGH -d $DB -tAc "SELECT 'reconciliation breaks before = ' || COALESCE(SUM(breaks),0)
                       FROM reconciliation;"

echo
echo "############ 1. there is NO in-place conversion -- the statement does not exist"
psql $PGH -d $DB -c "ALTER TABLE ledger_period_balances PARTITION BY LIST (period_code);" 2>&1 | head -4 || true

echo
echo "############ 2. ...and the table cannot even be dropped while its readers exist"
psql $PGH -d $DB -c "DROP TABLE ledger_period_balances;" 2>&1 | head -6 || true

echo
echo "############ 3. does the append-only / event-trigger perimeter permit a partition here?"
echo "--- ledger_period_balances is NOT in refuse_journal_ddl's protected array:"
psql $PGH -d $DB -tAc "SELECT pg_get_functiondef('refuse_journal_ddl'::regproc)
                       LIKE '%ledger_period_balances%' AS is_protected;"
echo "--- and a child of a PROTECTED table is refused (the same pg_inherits state"
echo "    assertion a PARTITION OF would trip), so a journal table is a different story:"
psql $PGH -d $DB -c "CREATE TABLE probe_child () INHERITS (ledger_entries);" 2>&1 | head -4 || true

echo
echo "############ 4. apply the candidate DDL"
$Q -f sql/70_partition_ddl.sql

echo
echo "############ 5. what the catalog says now"
psql $PGH -d $DB -c "
SELECT c.relkind::text || ' ' || c.relname
       || ' rowsecurity=' || c.relrowsecurity
       || ' ispartition=' || c.relispartition AS relation
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relname LIKE 'ledger_period_balances%'
  AND c.relkind IN ('r','p') ORDER BY 1;"
psql $PGH -d $DB -c "
SELECT pg_get_partkeydef('ledger_period_balances'::regclass) AS partition_key;"
psql $PGH -d $DB -c "
SELECT c.relname, pg_get_expr(c.relpartbound, c.oid) AS bound
FROM pg_class c JOIN pg_inherits i ON i.inhrelid=c.oid
WHERE i.inhparent='ledger_period_balances'::regclass ORDER BY 1;"
psql $PGH -d $DB -c "
SELECT conname, pg_get_constraintdef(oid) AS def, conrelid::regclass AS on_table
FROM pg_constraint WHERE conrelid IN (
    SELECT oid FROM pg_class WHERE relname LIKE 'ledger_period_balances%')
ORDER BY conrelid::regclass::text, conname;"

echo
echo "############ 6. do the FOREIGN KEYS still refuse a violation, through the parent?"
psql $PGH -d $DB -c "INSERT INTO ledger_period_balances
    VALUES ('t1','2026-01','USD','00000000-0000-0000-0000-000000000000',1,0);" 2>&1 | head -3 || true
psql $PGH -d $DB -c "INSERT INTO ledger_period_balances
    SELECT 't1','2026-99','USD', md5('t1:recv_1:USD')::uuid, 1, 0;" 2>&1 | head -3 || true

echo
echo "############ 7. RLS: is a scoped reader still scoped, through the parent?"
psql $PGH -d $DB -c "
SELECT t.relname, pol.polname, pol.polcmd::text,
       (SELECT string_agg(r.rolname,',' ORDER BY r.rolname) FROM pg_roles r
         WHERE r.oid = ANY(pol.polroles)) AS roles,
       pg_get_expr(pol.polqual, pol.polrelid) AS using_expr
FROM pg_policy pol JOIN pg_class t ON t.oid=pol.polrelid
WHERE t.relname LIKE 'ledger_period_balances%' ORDER BY 1,2;"
$Q -f sql/75_partition_rls.sql

echo
echo "############ 8. grants: does parent-routed DML need anything on the partitions?"
$Q -f sql/76_partition_grants.sql

echo
echo "############ 9. the gate: does the book still reconcile after the change?"
psql $PGH -d $DB -c "SELECT * FROM reconciliation ORDER BY check_name;"
psql $PGH -d $DB -tAc "SELECT 'reconciliation breaks after = ' || COALESCE(SUM(breaks),0)
                       FROM reconciliation;"
psql $PGH -d $DB -c "SELECT tenant_id, period_code, currency, count(*) AS rows,
                            tableoid::regclass AS lives_in
                     FROM ledger_period_balances GROUP BY 1,2,3,5 ORDER BY 1,2;"

echo
echo "############ 10. what the schema snapshot can and cannot see"
echo "--- catalog names the dump would need, grepped from the test itself:"
for col in relpartbound relispartition pg_inherits pg_partitioned_table pg_get_partkeydef; do
    printf '    %-24s in schema_snapshot.rs: ' "$col"
    if grep -q "$col" "$ROOT/crates/e2e/tests/e2e/schema_snapshot.rs"; then echo PRESENT; else echo ABSENT; fi
done
echo "--- the two sections that DO move:"
psql $PGH -d $DB -tAc "
SELECT c.relkind::text || ' ' || c.relname
       || ' persistence=' || c.relpersistence::text
       || ' rowsecurity=' || c.relrowsecurity
       || ' forcerowsecurity=' || c.relforcerowsecurity
       || ' options=[' || coalesce(array_to_string(c.reloptions, ', '), '') || ']'
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m','S')
  AND c.relname LIKE 'ledger_period_balance%'
ORDER BY c.relname COLLATE \"C\";"
psql $PGH -d $DB -tAc "
SELECT pg_get_indexdef(x.indexrelid) || ' valid=' || x.indisvalid || ' ready=' || x.indisready
FROM pg_index x JOIN pg_class i ON i.oid=x.indexrelid JOIN pg_class t ON t.oid=x.indrelid
JOIN pg_namespace n ON n.oid=t.relnamespace
WHERE n.nspname='public' AND t.relname LIKE 'ledger_period_balance%'
ORDER BY t.relname COLLATE \"C\", i.relname COLLATE \"C\";"

echo
echo "############ 11. the accident the snapshot would MISS: one DETACH statement"
psql $PGH -d $DB -c "ALTER TABLE ledger_period_balances DETACH PARTITION ledger_period_balances_p2026_01;"
psql $PGH -d $DB -c "SELECT (SELECT count(*) FROM ledger_period_balances) AS rows_via_parent,
                            (SELECT count(*) FROM ledger_period_balances_p2026_01) AS rows_in_detached,
                            (SELECT count(*) FROM recon_checkpoint_breaks) AS checkpoint_drift_breaks,
                            (SELECT COALESCE(SUM(breaks),0) FROM reconciliation) AS total_breaks;"
psql $PGH -d $DB -tAc "
SELECT c.relkind::text || ' ' || c.relname || ' rowsecurity=' || c.relrowsecurity
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relname LIKE 'ledger_period_balance%' AND c.relkind IN ('r','p')
ORDER BY 1;"
