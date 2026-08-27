-- AN EXAMPLE CHART OF ACCOUNTS. SEED DATA, not engine.
--
-- This is the chart for the PARKED reference product -- the embedded B2B charge card
-- whose DDL lives in parked/card/ and is applied by no migration. See
-- site/content/card/parked.md. The product is parked; its chart is not, because it is the
-- only chart in the tree, so `make reset` hands a wallet or marketplace deployment a
-- card-issuer-and-lender chart it did not ask for: customer_receivable,
-- facility_borrowings, credit_loss_expense, allowance_for_credit_losses. That is not
-- a recommendation. Delete the lines you do not have and add the ones you do --
-- ADR-0007 ships the chart AS DATA precisely so that this file is yours to replace.
--
-- migrations/00001_baseline.sql creates the chart tables EMPTY and requires no row
-- in any of them. Nothing in this file is part of the schema.
--
-- THE SHAPE (ADR-0012): account_types carries IDENTITY -- category, normal
-- balance, counterparty scope, perimeter status, the mirror pairing -- and NO
-- statement line. Which line a type reports under is PRESENTATION, and it lives
-- in chart_presentation keyed by chart_version, append-only: A RECLASSIFICATION
-- IS A NEW CHART VERSION, NEVER AN EDIT. This file seeds two versions -- version 1
-- is the chart as first declared, and version 2 is a real reclassification, kept
-- as history rather than squashed, because the pair is the worked example of the
-- mechanism.
--
-- ON CONFLICT IS GONE, in both directions. The old seed's `DO UPDATE` re-applied
-- an edit silently to every issued statement; `DO NOTHING` ignored it silently.
-- A plain INSERT is the third option -- re-running this file unchanged raises on
-- the primary key, and re-running it EDITED raises too, which is the loud failure
-- the old comment wanted and could not get. An edited chart is a NEW VERSION, and
-- the version number is in the file.

-- EACH VERSION LOADS IN ITS OWN TRANSACTION (A18/ADR-0012). "Current" is
-- max(chart_versions.version), DERIVED -- so the instant a `chart_versions` row
-- commits it becomes the current chart, and in autocommit its fs_lines and
-- chart_presentation rows have not been written yet: a concurrent reader (and a
-- statement function) sees a version that is current and empty. Wrapping each
-- version's three inserts in one transaction closes that window -- the version and
-- the complete chart it names commit together or not at all. (The A15 trigger also
-- refuses back-filling a superseded version, so the two work as a pair.)

-- ---------------------------------------------------------------- identity
BEGIN;

INSERT INTO account_types (code,category,normal_balance,description,is_perimeter,counterparty_scope) VALUES
  ('customer_receivable','asset','debit','what a customer owes us',false,'per_shard'),
  -- is_perimeter asserts "mirrors exactly one external balance and must reconcile
  -- against it" -- and it now HAS a consumer: perimeter_attestations stores what
  -- the third party said, perimeter_drift compares, and chart_lint names every
  -- perimeter account that has never been attested (ADR-0012).
  ('operating_cash','asset','debit','our own bank balance',true,'shared'),
  ('fbo_cash','asset','debit','customer funds held for benefit of',true,'shared'),
  -- the case that proves normal_balance cannot be derived from category
  ('allowance_for_credit_losses','asset','credit','expected losses, contra to receivable',false,'none'),
  ('due_from_treasury','asset','debit','tenant-side claim on operator treasury',false,'shared'),
  ('customer_wallet','liability','credit','customer funds we owe back',false,'per_shard'),
  -- THE CLEARING ACCOUNT. glossary.md defines one as "a designed staging account
  -- money passes THROUGH on its way somewhere, expected to return to zero", and
  -- until now the chart had none -- nineteen types and nowhere to stage a movement.
  -- A wallet withdrawal is DR customer_wallet / CR here on submit, DR here /
  -- CR fbo_cash on settle, and DR here / CR customer_wallet on return -- so the
  -- liability to the customer is continuous and the cash leaves exactly once.
  -- LIABILITY, not asset: until the money lands we still owe it.
  ('outbound_transfer_in_transit','liability','credit','left the wallet, has not settled',false,'per_shard'),
  ('network_settlement_payable','liability','credit','owed to the card network',true,'shared'),
  ('facility_borrowings','liability','credit','drawn on the warehouse line',true,'shared'),
  ('accrued_interest_payable','liability','credit','interest accrued, not paid',false,'shared'),
  ('platform_rev_share_payable','liability','credit','owed to the platform partner',false,'per_shard'),
  -- ACH-collected cash that can still come back R01. The docs always described this
  -- as "a matching liability"; it was typed asset/debit, which would have presented a
  -- NEGATIVE ASSET for the length of the return window. Found by the golden trace.
  ('ach_pull_returnable','liability','credit','collected by ACH, still inside the return window',false,'per_shard'),
  -- per_shard, NOT shared. The operator holds due_to_tenants per counterparty --
  -- ck_accounts__per_shard_is_owned refuses a house account for it, because a
  -- house account is one row per scope and both sides of a
  -- 425.00-against-425.00 position land in it, netted at write time where no
  -- report can recover them. IAS 32.42 and ASC 210-20-45-1 permit offset only
  -- between the SAME two parties.
  ('due_to_tenants','liability','credit','operator-side obligation to tenant scopes',false,'per_shard'),
  ('paid_in_capital','equity','credit','equity funding',false,'none'),
  -- prior periods' accumulated earnings. The close routes to it (ADR-0011).
  ('retained_earnings','equity','credit','accumulated earnings of prior periods',false,'none'),
  ('interchange_revenue','revenue','credit','interchange we keep',false,'none'),
  ('fee_revenue','revenue','credit','fees charged to customers',false,'none'),
  ('interest_expense','expense','debit','interest on the facility',false,'none'),
  ('platform_rev_share_expense','expense','debit','interchange shared with the platform',false,'none'),
  ('credit_loss_expense','expense','debit','realised and provisioned losses',false,'none');

-- The cross-scope mirror pairing (ADR-0010): a tenant's due_from_treasury is the
-- same money as the operator's due_to_tenants, declared on the asset side of the
-- pair. recon_scope_breaks sums the two to zero per currency, deployment-wide.
UPDATE account_types SET mirror_type = 'due_to_tenants' WHERE code = 'due_from_treasury';

-- ---------------------------------------------------------------- version 1

INSERT INTO chart_versions (version, note) VALUES
  (1, 'Initial chart. Every balance-sheet line declared onto the split '
      'liability/equity side, and a contra line declared for every type whose '
      'split key is the counterparty.');

INSERT INTO fs_lines (chart_version, code, caption, statement, side, sort_order) VALUES
  (1,'cash','Cash and cash equivalents','balance_sheet','asset',100),
  -- Customer funds held FBO are RESTRICTED and must not share a caption with the
  -- operator's own liquidity: Reg S-X 5-02.1 requires separate disclosure, and
  -- ASC 230-10-45-4 (as amended by ASU 2016-18) requires restricted cash to be
  -- identified. Mapped to 'cash', unrestricted liquidity was overstated by the
  -- entire float -- the number a lender and a covenant both read.
  (1,'restricted_cash','Restricted cash','balance_sheet','asset',150),
  (1,'receivables','Accounts receivable','balance_sheet','asset',200),
  (1,'other_assets','Other assets','balance_sheet','asset',300),
  -- ---- the five lines that used to share one two-valued side ----
  (1,'payables','Accounts payable and accrued','balance_sheet','liability',400),
  (1,'customer_funds','Customer funds payable','balance_sheet','liability',500),
  (1,'borrowings','Borrowings','balance_sheet','liability',600),
  (1,'equity','Shareholders equity','balance_sheet','equity',700),
  -- Where the close puts prior periods' earnings (ADR-0011); un-closed earnings
  -- appear as the derived `current_year_earnings` line in the balance sheet.
  (1,'retained_earnings','Retained earnings','balance_sheet','equity',800),
  (1,'revenue','Revenue','income_statement','credit',100),
  (1,'cost_of_revenue','Cost of revenue','income_statement','debit',200),
  -- For a lender, provision for credit losses is its own caption on the face of
  -- the income statement, not a component of cost of revenue. Buried there, credit
  -- performance is invisible.
  (1,'credit_losses','Provision for credit losses','income_statement','debit',250),
  (1,'interest','Interest expense','income_statement','debit',300);

-- type_code, category, counterparty_scope, fs_line, fs_line_contra
--
-- The contra column is the answer to "the opposite-sign position has no line to
-- move to". Read each per_shard row as: normally this line, and when this
-- counterparty is on the other side of the position, that one.
INSERT INTO chart_presentation (chart_version, type_code, category, counterparty_scope, fs_line, fs_line_contra) VALUES
  -- assets
  --   a customer whose account is in CREDIT is owed money, and the credit may
  --   not be netted against other customers' debits -- it is presented as a
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
  --   WRONG, and corrected by version 2 below. Version 1 is a faithful
  --   declaration of the chart as first written; the correction is a
  --   reclassification, and a reclassification is a new version.
  (1,'ach_pull_returnable','liability','per_shard','payables','receivables'),
  --   the mirror of due_from_treasury, so its contra line is the one
  --   due_from_treasury already sits on.
  (1,'due_to_tenants','liability','per_shard','payables','other_assets'),
  -- equity -- the two rows the side split protects: under the old two-valued
  -- side, 1,000.00 of paid-in capital presented under "Accounts payable and
  -- accrued" with every check green.
  (1,'paid_in_capital','equity','none','equity',NULL),
  (1,'retained_earnings','equity','none','retained_earnings',NULL),
  -- income statement
  (1,'interchange_revenue','revenue','none','revenue',NULL),
  (1,'fee_revenue','revenue','none','revenue',NULL),
  (1,'interest_expense','expense','none','interest',NULL),
  (1,'platform_rev_share_expense','expense','none','cost_of_revenue',NULL),
  (1,'credit_loss_expense','expense','none','credit_losses',NULL);

COMMIT;

-- ---------------------------------------------------------------- version 2
BEGIN;
--
-- A real reclassification, done the only legitimate way. IAS 1.41 requires the
-- nature, the amount and the reason of a reclassification to be disclosed, with
-- comparatives moved; the reason is NOT NULL here, and the amounts are derivable
-- by presenting the same period under both versions and differencing.
--
-- A VERSION IS A COMPLETE CHART, not a diff -- otherwise "which line was this
-- presented under" means walking a chain of overrides, and no foreign key can
-- express that. The copy is mechanical, so the file only spells out what CHANGED.

INSERT INTO chart_versions (version, note) VALUES
  (2, 'Reclassify ach_pull_returnable from `payables` to `customer_funds`. '
      'ACH-collected customer cash inside the R01 return window is customer '
      'money, not a trade payable; presenting it under "Accounts payable and '
      'accrued" understates customer funds payable and overstates what the '
      'operator owes its suppliers. Mirror of the outbound_transfer_in_transit '
      'correction already in the chart.');

INSERT INTO fs_lines (chart_version, code, caption, statement, side, sort_order)
SELECT 2, code, caption, statement, side, sort_order FROM fs_lines WHERE chart_version = 1;

INSERT INTO chart_presentation (chart_version, type_code, category, counterparty_scope, fs_line, fs_line_contra)
SELECT 2, type_code, category, counterparty_scope,
       CASE WHEN type_code = 'ach_pull_returnable' THEN 'customer_funds' ELSE fs_line END,
       fs_line_contra
FROM chart_presentation WHERE chart_version = 1;

COMMIT;

-- ---------------------------------------------------------------- version 3
BEGIN;
--
-- A third reclassification, and the worked example of A10 (ADR-0012, amended).
-- The schema now ALLOWS fs_line_contra on any balance-sheet type -- required for
-- per_shard, optional for shared -- and balance_sheet_at routes on POSITION SIGN,
-- not per_shard-only. Versions 1 and 2 declared a contra line only on the
-- per_shard types, so three SHARED balance-sheet types that can swing to the
-- opposite side still net gross-for-gross against another type on the same line:
--
--   * network_settlement_payable (shared liability, 'payables') and
--     accrued_interest_payable (shared liability, 'payables') -- a 425.00 debit
--     position in one and a 425.00 credit in the other net to 0 on `payables`,
--     hiding a real receivable and a real payable behind a single zero line.
--   * due_from_treasury (shared asset, 'other_assets') -- when it swings to a
--     credit (the tenant owes the treasury) it belongs on the liability side, but
--     with no contra line it drove `other_assets` NEGATIVE on the face, and it is
--     also where the per_shard due_to_tenants contra already lands.
--
-- Declaring a contra line for each makes a swung position present GROSS on the
-- opposite side instead of netting. Nothing else in the chart changes; the three
-- overrides are the whole diff. (Sign-swing is orthogonal to sharding, so this is
-- a presentation reclassification, not a re-typing -- account_types is untouched.)

INSERT INTO chart_versions (version, note) VALUES
  (3, 'Declare a contra line on the swing-capable shared balance-sheet types '
      '(network_settlement_payable, accrued_interest_payable -> other_assets; '
      'due_from_treasury -> payables). A shared payable that swings into a '
      'receivable position, or a shared receivable that swings into a payable, '
      'must present gross on the opposite side rather than netting against another '
      'type on its normal line (A10, IAS 32.42 / ASC 210-20-45-1 -- offset only '
      'between the same two parties).');

INSERT INTO fs_lines (chart_version, code, caption, statement, side, sort_order)
SELECT 3, code, caption, statement, side, sort_order FROM fs_lines WHERE chart_version = 2;

INSERT INTO chart_presentation (chart_version, type_code, category, counterparty_scope, fs_line, fs_line_contra)
SELECT 3, type_code, category, counterparty_scope, fs_line,
       CASE type_code
         WHEN 'network_settlement_payable' THEN 'other_assets'
         WHEN 'accrued_interest_payable'   THEN 'other_assets'
         WHEN 'due_from_treasury'          THEN 'payables'
         ELSE fs_line_contra
       END
FROM chart_presentation WHERE chart_version = 2;

COMMIT;
