#!/usr/bin/env bash
# Spike 024 -- the three adversarial cells that came out of the audit finding,
# all on the `spike024` book, all rolled back.
#
#   A. recon_cursor_breaks reports `above_horizon` for HONEST entries whenever any
#      older transaction is still running, because it bounds an entry's xact_id by
#      pg_snapshot_XMIN rather than pg_snapshot_XMAX.
#   B. computed_at_xid is bounded FROM BELOW ONLY: a close storing 2^62 is green in
#      recon_close_breaks, empties close_disclosures for that period, and surfaces
#      in recon_checkpoint_breaks only later and mislabelled.
#   C. computed_at_xid sits under a TABLE-WIDE insert grant, unlike xact_id, which
#      the baseline protects with a column list.
#
# NO TIMING.
set -euo pipefail
cd "$(dirname "$0")"
export PGPASSWORD=openledger
PGH="-h localhost -p 5433 -U openledger"
DB=spike024
mkdir -p out

echo "############ A. recon_cursor_breaks against an honest entry under an older open transaction"
# Run on the throwaway arms database, not on `spike024`: the entry has to be
# COMMITTED by a different session for the cell to be about the sweep rather than
# about the sweep's own uncommitted rows. (An earlier version of this cell posted
# inside the measuring transaction and reported 2 breaks under BOTH bounds --
# a snapshot's xmax is latestCompletedXid + 1, which EQUALS the observer's own
# xid, so the observer was flagging itself. The sweep holds no xid.)
ADB=spike024arms
FIFO=$(mktemp -u /tmp/spike024.adv.XXXX); mkfifo "$FIFO"
psql $PGH -d $ADB -q -v ON_ERROR_STOP=1 -f - <"$FIFO" >/dev/null 2>&1 &
HOLDER=$!
exec 3>"$FIFO"
echo "BEGIN;" >&3
# pg_current_xact_id() forces xid assignment without writing a row, so the holder
# pins the cluster horizon and changes no data at all.
echo "SELECT pg_current_xact_id();" >&3
for _ in $(seq 1 200); do
    n=$(psql $PGH -d $ADB -tAc "SELECT count(*) FROM pg_stat_activity
          WHERE datname='$ADB' AND state='idle in transaction'")
    [ "$n" -ge 1 ] && break
    sleep 0.05
done
# a committed posting from a THIRD session, above the pinned horizon
psql $PGH -d $ADB -q -tAc "SELECT spike_post_raw('a','USD', md5('a:pic:USD')::uuid,
        md5('a:recv_1:USD')::uuid, 11, '2026-01-25 00:00+00', 'adv-A') IS NOT NULL;" >/dev/null
# ...and now the sweep, exactly as `openledger reconcile` runs it: a READ ONLY
# transaction holding no xid of its own.
psql $PGH -d $ADB -v ON_ERROR_STOP=1 <<'SQL'
BEGIN TRANSACTION READ ONLY;
SELECT pg_snapshot_xmin(pg_current_snapshot()) AS xmin_pinned_by_the_holder,
       pg_snapshot_xmax(pg_current_snapshot()) AS xmax,
       (SELECT max(xact_id) FROM ledger_entries) AS newest_committed_entry_xid;
SELECT (SELECT count(*) FROM recon_cursor_breaks WHERE reason = 'above_horizon')
           AS shipped_above_horizon_breaks,
       -- the same question bounded by XMAX, which is latestCompletedXid + 1 and
       -- therefore a value no COMMITTED xid can reach.
       (SELECT count(*) FROM ledger_entries e
         WHERE e.xact_id >= pg_snapshot_xmax(pg_current_snapshot()))
           AS xmax_bounded_breaks,
       (SELECT count(*) FROM reconciliation WHERE check_name='cursor_forgery' AND breaks <> 0)
           AS sweep_would_exit_1;
ROLLBACK;
SQL
echo "COMMIT;" >&3
exec 3>&-
wait $HOLDER 2>/dev/null || true
rm -f "$FIFO"

echo
echo "############ B and C"
psql $PGH -d $DB -v ON_ERROR_STOP=1 -f sql/60_adversary.sql
