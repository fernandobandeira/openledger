#!/usr/bin/env bash
# Spike 017 -- reproduce every "known, and not fixed" finding in the card rail's
# ADR-0001, then demonstrate each fix. Ran 2026-08-27 against PostgreSQL 18.6.
#
#   ./run.sh            # everything, to stdout
#
# Builds a scratch database from scratch. Never touches `openledger`.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
DB=${DB:-spike_wsg}
export PGPASSWORD=openledger
P="psql -h localhost -p 5433 -U openledger"

echo "### building $DB: baseline, then the parked card DDL (the documented manual path)"
$P -d postgres -q -c "DROP DATABASE IF EXISTS $DB WITH (FORCE);" -c "CREATE DATABASE $DB;"
$P -d "$DB" -q -v ON_ERROR_STOP=1 -f "$ROOT/migrations/00001_baseline.sql"
$P -d "$DB" -q -v ON_ERROR_STOP=1 --single-transaction -f "$ROOT/parked/card/schema.sql"
$P -d "$DB" -q -v ON_ERROR_STOP=1 -f 00-harness.sql

echo; echo "### THE FINDINGS, on the parked schema as it stands"
for f in 01-misgrouped-total 02-expiry-race 03-decreasing-restatement \
         04-convention-mix 05-residue 07-currency-pin 09-drift-disjuncts; do
    echo; echo "======== $f"; $P -d "$DB" -f "$f.sql"
done
echo; echo "======== 08-deadlock"; ./08-deadlock.sh
echo; echo "======== how many disjuncts card_hold_drift really has"; ./09-count-disjuncts.sh

echo; echo "### THE FIXES: the proposed DDL, loaded into schema \`fixed\` beside it"
$P -d "$DB" -q -c "CREATE SCHEMA fixed;"
PGOPTIONS="--search_path=fixed,public" $P -d "$DB" -q -v ON_ERROR_STOP=1 \
    --single-transaction -f "$ROOT/parked/card/schema.sql"
$P -d "$DB" -q -v ON_ERROR_STOP=1 --single-transaction -f 20-proposed-ddl.sql
$P -d "$DB" -q -v ON_ERROR_STOP=1 -f 21-fixed-harness.sql
echo; echo "======== 22-proved";        $P -d "$DB" -f 22-proved.sql
echo; echo "======== 23-permutations";  $P -d "$DB" -f 23-permutations.sql
