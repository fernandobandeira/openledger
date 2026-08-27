#!/usr/bin/env bash
# 10_run.sh -- COPY vs multi-row INSERT vs unnest, on ledger_entries.
set -euo pipefail
cd "$(dirname "$0")"
: "${PGHOST:=localhost}" "${PGPORT:=5433}" "${PGUSER:=openledger}" "${PGDATABASE:=spike_wse}"
export PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD="${PGPASSWORD:-openledger}"
python3 10_copy_vs_insert.py 10_copy_vs_insert.sql
psql -X -q -f 10_copy_vs_insert.sql 2>&1 \
 | awk '/^@@/ {split($0,a," "); m=a[2]; n=a[3]; next}
        /^Time:/ && m != "" {printf "%s %s %s\n", m, n, $2; m=""}' \
 | sort -k2,2n -k1,1 \
 | awk '{k=$1" "$2; t[k]=t[k]" "$3; c[k]++}
        END {for (k in t) {split(t[k],v," "); n=asort(v);
             printf "%-8s %6s  median %8.2f ms  min %8.2f  max %8.2f\n",
                    substr(k,1,index(k," ")-1), substr(k,index(k," ")+1),
                    v[int((n+1)/2)], v[1], v[n]}}' 2>/dev/null \
 || true
