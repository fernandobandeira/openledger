-- Spike 003 — throughput ceiling harness.
-- Adds the M2 balance table to the spike schema, plus striped house accounts.

CREATE TABLE IF NOT EXISTS ledger_account_balances (
    account_id uuid    NOT NULL,
    currency   char(3) NOT NULL,
    input      bigint  NOT NULL DEFAULT 0,
    output     bigint  NOT NULL DEFAULT 0,
    last_seq   bigint  NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, currency)
);

-- The posting path, as one atomic upsert: the row lock IS the serialization point.
-- Returns the new balance AND the next per-account sequence together.
CREATE OR REPLACE FUNCTION post_entry(
    p_txn uuid, p_account uuid, p_dir ledger_direction, p_amount bigint,
    p_currency char(3), p_effective timestamptz
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_in bigint; v_out bigint; v_seq bigint; v_bal bigint;
BEGIN
    INSERT INTO ledger_account_balances (account_id, currency, input, output, last_seq)
    VALUES (p_account, p_currency,
            CASE WHEN p_dir='debit'  THEN p_amount ELSE 0 END,
            CASE WHEN p_dir='credit' THEN p_amount ELSE 0 END, 1)
    ON CONFLICT (account_id, currency) DO UPDATE
       SET input    = ledger_account_balances.input  + CASE WHEN p_dir='debit'  THEN p_amount ELSE 0 END,
           output   = ledger_account_balances.output + CASE WHEN p_dir='credit' THEN p_amount ELSE 0 END,
           last_seq = ledger_account_balances.last_seq + 1
    RETURNING input, output, last_seq INTO v_in, v_out, v_seq;

    v_bal := v_in - v_out;
    INSERT INTO ledger_entries (transaction_id, account_id, direction, amount_minor,
                                currency, account_seq, balance_after, effective_at)
    VALUES (p_txn, p_account, p_dir, p_amount, p_currency, v_seq, v_bal, p_effective);
    RETURN v_bal;
END $$;

-- Whole clearing in ONE server-side call: 1 round trip instead of 6
-- (BEGIN + txn insert + 3 post_entry + COMMIT).
CREATE OR REPLACE FUNCTION post_clearing(
    p_tenant text, p_key text, p_recv uuid, p_ns uuid, p_ic uuid
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_txn uuid; v_now timestamptz := now();
BEGIN
    INSERT INTO ledger_transactions (tenant_id, idempotency_key, idempotency_hash, kind, status, effective_at)
    VALUES (p_tenant, p_key, sha256(convert_to(p_key,'UTF8')), 'clearing', 'posted', v_now)
    RETURNING id INTO v_txn;
    PERFORM post_entry(v_txn, p_recv, 'debit',  500, 'USD', v_now);
    PERFORM post_entry(v_txn, p_ns,   'credit', 491, 'USD', v_now);
    PERFORM post_entry(v_txn, p_ic,   'credit',   9, 'USD', v_now);
END $$;

-- OPTIMISTIC: read the balance, then write conditionally on it being unchanged.
-- Returns false on conflict; the caller retries.
CREATE OR REPLACE FUNCTION post_entry_optimistic(
    p_txn uuid, p_account uuid, p_dir ledger_direction, p_amount bigint,
    p_currency char(3), p_effective timestamptz
) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE v_in bigint; v_out bigint; v_seq bigint; n int;
BEGIN
    SELECT input, output, last_seq INTO v_in, v_out, v_seq
      FROM ledger_account_balances WHERE account_id=p_account AND currency=p_currency;
    IF NOT FOUND THEN
        INSERT INTO ledger_account_balances (account_id,currency,input,output,last_seq)
        VALUES (p_account,p_currency,0,0,0) ON CONFLICT DO NOTHING;
        v_in := 0; v_out := 0; v_seq := 0;
    END IF;
    -- the compare-and-swap: only writes if nobody moved last_seq meanwhile
    UPDATE ledger_account_balances
       SET input = input + CASE WHEN p_dir='debit' THEN p_amount ELSE 0 END,
           output = output + CASE WHEN p_dir='credit' THEN p_amount ELSE 0 END,
           last_seq = last_seq + 1
     WHERE account_id=p_account AND currency=p_currency AND last_seq = v_seq;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n = 0 THEN RETURN false; END IF;

    INSERT INTO ledger_entries (transaction_id,account_id,direction,amount_minor,
                                currency,account_seq,balance_after,effective_at)
    VALUES (p_txn,p_account,p_dir,p_amount,p_currency,v_seq+1,
            (v_in + CASE WHEN p_dir='debit' THEN p_amount ELSE 0 END)
          - (v_out + CASE WHEN p_dir='credit' THEN p_amount ELSE 0 END), p_effective);
    RETURN true;
END $$;

-- LOCK-FREE APPEND: no balance row, no per-account sequence. Pure INSERT.
-- Balance becomes an aggregate on read. This is Formance's `moves` shape.
CREATE SEQUENCE IF NOT EXISTS global_entry_seq;
CREATE OR REPLACE FUNCTION post_entry_append(
    p_txn uuid, p_account uuid, p_dir ledger_direction, p_amount bigint,
    p_currency char(3), p_effective timestamptz
) RETURNS void LANGUAGE sql AS $$
    INSERT INTO ledger_entries (transaction_id,account_id,direction,amount_minor,
                                currency,account_seq,balance_after,effective_at)
    VALUES (p_txn,p_account,p_dir,p_amount,p_currency,nextval('global_entry_seq'),0,p_effective);
$$;

CREATE OR REPLACE FUNCTION post_clearing_mode(
    p_tenant text, p_key text, p_recv uuid, p_ns uuid, p_ic uuid, p_mode text
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_txn uuid; v_now timestamptz := now();
BEGIN
    INSERT INTO ledger_transactions (tenant_id,idempotency_key,idempotency_hash,kind,status,effective_at)
    VALUES (p_tenant,p_key,sha256(convert_to(p_key,'UTF8')),'clearing','posted',v_now)
    RETURNING id INTO v_txn;
    IF p_mode = 'append' THEN
        PERFORM post_entry_append(v_txn,p_recv,'debit',500,'USD',v_now);
        PERFORM post_entry_append(v_txn,p_ns,'credit',491,'USD',v_now);
        PERFORM post_entry_append(v_txn,p_ic,'credit',9,'USD',v_now);
    ELSIF p_mode = 'optimistic' THEN
        IF NOT post_entry_optimistic(v_txn,p_recv,'debit',500,'USD',v_now)
        OR NOT post_entry_optimistic(v_txn,p_ns,'credit',491,'USD',v_now)
        OR NOT post_entry_optimistic(v_txn,p_ic,'credit',9,'USD',v_now)
        THEN RAISE EXCEPTION 'optimistic conflict' USING ERRCODE='40001'; END IF;
    ELSE
        PERFORM post_entry(v_txn,p_recv,'debit',500,'USD',v_now);
        PERFORM post_entry(v_txn,p_ns,'credit',491,'USD',v_now);
        PERFORM post_entry(v_txn,p_ic,'credit',9,'USD',v_now);
    END IF;
END $$;
