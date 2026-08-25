-- Reference chart of accounts for the card product. SEED DATA, not engine:
-- a marketplace or wallet deployment ships a different one against the same core.
INSERT INTO fs_lines (code, caption, statement) VALUES
  ('receivables','Accounts receivable','balance_sheet'),
  ('cash','Cash and cash equivalents','balance_sheet'),
  ('other_assets','Other assets','balance_sheet'),
  ('payables','Accounts payable and accrued','balance_sheet'),
  ('borrowings','Borrowings','balance_sheet'),
  ('customer_funds','Customer funds payable','balance_sheet'),
  ('equity','Shareholders equity','balance_sheet'),
  ('revenue','Revenue','income_statement'),
  ('cost_of_revenue','Cost of revenue','income_statement'),
  ('interest','Interest expense','income_statement')
ON CONFLICT DO NOTHING;

INSERT INTO account_types (code,category,normal_balance,description,fs_line,is_perimeter,counterparty_scope) VALUES
  ('customer_receivable','asset','debit','what a customer owes us','receivables',false,'per_shard'),
  ('operating_cash','asset','debit','our own bank balance','cash',true,'shared'),
  ('fbo_cash','asset','debit','customer funds held for benefit of','cash',true,'shared'),
  -- the case that proves normal_balance cannot be derived from category
  ('allowance_for_credit_losses','asset','credit','expected losses, contra to receivable','receivables',false,'none'),
  ('due_from_treasury','asset','debit','tenant-side claim on operator treasury','other_assets',false,'shared'),
  ('customer_wallet','liability','credit','customer funds we owe back','customer_funds',false,'per_shard'),
  ('network_settlement_payable','liability','credit','owed to the card network','payables',true,'shared'),
  ('facility_borrowings','liability','credit','drawn on the warehouse line','borrowings',true,'shared'),
  ('accrued_interest_payable','liability','credit','interest accrued, not paid','payables',false,'shared'),
  ('platform_rev_share_payable','liability','credit','owed to the platform partner','payables',false,'per_shard'),
  -- ACH-collected cash that can still come back R01. The docs always described this
  -- as "a matching liability"; it was typed asset/debit, which would have presented a
  -- NEGATIVE ASSET for the length of the return window. Found by the golden trace.
  ('ach_pull_returnable','liability','credit','collected by ACH, still inside the return window','payables',false,'per_shard'),
  ('due_to_tenants','liability','credit','operator-side obligation to tenant scopes','payables',false,'shared'),
  ('paid_in_capital','equity','credit','equity funding','equity',false,'none'),
  ('interchange_revenue','revenue','credit','interchange we keep','revenue',false,'none'),
  ('fee_revenue','revenue','credit','fees charged to customers','revenue',false,'none'),
  ('interest_expense','expense','debit','interest on the facility','interest',false,'none'),
  ('platform_rev_share_expense','expense','debit','interchange shared with the platform','cost_of_revenue',false,'none'),
  ('credit_loss_expense','expense','debit','realised and provisioned losses','cost_of_revenue',false,'none')
ON CONFLICT DO NOTHING;
