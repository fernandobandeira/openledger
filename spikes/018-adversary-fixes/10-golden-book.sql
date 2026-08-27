-- A minimal but complete golden book on top of schema/chart.sql (version 2 current).
-- tenant t1: fund capital, earn a fee, close 2026-02. Exercises post -> close ->
-- three statements -> all reconciliation checks zero. Loaded by the owner (writer
-- not built): it seeds the balance row first (as the real upsert does, so
-- fk_entries__stripe is satisfied), appends entries, then settles the cache.
\set ON_ERROR_STOP on
\set cash    '''11111111-1111-1111-1111-111111111111'''
\set fee     '''22222222-2222-2222-2222-222222222222'''
\set pic     '''33333333-3333-3333-3333-333333333333'''
\set re      '''44444444-4444-4444-4444-444444444444'''

INSERT INTO ledger_accounts (tenant_id,id,owner_type,owner_id,purpose,category,normal_balance,counterparty_scope,currency) VALUES
 ('t1',:cash,'house',NULL,'operating_cash','asset','debit','shared','USD'),
 ('t1',:fee ,'house',NULL,'fee_revenue','revenue','credit','none','USD'),
 ('t1',:pic ,'house',NULL,'paid_in_capital','equity','credit','none','USD'),
 ('t1',:re  ,'house',NULL,'retained_earnings','equity','credit','none','USD');

-- balance rows first (the upsert's job), zeroed; settled after the entries land.
INSERT INTO ledger_account_balances (tenant_id,account_id,currency,stripe,owner_type,owner_id_key,purpose,category,normal_balance)
SELECT a.tenant_id, a.id, a.currency, 0, a.owner_type, a.owner_id_key, a.purpose, a.category, a.normal_balance
FROM ledger_accounts a WHERE a.tenant_id='t1';

INSERT INTO ledger_events (tenant_id,id,kind,source,idempotency_key,idempotency_hash,payload,effective_at) VALUES
 ('t1','a1111111-0000-0000-0000-000000000001','funding','internal','k-fund','\x00','{}'::jsonb,'2026-01-05'),
 ('t1','a1111111-0000-0000-0000-000000000002','fee','internal','k-fee','\x00','{}'::jsonb,'2026-02-10'),
 ('t1','a1111111-0000-0000-0000-000000000003','period_close','internal','k-close','\x00','{}'::jsonb,'2026-02-28');

INSERT INTO ledger_transactions (tenant_id,id,event_id,kind,status,effective_at) VALUES
 ('t1','b1111111-0000-0000-0000-000000000001','a1111111-0000-0000-0000-000000000001','funding','posted','2026-01-05'),
 ('t1','b1111111-0000-0000-0000-000000000002','a1111111-0000-0000-0000-000000000002','fee','posted','2026-02-10'),
 ('t1','b1111111-0000-0000-0000-000000000003','a1111111-0000-0000-0000-000000000003','period_close','posted','2026-02-28');

INSERT INTO ledger_entries (tenant_id,id,transaction_id,account_id,direction,amount_minor,currency,stripe,account_seq,effective_at) VALUES
 ('t1','c0000000-0000-0000-0000-000000000001','b1111111-0000-0000-0000-000000000001',:cash,'debit',100000,'USD',0,1,'2026-01-05'),
 ('t1','c0000000-0000-0000-0000-000000000002','b1111111-0000-0000-0000-000000000001',:pic ,'credit',100000,'USD',0,1,'2026-01-05'),
 ('t1','c0000000-0000-0000-0000-000000000003','b1111111-0000-0000-0000-000000000002',:cash,'debit',5000,'USD',0,2,'2026-02-10'),
 ('t1','c0000000-0000-0000-0000-000000000004','b1111111-0000-0000-0000-000000000002',:fee ,'credit',5000,'USD',0,1,'2026-02-10'),
 ('t1','c0000000-0000-0000-0000-000000000005','b1111111-0000-0000-0000-000000000003',:fee ,'debit',5000,'USD',0,2,'2026-02-28'),
 ('t1','c0000000-0000-0000-0000-000000000006','b1111111-0000-0000-0000-000000000003',:re  ,'credit',5000,'USD',0,1,'2026-02-28');

UPDATE ledger_account_balances b SET input=j.di, output=j.cr, last_seq=j.ms
FROM (SELECT account_id, currency, stripe,
             COALESCE(SUM(amount_minor) FILTER (WHERE direction='debit'),0) di,
             COALESCE(SUM(amount_minor) FILTER (WHERE direction='credit'),0) cr,
             MAX(account_seq) ms
      FROM ledger_entries WHERE tenant_id='t1' GROUP BY account_id,currency,stripe) j
WHERE b.tenant_id='t1' AND b.account_id=j.account_id AND b.currency=j.currency AND b.stripe=j.stripe;

INSERT INTO ledger_periods (tenant_id,code,starts_at,ends_at,tz) VALUES
 ('t1','2026-02', '2026-02-01 00:00-05','2026-03-01 00:00-05','America/New_York');

INSERT INTO ledger_period_closes (tenant_id,period_code,currency,starts_at,ends_at,transaction_id,txn_effective_at,computed_at_xid)
VALUES ('t1','2026-02','USD','2026-02-01 00:00-05','2026-03-01 00:00-05',
        'b1111111-0000-0000-0000-000000000003','2026-02-28', report_cursor());

INSERT INTO ledger_period_balances (tenant_id,period_code,currency,account_id,input,output)
SELECT c.tenant_id, c.period_code, c.currency, e.account_id,
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'),0),
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'),0)
FROM ledger_period_closes c
JOIN ledger_entries e ON e.tenant_id=c.tenant_id AND e.currency=c.currency
  AND e.effective_at < c.ends_at AND e.xact_id < c.computed_at_xid
JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
GROUP BY c.tenant_id, c.period_code, c.currency, e.account_id;

-- operating_cash is a perimeter account: attest it so chart_lint is clean. The
-- attestation carries its own zone (A16); as_of_end resolves to 2026-03-01 00:00-05.
INSERT INTO perimeter_attestations (tenant_id,account_id,currency,as_of,tz,source,external_balance_minor)
VALUES ('t1','11111111-1111-1111-1111-111111111111','USD','2026-02-28','America/New_York','bank',105000);
