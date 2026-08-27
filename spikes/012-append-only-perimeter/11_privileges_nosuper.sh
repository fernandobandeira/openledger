#!/usr/bin/env bash
# The half of 11 that needs a SECOND, non-superuser role. Managed Postgres (RDS,
# Cloud SQL, Neon) hands you a database owner and no superuser; this is that shape.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PGPASSWORD=openledger
psql -h localhost -p 5433 -U openledger -d postgres -q \
  -c "DROP DATABASE IF EXISTS spike_wsa_nosuper (FORCE);" \
  -c "DROP ROLE IF EXISTS wsa_owner;" \
  -c "CREATE ROLE wsa_owner LOGIN PASSWORD 'x';" \
  -c "CREATE DATABASE spike_wsa_nosuper OWNER wsa_owner;"
export PGPASSWORD=x
P="psql -h localhost -p 5433 -U wsa_owner -d spike_wsa_nosuper"
$P -q -v ON_ERROR_STOP=1 -f "$ROOT/migrations/00001_baseline.sql"
echo "-- baseline applied by a NON-superuser owner: it loads --"
echo "-- 1. can it set session_replication_role? --"
$P -c "SET session_replication_role='replica';"
echo "-- 2. can it promote an FK's internal triggers to ENABLE ALWAYS? --"
$P -c "SELECT tgname FROM pg_trigger WHERE tgrelid='ledger_entries'::regclass AND tgisinternal LIMIT 1;" -At \
  | head -1 | while read -r t; do $P -c "ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER \"$t\";"; done
echo "-- 3. can it create the event trigger? --"
$P -c "CREATE FUNCTION f() RETURNS event_trigger LANGUAGE plpgsql AS \$\$ BEGIN END \$\$;" \
   -c "CREATE EVENT TRIGGER e ON ddl_command_end EXECUTE FUNCTION f();"
echo "-- 4. can it run the pg_dump --disable-triggers restore path? --"
$P -c "ALTER TABLE ledger_entries DISABLE TRIGGER ALL;"
echo "-- 5. ...but DISABLE TRIGGER USER, which is enough to delete history, it CAN --"
$P -c "ALTER TABLE ledger_entries DISABLE TRIGGER USER;" \
   -c "SELECT tgname, tgenabled FROM pg_trigger WHERE tgrelid='ledger_entries'::regclass AND NOT tgisinternal;"
