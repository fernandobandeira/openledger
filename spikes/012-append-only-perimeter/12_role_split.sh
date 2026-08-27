#!/usr/bin/env bash
# 12 -- the role split, which is what turns the event trigger from decoration into
# a guard. Three shapes, same guard, three different answers.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PGPASSWORD=openledger
SU="psql -h localhost -p 5433 -U openledger"
run_migrator() { PGPASSWORD=x psql -h localhost -p 5433 -U wsa_migrator -d spike_wsa_split "$@"; }
setup() {
  $SU -d postgres -q -c "DROP DATABASE IF EXISTS spike_wsa_split (FORCE);" \
                   -c "DROP ROLE IF EXISTS wsa_migrator;" \
                   -c "CREATE ROLE wsa_migrator LOGIN PASSWORD 'x';" \
                   -c "$1"
}
attack() {
  echo "-- can the migrator remove the guard, or use any of the four channels? --"
  run_migrator -c "DROP FUNCTION refuse_journal_ddl() CASCADE;" \
               -c "DROP EVENT TRIGGER ck_journal__no_rewrite;" \
               -c "ALTER TABLE ledger_entries ALTER COLUMN account_seq TYPE bigint USING (account_seq*10);" \
               -c "CREATE TABLE shadow_entries () INHERITS (ledger_entries);" \
               -c "DROP TABLE ledger_entries CASCADE;" \
               -c "ALTER TABLE ledger_entries DISABLE TRIGGER USER;" 2>&1
}

echo "################ A. migrator IS the database owner (today's shape)"
setup "CREATE DATABASE spike_wsa_split OWNER wsa_migrator;"
PGPASSWORD=x psql -h localhost -p 5433 -U wsa_migrator -d spike_wsa_split -q -v ON_ERROR_STOP=1 -f "$ROOT/migrations/00001_baseline.sql" 2>&1 | head -3
$SU -d spike_wsa_split -q -v ON_ERROR_STOP=1 -f "$ROOT/spikes/012-append-only-perimeter/08_event_trigger.sql"
$SU -d spike_wsa_split -c "SELECT nspname, nspowner::regrole AS public_owner FROM pg_namespace WHERE nspname='public';"
echo "-- the database owner is a member of pg_database_owner, which OWNS public, --"
echo "-- so it can drop a superuser's function in it, and CASCADE takes the guard. --"
attack

echo
echo "################ B. migrator owns the TABLES; the database is owned elsewhere"
setup "CREATE DATABASE spike_wsa_split;"
$SU -d spike_wsa_split -q -c "GRANT CREATE, USAGE ON SCHEMA public TO wsa_migrator;"
PGPASSWORD=x psql -h localhost -p 5433 -U wsa_migrator -d spike_wsa_split -q -v ON_ERROR_STOP=1 -f "$ROOT/migrations/00001_baseline.sql" 2>&1 | head -5
$SU -d spike_wsa_split -q -v ON_ERROR_STOP=1 -f "$ROOT/spikes/012-append-only-perimeter/08_event_trigger.sql"
attack
echo "-- ...and what the split BREAKS in the shipped baseline: --"
$SU -d spike_wsa_split -c "SELECT grantee, privilege_type FROM information_schema.usage_privileges WHERE object_name='public' AND grantee='openledger_app';" \
                       -c "SELECT has_schema_privilege('openledger_app','public','USAGE') AS app_can_see_the_schema;"
