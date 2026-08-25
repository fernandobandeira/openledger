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
