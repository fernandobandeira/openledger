#!/usr/bin/env bash
# Spike 020 -- what a period close costs over a large account population.
#
#   ./run.sh          the full run: Q1 close scaling (10k/100k/1M), Q2 checkpoint
#                     read, Q3 reconciliation sweep. Takes a few minutes -- the 1M
#                     seed alone is ~2 min.
#   ./run.sh quick    skip the 1M size in Q1 (10k/100k only).
#
# LOCALHOST IS NOT A BENCHMARK (spike 003's banner). Everything runs on one
# localhost PostgreSQL 18; nothing here is measured over a network. The SHAPE --
# linear or not, per-currency, what dominates, what the checkpoint could save, how
# the sweep grows with the number of closes -- is the finding, never the millisecond.
#
# Nothing here is product. 00_functions.sql seeds a wide book and closes a period
# EXACTLY as the write path does it (ADR-0011 sp_close_period, post-fix convention).
set -euo pipefail
cd "$(dirname "$0")"
export PGPASSWORD=openledger
HOST="-h localhost -p 5433 -U openledger"
ROOT=../..
Q="psql $HOST -q -v ON_ERROR_STOP=1"

MODE="${1:-full}"

fresh() {  # $1 = dbname -- drop, create, load baseline + chart + spike functions
    psql $HOST -d postgres -qc "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$1' AND pid<>pg_backend_pid();" >/dev/null 2>&1 || true
    psql $HOST -d postgres -qc "DROP DATABASE IF EXISTS $1 WITH (FORCE);" -qc "CREATE DATABASE $1;" >/dev/null
    for f in $ROOT/migrations/00001_baseline.sql $ROOT/schema/chart.sql 00_functions.sql; do
        $Q -d "$1" -f "$f" >/dev/null
    done
}

# month bounds, half-open, resolved once in UTC
mstart() { printf '2026-%02d-01 00:00+00' "$1"; }
mend()   { if [ "$1" -eq 12 ]; then echo '2027-01-01 00:00+00'; else printf '2026-%02d-01 00:00+00' $(( $1 + 1 )); fi; }
menddate(){ if [ "$1" -eq 12 ]; then echo '2026-12-31'; else printf '2026-%02d-%02d' "$1" 27; fi; }  # a date inside the period, for the attestation

# seed+close one period of a multi-period book (seed COMMITS before the close, so
# the close's pg_snapshot_xmin cursor can see it -- a close cannot see its own txn).
seed_close_period() { # $1 db  $2 tenant  $3 curr  $4 monthidx  $5 apc  $6 rev
    local db=$1 tn=$2 cur=$3 m=$4 apc=$5 rev=$6
    local code; code=$(printf '2026-%02d' "$m")
    local g0=$(( (m - 1) * (apc + 2*rev) ))
    $Q -d "$db" -c "INSERT INTO ledger_periods VALUES ('$tn','$code','$(mstart $m)','$(mend $m)','UTC');"
    $Q -d "$db" -c "SET session_replication_role=replica;" \
       -c "SELECT spike_seed('$tn','$cur','$code','$(mstart $m)','$(mend $m)', $apc, $rev, $g0, $m);"
    $Q -d "$db" -c "SELECT spike_close('$tn','$code','$cur');" >/dev/null
    $Q -d "$db" -c "SELECT spike_attest('$tn','$cur', DATE '$(menddate $m)');"
}

echo "############################################################################"
echo "# SPIKE 020 -- close cost at scale.  PG18, localhost:5433 -- SHAPE, not bench."
echo "# $(psql $HOST -d postgres -tAc 'select version();')"
echo "############################################################################"

# ===========================================================================
echo; echo "########################## Q1 -- CLOSE WRITE COST vs ACCOUNT POPULATION"
# One tenant, USD, one period. Vary the account count; time the close exactly as
# the write path runs it. Linear in accounts? What dominates?
SIZES="10000 100000"
[ "$MODE" = "quick" ] || SIZES="10000 100000 1000000"
for apc in $SIZES; do
    echo; echo "===================================== $apc wallets (USD, one period)"
    fresh spike_close_cost
    $Q -d spike_close_cost -v apc=$apc -f 01_close_scaling.sql
done

echo; echo "===================================== per-currency: 3 currencies x 100k, one period"
# The close is ONE INSERT...SELECT PER CURRENCY. Three currencies = three closes,
# each scaling with that currency's own account count -- additive, not shared.
fresh spike_close_cost
$Q -d spike_close_cost -c "INSERT INTO ledger_periods VALUES ('mc','2026-01','$(mstart 1)','$(mend 1)','UTC');"
for cur in USD EUR GBP; do
    $Q -d spike_close_cost -c "SET session_replication_role=replica;" \
       -c "SELECT spike_seed('mc','$cur','2026-01','$(mstart 1)','$(mend 1)', 100000, 500, 0, 1);"
done
$Q -d spike_close_cost -c "ANALYZE;" >/dev/null
for cur in USD EUR GBP; do
    echo "--- close mc/2026-01/$cur ---"
    psql $HOST -d spike_close_cost -c "\timing on" -c "SELECT spike_close('mc','2026-01','$cur') IS NOT NULL AS closed;" 2>&1 | grep -iE "closed|Time|^ t"
done
psql $HOST -d spike_close_cost -tAc "SELECT currency, count(*) FROM ledger_period_balances GROUP BY currency ORDER BY 1;"

# ===========================================================================
echo; echo "########################## Q2 -- THE CHECKPOINT READ BENEFIT (and its reader)"
# tenant 'r': 20k wallets, 6 monthly periods, each wallet a deposit per period,
# every period closed. Deep enough history that a from-inception as-of scan is big.
fresh spike_close_cost
for m in 1 2 3 4 5 6; do seed_close_period spike_close_cost r USD $m 20000 500; done
$Q -d spike_close_cost -c "ANALYZE;" >/dev/null
$Q -d spike_close_cost -v boundary="$(mend 6)" -v lastp="2026-06" -f 02_checkpoint_read.sql

# ===========================================================================
echo; echo "########################## Q3 -- RECONCILIATION SWEEP vs NUMBER OF CLOSES"
# tenant 'q': 8k wallets, 12 monthly periods each closed. Time the checkpoint
# reconciliation and the full sweep at 3, 6, 9, 12 closes -- O(entries x closes)?
fresh spike_close_cost
for m in $(seq 1 12); do
    seed_close_period spike_close_cost q USD $m 8000 300
    if [ "$m" = 3 ] || [ "$m" = 6 ] || [ "$m" = 9 ] || [ "$m" = 12 ]; then
        $Q -d spike_close_cost -c "ANALYZE;" >/dev/null
        echo; echo "----------------------------------- after $m closes"
        $Q -d spike_close_cost -f 03_recon_sweep.sql
    fi
done

echo; echo "############################################################################"
echo "# done. localhost, PG18 -- ratios and shapes above, not a benchmark."
echo "############################################################################"
