-- AN EXAMPLE CHART OF ACCOUNTS. SEED DATA, not engine.
--
-- This is the chart for the PARKED reference product -- the embedded B2B charge card
-- whose DDL lives in parked/card/ and is applied by no migration. See
-- site/content/parked-card.md. The product is parked; its chart is not, because it is the
-- only chart in the tree, so `make reset` hands a wallet or marketplace deployment a
-- card-issuer-and-lender chart it did not ask for: customer_receivable,
-- facility_borrowings, credit_loss_expense, allowance_for_credit_losses. That is not
-- a recommendation. Delete the lines you do not have and add the ones you do --
-- ADR-0007 ships the chart AS DATA precisely so that this file is yours to replace.
--
-- migrations/00001_baseline.sql creates fs_lines and account_types EMPTY and requires
-- no row in either. Nothing in this file is part of the schema.
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
-- DO UPDATE, not DO NOTHING. Re-running this file must leave the database matching it.
-- Under DO NOTHING it does not: editing a caption or an fs_line mapping and re-seeding
-- exits 0 and changes nothing. Verified -- 'Restricted cash' rewritten to 'Restricted
-- cash (segregated)', re-applied with --single-transaction, exit 0, old caption still
-- in the table. In a file whose longest comment exists because a wrong fs_line
-- overstated unrestricted liquidity by the entire customer float, a fix that looks
-- applied and is not is the wrong default. `code` is the primary key on both tables,
-- so the conflict target is exact and the SET list is every non-key column.
ON CONFLICT (code) DO UPDATE SET
  caption    = excluded.caption,
  statement  = excluded.statement,
  side       = excluded.side,
  sort_order = excluded.sort_order;

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
  -- until now the chart had none -- nineteen types and nowhere to stage a movement. The
  -- cost of that gap was visible: site/public/diagrams/03-state-machines.svg drew an
  -- outbound transfer as DR fbo_cash / CR fbo_cash, a posting that moves no money,
  -- because there was no account to pass it through. A wallet withdrawal is
  -- DR customer_wallet / CR here on submit, DR here / CR fbo_cash on settle, and
  -- DR here / CR customer_wallet on return -- so the liability to the customer is
  -- continuous and the cash leaves exactly once. LIABILITY, not asset: until the
  -- money lands we still owe it.
  -- fs_line is customer_funds, NOT payables. The money is still the customer's
  -- until it lands; presenting it under operator trade payables during the
  -- in-transit window understates "Customer funds payable" and overstates what the
  -- operator owes its own suppliers -- the mirror image of the harm the Reg S-X
  -- 5-02.1 note at the top of this file exists to prevent on the asset side.
  ('outbound_transfer_in_transit','liability','credit','left the wallet, has not settled','customer_funds',false,'per_shard'),
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
-- DO UPDATE, for the reason above: a re-seed that silently ignores an edit is worse
-- than one that fails. Note what this does NOT make easy -- changing a type's category
-- or normal_balance while accounts already reference it is REFUSED, because
-- fk_accounts__type points at (code, category, normal_balance). That refusal is the
-- point: it is loud, and it happens at seed time rather than in a report. Verified,
-- with live accounts on the type: `update or delete on table "account_types" violates
-- foreign key constraint "fk_accounts__type" on table "ledger_accounts"`.
ON CONFLICT (code) DO UPDATE SET
  category         = excluded.category,
  normal_balance   = excluded.normal_balance,
  description      = excluded.description,
  fs_line          = excluded.fs_line,
  is_perimeter     = excluded.is_perimeter,
  counterparty_scope = excluded.counterparty_scope;
