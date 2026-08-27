-- 04 -- The period close, posted as ordinary balanced transactions through the write
-- primitive, and what the balance sheet reads afterwards.
--
-- The register's number is the target: a three-year book whose synthesised earnings plug
-- sums ALL history -- 34,000.00 against a true current year of 4,000.00 -- while
-- `retained_earnings` ships in the chart and stays at zero forever.

\pset border 2
\set ON_ERROR_STOP on

-- ------------------------------------------------------- a three-year book
\o /dev/null
SELECT sp_post('t1','seed','2024-01-02 00:00+00','operating_cash','paid_in_capital', 10000000);
SELECT sp_post('t1','fee', '2024-06-15 00:00+00','operating_cash','fee_revenue',      2000000);
SELECT sp_post('t1','int', '2024-09-15 00:00+00','interest_expense','operating_cash',  500000);
SELECT sp_post('t1','fee', '2025-06-15 00:00+00','operating_cash','fee_revenue',      2500000);
SELECT sp_post('t1','int', '2025-09-15 00:00+00','interest_expense','operating_cash', 1000000);
SELECT sp_post('t1','fee', '2026-03-15 00:00+00','operating_cash','fee_revenue',       600000);
SELECT sp_post('t1','int', '2026-04-15 00:00+00','interest_expense','operating_cash',  200000);
\o

-- three calendar years, resolved ONCE from a local date in a named zone (see 07)
INSERT INTO ledger_periods (tenant_id, code, starts_at, ends_at, tz) VALUES
  ('t1','2024', timestamp '2024-01-01 00:00' AT TIME ZONE 'UTC', timestamp '2025-01-01 00:00' AT TIME ZONE 'UTC', 'UTC'),
  ('t1','2025', timestamp '2025-01-01 00:00' AT TIME ZONE 'UTC', timestamp '2026-01-01 00:00' AT TIME ZONE 'UTC', 'UTC'),
  ('t1','2026', timestamp '2026-01-01 00:00' AT TIME ZONE 'UTC', timestamp '2027-01-01 00:00' AT TIME ZONE 'UTC', 'UTC');

-- periods may not overlap, declaratively
DO $$ BEGIN
    INSERT INTO ledger_periods (tenant_id, code, starts_at, ends_at, tz)
    VALUES ('t1','2025-H2', '2025-07-01 00:00+00', '2026-01-01 00:00+00', 'UTC');
    RAISE EXCEPTION 'OVERLAP WAS ACCEPTED';
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'ex_periods__no_overlap refused an overlapping period, declaratively';
END $$;

\echo '== BEFORE ANY CLOSE: the baseline view, unparameterised =='
SELECT caption, to_char(amount_minor/100.0,'FM999,999,990.00') AS amount
FROM balance_sheet WHERE tenant_id='t1' AND amount_minor <> 0 ORDER BY sort_order;

-- The close itself lives in 01_book.sql beside the posting helper, because 05 uses it too.

\echo '== CLOSE 2024 and 2025. Ordinary postings, nothing mutated. =='
\o /dev/null
SELECT sp_close_period('t1','2024');
SELECT sp_close_period('t1','2025');
\o

\echo '== the closing transaction, as it sits in the journal =='
SELECT a.purpose, e.direction, to_char(e.amount_minor/100.0,'FM999,990.00') AS amount,
       to_char(e.effective_at,'YYYY-MM-DD HH24:MI:SS.US') AS effective_at
FROM ledger_entries e JOIN ledger_accounts a ON a.tenant_id=e.tenant_id AND a.id=e.account_id
WHERE e.transaction_id = (SELECT transaction_id FROM ledger_period_closes WHERE period_code='2025')
ORDER BY a.purpose, e.direction;

\echo '== BALANCE SHEET as at 2026-12-31, after the close =='
SELECT caption, to_char(amount_minor/100.0,'FM999,999,990.00') AS amount
FROM balance_sheet_at('t1','2026-12-31 23:59:59.999999+00', report_cursor())
WHERE amount_minor <> 0 ORDER BY sort_order;

\echo '== ...and the accounting equation still holds, per side =='
SELECT to_char(SUM(amount_minor) FILTER (WHERE side='asset')/100.0,'FM999,999,990.00') AS assets,
       to_char(SUM(amount_minor) FILTER (WHERE side='liability_equity')/100.0,'FM999,999,990.00') AS liab_and_equity,
       SUM(amount_minor) FILTER (WHERE side='asset') = SUM(amount_minor) FILTER (WHERE side='liability_equity') AS balanced
FROM balance_sheet_at('t1','2026-12-31 23:59:59.999999+00', report_cursor());

\echo '== INCOME STATEMENT, per period. Each period reports ITS OWN year. =='
SELECT p.code AS period,
       to_char(SUM(i.amount_minor) FILTER (WHERE i.side='credit')/100.0,'FM999,999,990.00')  AS revenue,
       to_char(SUM(i.amount_minor) FILTER (WHERE i.side='debit')/100.0,'FM999,999,990.00')   AS expense,
       to_char((SUM(i.amount_minor) FILTER (WHERE i.side='credit')
              - SUM(i.amount_minor) FILTER (WHERE i.side='debit'))/100.0,'FM999,999,990.00') AS net_income
FROM ledger_periods p,
     LATERAL income_statement_for('t1', p.starts_at, p.ends_at, report_cursor()) i
WHERE p.tenant_id='t1' GROUP BY p.code ORDER BY p.code;

\echo '== the POST-CLOSING TRIAL BALANCE: only permanent accounts carry a balance =='
SELECT purpose, category,
       to_char(balance_debit_positive/100.0,'FM999,999,990.00') AS balance_debit_positive
FROM trial_balance_at('t1','-infinity','2026-01-01 00:00+00', report_cursor())
ORDER BY category::text, purpose;
