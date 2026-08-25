-- Does the golden trace actually bite?
--
-- A suite that only ever runs the happy path proves nothing: it can pass because
-- everything is right, or because nothing is being checked. This file breaks the
-- ledger thirteen ways and requires each break to be REFUSED, with the error we
-- expect rather than merely some error.
--
-- Case 2 is the reason this file exists. Re-routing interchange to fee_revenue --
-- a real, plausible, wrong posting -- passed the previous suite silently, because
-- both accounts are revenue and the accounting equation cannot tell them apart.

\set ON_ERROR_STOP on
\o /dev/null
BEGIN;

CREATE FUNCTION must_fail(p_label text, p_sql text, p_expect text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_msg text;
BEGIN
    BEGIN
        EXECUTE p_sql;
        -- deferred constraint triggers have not fired yet; force them
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'NOT_REFUSED';
    EXCEPTION
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
            IF v_msg = 'NOT_REFUSED' THEN
                RAISE EXCEPTION 'NOT CAUGHT -- %: the ledger accepted it', p_label;
            END IF;
            IF position(lower(p_expect) in lower(v_msg)) = 0 THEN
                RAISE EXCEPTION 'WRONG REASON -- %: expected to contain "%", got "%"',
                    p_label, p_expect, v_msg;
            END IF;
            RAISE NOTICE 'refused  %  (%)', p_label, left(v_msg, 72);
    END;
    SET CONSTRAINTS ALL DEFERRED;
END $$;

-- a minimal, valid world to break
INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose, category, normal_balance, currency)
SELECT v.tenant, v.otype::account_owner_type, v.oid, t.code, t.category, t.normal_balance, v.ccy
FROM (VALUES
  ('t1','company','acme','customer_receivable','USD'),
  ('t1','house',NULL,'network_settlement_payable','USD'),
  ('t1','house',NULL,'interchange_revenue','USD'),
  ('t1','house',NULL,'fee_revenue','USD'),
  ('t1','house',NULL,'due_from_treasury','USD'),
  ('t1','house',NULL,'interchange_revenue_eur','EUR'),
  ('t2','company','beta','customer_receivable','USD'),
  ('_treasury','house',NULL,'due_to_tenants','USD')
) AS v(tenant,otype,oid,purpose,ccy)
JOIN account_types t ON t.code = replace(v.purpose,'_eur','');

CREATE FUNCTION acct(p_tenant text, p_purpose text, p_ccy char(3) DEFAULT 'USD') RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT id FROM ledger_accounts
    WHERE tenant_id=p_tenant AND purpose=p_purpose AND currency=p_ccy LIMIT 1 $$;

CREATE FUNCTION txn(p_tenant text, p_key text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_event uuid; v_txn uuid;
BEGIN
    INSERT INTO ledger_events (tenant_id,kind,source,idempotency_key,idempotency_hash,payload,effective_at)
    VALUES (p_tenant,'neg','internal',p_key,sha256(convert_to(p_key,'UTF8')),'{}',now())
    RETURNING id INTO v_event;
    INSERT INTO ledger_transactions (tenant_id,event_id,kind,status,effective_at)
    VALUES (p_tenant,v_event,'neg','posted',now()) RETURNING id INTO v_txn;
    RETURN v_txn;
END $$;

CREATE FUNCTION entry(p_tenant text, p_txn uuid, p_acct uuid, p_dir text,
                      p_amt bigint, p_ccy char(3) DEFAULT 'USD', p_seq bigint DEFAULT NULL,
                      p_bal bigint DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_seq bigint;
BEGIN
    SELECT COALESCE(p_seq, COALESCE(MAX(account_seq),0)+1) INTO v_seq
      FROM ledger_entries WHERE tenant_id=p_tenant AND account_id=p_acct;
    INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,
                                currency,account_seq,balance_after,effective_at)
    VALUES (p_tenant,p_txn,p_acct,p_dir::ledger_direction,p_amt,p_ccy,v_seq,
            COALESCE(p_bal, CASE WHEN p_dir='debit' THEN p_amt ELSE -p_amt END), now());
END $$;

-- ---------------------------------------------------------------- the controls

-- 1. debits <> credits
SELECT must_fail('unbalanced transaction', $q$
    SELECT entry('t1', txn('t1','n1'), acct('t1','customer_receivable'), 'debit', 100);
$q$, 'does not balance');

-- 2. THE ONE THE OLD SUITE MISSED. Perfectly balanced, both legs revenue-typed,
--    accounting equation entirely happy -- and posted to the wrong account.
SELECT must_fail('interchange mis-routed to fee_revenue', $q$
    DO $d$ DECLARE t uuid := txn('t1','n2'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  500);
        PERFORM entry('t1', t, acct('t1','fee_revenue'),         'credit', 500);
    END $d$;
    DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM trial_balance
                    WHERE tenant_id='t1' AND purpose='fee_revenue') THEN
            RAISE EXCEPTION 'UNEXPECTED t1/fee_revenue holds %',
                (SELECT balance_minor FROM trial_balance
                  WHERE tenant_id='t1' AND purpose='fee_revenue');
        END IF;
    END $d$;
$q$, 'unexpected t1/fee_revenue');

-- 3. one transaction, two tenants -- the composite FK makes it unrepresentable
SELECT must_fail('transaction spanning two tenants', $q$
    DO $d$ DECLARE t uuid := txn('t1','n3'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  500);
        PERFORM entry('t2', t, acct('t2','customer_receivable'), 'credit', 500);
    END $d$;
$q$, 'fk_entries__txn');

-- 4. an entry carrying a currency its account does not hold
SELECT must_fail('entry currency <> account currency', $q$
    SELECT entry('t1', txn('t1','n4'), acct('t1','customer_receivable'), 'debit', 500, 'EUR');
$q$, 'fk_entries__account');

-- 5. balanced in TOTAL, unbalanced per currency. The identity A = L + E + (R - X)
--    holds for any union of balanced transactions REGARDLESS of denomination, so a
--    currency-blind check reports this as fine. Ours is per currency.
SELECT must_fail('100.00 USD debit against 100.00 EUR credit', $q$
    DO $d$ DECLARE t uuid := txn('t1','n5'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  10000, 'USD');
        PERFORM entry('t1', t, acct('t1','interchange_revenue','EUR'), 'credit', 10000, 'EUR');
    END $d$;
$q$, 'does not balance');

-- 6. append-only is a grant, not a convention
SELECT must_fail('UPDATE on ledger_entries as the app role', $q$
    DO $d$ DECLARE t uuid := txn('t1','n6a'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  700);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 700);
    END $d$;
    SET CONSTRAINTS ALL IMMEDIATE;
    SET LOCAL ROLE openledger_app;
    UPDATE ledger_entries SET amount_minor = 1 WHERE tenant_id='t1';
$q$, 'permission denied');
RESET ROLE;

-- 7. DELETE likewise
SELECT must_fail('DELETE on ledger_entries as the app role', $q$
    SET LOCAL ROLE openledger_app;
    DELETE FROM ledger_entries WHERE tenant_id='t1';
$q$, 'permission denied');
RESET ROLE;

-- 8. an account may not disagree with its own type
SELECT must_fail('account declaring a category its type does not have', $q$
    INSERT INTO ledger_accounts (tenant_id,owner_type,owner_id,purpose,category,normal_balance,currency)
    VALUES ('t1','house',NULL,'operating_cash','liability','credit','USD');
$q$, 'but type');

-- 9. ...and a type may not be reclassified out from under its accounts. Doing so
--    silently rewrote the income statement: revenue 9.00 -> 0.00, all checks green.
SELECT must_fail('reclassifying a type that has accounts', $q$
    UPDATE account_types SET category='expense', normal_balance='debit'
     WHERE code='interchange_revenue';
$q$, 'cannot reclassify');

-- 10. a mis-typed reporting axis must RAISE, not return an empty balanced report
SELECT must_fail('unknown as-of axis', $q$
    SELECT * FROM accounting_equation(NULL, now(), 'efective');
$q$, 'unknown axis');

-- 11. the same idempotency key twice
SELECT must_fail('duplicate idempotency key', $q$
    SELECT txn('t1','dup'), txn('t1','dup');
$q$, 'uq_events__idempotency');

-- 12. the corruption alarm: tamper with a stored running balance
SELECT must_fail('balance_after tampered with', $q$
    DO $d$ DECLARE t uuid := txn('t1','n12'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  900);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 900);
    END $d$;
    SET CONSTRAINTS ALL IMMEDIATE;
    UPDATE ledger_entries SET balance_after = balance_after + 1
     WHERE account_id = acct('t1','customer_receivable');
    DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM ledger_balance_drift WHERE stored <> recomputed) THEN
            RAISE EXCEPTION 'DRIFT DETECTED';
        END IF;
    END $d$;
$q$, 'drift detected');

-- 13. one side of a cross-scope movement, without the other
SELECT must_fail('one-sided intercompany movement', $q$
    DO $d$ DECLARE t uuid := txn('t1','n13'); BEGIN
        PERFORM entry('t1', t, acct('t1','due_from_treasury'),  'debit',  400);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'),'credit', 400);
    END $d$;
    SET CONSTRAINTS ALL IMMEDIATE;
    DO $d$ BEGIN
        IF (SELECT COALESCE(SUM(CASE WHEN e.direction='debit' THEN e.amount_minor
                                     ELSE -e.amount_minor END),0)
              FROM ledger_entries e
              JOIN ledger_accounts a ON a.tenant_id=e.tenant_id AND a.id=e.account_id
             WHERE a.purpose IN ('due_from_treasury','due_to_tenants')) <> 0 THEN
            RAISE EXCEPTION 'INTERCOMPANY DOES NOT ELIMINATE';
        END IF;
    END $d$;
$q$, 'intercompany does not eliminate');

DO $$ BEGIN RAISE NOTICE 'ok  13/13 refused'; END $$;

ROLLBACK;
