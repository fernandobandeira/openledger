-- F6, stage 1 -- the two books the reproduction posts into, opened as the
-- APPLICATION role and not as the owner.
--
-- Nothing here is a forgery: `GRANT SELECT, INSERT ON ledger_accounts TO
-- openledger_app` is table-wide and rls_accounts__writer is `WITH CHECK (true)`,
-- so opening an account -- including a striped one -- is a shipped app-role
-- privilege. SET ROLE proves that rather than asserting it.
--
-- WHY REVENUE AND EXPENSE TYPES. The amounts below are at the bigint ceiling,
-- and balance_sheet_at casts each fs_line total back to bigint
-- (`COALESCE(SUM(...), 0)::bigint`). A ceiling-sized position on any BALANCE
-- SHEET line would make the accounting_equation check raise for a reason that
-- has nothing to do with F6. Revenue and expense reach the balance sheet only
-- through the un-closed-earnings plug, which is `revenue - expense`; posting
-- the same amount to one of each leaves the plug at zero and every balance
-- sheet line flat, so the other nine checks stay green and the three aggregates
-- under test are the only thing being observed.
--
-- WHY A NEW TENANT. t1's accounts already carry balances, and the house
-- uniqueness index uq_accounts__house is (tenant_id, purpose, currency), so a
-- second house fee_revenue account has to live in a book of its own. t3 and t4
-- leave the negative-control book untouched.

SET ROLE openledger_app;
\echo
\echo '########## opening the books as openledger_app'
SELECT current_user;

INSERT INTO ledger_accounts (tenant_id, id, owner_type, owner_id, purpose, category,
                             normal_balance, counterparty_scope, currency, stripe_count)
VALUES
  -- t3: four unstriped accounts. Two debit destinations and two credit sources,
  -- because the writer's own `coalesce` refuses two ceiling-sized legs on ONE
  -- account with `checked_add` (crates/ledger/src/postings.rs) -- so a
  -- transaction whose DEBIT SUM passes the ceiling needs two debit accounts.
  ('t3','00000000-0000-4000-8000-0000000000a1','house',NULL,
   'platform_rev_share_expense','expense','debit','none','USD',1),
  ('t3','00000000-0000-4000-8000-0000000000a2','house',NULL,
   'credit_loss_expense','expense','debit','none','USD',1),
  ('t3','00000000-0000-4000-8000-0000000000b1','house',NULL,
   'fee_revenue','revenue','credit','none','USD',1),
  ('t3','00000000-0000-4000-8000-0000000000b2','house',NULL,
   'interchange_revenue','revenue','credit','none','USD',1),
  -- t4: the striped pair. 64 stripes is the configuration ADR-0018 measured
  -- (2,687 clearings/s against an unstriped 623), so this is the shape a hot
  -- account is MEANT to have -- and it is the shape the finding says lets one
  -- account's per-stripe cache rows each stay legal while their cross-stripe sum
  -- does not.
  ('t4','00000000-0000-4000-8000-0000000000c1','house',NULL,
   'platform_rev_share_expense','expense','debit','none','USD',64),
  ('t4','00000000-0000-4000-8000-0000000000d1','house',NULL,
   'fee_revenue','revenue','credit','none','USD',64),
  -- t5: a second striped pair, used ONLY by the concurrency probe. It has a book
  -- of its own because whether two simultaneous posts ride one batched statement
  -- is not deterministic, so what they leave behind must not be able to move the
  -- numbers the three aggregates are read at.
  ('t5','00000000-0000-4000-8000-0000000000e1','house',NULL,
   'platform_rev_share_expense','expense','debit','none','USD',64),
  ('t5','00000000-0000-4000-8000-0000000000f1','house',NULL,
   'fee_revenue','revenue','credit','none','USD',64);

RESET ROLE;

\echo
\echo '########## the accounts that now exist'
SELECT tenant_id, id, purpose, category, stripe_count
FROM ledger_accounts WHERE tenant_id IN ('t3','t4','t5') ORDER BY tenant_id, id;

\echo
\echo '########## the control still holds: ten checks, zero breaks'
SELECT * FROM reconciliation;
