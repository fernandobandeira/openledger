#!/usr/bin/env bash
# Q8 · the error grammar for reads, and the one distinction the API may not have.
#
# Every case below is run and its SQLSTATE printed, because the read endpoints'
# declared responses (ADR-0014: "each endpoint documents only the errors it can
# actually return") have to be derived from what the functions DO, not from what
# would be tidy.
set -uo pipefail
cd "$(dirname "$0")"
DB="${DB:-postgres://openledger:openledger@localhost:5433/spike023?sslmode=disable}"

# psql prints the SQLSTATE with VERBOSITY verbose; -v ON_ERROR_STOP=0 so the
# script walks every case.
run() { echo "---- $1"; shift; psql "$DB" -v VERBOSITY=verbose -v ON_ERROR_STOP=0 -c "$1" 2>&1 \
        | grep -vE '^(Time|LINE|\s*\^)' | head -12; echo; }

echo "############ 1 · an unknown chart version RAISES (the only input that does)"
run "balance_sheet_at, chart version 999" \
    "SELECT count(*) FROM balance_sheet_at('t1','infinity', report_cursor(), 999)"
run "income_statement_for, chart version 999" \
    "SELECT count(*) FROM income_statement_for('t1','-infinity','infinity', report_cursor(), 999)"
run "trial_balance_at takes no chart version at all" \
    "SELECT count(*) FROM trial_balance_at('t1','-infinity','infinity', report_cursor())"

echo "############ 2 · a type with posted entries that the version does not present"
psql "$DB" -c "SELECT t.code AS unpresented_type_at_v3
               FROM account_types t
               WHERE NOT EXISTS (SELECT 1 FROM chart_presentation p
                                 WHERE p.chart_version = 3 AND p.type_code = t.code)
               ORDER BY 1" 2>&1 | head -12
run "…is refused rather than silently dropped (A14)" \
    "SELECT count(*) FROM balance_sheet_at('t1','infinity', report_cursor(), 1)"

echo "############ 3 · a malformed cursor"
run "cursor = 'not-a-cursor'" \
    "SELECT count(*) FROM balance_sheet_at('t1','infinity','not-a-cursor'::xid8, 3)"
run "cursor = -1" \
    "SELECT count(*) FROM balance_sheet_at('t1','infinity','-1'::xid8, 3)"
run "cursor = 0  (below every transaction id ever issued)" \
    "SELECT count(*) AS rows, sum(amount_minor) AS total
     FROM balance_sheet_at('t1','infinity','0'::xid8, 3)"
run "cursor = 18446744073709551615 (xid8 max — above every id)" \
    "SELECT count(*) AS rows, sum(amount_minor) AS total
     FROM balance_sheet_at('t1','infinity','18446744073709551615'::xid8, 3)"

echo "############ 4 · an absent cursor: NULL, and what it fabricates"
run "balance_sheet_at with a NULL cursor" \
    "SELECT count(*) AS rows,
            sum(CASE WHEN side='asset' THEN amount_minor ELSE 0 END) AS assets,
            sum(CASE WHEN side<>'asset' THEN amount_minor ELSE 0 END) AS liab_eq_earn,
            count(*) FILTER (WHERE pinned_cursor IS NULL) AS rows_with_null_pinned_cursor
     FROM balance_sheet_at('t1','infinity', NULL, 3)"
run "…and the accounting-equation check on that fabrication" \
    "SELECT count(*) AS equation_breaks FROM recon_equation_breaks(NULL,'infinity')"
run "a NULL as-of instant" \
    "SELECT count(*) AS rows, sum(amount_minor) AS total
     FROM balance_sheet_at('t1', NULL, report_cursor(), 3)"
run "a NULL effective range on the income statement" \
    "SELECT count(*) AS rows, sum(amount_minor) AS total
     FROM income_statement_for('t1', NULL, NULL, report_cursor(), 3)"

echo "############ 5 · an unknown tenant — silence, not a refusal"
run "a tenant that does not exist" \
    "SELECT count(*) AS bs_rows FROM balance_sheet_at('nope','infinity', report_cursor(), 3)"
run "…on the trial balance too" \
    "SELECT count(*) AS tb_rows FROM trial_balance_at('nope','-infinity','infinity', report_cursor())"
run "a tenant that exists but has been TYPO'd by one character" \
    "SELECT count(*) AS bs_rows FROM balance_sheet_at('t11','infinity', report_cursor(), 3)"

echo "############ 6 · the two shapes of an empty book"
psql "$DB" -qc "BEGIN;
  INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose, category,
                               normal_balance, counterparty_scope, currency)
  VALUES ('t_open','house',NULL,'fee_revenue','revenue','credit','none','USD');
  COMMIT;" 2>&1 | tail -1
run "a tenant with ACCOUNTS but no entries" \
    "SELECT count(*) AS bs_rows, sum(amount_minor) AS total
     FROM balance_sheet_at('t_open','infinity', report_cursor(), 3)"
run "a tenant with NO accounts at all" \
    "SELECT count(*) AS bs_rows FROM balance_sheet_at('t_none','infinity', report_cursor(), 3)"

echo "############ 7 · scoped out by RLS — the same silence as case 5 and 6b"
run "reader scoped to t1, asking for t2" \
    "BEGIN READ ONLY;
     SET LOCAL ROLE openledger_read;
     SELECT set_config('app.tenant_id','t1',true);
     SELECT 'balance_sheet_at(t2)' AS q, count(*) AS rows
     FROM balance_sheet_at('t2','infinity', report_cursor(), 3);
     COMMIT"
run "reader with NO scope at all, asking for its own tenant" \
    "BEGIN READ ONLY;
     SET LOCAL ROLE openledger_read;
     SELECT 'balance_sheet_at(t1), unscoped' AS q, count(*) AS rows
     FROM balance_sheet_at('t1','infinity', report_cursor(), 3);
     COMMIT"

echo "############ 8 · an unknown ACCOUNT, on the balance read a caller would want"
ACCT=$(psql "$DB" -tAqc "SELECT id FROM ledger_accounts WHERE tenant_id='t1' AND purpose='customer_receivable'")
run "a real account with activity (the SUM over its stripes)" \
    "SELECT count(*) AS stripe_rows, sum(input - output) AS balance_minor
     FROM ledger_account_balances
     WHERE tenant_id='t1' AND account_id='$ACCT' AND currency='USD'"
run "an account id that does not exist" \
    "SELECT count(*) AS stripe_rows, sum(input - output) AS balance_minor
     FROM ledger_account_balances
     WHERE tenant_id='t1' AND account_id='00000000-0000-0000-0000-000000000000' AND currency='USD'"
NEW=$(psql "$DB" -tAqc "INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose,
                        category, normal_balance, counterparty_scope, currency)
                        VALUES ('t1','house',NULL,'interchange_revenue','revenue','credit','none','USD')
                        RETURNING id")
run "an account that EXISTS but has never been written (no balance row yet)" \
    "SELECT count(*) AS stripe_rows, sum(input - output) AS balance_minor
     FROM ledger_account_balances
     WHERE tenant_id='t1' AND account_id='$NEW' AND currency='USD'"
run "…and the account row itself, which is the only thing that can tell them apart" \
    "SELECT count(*) AS account_exists FROM ledger_accounts
     WHERE tenant_id='t1' AND id='$NEW' AND currency='USD'"

echo "############ 9 · a currency the account does not hold"
run "an existing account, currency EUR" \
    "SELECT count(*) AS stripe_rows FROM ledger_account_balances
     WHERE tenant_id='t1' AND account_id='$ACCT' AND currency='EUR'"

echo "############ 10 · the seed cases: no chart at all"
psql "$DB" -qc "SELECT 'chart versions on this database: ' || count(*) FROM chart_versions" 2>&1 | head -3
echo "(the 'no chart version exists' RAISE at :1122 needs an unseeded database;"
echo " it is the same ERRCODE 23514 as case 1 and is not re-run here)"
