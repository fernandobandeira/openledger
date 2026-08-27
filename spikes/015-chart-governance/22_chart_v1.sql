-- 22 -- THE RE-DECLARED CHART, as version 1. This is the proposed replacement for
-- schema/chart.sql, which is seed data and not engine.
--
-- Three things changed and nothing else:
--   1. Every balance-sheet line is re-declared onto the SPLIT side. Five lines
--      that said `liability_equity` now say `liability` or `equity`, and the pair
--      is no longer interchangeable.
--   2. fs_line moves out of account_types into chart_presentation, keyed by
--      version.
--   3. Every per_shard type declares fs_line_contra -- the line its opposite-sign
--      position presents under. Six types needed one; none had one, because the
--      column did not exist.
-- `ach_pull_returnable` is deliberately left on `payables` here, wrong, exactly as
-- the shipped chart has it. Version 1 is a faithful re-declaration of today's
-- chart. Correcting it is 50_ias1_41.sql, because a reclassification IS A NEW
-- VERSION and that is the whole point.
--
-- ON CONFLICT IS GONE. schema/chart.sql re-seeds with `ON CONFLICT (code) DO
-- UPDATE ... SET fs_line = excluded.fs_line`, and its comment defends that
-- against DO NOTHING on the grounds that "a re-seed that silently ignores an edit
-- is worse than one that fails". Both are true and both are wrong: DO NOTHING
-- ignores the edit, DO UPDATE APPLIES IT SILENTLY TO EVERY ISSUED STATEMENT. A
-- plain INSERT is the third option -- re-running this file unchanged raises on
-- the primary key, and re-running it EDITED raises too, which is the loud failure
-- the DO UPDATE comment wanted and could not get. An edited chart is a new
-- version, and the version number is in the file.

BEGIN;

INSERT INTO fs_lines (chart_version, code, caption, statement, side, sort_order) VALUES
  (1,'cash','Cash and cash equivalents','balance_sheet','asset',100),
  -- Reg S-X 5-02.1 requires separate disclosure and ASC 230-10-45-4 (as amended
  -- by ASU 2016-18) requires restricted cash to be identified.
  (1,'restricted_cash','Restricted cash','balance_sheet','asset',150),
  (1,'receivables','Accounts receivable','balance_sheet','asset',200),
  (1,'other_assets','Other assets','balance_sheet','asset',300),
  -- ---- the five lines that used to be one side ----
  (1,'payables','Accounts payable and accrued','balance_sheet','liability',400),
  (1,'customer_funds','Customer funds payable','balance_sheet','liability',500),
  (1,'borrowings','Borrowings','balance_sheet','liability',600),
  (1,'equity','Shareholders equity','balance_sheet','equity',700),
  (1,'retained_earnings','Retained earnings','balance_sheet','equity',800),
  -- ---- income statement, unchanged ----
  (1,'revenue','Revenue','income_statement','credit',100),
  (1,'cost_of_revenue','Cost of revenue','income_statement','debit',200),
  (1,'credit_losses','Provision for credit losses','income_statement','debit',250),
  (1,'interest','Interest expense','income_statement','debit',300);

-- type_code, category, counterparty_scope, fs_line, fs_line_contra
--
-- The contra column is the answer to "t2's opposite-sign position has no line to
-- move to". Read each per_shard row as: normally this, and when this counterparty
-- is on the other side of the position, that.
INSERT INTO chart_presentation (chart_version, type_code, category, counterparty_scope, fs_line, fs_line_contra) VALUES
  -- assets
  --   a customer whose card account is in CREDIT is owed money, and the credit
  --   may not be netted against other customers' debits -- it is presented as a
  --   liability. This is the textbook case the offsetting rule exists for.
  (1,'customer_receivable','asset','per_shard','receivables','customer_funds'),
  (1,'operating_cash','asset','shared','cash',NULL),
  (1,'fbo_cash','asset','shared','restricted_cash',NULL),
  --   contra-asset: asset category, CREDIT normal balance, reports under the line
  --   it is contra to. Unaffected by the side split, which is category-only.
  (1,'allowance_for_credit_losses','asset','none','receivables',NULL),
  (1,'due_from_treasury','asset','shared','other_assets',NULL),
  -- liabilities
  (1,'customer_wallet','liability','per_shard','customer_funds','receivables'),
  (1,'outbound_transfer_in_transit','liability','per_shard','customer_funds','receivables'),
  (1,'network_settlement_payable','liability','shared','payables',NULL),
  (1,'facility_borrowings','liability','shared','borrowings',NULL),
  (1,'accrued_interest_payable','liability','shared','payables',NULL),
  (1,'platform_rev_share_payable','liability','per_shard','payables','receivables'),
  --   WRONG, and left wrong on purpose. See 50_ias1_41.sql.
  (1,'ach_pull_returnable','liability','per_shard','payables','receivables'),
  --   the mirror of due_from_treasury, so its contra line is the one
  --   due_from_treasury already sits on.
  (1,'due_to_tenants','liability','per_shard','payables','other_assets'),
  -- equity -- and these are the two rows the side split protects
  (1,'paid_in_capital','equity','none','equity',NULL),
  (1,'retained_earnings','equity','none','retained_earnings',NULL),
  -- income statement
  (1,'interchange_revenue','revenue','none','revenue',NULL),
  (1,'fee_revenue','revenue','none','revenue',NULL),
  (1,'interest_expense','expense','none','interest',NULL),
  (1,'platform_rev_share_expense','expense','none','cost_of_revenue',NULL),
  (1,'credit_loss_expense','expense','none','credit_losses',NULL);

COMMIT;
