#!/usr/bin/env bash
# RUN.sh -- everything in this directory, in order, from an empty database.
# Ran 2026-08-27 against PostgreSQL 18.6 at localhost:5433.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=../..
: "${PGHOST:=localhost}" "${PGPORT:=5433}" "${PGUSER:=openledger}"
export PGHOST PGPORT PGUSER PGPASSWORD="${PGPASSWORD:-openledger}"
DB="${DB:-spike_wse}"

psql -X -q -d postgres -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"
export PGDATABASE="$DB"
psql -X -q -v ON_ERROR_STOP=1 -f $ROOT/migrations/00001_baseline.sql
psql -X -q -v ON_ERROR_STOP=1 -f $ROOT/schema/chart.sql
psql -X -q -v ON_ERROR_STOP=1 -f 00_seed.sql

echo "######## 01 -- isolation, two sessions"
for lvl in 'read committed' 'repeatable read' 'serializable'; do ./01_isolation_two_session.sh "$lvl"; done

echo "######## 02 -- isolation under contention"
uptime; ./02_run.sh "${W:-8}" "${N:-200}"; uptime

echo "######## 03 -- the idempotency replay contract"
psql -X -f 03_idempotency.sql

echo "######## 04 -- the replay contract when two callers race"
for v in two-stmt-rc two-stmt-rr one-stmt-cte; do ./04_idempotency_concurrent.sh "$v"; done

echo "######## 05 -- event_id NOT NULL"
psql -X -f 05_event_id_not_null.sql

echo "######## 06 -- row-level security"
psql -X -f 06_rls.sql

echo "######## 07 -- striping"
psql -X -f 07_striping.sql

echo "######## 08 -- does the striping DDL deliver the mechanism?"
./08_run.sh "${SW:-16}" "${SN:-400}"

echo "######## 09 -- the writer pins its own isolation level"
psql -X -f 09_pin_isolation.sql

echo "######## 10 -- is COPY load-bearing on the batched write path?"
./10_run.sh
