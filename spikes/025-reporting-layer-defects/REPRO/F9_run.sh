#!/usr/bin/env bash
# F9 end to end, against a freshly restored spike025_f9.
#
# Two connections are needed -- the reader half must run as a role the RLS
# policies bind, and the owner half must run as the role they do not -- so the
# ordering lives here rather than in one .sql file.
#
# Order matters: half two opens an EUR account, which changes the shape of every
# t1 statement afterwards, so the reader and owner halves of the claim run first.
set -euo pipefail

BASE="${BASE:-postgres://openledger:openledger@localhost:5455}"
DB="${DB:-spike025_f9}"
OWNER_URL="$BASE/$DB?sslmode=disable"
READ_URL="postgres://spike025_read_login:spike025-only@${BASE#*@}/$DB?sslmode=disable"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "########## F9 pre: the reader role"
psql "$OWNER_URL" -q -f "$HERE/F9_read_login_role.sql"

echo
echo "########## F9 half one, as spike025_read_login (RLS binds it)"
psql "$READ_URL" -q -f "$HERE/F9_wrong_tenant_reader.sql"

echo
echo "########## F9 half one, as the OWNER (RLS does not bind it)"
psql "$OWNER_URL" -q -f "$HERE/F9_wrong_tenant_owner.sql"

# report_cursor() is pg_snapshot_xmin, the CLUSTER horizon: it lags until every
# freshly committed row is retired below it. Poll rather than sleep blindly, and
# bound the poll so a stuck horizon fails loudly instead of hanging. The wait
# itself is pg_sleep on the server, not a shell sleep.
echo
echo "########## F9 half two: waiting for the cursor to retire the seeded entries"
for _ in $(seq 1 60); do
    settled=$(psql "$OWNER_URL" -tAqc \
        "SELECT coalesce(max(xact_id) < pg_snapshot_xmin(pg_current_snapshot()), true)
         FROM ledger_entries")
    [ "$settled" = "t" ] && break
    psql "$OWNER_URL" -tAqc "SELECT pg_sleep(0.25)" >/dev/null
done
if [ "$settled" != "t" ]; then
    echo "the cluster horizon never advanced past the seeded entries; a long-running" >&2
    echo "transaction is holding it back. Nothing pinned at report_cursor() is" >&2
    echo "readable yet, so F9 half two cannot run." >&2
    exit 1
fi
echo "settled: every seeded entry is strictly below report_cursor()"

echo
echo "########## F9 half two, as the OWNER (it opens an account)"
psql "$OWNER_URL" -q -f "$HERE/F9_unpinned_shape.sql"
