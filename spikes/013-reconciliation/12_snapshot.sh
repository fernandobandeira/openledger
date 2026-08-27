#!/usr/bin/env bash
# WHY THE SWEEP IS ONE TRANSACTION, AND WHY IT IS REPEATABLE READ.
#
# Six views read the journal separately. Under READ COMMITTED each statement takes
# its own snapshot, so the summary can report a break that the list enumerating it
# no longer contains -- an operator paged at 02:00 by a count, finding nothing to
# look at. This is not hypothetical concurrency: the repair path is itself a
# writer, and so is every posting.
#
# Run: ./12_snapshot.sh   (against spike_wsb, seeded by 02_seed_clean.sql)
# It forges the cache, races a repair against the sweep at both isolation levels,
# and leaves the cache rebuilt from the journal -- so the book is clean afterwards.
set -euo pipefail
export PGPASSWORD=openledger
PSQL="psql -h localhost -p 5433 -U openledger -d spike_wsb -q -v ON_ERROR_STOP=1"

forge() {
  $PSQL -c "UPDATE ledger_account_balances b SET output = 1000000
              FROM ledger_accounts a
             WHERE a.tenant_id = b.tenant_id AND a.id = b.account_id AND a.currency = b.currency
               AND b.tenant_id = 't1' AND a.purpose = 'customer_wallet' AND b.currency = 'USD';"
}

# the repair: rebuild the row from the append-only journal. Never a plug figure --
# FDIC RMS 4.2 calls that "forced balancing" and lists it as a control failure.
repair_after_2s() {
  $PSQL -c "SELECT pg_sleep(2);" -c "
    UPDATE ledger_account_balances b
       SET input = j.d, output = j.c, last_seq = j.s
      FROM (SELECT tenant_id, account_id, currency,
                   COALESCE(SUM(amount_minor) FILTER (WHERE direction='debit'),0)  AS d,
                   COALESCE(SUM(amount_minor) FILTER (WHERE direction='credit'),0) AS c,
                   MAX(account_seq) AS s
            FROM ledger_entries GROUP BY tenant_id, account_id, currency) j
     WHERE j.tenant_id = b.tenant_id AND j.account_id = b.account_id
       AND j.currency = b.currency
       AND (b.input, b.output, b.last_seq) IS DISTINCT FROM (j.d, j.c, j.s);" >/dev/null
}

sweep() {   # $1 = isolation level
  $PSQL -c "BEGIN ISOLATION LEVEL $1 READ ONLY;" \
        -c "SELECT '$1' AS isolation, 'summary says' AS step, breaks
              FROM reconciliation WHERE check_name = 'balance_cache';" \
        -c "SELECT pg_sleep(4);" \
        -c "SELECT '$1' AS isolation, 'list contains' AS step, count(*) AS breaks
              FROM recon_balance_breaks;" \
        -c "COMMIT;" | grep -v "^ *$\|pg_sleep\|^-\|^(" || true
}

for level in "READ COMMITTED" "REPEATABLE READ"; do
  echo "=== $level"
  forge >/dev/null
  repair_after_2s &
  sweep "$level"
  wait
done

echo "=== final state"
$PSQL -c "SELECT * FROM reconciliation ORDER BY check_name;"
