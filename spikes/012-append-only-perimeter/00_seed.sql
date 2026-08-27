-- 00 -- a minimal posted book, so every later run has something to damage.
-- Load order: migrations/00001_baseline.sql, schema/chart.sql, then this file.
--
-- Two tenants, one currency, four posted transactions, eight entries. Small on
-- purpose: every count below is meant to be checked by eye.

INSERT INTO ledger_accounts (tenant_id, id, owner_type, owner_id, purpose, category, normal_balance, currency)
VALUES
  ('t1','11111111-1111-1111-1111-111111111111','house',NULL,'operating_cash','asset','debit','USD'),
  ('t1','22222222-2222-2222-2222-222222222222','house',NULL,'interchange_revenue','revenue','credit','USD'),
  ('t2','33333333-3333-3333-3333-333333333333','house',NULL,'operating_cash','asset','debit','USD'),
  ('t2','44444444-4444-4444-4444-444444444444','house',NULL,'interchange_revenue','revenue','credit','USD');

INSERT INTO ledger_transactions (tenant_id, id, kind, status, effective_at)
VALUES
  ('t1','aaaaaaaa-0000-0000-0000-000000000001','clearing','posted','2026-01-15T00:00:00Z'),
  ('t1','aaaaaaaa-0000-0000-0000-000000000002','clearing','posted','2026-02-15T00:00:00Z'),
  ('t2','bbbbbbbb-0000-0000-0000-000000000001','clearing','posted','2026-01-15T00:00:00Z'),
  ('t2','bbbbbbbb-0000-0000-0000-000000000002','clearing','posted','2026-02-15T00:00:00Z');

INSERT INTO ledger_entries (tenant_id, id, transaction_id, account_id, direction, amount_minor, currency, account_seq, effective_at)
VALUES
  ('t1','e1000000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','debit', 10000,'USD',1,'2026-01-15T00:00:00Z'),
  ('t1','e1000000-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','credit',10000,'USD',1,'2026-01-15T00:00:00Z'),
  ('t1','e1000000-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','debit', 20000,'USD',2,'2026-02-15T00:00:00Z'),
  ('t1','e1000000-0000-0000-0000-000000000004','aaaaaaaa-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222','credit',20000,'USD',2,'2026-02-15T00:00:00Z'),
  ('t2','e2000000-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','33333333-3333-3333-3333-333333333333','debit', 30000,'USD',1,'2026-01-15T00:00:00Z'),
  ('t2','e2000000-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000001','44444444-4444-4444-4444-444444444444','credit',30000,'USD',1,'2026-01-15T00:00:00Z'),
  ('t2','e2000000-0000-0000-0000-000000000003','bbbbbbbb-0000-0000-0000-000000000002','33333333-3333-3333-3333-333333333333','debit', 40000,'USD',2,'2026-02-15T00:00:00Z'),
  ('t2','e2000000-0000-0000-0000-000000000004','bbbbbbbb-0000-0000-0000-000000000002','44444444-4444-4444-4444-444444444444','credit',40000,'USD',2,'2026-02-15T00:00:00Z');

INSERT INTO ledger_account_balances (tenant_id, account_id, currency, input, output, last_seq)
VALUES
  ('t1','11111111-1111-1111-1111-111111111111','USD',30000,0,2),
  ('t1','22222222-2222-2222-2222-222222222222','USD',0,30000,2),
  ('t2','33333333-3333-3333-3333-333333333333','USD',70000,0,2),
  ('t2','44444444-4444-4444-4444-444444444444','USD',0,70000,2);
