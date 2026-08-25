-- Spike 004 — the chart of accounts as DATA, and the math as a THEOREM.
--
-- The problem: purposes like 'platform_rev_share_payable', 'fee_revenue',
-- 'facility_borrowings' are business-specific. A card program funded by a warehouse
-- line has them; a marketplace wallet does not; a neobank has different ones again.
-- A general ledger cannot ship a fixed chart.
--
-- What it CAN ship is the capability: declare your own account types, and the engine
-- guarantees the math. This file is the mechanism.

BEGIN;

-- ---------------------------------------------------------------- the chart
-- A deployment declares its own account types. The card reference implementation
-- ships one as seed data; a marketplace would ship a different one.
CREATE TABLE account_types (
    code           text PRIMARY KEY,
    category       ledger_category       NOT NULL,
    normal_balance ledger_normal_balance NOT NULL,
    description    text NOT NULL,
    -- 'perimeter' accounts mirror an external balance 1:1 and must reconcile
    -- against it. This is a PROPERTY of the type, not of each account.
    is_perimeter   boolean NOT NULL DEFAULT false
);

-- THE structural fix. `purpose` was free text, so nothing stopped
-- 'interchange_revenue' being created as category 'asset' with a debit normal
-- balance -- which silently breaks every statement that rolls up from category.
ALTER TABLE ledger_accounts
    ADD CONSTRAINT fk_accounts__type FOREIGN KEY (purpose) REFERENCES account_types(code);

-- category and normal_balance now belong to the TYPE, not the account. Keeping
-- them on the account too would let the two disagree.
CREATE OR REPLACE FUNCTION assert_account_matches_type() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE t account_types;
BEGIN
    SELECT * INTO t FROM account_types WHERE code = NEW.purpose;
    IF NEW.category <> t.category OR NEW.normal_balance <> t.normal_balance THEN
        RAISE EXCEPTION
          'account %/% declares %/% but type % is %/%',
          NEW.owner_id, NEW.purpose, NEW.category, NEW.normal_balance,
          t.code, t.category, t.normal_balance;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER ck_accounts__matches_type
    BEFORE INSERT OR UPDATE ON ledger_accounts
    FOR EACH ROW EXECUTE FUNCTION assert_account_matches_type();

-- ------------------------------------------------------- the reference chart
-- This is SEED DATA for the card product, not part of the engine.
INSERT INTO account_types (code, category, normal_balance, description, is_perimeter) VALUES
  ('customer_receivable',        'asset',    'debit',  'what a customer owes us',                 false),
  ('operating_cash',             'asset',    'debit',  'our own bank balance',                    true),
  ('fbo_cash',                   'asset',    'debit',  'customer funds held for benefit of',      true),
  ('ach_pull_unsettled',         'asset',    'debit',  'collected, still inside the return window', false),
  -- the contra account: category asset, but a CREDIT normal balance. This is the
  -- case that proves normal_balance cannot be derived from category.
  ('allowance_for_credit_losses','asset',    'credit', 'expected losses, contra to receivable',   false),
  ('customer_wallet',            'liability','credit', 'customer funds we owe back',              false),
  ('network_settlement_payable', 'liability','credit', 'owed to the card network',                false),
  ('facility_borrowings',        'liability','credit', 'drawn on the warehouse line',             false),
  ('accrued_interest_payable',   'liability','credit', 'interest accrued, not yet paid',          false),
  ('platform_rev_share_payable', 'liability','credit', 'owed to the platform partner',            false),
  ('paid_in_capital',            'equity',   'credit', 'equity funding',                          false),
  ('interchange_revenue',        'revenue',  'credit', 'interchange we keep',                     false),
  ('fee_revenue',                'revenue',  'credit', 'fees charged to customers',               false),
  ('interest_expense',           'expense',  'debit',  'interest on the facility',                false),
  ('platform_rev_share_expense', 'expense',  'debit',  'interchange shared with the platform',    false),
  ('credit_loss_expense',        'expense',  'debit',  'realised and provisioned losses',         false);

COMMIT;
