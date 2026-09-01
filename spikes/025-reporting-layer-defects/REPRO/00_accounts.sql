-- The account register of the book every reproduction below runs on.
--
-- Opened as the OWNER, the way the e2e fixture opens accounts
-- (crates/e2e/tests/e2e/support/book.rs::account) -- there is no account
-- endpoint, so this is the only door. NO PERIMETER TYPE is used on purpose:
-- chart_lint's `perimeter_unattested` is an ERROR and fires for every
-- perimeter account with posted entries until an attestation feed exists,
-- and the negative control needs all ten checks at zero.
--
-- The 'none'-scope types are house accounts and the per_shard types are
-- owner-keyed, so chart_lint rules 3, 4 and 5 stay quiet by construction.

\set ON_ERROR_STOP on

CREATE TEMP TABLE IF NOT EXISTS book (label text PRIMARY KEY, id uuid);

INSERT INTO ledger_accounts
       (tenant_id, owner_type, owner_id, purpose, category, normal_balance,
        counterparty_scope, currency)
VALUES ('t1','company','co_1','customer_receivable','asset','debit','per_shard','USD'),
       ('t1','company','co_1','customer_wallet','liability','credit','per_shard','USD'),
       ('t1','company','co_1','platform_rev_share_payable','liability','credit','per_shard','USD'),
       ('t1','company','co_1','outbound_transfer_in_transit','liability','credit','per_shard','USD'),
       ('t1','house',NULL,'fee_revenue','revenue','credit','none','USD'),
       ('t1','house',NULL,'platform_rev_share_expense','expense','debit','none','USD'),
       ('t1','house',NULL,'paid_in_capital','equity','credit','none','USD'),
       ('t1','house',NULL,'retained_earnings','equity','credit','none','USD'),
       ('t2','company','co_2','customer_receivable','asset','debit','per_shard','USD'),
       ('t2','house',NULL,'fee_revenue','revenue','credit','none','USD');

SELECT tenant_id, purpose, owner_id, id FROM ledger_accounts ORDER BY tenant_id, purpose;
