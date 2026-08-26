-- Reference chart of accounts for the card product. SEED DATA, not engine:
-- a marketplace or wallet deployment ships a different one against the same core.
INSERT INTO fs_lines (code, caption, statement, side, sort_order) VALUES
  ('cash','Cash and cash equivalents','balance_sheet','asset',100),
  -- Customer funds held FBO are RESTRICTED and must not share a caption with the
  -- operator's own liquidity: Reg S-X 5-02.1 requires separate disclosure, and
  -- ASC 230-10-45-4 (as amended by ASU 2016-18) requires restricted cash to be
  -- identified. Mapped to 'cash', unrestricted liquidity was overstated by the
  -- entire float -- the number a lender and a covenant both read.
  ('restricted_cash','Restricted cash','balance_sheet','asset',150),
  ('receivables','Accounts receivable','balance_sheet','asset',200),
  ('other_assets','Other assets','balance_sheet','asset',300),
  ('payables','Accounts payable and accrued','balance_sheet','liability_equity',400),
  ('customer_funds','Customer funds payable','balance_sheet','liability_equity',500),
  ('borrowings','Borrowings','balance_sheet','liability_equity',600),
  ('equity','Shareholders equity','balance_sheet','liability_equity',700),
  -- Where a close would put prior periods' earnings. Nothing writes to it: there
  -- is no closing process yet, so un-closed earnings appear as the derived
  -- `current_year_earnings` line in the balance_sheet view instead.
  ('retained_earnings','Retained earnings','balance_sheet','liability_equity',800),
  ('revenue','Revenue','income_statement','credit',100),
  ('cost_of_revenue','Cost of revenue','income_statement','debit',200),
  -- For a lender, provision for credit losses is its own caption on the face of
  -- the income statement, not a component of cost of revenue. Buried there, credit
  -- performance is invisible.
  ('credit_losses','Provision for credit losses','income_statement','debit',250),
  ('interest','Interest expense','income_statement','debit',300)
ON CONFLICT DO NOTHING;

INSERT INTO account_types (code,category,normal_balance,description,fs_line,is_perimeter,counterparty_scope) VALUES
  ('customer_receivable','asset','debit','what a customer owes us','receivables',false,'per_shard'),
  -- NOTE, as for counterparty_scope below: `is_perimeter` is DECLARATIVE. No view,
  -- function or test reads it, so a wrong value here is undetectable by anything --
  -- mutation testing flips it and nothing fails. It asserts "this account mirrors
  -- exactly one external balance and must reconcile against it", and nothing
  -- reconciles. There is no CHECK either, and a CHECK could not help: the column
  -- is a claim about the world, not about the row.
  ('operating_cash','asset','debit','our own bank balance','cash',true,'shared'),
  ('fbo_cash','asset','debit','customer funds held for benefit of','restricted_cash',true,'shared'),
  -- the case that proves normal_balance cannot be derived from category
  ('allowance_for_credit_losses','asset','credit','expected losses, contra to receivable','receivables',false,'none'),
  ('due_from_treasury','asset','debit','tenant-side claim on operator treasury','other_assets',false,'shared'),
  ('customer_wallet','liability','credit','customer funds we owe back','customer_funds',false,'per_shard'),
  -- THE CLEARING ACCOUNT. glossary.md defines one as "a designed staging account
  -- money passes THROUGH on its way somewhere, expected to return to zero", and
  -- until now the chart had none -- 19 types and nowhere to stage a movement. The
  -- cost of that gap was visible: docs/diagrams/03-state-machines.svg drew an
  -- outbound transfer as DR fbo_cash / CR fbo_cash, a posting that moves no money,
  -- because there was no account to pass it through. A wallet withdrawal is
  -- DR customer_wallet / CR here on submit, DR here / CR fbo_cash on settle, and
  -- DR here / CR customer_wallet on return -- so the liability to the customer is
  -- continuous and the cash leaves exactly once. LIABILITY, not asset: until the
  -- money lands we still owe it.
  ('outbound_transfer_in_transit','liability','credit','left the wallet, has not settled','payables',false,'per_shard'),
  ('network_settlement_payable','liability','credit','owed to the card network','payables',true,'shared'),
  ('facility_borrowings','liability','credit','drawn on the warehouse line','borrowings',true,'shared'),
  ('accrued_interest_payable','liability','credit','interest accrued, not paid','payables',false,'shared'),
  ('platform_rev_share_payable','liability','credit','owed to the platform partner','payables',false,'per_shard'),
  -- ACH-collected cash that can still come back R01. The docs always described this
  -- as "a matching liability"; it was typed asset/debit, which would have presented a
  -- NEGATIVE ASSET for the length of the return window. Found by the golden trace.
  ('ach_pull_returnable','liability','credit','collected by ACH, still inside the return window','payables',false,'per_shard'),
  -- per_shard, NOT shared. The operator holds ONE due_to_tenants account per
  -- scope, so opposite-sign positions against DIFFERENT tenants collapse into one
  -- number: owing t1 425.00 while t2 owes 425.00 printed a payables line of ZERO.
  -- IAS 32.42 and ASC 210-20-45-1 permit offset only between the SAME two parties
  -- with an enforceable right of setoff; t1 and t2 are not the same party.
  -- NOTE: this field is currently declarative -- no view or function reads it, and
  -- uq_accounts__house (tenant_id, purpose, currency) makes a per-counterparty
  -- split impossible. Recorded as open in ADR-0007.
  ('due_to_tenants','liability','credit','operator-side obligation to tenant scopes','payables',false,'per_shard'),
  ('paid_in_capital','equity','credit','equity funding','equity',false,'none'),
  -- prior periods' accumulated earnings. Unused until a close exists.
  ('retained_earnings','equity','credit','accumulated earnings of prior periods','retained_earnings',false,'none'),
  ('interchange_revenue','revenue','credit','interchange we keep','revenue',false,'none'),
  ('fee_revenue','revenue','credit','fees charged to customers','revenue',false,'none'),
  ('interest_expense','expense','debit','interest on the facility','interest',false,'none'),
  ('platform_rev_share_expense','expense','debit','interchange shared with the platform','cost_of_revenue',false,'none'),
  ('credit_loss_expense','expense','debit','realised and provisioned losses','credit_losses',false,'none')
ON CONFLICT DO NOTHING;
