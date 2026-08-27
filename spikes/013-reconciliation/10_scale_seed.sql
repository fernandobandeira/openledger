-- The cost of a sweep, at a size worth measuring.
--
-- Every view here is a full scan of ledger_entries: there is no way to reconcile a
-- cache against a journal without reading the journal. So the number that matters
-- is not the absolute one -- localhost is not a benchmark -- but whether it is
-- linear and where it sits relative to the project's own figures: ADR-0006's
-- effective-axis aggregate at roughly 0.10 us per entry and 105.91 ms for a
-- 1M-entry account, and spike 009's per-account recompute at 57.5 ms (1M entries,
-- one account) and 248.9 ms for the status-aware form.
--
-- Run with: psql -v txns=50000 -f 10_scale_seed.sql
-- One tenant, 1,000 wallets and one house cash account -- so the house account
-- carries every transaction, which is the hot-account shape spike 003 measures.

\set ON_ERROR_STOP on

INSERT INTO ledger_accounts (tenant_id, id, owner_type, owner_id, purpose,
                             category, normal_balance, currency)
SELECT 'bulk',
       ('00000000-0000-7000-8000-' || lpad(to_hex(g), 12, '0'))::uuid,
       'company', 'cust-' || g, 'customer_wallet', 'liability', 'credit', 'USD'
FROM generate_series(1, 1000) g;

INSERT INTO ledger_accounts (tenant_id, id, owner_type, owner_id, purpose,
                             category, normal_balance, currency)
VALUES ('bulk','00000000-0000-7000-8000-ffffffffffff','house',NULL,'fbo_cash',
        'asset','debit','USD');

INSERT INTO ledger_transactions (tenant_id, id, kind, status, effective_at)
SELECT 'bulk',
       ('00000000-0001-7000-8000-' || lpad(to_hex(g), 12, '0'))::uuid,
       'deposit',
       -- one transaction in a thousand is left pending, so the status-aware half
       -- of every view has something to do
       CASE WHEN g % 1000 = 0 THEN 'pending' ELSE 'posted' END::ledger_txn_status,
       timestamptz '2026-01-01' + (g % 180) * interval '1 day'
FROM generate_series(1, :txns) g;

-- the house leg: account_seq is the transaction number, gapless by construction
INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, account_seq, effective_at)
SELECT 'bulk',
       ('00000000-0001-7000-8000-' || lpad(to_hex(g), 12, '0'))::uuid,
       '00000000-0000-7000-8000-ffffffffffff',
       'debit', 100 + (g % 977), 'USD', g,
       timestamptz '2026-01-01' + (g % 180) * interval '1 day'
FROM generate_series(1, :txns) g;

-- the wallet leg: 1..N within each of the thousand wallets
INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, account_seq, effective_at)
SELECT 'bulk',
       ('00000000-0001-7000-8000-' || lpad(to_hex(g), 12, '0'))::uuid,
       ('00000000-0000-7000-8000-' || lpad(to_hex(1 + (g % 1000)), 12, '0'))::uuid,
       'credit', 100 + (g % 977), 'USD',
       ((g - 1) / 1000) + 1,
       timestamptz '2026-01-01' + (g % 180) * interval '1 day'
FROM generate_series(1, :txns) g;

-- ...and the cache, built from the journal exactly as the writer would have left it
INSERT INTO ledger_account_balances (tenant_id, account_id, currency, input, output, last_seq)
SELECT e.tenant_id, e.account_id, e.currency,
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'), 0),
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'), 0),
       MAX(e.account_seq)
FROM ledger_entries e WHERE e.tenant_id = 'bulk'
GROUP BY e.tenant_id, e.account_id, e.currency;

ANALYZE;
SELECT count(*) AS entries, pg_size_pretty(pg_total_relation_size('ledger_entries')) AS journal_size
FROM ledger_entries;
