-- A LEDGER WRITE THAT IS ALREADY COMMITTED WHEN THE SUITES START.
--
-- `recorded_at` is assigned by the engine as `now()`, which in Postgres is
-- TRANSACTION-START time. A suite file is one transaction. So every row a suite
-- writes carries one recorded_at, to the microsecond, and the recorded axis has
-- exactly two reachable answers and exactly one reachable boundary -- and that
-- boundary IS `now()`.
--
-- That is not a nitpick. `tests/bitemporal.sql` aims at the boundary from both
-- sides using the value the engine assigned, and says of itself "no constant
-- predicate can be true at recorded_at and false one microsecond earlier". It is
-- defeated by the one constant that equals recorded_at: replacing
-- `en.recorded_at <= p_as_of` with `now() <= p_as_of` -- a predicate that reads no
-- column of the row at all -- passed every suite. Only tests/canary.sh saw it.
--
-- A second recorded_at cannot be manufactured inside one transaction. It needs a
-- second transaction, which is why this is a separate file applied in its own
-- psql invocation by both tests/run.sh and tests/canary.sh, and why it must stay
-- outside every suite.
--
-- It books ASSET against LIABILITY on a tenant of its own: no revenue, no expense,
-- so it adds no scope to income_statement and no line to any per-tenant count the
-- other suites make. It must balance, or the deferred balance trigger refuses it.

\set ON_ERROR_STOP on

INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose, category, normal_balance, currency)
SELECT 'bt0','company','prior',code,category,normal_balance,'USD'
  FROM account_types WHERE code IN ('customer_receivable','customer_wallet');

DO $$
DECLARE v_event uuid; v_txn uuid; r record; v_seq bigint; v_bal bigint;
        v_eff timestamptz := '2026-01-05';
BEGIN
    INSERT INTO ledger_events (tenant_id,kind,source,idempotency_key,idempotency_hash,payload,effective_at)
    VALUES ('bt0','bt0','internal','prior_commit',
            sha256(convert_to('prior_commit','UTF8')),'{}',v_eff)
    RETURNING id INTO v_event;
    INSERT INTO ledger_transactions (tenant_id,event_id,kind,status,effective_at)
    VALUES ('bt0',v_event,'bt0','posted',v_eff) RETURNING id INTO v_txn;

    FOR r IN SELECT a.id AS account_id, v.d::ledger_direction AS dir
               FROM (VALUES ('customer_receivable','debit'),('customer_wallet','credit')) v(p,d)
               JOIN ledger_accounts a ON a.tenant_id='bt0' AND a.purpose=v.p
              ORDER BY a.id
    LOOP
        INSERT INTO ledger_account_balances AS b (tenant_id,account_id,currency,input,output,last_seq)
        VALUES ('bt0',r.account_id,'USD',
                CASE WHEN r.dir='debit'  THEN 5000 ELSE 0 END,
                CASE WHEN r.dir='credit' THEN 5000 ELSE 0 END,1)
        ON CONFLICT (tenant_id,account_id,currency) DO UPDATE
           SET input=b.input+EXCLUDED.input, output=b.output+EXCLUDED.output,
               last_seq=b.last_seq+1
        RETURNING b.last_seq, b.input-b.output INTO v_seq, v_bal;

        INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,
                                    currency,account_seq,balance_after,effective_at)
        VALUES ('bt0',v_txn,r.account_id,r.dir,5000,'USD',v_seq,v_bal,v_eff);
    END LOOP;
END $$;
