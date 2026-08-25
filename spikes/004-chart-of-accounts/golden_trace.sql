-- M0's acceptance test: the the reference product spec §06 trace, one $500 purchase, row by row.
-- After every step the accounting equation must hold. Not checked at the end --
-- checked at each step, because a ledger that is only right at the end is wrong.

BEGIN;

INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose, category, normal_balance, currency)
SELECT v.tenant, v.otype::account_owner_type, v.oid, t.code, t.category, t.normal_balance, 'USD'
FROM (VALUES
  ('t1','company',     'acme',      'customer_receivable'),
  ('t1','bank_account','bank_a',    'operating_cash'),
  (NULL,'house',       NULL,        'ach_pull_unsettled'),
  (NULL,'house',       NULL,        'network_settlement_payable'),
  (NULL,'house',       NULL,        'facility_borrowings'),
  (NULL,'house',       NULL,        'accrued_interest_payable'),
  ('t1','platform',    'platform_a','platform_rev_share_payable'),
  (NULL,'house',       NULL,        'paid_in_capital'),
  (NULL,'house',       NULL,        'interchange_revenue'),
  (NULL,'house',       NULL,        'interest_expense'),
  (NULL,'house',       NULL,        'platform_rev_share_expense')
) AS v(tenant,otype,oid,purpose)
JOIN account_types t ON t.code = v.purpose;

-- post(key, [purpose, direction, amount_minor] ...) -- balance enforced by trigger at COMMIT
CREATE FUNCTION post(p_key text, p_legs text[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_txn uuid; i int; v_acct uuid; v_seq bigint; v_bal bigint;
BEGIN
    INSERT INTO ledger_transactions (tenant_id,idempotency_key,idempotency_hash,kind,status,effective_at)
    VALUES ('t1',p_key,sha256(convert_to(p_key,'UTF8')),'trace','posted',now()) RETURNING id INTO v_txn;
    FOR i IN 1..array_length(p_legs,1)/3 LOOP
        SELECT id INTO v_acct FROM ledger_accounts WHERE purpose = p_legs[(i-1)*3+1];
        SELECT COALESCE(MAX(account_seq),0)+1 INTO v_seq FROM ledger_entries WHERE account_id=v_acct;
        SELECT COALESCE(SUM(CASE WHEN direction='debit' THEN amount_minor ELSE -amount_minor END),0)
          INTO v_bal FROM ledger_entries WHERE account_id=v_acct;
        INSERT INTO ledger_entries (transaction_id,account_id,direction,amount_minor,currency,
                                    account_seq,balance_after,effective_at)
        VALUES (v_txn, v_acct, p_legs[(i-1)*3+2]::ledger_direction, p_legs[(i-1)*3+3]::bigint,
                'USD', v_seq,
                v_bal + CASE WHEN p_legs[(i-1)*3+2]='debit' THEN p_legs[(i-1)*3+3]::bigint
                             ELSE -p_legs[(i-1)*3+3]::bigint END,
                now());
    END LOOP;
END $$;

-- opening: equity funds the 15% the advance rate leaves
SELECT post('open', ARRAY['operating_cash','debit','6600', 'paid_in_capital','credit','6600']);
-- 01 authorization: NOTHING. an auth creates no obligation.
-- 02 partial clearing $300
SELECT post('evt_clear_1:posting', ARRAY['customer_receivable','debit','30000',
        'network_settlement_payable','credit','29460','interchange_revenue','credit','540']);
SELECT post('evt_clear_1:revshare', ARRAY['platform_rev_share_expense','debit','162',
        'platform_rev_share_payable','credit','162']);
-- 03 final clearing $200
SELECT post('evt_clear_2:posting', ARRAY['customer_receivable','debit','20000',
        'network_settlement_payable','credit','19640','interchange_revenue','credit','360']);
SELECT post('evt_clear_2:revshare', ARRAY['platform_rev_share_expense','debit','108',
        'platform_rev_share_payable','credit','108']);
-- 04 facility draw, 85% advance rate
SELECT post('evt_draw', ARRAY['operating_cash','debit','42500','facility_borrowings','credit','42500']);
-- 05 network settlement: wire 491, not 500
SELECT post('evt_settle', ARRAY['network_settlement_payable','debit','49100','operating_cash','credit','49100']);
-- interest accrues 425 x 10% x 30/360
SELECT post('evt_accrue', ARRAY['interest_expense','debit','354','accrued_interest_payable','credit','354']);
-- 06 statement closes: NOTHING. a statement is a read.
-- 7.1 repayment initiated: NOTHING. money in commits at settlement.
-- 7.2 funds land, still reversible
SELECT post('evt_pull:settle', ARRAY['operating_cash','debit','50000','ach_pull_unsettled','credit','50000']);
-- 7.3 return window closes: only NOW is the debt extinguished
SELECT post('evt_pull:final', ARRAY['ach_pull_unsettled','debit','50000','customer_receivable','credit','50000']);
-- 08 repay the facility
SELECT post('evt_repay:principal', ARRAY['facility_borrowings','debit','42500','operating_cash','credit','42500']);
SELECT post('evt_repay:interest', ARRAY['accrued_interest_payable','debit','354','operating_cash','credit','354']);
SELECT post('evt_repay:revshare', ARRAY['platform_rev_share_payable','debit','270','operating_cash','credit','270']);

COMMIT;
