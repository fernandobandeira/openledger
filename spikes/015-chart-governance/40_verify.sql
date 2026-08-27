-- 40 -- every reproduction from 10_repro_baseline.sql, re-run under the DDL of
-- 20/21/22/30. Refused, or caught.
--
-- Each probe that must be REFUSED runs in its own transaction, because a refusal
-- aborts one; the ROLLBACKs are not undoing damage, they are ending the probe.

\set ON_ERROR_STOP 0

\echo ''
\echo '### V1 -- reclassify a statement line in place. Refused, unconditionally --'
\echo '### not "while posted entries exist", which would need a subquery in a'
\echo '### trigger, the exact shape ADR-0004 deleted nineteen of.'
BEGIN;
UPDATE chart_presentation SET fs_line='cash' WHERE chart_version=1 AND type_code='fbo_cash';
ROLLBACK;
\echo '### ...and so is rewriting the line itself, or deleting the mapping:'
BEGIN;
UPDATE fs_lines SET caption='Cash and cash equivalents' WHERE chart_version=1 AND code='restricted_cash';
ROLLBACK;
BEGIN;
DELETE FROM chart_presentation WHERE chart_version=1 AND type_code='fbo_cash';
ROLLBACK;
\echo '### ...and re-seeding an EDITED chart at the same version raises on the key,'
\echo '### where schema/chart.sql''s ON CONFLICT DO UPDATE applied it silently:'
BEGIN;
INSERT INTO chart_presentation (chart_version,type_code,category,counterparty_scope,fs_line)
VALUES (1,'fbo_cash','asset','shared','cash');
ROLLBACK;

\echo ''
\echo '### V2 -- the balance-sheet side is no longer two-valued.'
SELECT statement, side, count(*) AS lines FROM fs_lines WHERE chart_version=1
GROUP BY statement, side ORDER BY statement, side;
\echo '### an equity type presented under a LIABILITY caption -- accepted by the'
\echo '### baseline (10_repro_baseline.sql R2, 1,000.00 of paid-in capital under'
\echo '### "Accounts payable and accrued"), refused now:'
BEGIN;
INSERT INTO account_types (code,category,normal_balance,description,is_perimeter,counterparty_scope)
VALUES ('probe_equity','equity','credit','probe',false,'none');
INSERT INTO chart_presentation (chart_version,type_code,category,counterparty_scope,fs_line)
VALUES (1,'probe_equity','equity','none','payables');
ROLLBACK;
\echo '### positive control -- the same type under an EQUITY caption is accepted:'
BEGIN;
INSERT INTO account_types (code,category,normal_balance,description,is_perimeter,counterparty_scope)
VALUES ('probe_equity','equity','credit','probe',false,'none');
INSERT INTO chart_presentation (chart_version,type_code,category,counterparty_scope,fs_line)
VALUES (1,'probe_equity','equity','none','equity');
SELECT type_code, fs_line, fs_statement, fs_side FROM chart_presentation WHERE type_code='probe_equity';
ROLLBACK;

\echo ''
\echo '### V2b -- and the contra line is held to the OPPOSITE side by the same key.'
BEGIN;
INSERT INTO account_types (code,category,normal_balance,description,is_perimeter,counterparty_scope)
VALUES ('probe_payable','liability','credit','probe',false,'per_shard');
\echo '### a liability type whose contra line is another LIABILITY caption:'
INSERT INTO chart_presentation (chart_version,type_code,category,counterparty_scope,fs_line,fs_line_contra)
VALUES (1,'probe_payable','liability','per_shard','payables','customer_funds');
ROLLBACK;
BEGIN;
INSERT INTO account_types (code,category,normal_balance,description,is_perimeter,counterparty_scope)
VALUES ('probe_payable','liability','credit','probe',false,'per_shard');
\echo '### ...and a per_shard type with NO contra line at all:'
INSERT INTO chart_presentation (chart_version,type_code,category,counterparty_scope,fs_line)
VALUES (1,'probe_payable','liability','per_shard','payables');
ROLLBACK;
BEGIN;
INSERT INTO account_types (code,category,normal_balance,description,is_perimeter,counterparty_scope)
VALUES ('probe_revenue','revenue','credit','probe',false,'per_shard');
\echo '### ...and per_shard on an income-statement type, which IAS 32.42 does not reach:'
INSERT INTO chart_presentation (chart_version,type_code,category,counterparty_scope,fs_line,fs_line_contra)
VALUES (1,'probe_revenue','revenue','per_shard','revenue','receivables');
ROLLBACK;

\echo ''
\echo '### V3 -- the counterparty netting, on the book that CAN express the grain (op2).'
\echo '### trial_balance holds the gross figures and always did:'
SELECT purpose, owner_id, debits/100 AS dr, credits/100 AS cr,
       balance_debit_positive/100 AS net_debit_positive
  FROM trial_balance WHERE tenant_id='op2' AND purpose='due_to_tenants' ORDER BY owner_id;
\echo '### ...and the balance sheet now prints them, on two lines, instead of one zero:'
SELECT fs_line, caption, side, amount_minor/100 AS usd FROM balance_sheet
 WHERE tenant_id='op2' ORDER BY sort_order;

\echo ''
\echo '### V3b -- reconciled against trial_balance, gross against gross.'
\echo '### The two sides of the per_shard position, assembled straight from the'
\echo '### trial balance without touching the chart, must equal the two lines the'
\echo '### balance sheet prints.'
SELECT t.purpose,
       sum(t.balance_debit_positive) FILTER (WHERE t.balance_debit_positive > 0)/100
           AS tb_debit_positions,
       -sum(t.balance_debit_positive) FILTER (WHERE t.balance_debit_positive < 0)/100
           AS tb_credit_positions
  FROM trial_balance t WHERE t.tenant_id='op2' AND t.purpose='due_to_tenants'
 GROUP BY t.purpose;
SELECT fs_line, side, amount_minor/100 AS bs_amount FROM balance_sheet
 WHERE tenant_id='op2' AND fs_line IN ('other_assets','payables') ORDER BY sort_order;

\echo ''
\echo '### V3c -- and the whole-statement identity, which is not 0 = 0:'
\echo '### assets - liabilities - equity over the chart equals the debit-positive'
\echo '### sum over the journal. A position dropped by the sign routing, or counted'
\echo '### twice, breaks this and nothing else notices.'
WITH s AS (SELECT DISTINCT tenant_id, currency FROM ledger_accounts)
SELECT s.tenant_id, s.currency,
  (SELECT COALESCE(sum(CASE WHEN b.side='asset' THEN b.amount_minor ELSE -b.amount_minor END),0)
     FROM balance_sheet b
    WHERE b.tenant_id=s.tenant_id AND b.currency=s.currency
      AND b.fs_line <> 'current_year_earnings')/100 AS from_balance_sheet,
  (SELECT COALESCE(sum(t.balance_debit_positive),0)
     FROM trial_balance t
    WHERE t.tenant_id=s.tenant_id AND t.currency=s.currency
      AND t.category IN ('asset','liability','equity'))/100 AS from_trial_balance
FROM s ORDER BY 1,2;

\echo ''
\echo '### V3d -- the statement still balances, now with L and E distinguishable:'
SELECT tenant_id, currency,
       sum(amount_minor) FILTER (WHERE side='asset')/100      AS assets,
       sum(amount_minor) FILTER (WHERE side='liability')/100   AS liabilities,
       sum(amount_minor) FILTER (WHERE side='equity')/100      AS equity,
       sum(amount_minor) FILTER (WHERE side='asset')
     = sum(amount_minor) FILTER (WHERE side IN ('liability','equity')) AS balanced
  FROM balance_sheet GROUP BY tenant_id, currency ORDER BY 1,2;

\echo ''
\echo '### V4 -- the shape no report can fix: a per_shard type in a house account,'
\echo '### where both counterparties'' positions were already netted at write time.'
\echo '### Going forward it is unrepresentable:'
BEGIN;
INSERT INTO ledger_accounts (tenant_id,id,owner_type,owner_id,purpose,category,normal_balance,counterparty_scope,currency)
VALUES ('op2','44444444-0000-0000-0000-0000000000ff','house',NULL,'due_to_tenants','liability','credit','per_shard','USD');
ROLLBACK;
\echo '### ...and the legacy row op already carries is what VALIDATE CONSTRAINT is for:'
ALTER TABLE ledger_accounts VALIDATE CONSTRAINT ck_accounts__per_shard_is_owned;
\echo '### op therefore still nets, and the lint says exactly why:'
SELECT fs_line, amount_minor/100 AS usd FROM balance_sheet
 WHERE tenant_id='op' AND fs_line IN ('payables','other_assets') ORDER BY sort_order;

\echo ''
\echo '### V5 -- counterparty_scope and is_perimeter have consumers now.'
SELECT count(*) AS views_reading_either FROM pg_views
 WHERE schemaname='public' AND definition ~ 'counterparty_scope|is_perimeter';
\echo '### A wrong counterparty_scope cannot be introduced under a live chart:'
BEGIN;
UPDATE account_types SET counterparty_scope='shared' WHERE code='due_to_tenants';
ROLLBACK;
\echo '### ...nor under live accounts, which is the copy the CHECK reads:'
BEGIN;
UPDATE ledger_accounts SET counterparty_scope='shared' WHERE purpose='due_to_tenants';
ROLLBACK;
\echo '### ...and the lint catches the shapes no key can see:'
SELECT rule, severity, subject, detail FROM chart_lint ORDER BY rule, subject;

\echo ''
\echo '### V6 -- is_perimeter, given a mechanism. Two bank statements, one wrong:'
INSERT INTO perimeter_attestations (tenant_id,account_id,currency,as_of,source,external_balance_minor)
VALUES ('op','11111111-0000-0000-0000-000000000001','USD','2026-01-04','acme_bank_stmt', 100000),
       ('op','11111111-0000-0000-0000-000000000001','USD','2026-01-05','acme_bank_stmt', 100000),
       ('op','11111111-0000-0000-0000-000000000002','USD','2026-01-04','trustee_stmt',    30000);
SELECT purpose, source, as_of, external_balance_minor/100 AS attested,
       ledger_balance_minor/100 AS ours, drift_minor/100 AS drift
  FROM perimeter_drift ORDER BY purpose, as_of;
SELECT rule, severity, subject, detail FROM chart_lint WHERE rule LIKE 'perimeter%' ORDER BY rule, subject;
\echo '### ...and an attestation against an account the chart says is NOT perimeter --'
\echo '### the direction that caught network_settlement_payable in spike 004, by reading:'
INSERT INTO perimeter_attestations (tenant_id,account_id,currency,as_of,source,external_balance_minor)
VALUES ('op','11111111-0000-0000-0000-000000000003','USD','2026-01-04','tenant_confirm', 0);
SELECT rule, severity, subject, detail FROM chart_lint WHERE rule='attested_but_not_perimeter';
\echo '### an attestation is evidence, so it is append-only too:'
BEGIN;
UPDATE perimeter_attestations SET external_balance_minor=0 WHERE source='acme_bank_stmt';
ROLLBACK;

\echo ''
\echo '### V7 -- regression. The side split is category-only on both halves, so'
\echo '### ADR-0007''s contra-revenue fix and the contra-ASSET case are untouched.'
BEGIN;
INSERT INTO account_types (code,category,normal_balance,description,is_perimeter,counterparty_scope)
VALUES ('probe_refunds','revenue','debit','contra-revenue: refunds and chargebacks',false,'none');
INSERT INTO chart_presentation (chart_version,type_code,category,counterparty_scope,fs_line)
VALUES (1,'probe_refunds','revenue','none','revenue');
\echo '### revenue category, DEBIT normal balance, and it still reports under Revenue:'
SELECT type_code, category, fs_statement, fs_side, fs_line
  FROM chart_presentation WHERE type_code='probe_refunds';
ROLLBACK;
\echo '### and the contra-ASSET already in the chart:'
SELECT p.type_code, p.category, t.normal_balance, p.fs_line, p.fs_side
  FROM chart_presentation p JOIN account_types t ON t.code=p.type_code
 WHERE p.chart_version=1 AND p.type_code='allowance_for_credit_losses';
\echo '### the income statement, which groups by fs_line and signs by the line''s side:'
SELECT chart_version, fs_line, caption, side, amount_minor/100 AS usd
  FROM income_statement WHERE tenant_id='op';
