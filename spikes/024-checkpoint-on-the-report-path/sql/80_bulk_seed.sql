-- Spike 024 -- a book big enough for the PLANNER to prefer an index, seeded in
-- bulk. This exists ONLY to answer Q1.3 (does the tenant-wide statement have an
-- index for its tails), and every measurement taken on it is a PLAN from plain
-- EXPLAIN -- no ANALYZE, no timing. The queries below are never executed.
--
-- Bulk, with session_replication_role=replica to skip the foreign-key triggers,
-- exactly as spike 020's seed did. The append-only and event triggers are
-- ENABLE ALWAYS and still fire. The book is built consistently -- balance rows
-- with the right sums and last_seq -- so `SELECT * FROM reconciliation` is still
-- the gate.
\set ON_ERROR_STOP on
SET session_replication_role = replica;

-- 200 owned receivables + 4 house accounts, 12 monthly periods, ~180,000 entries.
INSERT INTO ledger_accounts (tenant_id, id, owner_type, owner_id, purpose, category,
                             normal_balance, counterparty_scope, currency)
SELECT 'big', md5('big:recv:' || g)::uuid, 'company', 'co_' || g,
       'customer_receivable', 'asset', 'debit', 'per_shard', 'USD'
FROM generate_series(1, 200) g;
SELECT spike_account('big','fee',NULL,'fee_revenue','revenue','credit','none','USD'),
       spike_account('big','pic',NULL,'paid_in_capital','equity','credit','none','USD'),
       spike_retained_earnings('big','USD');

INSERT INTO ledger_periods (tenant_id, code, starts_at, ends_at, tz)
SELECT 'big', to_char(make_date(2026, m, 1), 'YYYY-MM'),
       make_timestamptz(2026, m, 1, 0, 0, 0, 'UTC'),
       CASE WHEN m = 12 THEN make_timestamptz(2027, 1, 1, 0, 0, 0, 'UTC')
            ELSE make_timestamptz(2026, m + 1, 1, 0, 0, 0, 'UTC') END,
       'UTC'
FROM generate_series(1, 12) m;

-- 75 postings per account per year: DR receivable / CR fee_revenue.
CREATE TEMP TABLE seed AS
SELECT md5('big:recv:' || g)::uuid AS acct,
       md5('big:fee:USD')::uuid    AS fee,
       (100 + (n % 900))::bigint   AS amt,
       n,
       make_timestamptz(2026, 1 + (n % 12), 1 + (n % 27), 12, 0, 0, 'UTC') AS eff
FROM generate_series(1, 200) g, generate_series(1, 75) n;

INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                           idempotency_hash, payload, effective_at)
SELECT 'big', md5('big:ev:' || s.acct::text || ':' || s.n)::uuid, 'posting', 'internal',
       'big-' || s.acct::text || '-' || s.n, '\x00'::bytea, '{}'::jsonb, s.eff
FROM seed s;
INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
SELECT 'big', md5('big:tx:' || s.acct::text || ':' || s.n)::uuid,
       md5('big:ev:' || s.acct::text || ':' || s.n)::uuid, 'posting', 'posted', s.eff
FROM seed s;

-- the balance cache, one row per account, summing what the entries will say
INSERT INTO ledger_account_balances (tenant_id, account_id, currency, stripe, input, output,
                                     last_seq, owner_type, owner_id_key, purpose, category,
                                     normal_balance)
SELECT 'big', s.acct, 'USD', 0, SUM(s.amt), 0, COUNT(*),
       'company'::account_owner_type, 'co_x', 'customer_receivable',
       'asset'::ledger_category, 'debit'::ledger_normal_balance
FROM seed s GROUP BY s.acct
UNION ALL
SELECT 'big', md5('big:fee:USD')::uuid, 'USD', 0, 0, SUM(s.amt), COUNT(*),
       'house'::account_owner_type, '', 'fee_revenue',
       'revenue'::ledger_category, 'credit'::ledger_normal_balance
FROM seed s;
-- owner_id_key must match the account row for fk_balances__account_owner
UPDATE ledger_account_balances b SET owner_id_key = a.owner_id_key
FROM ledger_accounts a
WHERE a.tenant_id = 'big' AND a.id = b.account_id AND a.currency = b.currency
  AND b.tenant_id = 'big';

INSERT INTO ledger_entries (tenant_id, id, transaction_id, account_id, direction,
                            amount_minor, currency, stripe, account_seq, effective_at)
SELECT 'big', md5('big:e1:' || s.acct::text || ':' || s.n)::uuid,
       md5('big:tx:' || s.acct::text || ':' || s.n)::uuid,
       s.acct, 'debit'::ledger_direction, s.amt, 'USD', 0,
       row_number() OVER (PARTITION BY s.acct ORDER BY s.n), s.eff
FROM seed s
UNION ALL
SELECT 'big', md5('big:e2:' || s.acct::text || ':' || s.n)::uuid,
       md5('big:tx:' || s.acct::text || ':' || s.n)::uuid,
       s.fee, 'credit'::ledger_direction, s.amt, 'USD', 0,
       row_number() OVER (ORDER BY s.acct, s.n), s.eff
FROM seed s;

RESET session_replication_role;
ANALYZE;
