#!/usr/bin/env bash
# Spike 024 -- what a one-transaction close can actually store in
# ledger_period_closes.computed_at_xid, settled by running it.
#
# Three arms (sql/00_helpers.sql: spike_close_mode), each twice:
#   IDLE        -- nothing else running on the cluster
#   CONCURRENT  -- an OLDER writer holds an uncommitted posting across the close
#                  and commits after it, which is the interleaving ADR-0011 §1
#                  built the whole cursor argument on
#
# For each of the six cells, report:
#   * computed_at_xid against the closing transaction's own xact_id
#   * whether the stored checkpoint is the AT-CLOSE position (a temporary
#     account at exactly 0 and a retained_earnings row present) -- the property
#     ADR-0011 §3 A4, the ledger_period_balances comment and recon_close_breaks'
#     own header note all assert
#   * recon_close_breaks and recon_checkpoint_breaks
#   * and the one that matters: does a checkpoint+tails READER agree with the
#     from-inception aggregate
#
# NO TIMING. Nothing here is measured in milliseconds.
set -euo pipefail
cd "$(dirname "$0")"
export PGPASSWORD=openledger
PGH="-h localhost -p 5433 -U openledger"
ROOT=../..
DB=spike024arms
Q="psql $PGH -d $DB -q -v ON_ERROR_STOP=1"
mkdir -p out

fresh() {
    psql $PGH -d postgres -qc \
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid<>pg_backend_pid();" >/dev/null 2>&1 || true
    psql $PGH -d postgres -qc "DROP DATABASE IF EXISTS $DB WITH (FORCE);" -qc "CREATE DATABASE $DB;" >/dev/null
    DATABASE_URL="postgres://openledger:openledger@localhost:5433/$DB?sslmode=disable" \
        "$ROOT/target/debug/openledger" migrate >/dev/null
    $Q --single-transaction -f "$ROOT/schema/chart.sql" >/dev/null 2>&1
    $Q -f sql/00_helpers.sql >/dev/null
    $Q >/dev/null <<'SQL'
SELECT spike_account('a','recv_1','co_1','customer_receivable','asset','debit','per_shard','USD'),
       spike_account('a','fee',NULL,'fee_revenue','revenue','credit','none','USD'),
       spike_account('a','pic',NULL,'paid_in_capital','equity','credit','none','USD'),
       spike_retained_earnings('a','USD');
INSERT INTO ledger_periods VALUES
  ('a','2026-01','2026-01-01 00:00+00','2026-02-01 00:00+00','UTC');
-- two committed postings, each its own transaction
SELECT spike_post_raw('a','USD', md5('a:pic:USD')::uuid, md5('a:recv_1:USD')::uuid,
                      10000, '2026-01-05 00:00+00', 'a-1');
SQL
    $Q -c "SELECT spike_post_raw('a','USD', md5('a:fee:USD')::uuid, md5('a:recv_1:USD')::uuid,
                                 500, '2026-01-10 00:00+00', 'a-2');" >/dev/null
}

# A reader that follows ADR-0011 §3 literally for the arm being tested, so the
# READER is not what varies between the two sub-arms. `p_own` says whether the
# close's own transaction is admitted to the checkpoint by identity.
reader_sql() {  # $1 = 'cursor' | 'identity'
    local own_ck own_tail
    if [ "$1" = identity ]; then
        own_ck=""   # the close's entries are IN the stored checkpoint already
        own_tail="AND e.transaction_id <> k.transaction_id"
    else
        own_ck=""
        own_tail=""
    fi
    cat <<SQL
CREATE OR REPLACE VIEW arm_reader AS
WITH k AS (
    SELECT c.currency, c.period_code, c.ends_at, c.computed_at_xid, c.transaction_id
    FROM ledger_period_closes c WHERE c.tenant_id='a'
), terms AS (
    SELECT b.account_id, b.input::numeric dr, b.output::numeric cr
    FROM k JOIN ledger_period_balances b
      ON b.tenant_id='a' AND b.currency=k.currency AND b.period_code=k.period_code
    UNION ALL
    SELECT e.account_id,
           CASE WHEN e.direction='debit'  THEN e.amount_minor::numeric ELSE 0 END,
           CASE WHEN e.direction='credit' THEN e.amount_minor::numeric ELSE 0 END
    FROM k JOIN ledger_entries e ON e.tenant_id='a' AND e.currency=k.currency
       AND e.effective_at >= k.ends_at AND e.effective_at < 'infinity'
    JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
    UNION ALL
    SELECT e.account_id,
           CASE WHEN e.direction='debit'  THEN e.amount_minor::numeric ELSE 0 END,
           CASE WHEN e.direction='credit' THEN e.amount_minor::numeric ELSE 0 END
    FROM k JOIN ledger_entries e ON e.tenant_id='a' AND e.currency=k.currency
       AND e.effective_at < k.ends_at AND e.xact_id >= k.computed_at_xid $own_tail
    JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
)
SELECT account_id, SUM(dr) AS debits, SUM(cr) AS credits FROM terms GROUP BY account_id;

CREATE OR REPLACE VIEW arm_from_inception AS
SELECT e.account_id,
       SUM(CASE WHEN e.direction='debit'  THEN e.amount_minor::numeric ELSE 0 END) AS debits,
       SUM(CASE WHEN e.direction='credit' THEN e.amount_minor::numeric ELSE 0 END) AS credits
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
WHERE e.tenant_id='a' AND e.currency='USD'
GROUP BY e.account_id;
SQL
}

# THE CLUSTER HORIZON IS NOT OURS. pg_snapshot_xmin is per CLUSTER, and another
# spike is writing to another database on this same server, so xmin wanders. A
# close whose cursor sits BELOW our own book stores an empty checkpoint and the
# arm measures nothing. So wait until everything we have written is below the
# horizon, and record how long that took in polls rather than in milliseconds.
wait_for_horizon() {
    local i
    for i in $(seq 1 400); do
        if [ "$(psql $PGH -d $DB -tAc "SELECT pg_snapshot_xmin(pg_current_snapshot())
                    > COALESCE((SELECT max(xact_id) FROM ledger_entries), '0'::xid8)")" = t ]; then
            echo "   horizon caught up after $i polls"; return 0
        fi
        sleep 0.25
    done
    echo "   !! horizon never caught up with our own book -- arm is not interpretable"
    return 1
}

report() {  # $1 = arm label
    echo "--------------------------------------------------------------- $1"
    psql $PGH -d $DB -x -c "
    SELECT c.computed_at_xid::text AS computed_at_xid,
           x.xact_id::text         AS close_txn_xact_id,
           CASE WHEN c.computed_at_xid = x.xact_id THEN 'equal'
                WHEN c.computed_at_xid < x.xact_id THEN 'BELOW the close (recon_close_breaks fires)'
                ELSE 'above' END   AS relation,
           (SELECT count(*) FROM recon_close_breaks)      AS close_typing_breaks,
           (SELECT count(*) FROM recon_checkpoint_breaks) AS checkpoint_drift_breaks,
           (SELECT count(*) FROM recon_cursor_breaks WHERE reason='above_horizon')
                                                         AS cursor_above_horizon_breaks,
           (SELECT count(*) FROM ledger_period_balances) AS checkpoint_rows,
           -- AT-CLOSE, as ADR-0011 A4 asserts: temporary accounts at 0 and a
           -- retained_earnings row present in the checkpoint
           (SELECT COALESCE(string_agg(a.purpose || '=' || (b.input-b.output), ', ' ORDER BY a.purpose), '(no rows)')
              FROM ledger_period_balances b
              JOIN ledger_accounts a ON a.tenant_id=b.tenant_id AND a.id=b.account_id AND a.currency=b.currency
              JOIN account_types t ON t.code=a.purpose
             WHERE t.category IN ('revenue','expense','equity')) AS temporary_and_equity_rows,
           (SELECT EXISTS (SELECT 1 FROM ledger_period_balances b
                           JOIN ledger_accounts a ON a.tenant_id=b.tenant_id AND a.id=b.account_id
                                                 AND a.currency=b.currency
                           WHERE a.purpose='retained_earnings')) AS checkpoint_has_retained_earnings,
           -- the only question that matters: does the checkpoint reader agree
           -- with the from-inception aggregate, account by account
           (SELECT count(*) FROM arm_reader r
              FULL JOIN arm_from_inception f ON f.account_id = r.account_id
             WHERE r.debits IS DISTINCT FROM f.debits
                OR r.credits IS DISTINCT FROM f.credits)   AS reader_disagreements,
           (SELECT COALESCE(SUM(breaks),0) FROM reconciliation) AS total_reconciliation_breaks
    FROM ledger_period_closes c
    JOIN ledger_transactions x ON x.tenant_id=c.tenant_id AND x.id=c.transaction_id;"
    psql $PGH -d $DB -c "
    SELECT COALESCE(a.purpose,'?') AS purpose, f.debits AS inception_dr, r.debits AS reader_dr,
           f.credits AS inception_cr, r.credits AS reader_cr
    FROM arm_from_inception f
    FULL JOIN arm_reader r ON r.account_id=f.account_id
    LEFT JOIN ledger_accounts a ON a.tenant_id='a' AND a.id=COALESCE(f.account_id,r.account_id)
    WHERE r.debits IS DISTINCT FROM f.debits OR r.credits IS DISTINCT FROM f.credits;"
}

echo "############################################################################"
echo "# SPIKE 024 -- the three arms of computed_at_xid.  PG18, localhost:5433."
echo "# $(psql $PGH -d postgres -tAc 'select version();')"
echo "############################################################################"

for MODE in xmin_strict own_xid identity; do
    READER=cursor; [ "$MODE" = identity ] && READER=identity

    # ---------------------------------------------------------------- IDLE
    fresh
    wait_for_horizon || true
    $Q -c "SELECT spike_close_mode('a','2026-01','USD','$MODE');" >/dev/null
    reader_sql "$READER" | $Q >/dev/null
    report "$MODE / horizon caught up before the close"

    # ---------------------------------------------------------------- CONCURRENT
    # An OLDER writer: it acquires its xid and inserts its posting BEFORE the
    # close begins, holds the transaction open ACROSS the close, and commits
    # after. Its xid is therefore LOWER than the close's, and its rows are
    # invisible to the close's own INSERT ... SELECT. This is exactly the
    # interleaving ADR-0011 §1's table is about.
    fresh
    wait_for_horizon || true
    FIFO=$(mktemp -u /tmp/spike024.fifo.XXXX); mkfifo "$FIFO"
    psql $PGH -d $DB -q -v ON_ERROR_STOP=1 -f - <"$FIFO" >/dev/null 2>&1 &
    HOLDER=$!
    exec 3>"$FIFO"
    echo "BEGIN;" >&3
    # pic -> recv_1, NOT through a temporary account: the close upserts the
    # balance cache row of every temporary account it sweeps, so a holder sitting
    # on fee_revenue's row makes the close BLOCK rather than proceed -- measured,
    # and an operational note in FINDINGS rather than the experiment.
    echo "SELECT spike_post_raw('a','USD', md5('a:pic:USD')::uuid, md5('a:recv_1:USD')::uuid,
                                70, '2026-01-20 00:00+00', 'a-held');" >&3
    # give the holder time to have really executed it and be sitting idle in
    # transaction -- polled, not slept-on, so there is no timing dependence
    for _ in $(seq 1 200); do
        n=$(psql $PGH -d $DB -tAc "SELECT count(*) FROM pg_stat_activity
              WHERE datname='$DB' AND state='idle in transaction'")
        [ "$n" -ge 1 ] && break
        sleep 0.05
    done
    [ "${n:-0}" -ge 1 ] || { echo "holder never reached idle-in-transaction"; exit 1; }
    # lock_timeout so a block fails loudly instead of hanging the spike
    $Q -c "SET lock_timeout='10s';" -c "SELECT spike_close_mode('a','2026-01','USD','$MODE');" >/dev/null
    echo "COMMIT;" >&3
    exec 3>&-
    wait $HOLDER 2>/dev/null || true
    rm -f "$FIFO"
    reader_sql "$READER" | $Q >/dev/null
    report "$MODE / CONCURRENT older writer committing after the close"
done

echo
echo "############################################################################"
echo "# done -- shapes and green/red above, no milliseconds anywhere."
echo "############################################################################"
