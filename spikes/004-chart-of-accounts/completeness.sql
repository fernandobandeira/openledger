-- The invariant the accounting equation does NOT give you.
--
-- A = L + E + (R - X) proves the LEDGER is internally consistent. It cannot detect
-- a REPORT that enumerated only some of the accounts -- omitting a shard removes it
-- from both sides, so the equation still balances while revenue is understated.
-- Demonstrated: 3 tenants x 10.00 interchange, a mapping missing one tenant reports
-- 20.00, equation says BALANCED.
--
-- Removing `uq_accounts__house` (one interchange_revenue per DEPLOYMENT) removes a
-- machine-checked completeness guarantee. This replaces it with a stronger one.

BEGIN;

-- Every account type must map to exactly one financial-statement line. This is the
-- controlled artifact an auditor asks for -- not a query someone wrote.
CREATE TABLE fs_lines (
    code    text PRIMARY KEY,
    caption text NOT NULL,
    statement text NOT NULL CHECK (statement IN ('balance_sheet','income_statement'))
);

ALTER TABLE account_types
    ADD COLUMN fs_line text REFERENCES fs_lines(code);

INSERT INTO fs_lines (code, caption, statement) VALUES
  ('receivables',    'Accounts receivable',            'balance_sheet'),
  ('cash',           'Cash and cash equivalents',      'balance_sheet'),
  ('other_assets',   'Other assets',                   'balance_sheet'),
  ('payables',       'Accounts payable and accrued',   'balance_sheet'),
  ('borrowings',     'Borrowings',                     'balance_sheet'),
  ('customer_funds', 'Customer funds payable',         'balance_sheet'),
  ('equity',         'Shareholders equity',            'balance_sheet'),
  ('revenue',        'Revenue',                        'income_statement'),
  ('cost_of_revenue','Cost of revenue',                'income_statement'),
  ('interest',       'Interest expense',               'income_statement');

UPDATE account_types SET fs_line = CASE code
  WHEN 'customer_receivable'         THEN 'receivables'
  WHEN 'operating_cash'              THEN 'cash'
  WHEN 'fbo_cash'                    THEN 'cash'
  WHEN 'ach_pull_unsettled'          THEN 'other_assets'
  WHEN 'allowance_for_credit_losses' THEN 'receivables'
  WHEN 'customer_wallet'             THEN 'customer_funds'
  WHEN 'network_settlement_payable'  THEN 'payables'
  WHEN 'facility_borrowings'         THEN 'borrowings'
  WHEN 'accrued_interest_payable'    THEN 'payables'
  WHEN 'platform_rev_share_payable'  THEN 'payables'
  WHEN 'paid_in_capital'             THEN 'equity'
  WHEN 'interchange_revenue'         THEN 'revenue'
  WHEN 'fee_revenue'                 THEN 'revenue'
  WHEN 'interest_expense'            THEN 'interest'
  WHEN 'platform_rev_share_expense'  THEN 'cost_of_revenue'
  WHEN 'credit_loss_expense'         THEN 'cost_of_revenue'
END;

-- No account type may exist without a statement line. This is what makes omission
-- structurally impossible rather than merely unlikely.
ALTER TABLE account_types ALTER COLUMN fs_line SET NOT NULL;

-- network_settlement_payable IS a perimeter account: the card network holds the
-- authoritative balance and will confirm it. Marking it false was wrong.
UPDATE account_types SET is_perimeter = true WHERE code = 'network_settlement_payable';

-- Can a shard set be summed for reporting? Only if all shards face ONE counterparty.
-- IAS 1.32 / ASC 210-20-45-1: netting requires amounts due to and from the SAME party.
-- If the shard key IS the counterparty, opposite-sign shards must be shown GROSS.
ALTER TABLE account_types ADD COLUMN counterparty_scope text NOT NULL DEFAULT 'none'
    CHECK (counterparty_scope IN ('none','shared','per_shard'));
UPDATE account_types SET counterparty_scope = 'shared'
    WHERE code IN ('network_settlement_payable','facility_borrowings','operating_cash','fbo_cash');
UPDATE account_types SET counterparty_scope = 'per_shard'
    WHERE code IN ('customer_receivable','customer_wallet','platform_rev_share_payable');

-- THE REPORT. It enumerates from the chart outward, so there is no parameter in
-- which to pass an incomplete list of accounts.
CREATE OR REPLACE VIEW financial_statements AS
SELECT f.statement, f.code AS fs_line, f.caption, t.code AS account_type,
       COUNT(DISTINCT a.id)          AS instances,
       COALESCE(SUM(CASE WHEN t.normal_balance='debit'
            THEN CASE WHEN e.direction='debit'  THEN e.amount_minor ELSE -e.amount_minor END
            ELSE CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END
       END),0) AS balance_minor
FROM fs_lines f
JOIN account_types t   ON t.fs_line = f.code       -- every type, by construction
LEFT JOIN ledger_accounts a ON a.purpose = t.code  -- EVERY instance of it
LEFT JOIN ledger_entries e  ON e.account_id = a.id
GROUP BY f.statement, f.code, f.caption, t.code;

-- The loud exception: any account instance not reachable from the chart.
-- Must always return zero rows.
CREATE OR REPLACE VIEW unmapped_accounts AS
SELECT a.id, a.tenant_id, a.purpose
FROM ledger_accounts a
LEFT JOIN account_types t ON t.code = a.purpose
LEFT JOIN fs_lines f      ON f.code = t.fs_line
WHERE t.code IS NULL OR f.code IS NULL;

COMMIT;
