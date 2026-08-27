-- 10 -- every hole re-reproduced against the CURRENT baseline, 2026-08-27,
-- PostgreSQL 18.6. Nothing here is fixed yet.

\echo ''
\echo '### R1 -- a statement line is reclassified under posted history'
\echo '### fbo_cash: restricted_cash -> cash, with 300.00 of customer float posted.'
SELECT fs_line, amount_minor/100 AS before_usd FROM balance_sheet
 WHERE tenant_id='op' AND fs_line IN ('cash','restricted_cash') ORDER BY fs_line;
UPDATE account_types SET fs_line='cash' WHERE code='fbo_cash';
SELECT fs_line, amount_minor/100 AS after_usd FROM balance_sheet
 WHERE tenant_id='op' AND fs_line IN ('cash','restricted_cash') ORDER BY fs_line;
UPDATE account_types SET fs_line='restricted_cash' WHERE code='fbo_cash';

\echo ''
\echo '### R2 -- 1,000.00 of paid-in capital presented under "Accounts payable and accrued"'
UPDATE account_types SET fs_line='payables' WHERE code='paid_in_capital';
SELECT fs_line, caption, side, amount_minor/100 AS usd FROM balance_sheet
 WHERE tenant_id='op' ORDER BY sort_order;
SELECT sum(amount_minor) FILTER (WHERE side='asset')/100            AS assets,
       sum(amount_minor) FILTER (WHERE side='liability_equity')/100 AS liab_and_equity,
       sum(amount_minor) FILTER (WHERE side='asset')
     = sum(amount_minor) FILTER (WHERE side='liability_equity')     AS balanced
  FROM balance_sheet WHERE tenant_id='op';
UPDATE account_types SET fs_line='equity' WHERE code='paid_in_capital';

\echo ''
\echo '### R3 -- what fk_types__fs_line DOES refuse: only ACROSS a statement or a side'
\set ON_ERROR_STOP 0
UPDATE account_types SET fs_line='revenue' WHERE code='paid_in_capital';   -- other statement
UPDATE account_types SET fs_line='cash'    WHERE code='paid_in_capital';   -- other side
\set ON_ERROR_STOP 1
\echo '(both refused; R1 and R2 above were not)'

\echo ''
\echo '### R4a -- the balance sheet nets counterparties the chart declares un-nettable'
\echo '### op owes t1 425.00 and t2 owes op 425.00, in ONE house due_to_tenants account.'
SELECT purpose, owner_id, debits/100 AS dr, credits/100 AS cr,
       balance_debit_positive/100 AS net
  FROM trial_balance WHERE tenant_id='op' AND purpose='due_to_tenants';
SELECT fs_line, caption, amount_minor/100 AS usd FROM balance_sheet
 WHERE tenant_id='op' AND fs_line IN ('payables','receivables','other_assets') ORDER BY sort_order;

\echo ''
\echo '### R4b -- splitting the account PER COUNTERPARTY does not fix it'
SELECT purpose, owner_id, balance_debit_positive/100 AS net
  FROM trial_balance WHERE tenant_id='op2' AND purpose='due_to_tenants' ORDER BY owner_id;
SELECT fs_line, caption, amount_minor/100 AS usd FROM balance_sheet
 WHERE tenant_id='op2' AND fs_line IN ('payables','receivables','other_assets') ORDER BY sort_order;

\echo ''
\echo '### R5 -- nothing reads counterparty_scope or is_perimeter'
SELECT count(*) AS views_reading_either FROM pg_views
 WHERE schemaname='public' AND definition ~ 'counterparty_scope|is_perimeter';
SELECT count(*) AS functions_reading_either FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.prokind='f'
   AND pg_get_functiondef(p.oid) ~ 'counterparty_scope|is_perimeter';
\echo '-- mutation: declare the netting account shared and the bank account per_shard.'
\echo '-- Both are false. Nothing anywhere changes.'
UPDATE account_types SET counterparty_scope='shared'    WHERE code='due_to_tenants';
UPDATE account_types SET counterparty_scope='per_shard' WHERE code='operating_cash';
UPDATE account_types SET is_perimeter = NOT is_perimeter;
SELECT fs_line, amount_minor/100 AS usd FROM balance_sheet
 WHERE tenant_id='op' AND fs_line='payables';
UPDATE account_types SET counterparty_scope='per_shard' WHERE code='due_to_tenants';
UPDATE account_types SET counterparty_scope='shared'    WHERE code='operating_cash';
UPDATE account_types SET is_perimeter = NOT is_perimeter;

\echo ''
\echo '### R6 -- what the `payables` line actually hosts'
SELECT t.code, t.category, t.counterparty_scope, t.is_perimeter
  FROM account_types t WHERE t.fs_line='payables' ORDER BY t.code;
