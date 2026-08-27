#!/usr/bin/env bash
# 019 -- Confirm, against a REAL managed instance, that the master account can install
# ADR-0009's DDL perimeter. This is the empirical half of the desk research in NOTES.md.
#
# IMPORTANT: this test is meaningless against self-managed Postgres. localhost:5433 is
# self-managed -- it has (or can have) a real superuser, so it will NOT reproduce the
# managed NOSUPERUSER restriction and would "pass" for the wrong reason. Point it at a
# genuine RDS / Aurora / Cloud SQL / Azure endpoint, connected as the provider's TOP
# customer role (RDS/Aurora: the master `postgres`; Cloud SQL: a cloudsqlsuperuser member;
# Azure: the azure_pg_admin server admin). Then read the four verdicts.
#
# Desk-research prediction (see NOTES.md):
#   RDS/Aurora PG18 : steps 1-4 all SUCCEED (event triggers are documented for the master account).
#   Cloud SQL       : step 1/2 FAIL (no customer event triggers); step 4 (session_replication_role) may succeed.
#   Azure Flexible  : step 1/2 FAIL (event triggers not supported).
#   self-managed    : all SUCCEED only because you connected as/near a superuser -- not a valid datapoint.
#
# Usage:
#   PGHOST=my-instance.abc123.us-east-1.rds.amazonaws.com \
#   PGPORT=5432 PGUSER=postgres PGDATABASE=postgres PGPASSWORD=... \
#   ./test_managed.sh
set -uo pipefail

: "${PGHOST:?set PGHOST to a MANAGED endpoint -- do not run against localhost}"
: "${PGPORT:=5432}"
: "${PGUSER:?set PGUSER to the provider's top customer role (e.g. postgres on RDS)}"
: "${PGDATABASE:=postgres}"
export PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD

if [[ "$PGHOST" == localhost || "$PGHOST" == 127.0.0.1 || "$PGHOST" == "::1" ]]; then
  echo "REFUSING: $PGHOST is self-managed; this test only means something on a managed service." >&2
  exit 2
fi

P=(psql -v ON_ERROR_STOP=0 -X -q)

echo "== target: role=$(psql -Atqc 'select current_user') on $PGHOST:$PGPORT/$PGDATABASE =="
echo "== rolsuper for current_user (expect f on a managed service): =="
"${P[@]}" -Atc "SELECT rolname, rolsuper FROM pg_roles WHERE rolname = current_user;"

echo
echo "-- clean slate --"
"${P[@]}" -c "DROP EVENT TRIGGER IF EXISTS spike019_et;" \
          -c "DROP TABLE IF EXISTS spike019_t;" \
          -c "DROP FUNCTION IF EXISTS spike019_guard();"

echo
echo "== step 1: CREATE EVENT TRIGGER (the load-bearing statement -- stock PG needs superuser) =="
"${P[@]}" \
  -c "CREATE FUNCTION spike019_guard() RETURNS event_trigger LANGUAGE plpgsql AS \$\$ BEGIN END \$\$;" \
  -c "CREATE EVENT TRIGGER spike019_et ON ddl_command_end EXECUTE FUNCTION spike019_guard();"

echo
echo "== step 2: ALTER EVENT TRIGGER ... ENABLE ALWAYS (stock PG needs superuser) =="
"${P[@]}" -c "ALTER EVENT TRIGGER spike019_et ENABLE ALWAYS;"

echo
echo "== step 3: ALTER TABLE ... ENABLE ALWAYS TRIGGER on an ORDINARY user trigger =="
echo "   (predicted to work everywhere the caller owns the table -- table-owner privilege, not superuser)"
"${P[@]}" \
  -c "CREATE TABLE spike019_t (id int);" \
  -c "CREATE TRIGGER spike019_tt BEFORE INSERT ON spike019_t FOR EACH ROW EXECUTE FUNCTION suppress_redundant_updates_trigger();" \
  -c "ALTER TABLE spike019_t ENABLE ALWAYS TRIGGER spike019_tt;"

echo
echo "== step 4: session_replication_role (PG15+ RDS: GRANT SET ON PARAMETER ...; needed by the"
echo "   replication-apply and data-only-restore open rows, NOT by 0009's chosen design) =="
"${P[@]}" -c "SET session_replication_role = 'replica';" -c "RESET session_replication_role;"

echo
echo "== verdict: what actually got installed =="
"${P[@]}" -Atc "SELECT evtname, evtenabled FROM pg_event_trigger WHERE evtname = 'spike019_et';"
"${P[@]}" -Atc "SELECT tgname, tgenabled FROM pg_trigger WHERE tgname = 'spike019_tt';"

echo
echo "-- cleanup --"
"${P[@]}" -c "DROP EVENT TRIGGER IF EXISTS spike019_et;" \
          -c "DROP TABLE IF EXISTS spike019_t;" \
          -c "DROP FUNCTION IF EXISTS spike019_guard();"

echo
echo "Read the output: a managed service where steps 1-2 print CREATE/ALTER (no 'permission denied"
echo "to create event trigger' / 'must be superuser') confirms the perimeter installs there. On"
echo "RDS/Aurora PG18 that is the documented and expected result (NOTES.md)."
