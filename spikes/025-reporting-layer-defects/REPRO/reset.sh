#!/usr/bin/env bash
# Restore the clean book. The journal is append-only -- refuse_mutation()
# refuses the DELETE that would undo an injection -- so a reproduction cannot
# tidy up after itself. `CREATE DATABASE ... TEMPLATE` is the cheap exact
# restore: `spike025_clean` is the negative-control book, taken once, and
# every reproduction starts from a byte-identical copy of it.
set -euo pipefail
BASE="${BASE:-postgres://openledger:openledger@localhost:5455}"
psql "$BASE/postgres?sslmode=disable" -v ON_ERROR_STOP=1 -q \
  -c "DROP DATABASE IF EXISTS spike025 WITH (FORCE);" \
  -c "CREATE DATABASE spike025 TEMPLATE spike025_clean;"
echo "restored spike025 from spike025_clean"
