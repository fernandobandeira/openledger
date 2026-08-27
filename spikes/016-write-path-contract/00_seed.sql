-- 00_seed.sql -- a two-tenant book on the shipped baseline, for spike 014.
--
-- Loads on top of `migrations/00001_baseline.sql` + `schema/chart.sql`, nothing
-- else. Every other file in this directory assumes this one has been run.
--
--   psql -d spike_wse -f migrations/00001_baseline.sql
--   psql -d spike_wse -f schema/chart.sql
--   psql -d spike_wse -f spikes/016-write-path-contract/00_seed.sql

\set ON_ERROR_STOP on

-- Fixed uuids so every later file can name an account without a lookup.
INSERT INTO ledger_accounts (tenant_id, id, owner_type, owner_id, purpose, category, normal_balance, currency) VALUES
  -- tenant t1: the two house accounts every clearing touches, plus one customer
  ('t1','11111111-0000-0000-0000-000000000001','house',   NULL,  'network_settlement_payable','liability','credit','USD'),
  ('t1','11111111-0000-0000-0000-000000000002','house',   NULL,  'interchange_revenue',       'revenue',  'credit','USD'),
  ('t1','11111111-0000-0000-0000-000000000003','company', 'c-1', 'customer_receivable',       'asset',    'debit', 'USD'),
  ('t1','11111111-0000-0000-0000-000000000004','company', 'c-2', 'customer_receivable',       'asset',    'debit', 'USD'),
  -- tenant t2: the same shape, so the RLS file has something to be refused
  ('t2','22222222-0000-0000-0000-000000000001','house',   NULL,  'network_settlement_payable','liability','credit','USD'),
  ('t2','22222222-0000-0000-0000-000000000002','house',   NULL,  'interchange_revenue',       'revenue',  'credit','USD'),
  ('t2','22222222-0000-0000-0000-000000000003','company', 'c-9', 'customer_receivable',       'asset',    'debit', 'USD');

-- The balance rows the write path upserts into. Created empty so the ON CONFLICT
-- path is the one under test rather than the insert path.
INSERT INTO ledger_account_balances (tenant_id, account_id, currency)
SELECT tenant_id, id, currency FROM ledger_accounts;

SELECT tenant_id, purpose, owner_id, id FROM ledger_accounts ORDER BY tenant_id, purpose, owner_id NULLS FIRST;

-- One posted transaction per tenant, so the read-side files have something to be
-- scoped away from. Written the long way -- event, transaction, two balanced legs
-- -- because there is no writer.
INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key, idempotency_hash, payload, effective_at) VALUES
  ('t1','eeeeeeee-0000-0000-0000-000000000001','opening','internal','seed-t1', sha256('{"seed":1}'), '{"seed":1}', '2026-08-01T00:00:00Z'),
  ('t2','eeeeeeee-0000-0000-0000-000000000002','opening','internal','seed-t2', sha256('{"seed":2}'), '{"seed":2}', '2026-08-01T00:00:00Z');

INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at) VALUES
  ('t1','dddddddd-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','opening','posted','2026-08-01T00:00:00Z'),
  ('t2','dddddddd-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000002','opening','posted','2026-08-01T00:00:00Z');

INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction, amount_minor, currency, account_seq, effective_at) VALUES
  ('t1','dddddddd-0000-0000-0000-000000000001','11111111-0000-0000-0000-000000000003','debit', 1000,'USD',1,'2026-08-01T00:00:00Z'),
  ('t1','dddddddd-0000-0000-0000-000000000001','11111111-0000-0000-0000-000000000001','credit',1000,'USD',1,'2026-08-01T00:00:00Z'),
  ('t2','dddddddd-0000-0000-0000-000000000002','22222222-0000-0000-0000-000000000003','debit', 2000,'USD',1,'2026-08-01T00:00:00Z'),
  ('t2','dddddddd-0000-0000-0000-000000000002','22222222-0000-0000-0000-000000000001','credit',2000,'USD',1,'2026-08-01T00:00:00Z');

UPDATE ledger_account_balances b SET input = x.inp, output = x.outp, last_seq = 1
FROM (SELECT tenant_id, account_id, currency,
             COALESCE(SUM(amount_minor) FILTER (WHERE direction='credit'),0) AS inp,
             COALESCE(SUM(amount_minor) FILTER (WHERE direction='debit'),0)  AS outp
      FROM ledger_entries GROUP BY tenant_id, account_id, currency) x
WHERE b.tenant_id=x.tenant_id AND b.account_id=x.account_id AND b.currency=x.currency;
