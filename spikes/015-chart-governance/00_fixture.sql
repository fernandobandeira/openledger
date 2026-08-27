-- 00 -- the book every reproduction below runs against.
--
-- Two scopes, deliberately different:
--   op   -- the operator holds ONE house due_to_tenants account, which is what
--           the shipped uq_accounts__house (tenant_id, purpose, currency) allows
--           and what the chart's own comment describes. Owing t1 425.00 while t2
--           owes 425.00 lands in that one row.
--   op2  -- the same two positions, SPLIT per counterparty into two accounts.
--           This is the fix the decision log says does not work; it does not.
-- Plus 1,000.00 of paid-in capital, 300.00 of ACH-collected customer cash inside
-- the return window, and 300.00 of FBO float.

BEGIN;

INSERT INTO ledger_accounts (tenant_id, id, owner_type, owner_id, purpose, category, normal_balance, currency) VALUES
  ('op','11111111-0000-0000-0000-000000000001','house',NULL,'operating_cash','asset','debit','USD'),
  ('op','11111111-0000-0000-0000-000000000002','house',NULL,'fbo_cash','asset','debit','USD'),
  ('op','11111111-0000-0000-0000-000000000003','house',NULL,'due_to_tenants','liability','credit','USD'),
  ('op','11111111-0000-0000-0000-000000000004','house',NULL,'paid_in_capital','equity','credit','USD'),
  ('op','11111111-0000-0000-0000-000000000005','company','cust_a','customer_wallet','liability','credit','USD'),
  ('op','11111111-0000-0000-0000-000000000006','company','cust_a','ach_pull_returnable','liability','credit','USD'),
  ('op','11111111-0000-0000-0000-000000000007','house',NULL,'fee_revenue','revenue','credit','USD');

INSERT INTO ledger_events (tenant_id,id,kind,source,idempotency_key,idempotency_hash,payload,effective_at) VALUES
  ('op','22222222-0000-0000-0000-000000000001','seed','internal','k1','\x00','{}','2026-01-01'),
  ('op','22222222-0000-0000-0000-000000000002','seed','internal','k2','\x00','{}','2026-01-02'),
  ('op','22222222-0000-0000-0000-000000000003','seed','internal','k3','\x00','{}','2026-01-03'),
  ('op','22222222-0000-0000-0000-000000000004','seed','internal','k4','\x00','{}','2026-01-04'),
  ('op','22222222-0000-0000-0000-000000000005','seed','internal','k5','\x00','{}','2026-01-05');

INSERT INTO ledger_transactions (tenant_id,id,event_id,kind,status,effective_at) VALUES
  ('op','33333333-0000-0000-0000-000000000001','22222222-0000-0000-0000-000000000001','capital','posted','2026-01-01'),
  ('op','33333333-0000-0000-0000-000000000002','22222222-0000-0000-0000-000000000002','owe_t1','posted','2026-01-02'),
  ('op','33333333-0000-0000-0000-000000000003','22222222-0000-0000-0000-000000000003','owed_by_t2','posted','2026-01-03'),
  ('op','33333333-0000-0000-0000-000000000004','22222222-0000-0000-0000-000000000004','ach_pull','posted','2026-01-04'),
  ('op','33333333-0000-0000-0000-000000000005','22222222-0000-0000-0000-000000000005','fee','posted','2026-01-05');

-- 1,000.00 of paid-in capital
INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,currency,account_seq,effective_at) VALUES
  ('op','33333333-0000-0000-0000-000000000001','11111111-0000-0000-0000-000000000001','debit', 100000,'USD',1,'2026-01-01'),
  ('op','33333333-0000-0000-0000-000000000001','11111111-0000-0000-0000-000000000004','credit',100000,'USD',1,'2026-01-01');
-- the operator owes tenant t1 425.00
INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,currency,account_seq,effective_at) VALUES
  ('op','33333333-0000-0000-0000-000000000002','11111111-0000-0000-0000-000000000001','debit', 42500,'USD',2,'2026-01-02'),
  ('op','33333333-0000-0000-0000-000000000002','11111111-0000-0000-0000-000000000003','credit',42500,'USD',1,'2026-01-02');
-- tenant t2 owes the operator 425.00 -- the SAME account row
INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,currency,account_seq,effective_at) VALUES
  ('op','33333333-0000-0000-0000-000000000003','11111111-0000-0000-0000-000000000003','debit', 42500,'USD',2,'2026-01-03'),
  ('op','33333333-0000-0000-0000-000000000003','11111111-0000-0000-0000-000000000001','credit',42500,'USD',3,'2026-01-03');
-- 300.00 pulled by ACH, landed in FBO cash, still returnable
INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,currency,account_seq,effective_at) VALUES
  ('op','33333333-0000-0000-0000-000000000004','11111111-0000-0000-0000-000000000002','debit', 30000,'USD',1,'2026-01-04'),
  ('op','33333333-0000-0000-0000-000000000004','11111111-0000-0000-0000-000000000006','credit',30000,'USD',1,'2026-01-04');

-- 50.00 of fee revenue, so the reconciliation in 40_verify.sql is not 0 = 0
INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,currency,account_seq,effective_at) VALUES
  ('op','33333333-0000-0000-0000-000000000005','11111111-0000-0000-0000-000000000001','debit',  5000,'USD',4,'2026-01-05'),
  ('op','33333333-0000-0000-0000-000000000005','11111111-0000-0000-0000-000000000007','credit', 5000,'USD',1,'2026-01-05');

-- ---- op2: the same two tenant positions, split per counterparty ----
INSERT INTO ledger_accounts (tenant_id,id,owner_type,owner_id,purpose,category,normal_balance,currency) VALUES
  ('op2','44444444-0000-0000-0000-000000000001','house',NULL,'operating_cash','asset','debit','USD'),
  ('op2','44444444-0000-0000-0000-000000000002','platform','t1','due_to_tenants','liability','credit','USD'),
  ('op2','44444444-0000-0000-0000-000000000003','platform','t2','due_to_tenants','liability','credit','USD');
INSERT INTO ledger_events (tenant_id,id,kind,source,idempotency_key,idempotency_hash,payload,effective_at) VALUES
  ('op2','55555555-0000-0000-0000-000000000001','seed','internal','k1','\x00','{}','2026-01-02'),
  ('op2','55555555-0000-0000-0000-000000000002','seed','internal','k2','\x00','{}','2026-01-03');
INSERT INTO ledger_transactions (tenant_id,id,event_id,kind,status,effective_at) VALUES
  ('op2','66666666-0000-0000-0000-000000000001','55555555-0000-0000-0000-000000000001','owe_t1','posted','2026-01-02'),
  ('op2','66666666-0000-0000-0000-000000000002','55555555-0000-0000-0000-000000000002','owed_by_t2','posted','2026-01-03');
INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,currency,account_seq,effective_at) VALUES
  ('op2','66666666-0000-0000-0000-000000000001','44444444-0000-0000-0000-000000000001','debit', 42500,'USD',1,'2026-01-02'),
  ('op2','66666666-0000-0000-0000-000000000001','44444444-0000-0000-0000-000000000002','credit',42500,'USD',1,'2026-01-02'),
  ('op2','66666666-0000-0000-0000-000000000002','44444444-0000-0000-0000-000000000003','debit', 42500,'USD',1,'2026-01-03'),
  ('op2','66666666-0000-0000-0000-000000000002','44444444-0000-0000-0000-000000000001','credit',42500,'USD',2,'2026-01-03');

COMMIT;
