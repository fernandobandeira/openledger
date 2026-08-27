#!/usr/bin/env bash
# Spike 018 -- verify every BUCKET A schema fix on a live database.
#
# Method: build a clean golden book on the FIXED schema (fix_verify). For each
# money-wrong fix, reproduce the finding by cloning the golden DB and removing JUST
# that one fix (drop the constraint / install the pre-fix function), show the hole
# is open, then show the fixed schema refuses or catches it. The pre-fix "merged
# baseline" was uncommitted working-tree state overwritten by the fix pass, so the
# clone-and-isolate method stands in for a second pre-fix database -- it is stricter,
# since it changes exactly one object at a time.
#
# Requires: PostgreSQL 18 on localhost:5433, role openledger/openledger.
set -uo pipefail
export PGPASSWORD=openledger
H="-h localhost -p 5433 -U openledger"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="$ROOT/migrations/00001_baseline.sql"
CHART="$ROOT/schema/chart.sql"
GOLDEN="$ROOT/spikes/018-adversary-fixes/10-golden-book.sql"
PREFIX_BS="$ROOT/spikes/018-adversary-fixes/12-prefix-balance-sheet.sql"
BACKDATE="$ROOT/spikes/018-adversary-fixes/13-backdate-into-closed-period.sql"

build() {  # build <db> [with_golden]
  psql $H -d postgres -c "DROP DATABASE IF EXISTS $1;" >/dev/null 2>&1
  psql $H -d postgres -c "CREATE DATABASE $1 TEMPLATE template0;" >/dev/null 2>&1
  psql $H -q -v ON_ERROR_STOP=1 -d "$1" -f "$BASE"  >/dev/null 2>&1
  psql $H -q -v ON_ERROR_STOP=1 -d "$1" -f "$CHART" >/dev/null 2>&1
  [ "${2:-}" = golden ] && psql $H -q -v ON_ERROR_STOP=1 -d "$1" -f "$GOLDEN" >/dev/null 2>&1
}
clone() { psql $H -d postgres -c "DROP DATABASE IF EXISTS $2;" >/dev/null 2>&1; psql $H -d postgres -c "CREATE DATABASE $2 TEMPLATE $1;" >/dev/null 2>&1; }
q() { psql $H -d "$1" -tA -c "$2" 2>&1; }
run() { psql $H -d "$1" -c "$2" 2>&1; }

echo "############################################################"
echo "# GOLDEN PASS on the fixed schema"
echo "############################################################"
build fix_verify golden
echo "reconciliation (all breaks must be 0):"
run fix_verify "SELECT check_name,breaks FROM reconciliation ORDER BY 1;"
echo; echo "balance sheet:"; run fix_verify "SELECT fs_line,amount_minor,side FROM balance_sheet_at('t1','2026-03-01 00:00-05',report_cursor()) WHERE amount_minor<>0 ORDER BY side,fs_line;"

echo; echo "############ A1: column-level INSERT grant refuses a forged xact_id ############"
echo "PRE-FIX (table-wide grant restored) forged xact_id inserts:"
clone fix_verify repro
run repro "GRANT INSERT ON ledger_entries TO openledger_app; SET ROLE openledger_app; SET app.tenant_id='t1';
 INSERT INTO ledger_entries(tenant_id,id,transaction_id,account_id,direction,amount_minor,currency,stripe,account_seq,effective_at,xact_id)
 VALUES('t1',gen_random_uuid(),'b1111111-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','debit',1,'USD',0,9,'2026-02-10','1'); RESET ROLE;" | grep -iE "INSERT 0 1|ERROR"
echo "FIXED forged xact_id refused:"
run fix_verify "SET ROLE openledger_app; SET app.tenant_id='t1';
 INSERT INTO ledger_entries(tenant_id,id,transaction_id,account_id,direction,amount_minor,currency,stripe,account_seq,effective_at,xact_id)
 VALUES('t1',gen_random_uuid(),'b1111111-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','debit',1,'USD',0,9,'2026-02-10','1'); RESET ROLE;" | grep -iE "ERROR"

echo; echo "############ A2: identity freeze (fk_balances__account_purpose) ############"
echo "PRE-FIX (freeze FK dropped) reclassification succeeds:"
clone fix_verify repro
run repro "ALTER TABLE ledger_account_balances DROP CONSTRAINT fk_balances__account_purpose;
 UPDATE ledger_accounts SET purpose='interchange_revenue' WHERE id='22222222-2222-2222-2222-222222222222';" | grep -iE "UPDATE 1|ERROR"
echo "FIXED reclassification refused:"
run fix_verify "UPDATE ledger_accounts SET purpose='interchange_revenue' WHERE id='22222222-2222-2222-2222-222222222222';" | grep -iE "ERROR"

echo; echo "############ A3/A6: plug + accounting-equation catch a backdated-into-closed-period entry ############"
clone fix_verify repro
psql $H -q -d repro -c "DROP FUNCTION balance_sheet_at(text,timestamptz,xid8,integer);" >/dev/null 2>&1
psql $H -q -v ON_ERROR_STOP=1 -d repro -f "$PREFIX_BS" >/dev/null 2>&1
psql $H -q -v ON_ERROR_STOP=1 -d repro -f "$BACKDATE" >/dev/null 2>&1
echo "PRE-FIX plug: backdated fee drops from equity; recon_equation_breaks gap ="
q repro "SELECT gap_minor FROM recon_equation_breaks(report_cursor(),'infinity');"
psql $H -q -v ON_ERROR_STOP=1 -d fix_verify -f "$BACKDATE" >/dev/null 2>&1
echo "FIXED plug: backdated fee held as un-closed earnings; recon_equation_breaks rows ="
q fix_verify "SELECT count(*) FROM recon_equation_breaks(report_cursor(),'infinity');"
build fix_verify golden   # restore clean

echo; echo "############ A4: close typing (fk_closes__txn_kind) + recon_close_breaks ############"
echo "FIXED: a close naming a non-close txn is refused:"
run fix_verify "INSERT INTO ledger_periods(tenant_id,code,starts_at,ends_at,tz) VALUES('t1','2026-07','2026-07-01 00:00-04','2026-08-01 00:00-04','America/New_York');
 INSERT INTO ledger_events(tenant_id,id,kind,source,idempotency_key,idempotency_hash,payload,effective_at) VALUES('t1','a1111111-0000-0000-0000-0000000000d1','fee','internal','k-d1','\x00','{}','2026-07-10');
 INSERT INTO ledger_transactions(tenant_id,id,event_id,kind,status,effective_at) VALUES('t1','b1111111-0000-0000-0000-0000000000d1','a1111111-0000-0000-0000-0000000000d1','fee','posted','2026-07-10');
 INSERT INTO ledger_period_closes(tenant_id,period_code,currency,starts_at,ends_at,transaction_id,txn_effective_at,computed_at_xid)
  VALUES('t1','2026-07','USD','2026-07-01 00:00-04','2026-08-01 00:00-04','b1111111-0000-0000-0000-0000000000d1','2026-07-10',report_cursor());" | grep -iE "ERROR"
build fix_verify golden

echo; echo "############ A5: a resolved hold leaves the pending population ############"
psql $H -q -v ON_ERROR_STOP=1 -d fix_verify -c "
 INSERT INTO ledger_events(tenant_id,id,kind,source,idempotency_key,idempotency_hash,payload,effective_at) VALUES('t1','a1111111-0000-0000-0000-000000000201','hold','internal','k-h','\x00','{}','2026-02-20'),('t1','a1111111-0000-0000-0000-000000000202','settle','internal','k-s','\x00','{}','2026-02-21');
 INSERT INTO ledger_transactions(tenant_id,id,event_id,kind,status,effective_at) VALUES('t1','b1111111-0000-0000-0000-000000000201','a1111111-0000-0000-0000-000000000201','hold','pending','2026-02-20');
 INSERT INTO ledger_entries(tenant_id,id,transaction_id,account_id,direction,amount_minor,currency,stripe,account_seq,effective_at) VALUES('t1','c0000000-0000-0000-0000-000000000201','b1111111-0000-0000-0000-000000000201','11111111-1111-1111-1111-111111111111','debit',900,'USD',0,3,'2026-02-20'),('t1','c0000000-0000-0000-0000-000000000202','b1111111-0000-0000-0000-000000000201','33333333-3333-3333-3333-333333333333','credit',900,'USD',0,2,'2026-02-20');" >/dev/null 2>&1
echo "pending on cash BEFORE resolution = $(q fix_verify "SELECT COALESCE(SUM(pending_debits-pending_credits),0) FROM recon_pending_bridge WHERE account_id='11111111-1111-1111-1111-111111111111';")"
psql $H -q -d fix_verify -c "INSERT INTO ledger_transactions(tenant_id,id,event_id,kind,status,effective_at,resolves_id) VALUES('t1','b1111111-0000-0000-0000-000000000202','a1111111-0000-0000-0000-000000000202','settle','posted','2026-02-21','b1111111-0000-0000-0000-000000000201');" >/dev/null 2>&1
echo "pending on cash AFTER resolution  = $(q fix_verify "SELECT COALESCE(SUM(pending_debits-pending_credits),0) FROM recon_pending_bridge WHERE account_id='11111111-1111-1111-1111-111111111111';") (superseded bucket = $(q fix_verify "SELECT superseded_debits FROM recon_journal_to_reports WHERE currency='USD';"))"
build fix_verify golden

echo; echo "############ A8: forged xact_id caught by recon_cursor_breaks ############"
echo "clean recon_cursor_breaks = $(q fix_verify "SELECT count(*) FROM recon_cursor_breaks;")"
psql $H -q -d fix_verify -c "INSERT INTO ledger_entries(tenant_id,id,transaction_id,account_id,direction,amount_minor,currency,stripe,account_seq,effective_at,xact_id) VALUES('t1','c0000000-0000-0000-0000-0000000000ff','b1111111-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','debit',1,'USD',0,9,'2026-02-10','1');" >/dev/null 2>&1
echo "after owner forges xact_id='1': recon_cursor_breaks = $(q fix_verify "SELECT count(*)||' '||max(reason) FROM recon_cursor_breaks;")"
build fix_verify golden

echo; echo "############ A13/A14: statement functions RAISE on unknown / unpresented version ############"
echo "A13 unknown version: $(run fix_verify "SELECT count(*) FROM balance_sheet_at('t1','2026-03-01 00:00-05',report_cursor(),999);" | grep -iE 'ERROR')"

echo; echo "############ A15: back-filling a superseded chart version is refused ############"
run fix_verify "INSERT INTO fs_lines(chart_version,code,caption,statement,side,sort_order) VALUES(1,'sneaky','X','balance_sheet','asset',999);" | grep -iE "ERROR"

echo; echo "############ A16/A17/A19: attestation tz, finite effective_at, non-empty tenant ############"
echo "A16 unknown zone: $(run fix_verify "INSERT INTO perimeter_attestations(tenant_id,account_id,currency,as_of,tz,source,external_balance_minor) VALUES('t1','11111111-1111-1111-1111-111111111111','USD','2026-03-31','Mars/Phobos','bank',1);" | grep -iE 'ERROR')"
echo "A17 infinity:     $(run fix_verify "INSERT INTO ledger_transactions(tenant_id,id,event_id,kind,status,effective_at) VALUES('t1',gen_random_uuid(),'a1111111-0000-0000-0000-000000000001','fee','posted','infinity');" | grep -iE 'ERROR')"
echo "A19 blank tenant: $(run fix_verify "INSERT INTO ledger_accounts(tenant_id,id,owner_type,owner_id,purpose,category,normal_balance,counterparty_scope,currency) VALUES(' ',gen_random_uuid(),'house',NULL,'operating_cash','asset','debit','shared','USD');" | grep -iE 'ERROR')"

echo; echo "############ SURVIVALS (attacks the design defeated must still hold) ############"
echo "cross-tenant entry:  $(run fix_verify "INSERT INTO ledger_entries(tenant_id,id,transaction_id,account_id,direction,amount_minor,currency,stripe,account_seq,effective_at) VALUES('t2',gen_random_uuid(),'b1111111-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','debit',1,'USD',0,9,'2026-02-10');" | grep -ioE 'fk_entries__txn')"
echo "currency mismatch:   $(run fix_verify "INSERT INTO ledger_entries(tenant_id,id,transaction_id,account_id,direction,amount_minor,currency,stripe,account_seq,effective_at) VALUES('t1',gen_random_uuid(),'b1111111-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','debit',1,'EUR',0,9,'2026-02-10');" | grep -ioE 'fk_entries__account')"
echo "app UPDATE journal:  $(run fix_verify "SET ROLE openledger_app; UPDATE ledger_entries SET amount_minor=1 WHERE id='c0000000-0000-0000-0000-000000000001'; RESET ROLE;" | grep -ioE 'permission denied')"
echo "owner UPDATE journal:$(run fix_verify "UPDATE ledger_entries SET amount_minor=2 WHERE id='c0000000-0000-0000-0000-000000000001';" | grep -ioE 'append-only')"
echo "TRUNCATE journal:    $(run fix_verify "TRUNCATE ledger_entries;" | grep -ioE 'cannot be truncated')"
echo "per_shard in house:  $(run fix_verify "INSERT INTO ledger_accounts(tenant_id,id,owner_type,owner_id,purpose,category,normal_balance,counterparty_scope,currency) VALUES('t1',gen_random_uuid(),'house',NULL,'customer_wallet','liability','credit','per_shard','USD');" | grep -ioE 'per_shard_is_owned')"
echo "RLS unscoped rows:   $(run fix_verify "SET ROLE openledger_read; RESET app.tenant_id; SELECT count(*) FROM ledger_entries; RESET ROLE;" | grep -oE "^ +[0-9]+ *$" | tr -d " ")"
echo
echo "DONE."
