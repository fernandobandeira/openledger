#!/usr/bin/env bash
# F10 -- recon_cursor_breaks' stated justification, tested.
#
# The view's own comment says the two shapes it lists are "impossible on an
# honest book", and gives this reason for the first:
#
#   "an xact_id at or above the current snapshot's xmin (a committed row's commit
#    position is always retired below the horizon by the time the sweep runs)"
#
# report_cursor()'s comment, forty lines earlier in the same file, says the
# opposite about the same function:
#
#   "pg_snapshot_xmin is the CLUSTER's horizon, so one long-running transaction
#    anywhere on the server -- another database included -- holds every new
#    report's cursor back (lag, never wrongness ...)"
#
# The two cannot both be right. For report_cursor() a held-back xmin is lag; for
# recon_cursor_breaks the same held-back xmin is a FORGERY VERDICT on a committed,
# honest row.
#
# THIS SCRIPT NEEDS ITS OWN POSTGRES INSTANCE. It opens a transaction and holds
# it, which drags the horizon back for every database on the cluster -- which is
# precisely the finding, and precisely why it must not be run on a shared server.
#
# RE-RUNNING IT. Sections 2 and 6 append entries, and section 6's are forged, so
# a second run collides on pk_entries. Rebuild the book first:
#
#   docker rm -f spike025-db-f10
#   docker run -d --name spike025-db-f10 -e POSTGRES_USER=openledger \
#     -e POSTGRES_PASSWORD=openledger -e POSTGRES_DB=openledger \
#     -p 5456:5432 postgres:18-alpine
#   psql ".../postgres" -c 'CREATE DATABASE spike025;' -c 'CREATE DATABASE spike025_neighbour;'
#   DATABASE_URL=".../spike025" ./target/debug/openledger migrate
#   psql ".../spike025" --single-transaction -f schema/chart.sql
#   psql ".../spike025" -f REPRO/00_accounts.sql
#   DATABASE_URL=".../spike025" BIND=127.0.0.1:8127 ./REPRO/01_seed_book.sh
set -euo pipefail
BASE="${BASE:-postgres://openledger:openledger@localhost:5456}"
BOOK="$BASE/spike025?sslmode=disable"
NEIGHBOUR="$BASE/spike025_neighbour?sslmode=disable"

say() { printf '\n=== %s\n' "$*"; }

say "0. the negative control: an honest book, nothing held, ten checks at zero"
psql "$BOOK" -c "SELECT * FROM reconciliation;"
psql "$BOOK" -c "SELECT pg_snapshot_xmin(pg_current_snapshot()) AS horizon,
                        (SELECT max(xact_id) FROM ledger_entries) AS max_entry,
                        (SELECT count(*) FROM recon_cursor_breaks) AS cursor_breaks;"

say "1. a long-running transaction in ANOTHER DATABASE on the same instance"
# psql on its own fd, kept open; the transaction acquires a real xid so it is
# counted by the horizon (a read-only transaction would not be).
coproc HOLD { psql -q -X "$NEIGHBOUR" 2>&1; }
cat >&"${HOLD[1]}" <<'EOS'
BEGIN;
CREATE TEMP TABLE hold_the_horizon (n int);
INSERT INTO hold_the_horizon VALUES (1);
SELECT pg_current_xact_id() AS the_xid_being_held;
EOS
# wait for the neighbour's xid to be visible, bounded, no bare sleep
for _ in $(seq 1 200); do
  n=$(psql "$BOOK" -At -c "SELECT count(*) FROM pg_stat_activity
                            WHERE datname='spike025_neighbour' AND backend_xid IS NOT NULL")
  [ "$n" = "1" ] && break
done
psql "$BOOK" -c "SELECT pid, datname, state, backend_xid FROM pg_stat_activity
                 WHERE datname='spike025_neighbour' AND backend_xid IS NOT NULL;"

say "2. one honest commit on the BOOK, while the neighbour holds"
psql "$BOOK" -v ON_ERROR_STOP=1 -q <<'EOS'
INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                           idempotency_hash, payload, effective_at)
VALUES ('t1','02510000-0000-7000-8000-000000000001','posting','internal','f10-fee',
        decode('00','hex'),'{}'::jsonb,'2026-08-26T00:00:00Z');
INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
VALUES ('t1','02510000-0000-7000-8000-000000000002',
        '02510000-0000-7000-8000-000000000001','posting','posted','2026-08-26T00:00:00Z');
INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, stripe, account_seq, effective_at)
SELECT 't1','02510000-0000-7000-8000-000000000002', a.id, v.direction::ledger_direction,
       11000,'USD',0,v.seq,'2026-08-26T00:00:00Z'
FROM (VALUES ('customer_receivable','debit',4::bigint),('fee_revenue','credit',2))
     AS v(purpose,direction,seq)
JOIN ledger_accounts a ON a.tenant_id='t1' AND a.purpose=v.purpose;
UPDATE ledger_account_balances b SET input=b.input+11000, last_seq=4
FROM ledger_accounts a WHERE a.tenant_id=b.tenant_id AND a.id=b.account_id
 AND a.currency=b.currency AND b.tenant_id='t1' AND a.purpose='customer_receivable';
UPDATE ledger_account_balances b SET output=b.output+11000, last_seq=2
FROM ledger_accounts a WHERE a.tenant_id=b.tenant_id AND a.id=b.account_id
 AND a.currency=b.currency AND b.tenant_id='t1' AND a.purpose='fee_revenue';
EOS

say "3. recon_cursor_breaks now reports above_horizon on an honest book"
psql "$BOOK" -c "SELECT reason, count(*) FROM recon_cursor_breaks GROUP BY reason;"
psql "$BOOK" -c "SELECT entry_id, xact_id, txn_xact_id, reason FROM recon_cursor_breaks ORDER BY xact_id;"
psql "$BOOK" -c "SELECT pg_snapshot_xmin(pg_current_snapshot()) AS horizon_xmin,
                        pg_snapshot_xmax(pg_current_snapshot()) AS horizon_xmax,
                        (SELECT max(xact_id) FROM ledger_entries) AS max_entry;"
psql "$BOOK" -c "SELECT * FROM reconciliation;"

say "4. the shipped sweep, on this book, while the neighbour holds"
DATABASE_URL="$BOOK" ./target/debug/openledger reconcile && echo "exit=0" || echo "exit=$?"

say "5. THE CANDIDATE FIX, evaluated in place: pg_snapshot_xmax instead of xmin."
psql "$BOOK" <<'EOS'
-- xmax is "one past the highest xid that has been ASSIGNED", so every committed
-- row on this cluster is strictly below it regardless of who is holding an old
-- transaction open. It is not a horizon and cannot be used as a REPORT cursor --
-- a report pinned at xmax would include rows that are still in flight -- but the
-- forgery check is asking a different question: is this xact_id one that could
-- have been assigned by now?
SELECT 'xmin (shipped)' AS bound, count(*) AS breaks
FROM ledger_entries e JOIN ledger_transactions x
  ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id
WHERE e.xact_id > pg_snapshot_xmin(pg_current_snapshot()) OR e.xact_id < x.xact_id
UNION ALL
SELECT 'xmax (candidate)', count(*)
FROM ledger_entries e JOIN ledger_transactions x
  ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id
WHERE e.xact_id >= pg_snapshot_xmax(pg_current_snapshot()) OR e.xact_id < x.xact_id;
EOS

say "6. ...and does the candidate still catch a FAR-FUTURE forged xact_id?"
psql "$BOOK" -v ON_ERROR_STOP=1 -q <<'EOS'
-- Appended as the OWNER: the column-level INSERT grant withholds xact_id from
-- the app role, so this is the shape the view's comment says only the owner can
-- write. Balanced and cache-consistent, so nothing else moves.
INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, stripe, account_seq, effective_at, xact_id)
SELECT 't1','02510000-0000-7000-8000-000000000002', a.id, v.direction::ledger_direction,
       500,'USD',0,v.seq,'2026-08-26T00:00:00Z','9000000000000000000'::xid8
FROM (VALUES ('customer_receivable','debit',5::bigint),('fee_revenue','credit',3))
     AS v(purpose,direction,seq)
JOIN ledger_accounts a ON a.tenant_id='t1' AND a.purpose=v.purpose;
UPDATE ledger_account_balances b SET input=b.input+500, last_seq=5
FROM ledger_accounts a WHERE a.tenant_id=b.tenant_id AND a.id=b.account_id
 AND a.currency=b.currency AND b.tenant_id='t1' AND a.purpose='customer_receivable';
UPDATE ledger_account_balances b SET output=b.output+500, last_seq=3
FROM ledger_accounts a WHERE a.tenant_id=b.tenant_id AND a.id=b.account_id
 AND a.currency=b.currency AND b.tenant_id='t1' AND a.purpose='fee_revenue';
EOS
psql "$BOOK" <<'EOS'
SELECT 'xmin (shipped)' AS bound, count(*) AS breaks
FROM ledger_entries e JOIN ledger_transactions x
  ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id
WHERE e.xact_id > pg_snapshot_xmin(pg_current_snapshot()) OR e.xact_id < x.xact_id
UNION ALL
SELECT 'xmax (candidate)', count(*)
FROM ledger_entries e JOIN ledger_transactions x
  ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id
WHERE e.xact_id >= pg_snapshot_xmax(pg_current_snapshot()) OR e.xact_id < x.xact_id;
EOS

say "7. release the neighbour, and re-read the shipped check"
cat >&"${HOLD[1]}" <<'EOS'
ROLLBACK;
\q
EOS
wait "$HOLD_PID" 2>/dev/null || true
for _ in $(seq 1 200); do
  n=$(psql "$BOOK" -At -c "SELECT count(*) FROM pg_stat_activity
                            WHERE datname='spike025_neighbour' AND backend_xid IS NOT NULL")
  [ "$n" = "0" ] && break
done
psql "$BOOK" -c "SELECT reason, count(*) FROM recon_cursor_breaks GROUP BY reason;"
psql "$BOOK" -c "SELECT pg_snapshot_xmin(pg_current_snapshot()) AS horizon_xmin,
                        (SELECT max(xact_id) FROM ledger_entries
                          WHERE xact_id < '9000000000000000000'::xid8) AS max_honest_entry;"
