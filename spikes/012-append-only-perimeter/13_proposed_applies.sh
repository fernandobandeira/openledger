#!/usr/bin/env bash
# 13 -- the proposed baseline edits, applied to a clean database, then attacked.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
export PGPASSWORD=openledger
P="psql -h localhost -p 5433 -U openledger -d spike_wsa"
"$D/reset.sh" >/dev/null
$P -q -v ON_ERROR_STOP=1 -f "$D/PROPOSED_baseline.sql" && echo "proposed edits applied clean"
echo "--- the four channels, as the database owner ---"
$P -c "ALTER TABLE ledger_entries ALTER COLUMN account_seq TYPE bigint USING (account_seq*10);" \
   -c "CREATE TABLE shadow_entries () INHERITS (ledger_entries);" \
   -c "DROP TABLE ledger_entries CASCADE;" \
   -c "UPDATE ledger_accounts SET owner_type='house', owner_id=NULL WHERE id='11111111-1111-1111-1111-111111111111';" 2>&1
echo "--- ...and an owned account, which the seed does not have: open one and try ---"
$P -q -c "INSERT INTO ledger_accounts (tenant_id,id,owner_type,owner_id,purpose,category,normal_balance,currency) VALUES ('t1','55555555-5555-5555-5555-555555555555','company','acme','customer_wallet','liability','credit','USD');" \
      -c "INSERT INTO ledger_account_balances (tenant_id,account_id,currency,input,output,last_seq,owner_type,owner_id_key) VALUES ('t1','55555555-5555-5555-5555-555555555555','USD',50000,0,1,'company','acme');"
$P -c "UPDATE ledger_accounts SET owner_type='house', owner_id=NULL WHERE id='55555555-5555-5555-5555-555555555555';" 2>&1
echo "--- the reports are unchanged by any of it ---"
$P -c "SELECT count(*) AS entries FROM ledger_entries;" -c "SELECT tenant_id,currency,fs_line,amount_minor FROM income_statement WHERE amount_minor<>0;"
echo "--- census after ---"
$P -c "SELECT tgisinternal, tgenabled, count(*) FROM pg_trigger GROUP BY 1,2 ORDER BY 1,2;" \
   -c "SELECT evtname, evtevent, evtenabled FROM pg_event_trigger ORDER BY 1;"
