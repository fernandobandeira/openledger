-- A clean book: three scopes, two currencies, one cross-scope obligation posted on
-- both sides, and one pending transaction.
--
-- Seeded the way the writer is specified to write (ADR-0004, database.md): the
-- balance row is upserted first and RETURNS the sequence number the entry then
-- carries, so account_seq is issued under the lock rather than chosen. The two
-- helper functions below are SPIKE code and never product -- they exist so this
-- file writes a book that is correct by construction, and so a drift has to be
-- injected deliberately rather than arriving by accident.
--
-- Minor units throughout. 100,000.00 is 10000000.

CREATE FUNCTION seed_open(p_tenant text, p_purpose text, p_currency char(3),
                          p_owner_type account_owner_type, p_owner text)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
    INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose,
                                 category, normal_balance, currency)
    SELECT p_tenant, p_owner_type, p_owner, p_purpose, t.category, t.normal_balance, p_currency
    FROM account_types t WHERE t.code = p_purpose
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;

CREATE FUNCTION seed_acct(p_tenant text, p_purpose text, p_currency char(3))
RETURNS uuid LANGUAGE sql STABLE AS $$
    SELECT id FROM ledger_accounts
    WHERE tenant_id = p_tenant AND purpose = p_purpose AND currency = p_currency
$$;

-- The upsert from database.md, verbatim in shape: one statement advances the
-- balance and issues the next sequence number together, under one row lock.
CREATE FUNCTION seed_post(p_tenant text, p_txn uuid, p_account uuid,
                          p_dir ledger_direction, p_amount bigint,
                          p_currency char(3), p_effective timestamptz)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_seq bigint;
BEGIN
    INSERT INTO ledger_account_balances AS b (tenant_id, account_id, currency, input, output, last_seq)
    VALUES (p_tenant, p_account, p_currency,
            CASE WHEN p_dir = 'debit'  THEN p_amount ELSE 0 END,
            CASE WHEN p_dir = 'credit' THEN p_amount ELSE 0 END, 1)
    ON CONFLICT (tenant_id, account_id, currency) DO UPDATE
       SET input    = b.input  + CASE WHEN p_dir = 'debit'  THEN p_amount ELSE 0 END,
           output   = b.output + CASE WHEN p_dir = 'credit' THEN p_amount ELSE 0 END,
           last_seq = b.last_seq + 1,
           updated_at = now()
    RETURNING b.last_seq INTO v_seq;

    INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                                amount_minor, currency, account_seq, effective_at)
    VALUES (p_tenant, p_txn, p_account, p_dir, p_amount, p_currency, v_seq, p_effective);
    RETURN v_seq;
END $$;

CREATE FUNCTION seed_txn(p_tenant text, p_kind text, p_status ledger_txn_status,
                         p_effective timestamptz)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
    INSERT INTO ledger_transactions (tenant_id, kind, status, effective_at)
    VALUES (p_tenant, p_kind, p_status, p_effective)
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;

-- ----------------------------------------------------------------------
-- the accounts
--
-- Three scopes. 't1' and 't2' are tenant books; 'op' is the operator's own. Each
-- balances on its own -- no transaction below spans two of them.

SELECT seed_open('t1','customer_wallet','USD','company','cust-1');
SELECT seed_open('t1','due_from_treasury','USD','house',NULL);
SELECT seed_open('t1','fee_revenue','USD','house',NULL);
SELECT seed_open('t1','outbound_transfer_in_transit','USD','house',NULL);

SELECT seed_open('t2','customer_wallet','EUR','company','cust-9');
SELECT seed_open('t2','due_from_treasury','EUR','house',NULL);
SELECT seed_open('t2','fee_revenue','EUR','house',NULL);

SELECT seed_open('op','fbo_cash','USD','house',NULL);
SELECT seed_open('op','due_to_tenants','USD','house',NULL);
SELECT seed_open('op','fbo_cash','EUR','house',NULL);
SELECT seed_open('op','due_to_tenants','EUR','house',NULL);
SELECT seed_open('op','operating_cash','USD','house',NULL);
SELECT seed_open('op','interchange_revenue','USD','house',NULL);

-- ----------------------------------------------------------------------
-- the book

-- 1 - a customer deposits 100,000.00 into t1's wallet. The cash sits with the
--     operator, so t1 holds a claim on the treasury rather than the cash itself.
DO $$
DECLARE v uuid; BEGIN
    v := seed_txn('t1','deposit','posted','2026-06-01');
    PERFORM seed_post('t1', v, seed_acct('t1','due_from_treasury','USD'), 'debit',  10000000, 'USD','2026-06-01');
    PERFORM seed_post('t1', v, seed_acct('t1','customer_wallet','USD'),   'credit', 10000000, 'USD','2026-06-01');
END $$;

-- 2 - ...and the operator books the other side of the same money. TWO
--     transactions, one per scope, joined by the clearing pair -- the only shape
--     tenant-locality permits.
DO $$
DECLARE v uuid; BEGIN
    v := seed_txn('op','deposit','posted','2026-06-01');
    PERFORM seed_post('op', v, seed_acct('op','fbo_cash','USD'),       'debit',  10000000, 'USD','2026-06-01');
    PERFORM seed_post('op', v, seed_acct('op','due_to_tenants','USD'), 'credit', 10000000, 'USD','2026-06-01');
END $$;

-- 3 - a 9.00 fee out of the wallet
DO $$
DECLARE v uuid; BEGIN
    v := seed_txn('t1','fee','posted','2026-06-02');
    PERFORM seed_post('t1', v, seed_acct('t1','customer_wallet','USD'), 'debit',  900, 'USD','2026-06-02');
    PERFORM seed_post('t1', v, seed_acct('t1','fee_revenue','USD'),     'credit', 900, 'USD','2026-06-02');
END $$;

-- 4/5 - the same pair in EUR, in the second tenant: 50,000.00
DO $$
DECLARE v uuid; BEGIN
    v := seed_txn('t2','deposit','posted','2026-06-03');
    PERFORM seed_post('t2', v, seed_acct('t2','due_from_treasury','EUR'), 'debit',  5000000, 'EUR','2026-06-03');
    PERFORM seed_post('t2', v, seed_acct('t2','customer_wallet','EUR'),   'credit', 5000000, 'EUR','2026-06-03');
    v := seed_txn('op','deposit','posted','2026-06-03');
    PERFORM seed_post('op', v, seed_acct('op','fbo_cash','EUR'),       'debit',  5000000, 'EUR','2026-06-03');
    PERFORM seed_post('op', v, seed_acct('op','due_to_tenants','EUR'), 'credit', 5000000, 'EUR','2026-06-03');
END $$;

-- 6 - a withdrawal of 500.00 submitted and not yet settled. PENDING, and never
--     mutated into posted: the resolution is a new transaction with resolves_id.
--     This is the population every report excludes and the cache counts.
DO $$
DECLARE v uuid; BEGIN
    v := seed_txn('t1','withdrawal','pending','2026-06-04');
    PERFORM seed_post('t1', v, seed_acct('t1','customer_wallet','USD'),              'debit',  50000, 'USD','2026-06-04');
    PERFORM seed_post('t1', v, seed_acct('t1','outbound_transfer_in_transit','USD'), 'credit', 50000, 'USD','2026-06-04');
END $$;

-- 7 - operator revenue, so 'op' has an income statement of its own
DO $$
DECLARE v uuid; BEGIN
    v := seed_txn('op','interchange','posted','2026-06-05');
    PERFORM seed_post('op', v, seed_acct('op','operating_cash','USD'),      'debit',  25006, 'USD','2026-06-05');
    PERFORM seed_post('op', v, seed_acct('op','interchange_revenue','USD'), 'credit', 25006, 'USD','2026-06-05');
END $$;
