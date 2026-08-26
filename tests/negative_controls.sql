-- Does the golden trace actually bite?
--
-- A suite that only ever runs the happy path proves nothing: it can pass because
-- everything is right, or because nothing is being checked. This file breaks the
-- ledger sixty-odd ways and requires each break to be REFUSED, with the error we
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
  ('t1','house',NULL,'fbo_cash','USD'),
  ('t1','house',NULL,'credit_loss_expense','USD'),
  ('t1','house',NULL,'allowance_for_credit_losses','USD'),
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
DECLARE v_seq bigint; v_bal bigint;
BEGIN
    -- The running balance must ACCUMULATE. It used to be written as a bare
    -- +/-amount, which is correct for an account's first entry and wrong for every
    -- one after -- so any account with two entries genuinely diverged, and the
    -- drift controls below then fired on the running-balance branch instead of the
    -- one they name.
    SELECT COALESCE(input - output, 0) INTO v_bal FROM ledger_account_balances
     WHERE tenant_id=p_tenant AND account_id=p_acct AND currency=p_ccy;
    v_bal := COALESCE(v_bal, 0) + CASE WHEN p_dir='debit' THEN p_amt ELSE -p_amt END;

    -- The ENTRY first, then the cache. account_seq is assigned by the engine from
    -- the journal now, so a helper that picks a sequence from the cache and then
    -- writes the entry can diverge from it -- which shows up as last_seq drift and
    -- makes every later drift control assert the wrong branch. Derive the cache
    -- from what the journal actually recorded. p_seq is still accepted so a control
    -- can supply a deliberately bad one and watch it be discarded.
    INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,
                                currency,account_seq,balance_after,effective_at)
    VALUES (p_tenant,p_txn,p_acct,p_dir::ledger_direction,p_amt,p_ccy,
            COALESCE(p_seq, 1),
            COALESCE(p_bal, v_bal),
            COALESCE((SELECT effective_at FROM ledger_transactions
                       WHERE tenant_id=p_tenant AND id=p_txn), now()))
    RETURNING account_seq INTO v_seq;

    INSERT INTO ledger_account_balances AS b (tenant_id,account_id,currency,input,output,last_seq)
    VALUES (p_tenant,p_acct,p_ccy,
            CASE WHEN p_dir='debit'  THEN p_amt ELSE 0 END,
            CASE WHEN p_dir='credit' THEN p_amt ELSE 0 END, v_seq)
    ON CONFLICT (tenant_id,account_id,currency) DO UPDATE
       SET input=b.input+EXCLUDED.input, output=b.output+EXCLUDED.output,
           last_seq=EXCLUDED.last_seq;
END $$;

-- ---------------------------------------------------------------- the controls

-- 1. debits <> credits. TWO legs, deliberately: a one-legged transaction is now
--    refused by ck_txn__has_entries first, which would test a different rule.
SELECT must_fail('unbalanced transaction', $q$
    DO $d$ DECLARE t uuid := txn('t1','n1'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  100);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit',  99);
    END $d$;
$q$, 'does not balance');

-- 1b. a transaction with NO entries is VACUOUSLY balanced, so the per-row balance
--     trigger never fires for it. It used to commit -- a posted clearing that moved
--     nothing and consumed an idempotency key.
SELECT must_fail('transaction with no entries', $q$
    SELECT txn('t1','n1b');
$q$, 'needs at least two');

-- 1c. deleting one leg of a COMMITTED transaction. The trigger was AFTER INSERT
--     only, so this left 900 debits against 0 credits and nothing complained.
SELECT must_fail('deleting one leg of a balanced transaction', $q$
    DO $d$ DECLARE t uuid := txn('t1','n1c'); BEGIN
        -- FOUR legs: deleting one of two would leave a single entry and trip
        -- ck_txn__has_entries first, testing a different rule.
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  900);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 900);
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  100);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 100);
    END $d$;
    SET CONSTRAINTS ALL IMMEDIATE;
    DELETE FROM ledger_entries WHERE tenant_id='t1' AND transaction_id IN
        (SELECT id FROM ledger_transactions WHERE tenant_id='t1'
          AND event_id=(SELECT id FROM ledger_events WHERE idempotency_key='n1c'))
      AND direction='credit' AND amount_minor=100;
$q$, 'ledger entries are immutable');

-- 1c-alt. ...and with that guard explicitly lifted -- simulating corruption that
--     reached the table another way -- the balance trigger is still the backstop.
SELECT must_fail('deleting one leg, with immutability lifted', $q$
    DO $d$ DECLARE t uuid := txn('t1','n1calt'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  900);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 900);
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  100);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 100);
    END $d$;
    SET CONSTRAINTS ALL IMMEDIATE;
    ALTER TABLE ledger_entries DISABLE TRIGGER ck_entries__immutable;
    DELETE FROM ledger_entries WHERE tenant_id='t1' AND transaction_id IN
        (SELECT id FROM ledger_transactions WHERE tenant_id='t1'
          AND event_id=(SELECT id FROM ledger_events WHERE idempotency_key='n1calt'))
      AND direction='credit' AND amount_minor=100;
$q$, 'does not balance');

-- 1c-bis. Deleting EVERY leg is "vacuously balanced" -- a zero-row GROUP BY finds
--     nothing, so the balance check passes. Verified before the fix: a committed
--     2-leg transaction was reduced to zero entries, the posted row survived, and
--     with its cached balances also removed the drift view returned nothing, the
--     balance sheet balanced, and the equation returned no rows at all.
SELECT must_fail('deleting EVERY leg, with immutability lifted', $q$
    ALTER TABLE ledger_entries DISABLE TRIGGER ck_entries__immutable;
    DO $d$ DECLARE t uuid := txn('t1','n1cb'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  700);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 700);
    END $d$;
    SET CONSTRAINTS ALL IMMEDIATE;
    DELETE FROM ledger_entries WHERE tenant_id='t1' AND transaction_id IN
        (SELECT id FROM ledger_transactions WHERE tenant_id='t1'
          AND event_id=(SELECT id FROM ledger_events WHERE idempotency_key='n1cb'));
$q$, 'fewer than two entries');

-- 1c-ter. THE JOURNAL IS SEALED AT COMMIT. The newest and most critical guard had
--     zero coverage: no test file contained the words `sealed`, `xact_id` or
--     `already committed`. It closes the hole where legs could be APPENDED to a
--     transaction committed and reported months earlier -- balanced, correctly
--     dated, correctly sequenced, and invisible to every alarm.
--     This whole file is ONE transaction, so every statement shares an xact id and
--     "already committed" cannot occur naturally here. The transaction row is
--     written with an EARLIER xact_id instead, which is exactly the state a
--     genuinely prior commit leaves behind.
SELECT must_fail('appending a leg to an already-committed transaction', $q$
    INSERT INTO ledger_events (tenant_id,kind,source,idempotency_key,idempotency_hash,
                               payload,effective_at)
    VALUES ('t1','neg','internal','sealed',sha256('sealed'),'{}',now());
    INSERT INTO ledger_transactions (tenant_id,id,event_id,kind,status,effective_at,xact_id)
    SELECT 't1','0f0f0f0f-0000-7000-8000-00000000f00d',id,'neg','posted',now(),
           pg_current_xact_id()::text::bigint - 1
      FROM ledger_events WHERE tenant_id='t1' AND idempotency_key='sealed';
    INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,
                                currency,account_seq,balance_after,effective_at)
    SELECT 't1','0f0f0f0f-0000-7000-8000-00000000f00d',
           acct('t1','customer_receivable'),'debit',100,'USD',900,100,
           (SELECT effective_at FROM ledger_transactions
             WHERE id='0f0f0f0f-0000-7000-8000-00000000f00d');
$q$, 'sealed');

-- 1c-quater. TRUNCATE is not covered by DELETE and fires no row trigger. After a
--     careless GRANT ALL the shipped REVOKEs left it in place, and truncating the
--     whole journal succeeded.
SELECT must_fail('TRUNCATE as the app role', $q$
    SET LOCAL ROLE openledger_app;
    TRUNCATE ledger_entries;
$q$, 'permission denied');
RESET ROLE;

-- 1d. session_replication_role='replica' is the logical-replication apply path and
--     what pg_restore --disable-triggers sets. Under it an unbalanced transaction
--     COMMITTED. A subscriber must enforce what its publisher enforces.
SELECT must_fail('unbalanced under session_replication_role=replica', $q$
    SET LOCAL session_replication_role = 'replica';
    DO $d$ DECLARE t uuid := txn('t1','n1d'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  424242);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit',      1);
    END $d$;
$q$, 'does not balance');
RESET ROLE;

-- 1e. a transaction cannot reverse itself
-- Set at INSERT, not by UPDATE: ledger_transactions is immutable now, so an
-- UPDATE would trip that guard instead and test a different rule.
SELECT must_fail('self-reversal', $q$
    INSERT INTO ledger_events (tenant_id,kind,source,idempotency_key,idempotency_hash,
                               payload,effective_at)
    VALUES ('t1','neg','internal','n1e',sha256('n1e'),'{}',now());
    INSERT INTO ledger_transactions (tenant_id,id,event_id,kind,status,effective_at,reverses_id)
    SELECT 't1','0e0e0e0e-0000-7000-8000-00000000000e',id,'neg','posted',now(),
           '0e0e0e0e-0000-7000-8000-00000000000e'
      FROM ledger_events WHERE tenant_id='t1' AND idempotency_key='n1e';
$q$, 'ck_txn__no_self_reference');

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
$q$, 'fk_entries__txn"');   -- trailing quote: fk_entries__txn is a PREFIX of
                           -- fk_entries__txn_effective, so a bare substring match
                           -- passed even with the cross-tenant FK dropped

-- 4. an entry carrying a currency its account does not hold. TWO constraints now
--    enforce this -- the cache's FK carries currency as well -- so it is asserted
--    on both paths rather than whichever happens to fire first.
-- the cache's own FK carries currency too, so it is asserted directly rather than
-- through a path where the entries FK now fires first
SELECT must_fail('a cached balance in a currency its account does not hold', $q$
    INSERT INTO ledger_account_balances (tenant_id,account_id,currency,input,output,last_seq)
    VALUES ('t1', acct('t1','customer_receivable'), 'EUR', 500, 0, 1);
$q$, 'fk_balances__account');

-- Two constraints enforce this, and which one fires first is now decided by
-- assign_entry_seq, which materialises the cache row for (account, currency)
-- before the entry lands. Both are asserted; neither is left to ordering.
SELECT must_fail('entry currency <> account currency', $q$
    INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,
                                currency,account_seq,balance_after,effective_at)
    SELECT 't1', txn('t1','n4b'), acct('t1','customer_receivable'), 'debit', 500, 'EUR', 1, 500,
           now();
$q$, 'fk_balances__account');

SELECT must_fail('an entry whose currency its account does not hold, cache pre-seeded', $q$
    -- with the cache row already present for the WRONG currency's account, the
    -- entries FK is the one that must speak
    ALTER TABLE ledger_entries DISABLE TRIGGER ck_entries__seq;
    INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,
                                currency,account_seq,balance_after,effective_at)
    SELECT 't1', txn('t1','n4c'), acct('t1','customer_receivable'), 'debit', 500, 'EUR', 1, 500,
           now();
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

-- 10b. ...and so must a NULL one. `NULL NOT IN (...)` is NULL, not TRUE, so a nil
--      *string from Go fell straight through the guard and returned the empty,
--      trivially-BALANCED report the guard exists to prevent.
SELECT must_fail('NULL as-of axis', $q$
    SELECT * FROM accounting_equation(NULL, now(), NULL);
$q$, 'unknown axis');

-- 10c. THE EQUATION ITSELF MUST BE ABLE TO FAIL.
--
--      Mutation testing showed that hardcoding `balanced := true` passed the whole
--      suite: no control existed in which the accounting equation was the thing
--      that failed. Writing one surfaced something worth stating plainly.
--
--      RECLASSIFYING AN ACCOUNT CANNOT MAKE THE EQUATION FALSE. The debit-positive
--      sum over ALL categories is zero whenever debits equal credits, so moving an
--      amount between category buckets leaves the identity intact. Given the
--      per-transaction balance invariant, A = L + E + (R - X) is a COROLLARY, not
--      an independent check.
--
--      So its real job is detecting state that got in some other way -- and the
--      only way to produce that is to bypass the trigger, which is what corruption,
--      a restore, or a replication apply would do.
SELECT must_fail('the accounting equation, made false', $q$
    ALTER TABLE ledger_entries      DISABLE TRIGGER ck_entries__balances;
    ALTER TABLE ledger_transactions DISABLE TRIGGER ck_txn__has_entries;
    DO $d$ DECLARE t uuid := txn('t1','n10c'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit', 500);
    END $d$;
    ALTER TABLE ledger_entries      ENABLE ALWAYS TRIGGER ck_entries__balances;
    ALTER TABLE ledger_transactions ENABLE ALWAYS TRIGGER ck_txn__has_entries;
    DO $d$ DECLARE r record; BEGIN
        FOR r IN SELECT * FROM accounting_equation('t1') LOOP
            IF NOT r.balanced THEN
                RAISE EXCEPTION 'EQUATION IS FALSE: lhs=% rhs=%', r.lhs, r.rhs;
            END IF;
        END LOOP;
    END $d$;
$q$, 'equation is false');

-- 10d. a CONTRA account must SUBTRACT. The equation normalised each account to its
--      own normal_balance and then summed those into category buckets, so
--      allowance_for_credit_losses (asset/CREDIT) added +100 to assets instead of
--      -100 -- wrong on the exact account the design cites as its hard case, and
--      still reporting balanced=true.
SELECT must_fail('a contra-asset that adds to assets', $q$
    DO $d$ DECLARE t uuid := txn('t1','n10d'); BEGIN
        PERFORM entry('t1', t, acct('t1','credit_loss_expense'),         'debit',  100);
        PERFORM entry('t1', t, acct('t1','allowance_for_credit_losses'), 'credit', 100);
    END $d$;
    SET CONSTRAINTS ALL IMMEDIATE;
    DO $d$ DECLARE v bigint; BEGIN
        SELECT balance_debit_positive INTO v FROM trial_balance
         WHERE tenant_id='t1' AND purpose='allowance_for_credit_losses';
        IF v <> -100 THEN
            RAISE EXCEPTION 'CONTRA ACCOUNT HAS THE WRONG SIGN: %', v;
        END IF;
        RAISE EXCEPTION 'CONTRA-OK';   -- expected: the control passes by raising this
    END $d$;
$q$, 'contra-ok');

-- 10d-bis. The state assertion itself must be PER CURRENCY. It grouped by
--      (tenant, purpose) alone, so an account holding 100.00 USD and 100.00 EUR
--      read as 20000 -- adding minor units across denominations, in the very
--      assertion that guards against exactly that.
SELECT must_fail('a state assertion that adds EUR to USD', $q$
    DO $d$ DECLARE t uuid := txn('t1','n10dbis'); BEGIN
        PERFORM entry('t1', t, acct('t1','interchange_revenue','EUR'), 'credit', 10000, 'EUR');
        PERFORM entry('t1', t, acct('t1','customer_receivable'),       'debit',  10000, 'USD');
    END $d$;
    SET CONSTRAINTS ALL IMMEDIATE;
$q$, 'does not balance');

-- 10e. the balance sheet must balance, including un-closed earnings
SELECT must_fail('balance sheet that does not balance', $q$
    DO $d$ DECLARE r record; BEGIN
        FOR r IN SELECT * FROM balance_sheet_balances() LOOP
            IF NOT r.balanced THEN
                RAISE EXCEPTION 'BALANCE SHEET IS OUT by %',
                    r.assets - r.liabilities_and_equity;
            END IF;
        END LOOP;
        RAISE EXCEPTION 'BS-OK';
    END $d$;
$q$, 'bs-ok');

-- 10f. an account may not disagree with its type on normal_balance ALONE. Control
--      8 differs on BOTH fields, so it passed even when the trigger checked only
--      category.
SELECT must_fail('account matching its type category but not its normal balance', $q$
    INSERT INTO ledger_accounts (tenant_id,owner_type,owner_id,purpose,category,normal_balance,currency)
    VALUES ('t1','house',NULL,'fbo_cash','asset','credit','USD');
$q$, 'but type');

-- 10g. the statement line an account reports under may not be silently rewritten
SELECT must_fail('moving a type to a different statement line', $q$
    UPDATE account_types SET fs_line='other_assets' WHERE code='interchange_revenue';
$q$, 'cannot move');

-- 10h. a lowercase currency code splits "per currency" on spelling
SELECT must_fail('lowercase currency code', $q$
    INSERT INTO ledger_accounts (tenant_id,owner_type,owner_id,purpose,category,normal_balance,currency)
    VALUES ('t1','house',NULL,'fbo_cash','asset','debit','usd');
$q$, 'currency_iso');

-- 10i. account_seq orders history. A client-chosen one is refused outright now --
--      it must be the number the balance upsert issued -- which subsumes the
--      positivity CHECK on the posting path. Both are asserted: the trigger on the
--      path callers use, and the CHECK on a direct write that skips it.
-- account_seq is ASSIGNED from the journal now, so a client-chosen one is not
-- refused -- it is DISCARDED, which is stronger. Asserted rather than described.
DO $$
DECLARE t uuid; v_seq bigint;
BEGIN
    t := txn('t1','n10i');
    PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  5, 'USD', 4242);
    PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 5, 'USD', 9999);
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    SELECT max(account_seq) INTO v_seq FROM ledger_entries
     WHERE tenant_id='t1' AND account_id = acct('t1','customer_receivable');
    IF v_seq > 100 THEN
        RAISE EXCEPTION 'a client-supplied account_seq survived: %', v_seq;
    END IF;
    RAISE NOTICE 'ok  a client-supplied account_seq is discarded, not honoured (got %)', v_seq;
END $$;

-- 10j. an entry may not disagree with its transaction about when it happened
SELECT must_fail('entry effective_at disagreeing with its transaction', $q$
    DO $d$
    DECLARE t uuid := txn('t1','n10j');
    BEGIN
        INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,
                                    amount_minor,currency,account_seq,balance_after,effective_at)
        VALUES ('t1', t, acct('t1','customer_receivable'), 'debit', 5,'USD',900,5,
                (SELECT effective_at - interval '27 years' FROM ledger_transactions
                  WHERE tenant_id='t1' AND id = t));
    END $d$;
$q$, 'fk_entries__txn_effective');

-- 11. the same idempotency key twice
SELECT must_fail('duplicate idempotency key', $q$
    SELECT txn('t1','dup'), txn('t1','dup');
$q$, 'uq_events__idempotency');

-- 11b. the alarm must cover ledger_account_balances -- the copy the hot path reads
--      and the ONLY one the app role may UPDATE. It was outside the view entirely.
SELECT must_fail('cached balance desynchronised from the journal', $q$
    DO $d$ DECLARE t uuid := txn('t1','n11b'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  600);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 600);
    END $d$;
    SET CONSTRAINTS ALL IMMEDIATE;
    -- entry() maintains the cache now, so the row exists: desynchronise it rather
    -- than inserting a phantom (which would test uq/pk, not the alarm).
    UPDATE ledger_account_balances SET input = input + 99999999
     WHERE tenant_id='t1' AND account_id = acct('t1','customer_receivable');
    DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM ledger_balance_drift) THEN
            RAISE EXCEPTION 'DRIFT DETECTED: %',
                (SELECT problem FROM ledger_balance_drift LIMIT 1);
        END IF;
    END $d$;
$q$, 'drift detected');

-- 12. the corruption alarm: tamper with a stored running balance
SELECT must_fail('balance_after tampered with', $q$
    DO $d$ DECLARE t uuid := txn('t1','n12'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  900);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 900);
    END $d$;
    SET CONSTRAINTS ALL IMMEDIATE;
    -- the FIRST entry, not the last. The alarm compared only last_value() against
    -- a full-partition sum, so corrupting any intermediate running balance was
    -- invisible -- and those are exactly the rows an as-of read returns.
    ALTER TABLE ledger_entries DISABLE TRIGGER ck_entries__immutable;
    UPDATE ledger_entries SET balance_after = balance_after + 1
     WHERE account_id = acct('t1','customer_receivable') AND account_seq = 1;
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

-- ---------------------------------------------------------------- alarm branches
--
-- Mutation testing showed the drift view was tested only as "does it return ANY
-- row" -- every individual branch could be deleted and the suite stayed green.
-- Each branch now has a control that makes THAT branch the reason a test fails.

-- An INTERMEDIATE running balance. The alarm once compared only last_value()
-- against a full-partition sum, so corrupting any row but the last was invisible
-- -- and those are exactly the rows an as-of read returns.
SELECT must_fail('an intermediate balance_after', $q$
    DO $d$ DECLARE t uuid := txn('t1','d1'); BEGIN
        PERFORM entry('t1', t, acct('t1','fee_revenue'),         'credit', 300);
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  300);
    END $d$;
    DO $d$ DECLARE t uuid := txn('t1','d2'); BEGIN
        PERFORM entry('t1', t, acct('t1','fee_revenue'),         'credit', 400);
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  400);
    END $d$;
    SET CONSTRAINTS ALL IMMEDIATE;
    -- entries are immutable, so this corruption is only reachable with the guard
    -- lifted -- which is the point: the alarm exists for damage that got in some
    -- other way (a restore, a replication bug, a direct write)
    ALTER TABLE ledger_entries DISABLE TRIGGER ck_entries__immutable;
    UPDATE ledger_entries SET balance_after = balance_after + 5
     WHERE tenant_id='t1' AND account_id = acct('t1','fee_revenue') AND account_seq = 1;
    DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM ledger_balance_drift
                    WHERE problem LIKE 'running balance diverges%') THEN
            RAISE EXCEPTION 'DRIFT: %', (SELECT problem FROM ledger_balance_drift LIMIT 1);
        END IF;
    END $d$;
$q$, 'drift: running balance diverges');

-- GROSS TURNOVER. input and output are stored separately precisely so gross
-- turnover is free -- and it was the one thing nothing validated: adding the same
-- amount to both left the difference intact and the alarm silent.
-- Seeded at top level, not inside must_fail: each control is rolled back, so a
-- seed inside one leaves nothing for its own tamper to act on.
DO $$ DECLARE t uuid := txn('t1','gross_seed'); BEGIN
    PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  600);
    PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 600);
END $$;
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

-- GROSS TURNOVER. input and output are stored separately precisely so gross
-- turnover is free -- and it was the one thing nothing validated: adding the same
-- amount to both left the difference intact and the alarm silent.
SELECT must_fail('fabricated gross turnover', $q$
    UPDATE ledger_account_balances SET input = input + 999999, output = output + 999999
     WHERE tenant_id='t1' AND account_id = acct('t1','customer_receivable');
    DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM ledger_balance_drift
                    WHERE problem LIKE '%gross turnover%') THEN
            RAISE EXCEPTION 'DRIFT: gross turnover';
        END IF;
    END $d$;
$q$, 'drift: gross turnover');

-- last_seq drives the next account_seq; poisoned, it is a per-account denial of
-- service upward and silent corruption downward.
SELECT must_fail('a poisoned last_seq', $q$
    UPDATE ledger_account_balances SET last_seq = last_seq + 40
     WHERE tenant_id='t1' AND account_id = acct('t1','customer_receivable');
    DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM ledger_balance_drift
                    WHERE problem LIKE '%last_seq%') THEN
            RAISE EXCEPTION 'DRIFT: last_seq';
        END IF;
    END $d$;
$q$, 'drift: last_seq');

-- ---------------------------------------------------------------- new guards
--
-- Each of these landed as a new trigger or a new RAISE and arrived without a
-- control that makes it the reason a test fails.

-- An account's purpose decides which statement line its whole history reports
-- under; re-pointing it at a same-shaped type moved that history silently.
-- Its own tenant: t1 already holds both revenue accounts, so the re-point would
-- collide on uq_accounts__house before ever reaching the guard under test.
SELECT must_fail('re-pointing an account that has entries', $q$
    INSERT INTO ledger_accounts (tenant_id,owner_type,owner_id,purpose,category,normal_balance,currency)
    SELECT 't3','house',NULL,code,category,normal_balance,'USD'
      FROM account_types WHERE code IN ('interchange_revenue','customer_receivable');
    DO $d$ DECLARE t uuid := txn('t3','rp1'); BEGIN
        PERFORM entry('t3', t, acct('t3','customer_receivable'), 'debit',  200);
        PERFORM entry('t3', t, acct('t3','interchange_revenue'), 'credit', 200);
    END $d$;
    SET CONSTRAINTS ALL IMMEDIATE;
    UPDATE ledger_accounts SET purpose='fee_revenue'
     WHERE tenant_id='t3' AND purpose='interchange_revenue';
$q$, 'cannot re-point');

-- fs_lines had no guard at all while account_types.fs_line had one.
-- 'revenue', not 'equity': the guard counts accounts reporting under the line, and
-- the fixture has no equity account, so that version asserted nothing.
SELECT must_fail('moving a statement line to the other statement', $q$
    UPDATE fs_lines SET statement='balance_sheet' WHERE code='revenue';
$q$, 'cannot move statement line');

-- An unknown tenant must RAISE. bool_and() over zero rows is NULL, and the
-- idiomatic `for rows.Next() { if !balanced }` loop passes on an empty result --
-- the green check that did not execute, reached through the tenant parameter
-- instead of the axis one.
SELECT must_fail('an unknown tenant, on the equation', $q$
    SELECT * FROM accounting_equation('T1');
$q$, 'unknown tenant');
SELECT must_fail('an unknown tenant, on the balance sheet', $q$
    SELECT * FROM balance_sheet_balances('nope');
$q$, 'unknown tenant');

-- THE BALANCE SHEET MUST BE ABLE TO FAIL. Hardcoding balanced := true passed the
-- whole suite: every balance-sheet mutation that was caught was caught only
-- because the function still computed, and the completeness control raises its own
-- sentinel so it passes on any state.
SELECT must_fail('a balance sheet that does not balance', $q$
    ALTER TABLE ledger_entries      DISABLE TRIGGER ck_entries__balances;
    ALTER TABLE ledger_transactions DISABLE TRIGGER ck_txn__has_entries;
    DO $d$ DECLARE t uuid := txn('t1','bs1'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit', 12345);
    END $d$;
    ALTER TABLE ledger_entries      ENABLE ALWAYS TRIGGER ck_entries__balances;
    ALTER TABLE ledger_transactions ENABLE ALWAYS TRIGGER ck_txn__has_entries;
    DO $d$ DECLARE r record; BEGIN
        FOR r IN SELECT * FROM balance_sheet_balances('t1') LOOP
            IF NOT r.balanced THEN
                RAISE EXCEPTION 'BALANCE SHEET IS OUT by %',
                    r.assets - r.liabilities_and_equity;
            END IF;
        END LOOP;
    END $d$;
$q$, 'balance sheet is out');

-- ---------------------------------------------------------------- untested tier
--
-- Mutation testing found a whole tier of constraints that could be deleted with
-- the suite green, plus two properties reachable only through a column no
-- assertion read. Each of these now makes its constraint the reason a test fails.

-- direction carries the sign, so a NEGATIVE amount is a silent sign inversion that
-- still "balances" and that every downstream check tolerates
SELECT must_fail('a negative amount_minor', $q$
    INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,
                                currency,account_seq,balance_after,effective_at)
    SELECT 't1', txn('t1','neg_amt'), acct('t1','customer_receivable'), 'debit', -500,'USD',
           1, -500, now();
$q$, 'ck_entries__amount_positive');

SELECT must_fail('a zero amount_minor', $q$
    INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,
                                currency,account_seq,balance_after,effective_at)
    SELECT 't1', txn('t1','zero_amt'), acct('t1','customer_receivable'), 'debit', 0,'USD',
           1, 0, now();
$q$, 'ck_entries__amount_positive');

-- the ENTRY-level currency check, distinct from the account-level one: it is what
-- stops 'usd' entries splitting an account's per-currency balance
-- assign_entry_seq materialises the cache row first, so its ISO check speaks
-- first. Both are asserted rather than depending on trigger order.
SELECT must_fail('a lowercase currency, via the cache', $q$
    INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,
                                currency,account_seq,balance_after,effective_at)
    SELECT 't1', txn('t1','lc_entry'), acct('t1','customer_receivable'), 'debit', 5,'usd',
           1, 5, now();
$q$, 'ck_balances__currency_iso');

SELECT must_fail('a lowercase currency on an entry', $q$
    ALTER TABLE ledger_entries DISABLE TRIGGER ck_entries__seq;
    INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,
                                currency,account_seq,balance_after,effective_at)
    SELECT 't1', txn('t1','lc_entry2'), acct('t1','customer_receivable'), 'debit', 5,'usd',
           1, 5, now();
$q$, 'ck_entries__currency_iso');

-- account_seq uniqueness. A duplicate is no longer expressible through an INSERT
-- at all -- the engine assigns the sequence, so a client-supplied one is discarded
-- and the index has become a backstop rather than the guard. It is tested as a
-- backstop: with the assignment lifted, the index must still refuse.
SELECT must_fail('a duplicate account_seq, with assignment lifted', $q$
    ALTER TABLE ledger_entries DISABLE TRIGGER ck_entries__seq;
    DO $d$ DECLARE t uuid := txn('t1','dup_seq'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  10, 'USD', 1);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 10, 'USD', 1);
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  10, 'USD', 1);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 10, 'USD', 1);
    END $d$;
$q$, 'uq_entries__account_seq');

-- the cache is the only table the app role may UPDATE; both its guards were dead
SELECT must_fail('a cached balance for an account that does not exist', $q$
    INSERT INTO ledger_account_balances (tenant_id,account_id,currency,input,output,last_seq)
    VALUES ('t1','00000000-0000-7000-8000-0000000000ff','USD',0,0,0);
$q$, 'fk_balances__account');

SELECT must_fail('a negative cached input', $q$
    -- its own data: must_fail rolls each control back, so without this the UPDATE
    -- matches no rows and the control asserts nothing
    DO $d$ DECLARE t uuid := txn('t1','neg_cache'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  30);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 30);
    END $d$;
    SET CONSTRAINTS ALL IMMEDIATE;
    UPDATE ledger_account_balances SET input = -1
     WHERE tenant_id='t1' AND account_id = acct('t1','customer_receivable');
$q$, 'ck_balances__non_negative');

-- the reversal / resolution model: shipped, and until now entirely unexercised
SELECT must_fail('a transaction that both resolves and reverses', $q$
    INSERT INTO ledger_events (tenant_id,kind,source,idempotency_key,idempotency_hash,
                               payload,effective_at)
    VALUES ('t1','neg','internal','both',sha256('both'),'{}',now());
    INSERT INTO ledger_transactions (tenant_id,id,event_id,kind,status,effective_at,
                                     resolves_id,reverses_id)
    SELECT 't1','0b0b0b0b-0000-7000-8000-00000000000b',id,'neg','posted',now(),
           '0b0b0b0b-0000-7000-8000-00000000000c','0b0b0b0b-0000-7000-8000-00000000000d'
      FROM ledger_events WHERE tenant_id='t1' AND idempotency_key='both';
$q$, 'ck_txn__not_both');

-- ...and a transaction may be reversed only once. The reversals are given a fixed
-- target id so the control cannot silently degrade to reverses_id IS NULL, where
-- the partial index does not apply and nothing is tested.
SELECT must_fail('reversing the same transaction twice', $q$
    DO $d$
    DECLARE tgt uuid := '0a0a0a0a-0000-7000-8000-00000000000a'; i int;
    BEGIN
        INSERT INTO ledger_events (tenant_id,kind,source,idempotency_key,idempotency_hash,
                                   payload,effective_at)
        VALUES ('t1','neg','internal','rev_tgt',sha256(convert_to('rev_tgt','UTF8')),'{}',now());
        INSERT INTO ledger_transactions (tenant_id,id,event_id,kind,status,effective_at)
        SELECT 't1',tgt,id,'neg','posted',now() FROM ledger_events
         WHERE tenant_id='t1' AND idempotency_key='rev_tgt';
        FOR i IN 1..2 LOOP
            INSERT INTO ledger_events (tenant_id,kind,source,idempotency_key,idempotency_hash,
                                       payload,effective_at)
            VALUES ('t1','neg','internal','rev'||i,sha256(convert_to('rev'||i,'UTF8')),'{}',now());
            INSERT INTO ledger_transactions (tenant_id,event_id,kind,status,effective_at,reverses_id)
            SELECT 't1',id,'neg','posted',now(),tgt FROM ledger_events
             WHERE tenant_id='t1' AND idempotency_key='rev'||i;
        END LOOP;
    END $d$;
$q$, 'uq_txn__one_reversal');

-- a transaction may not cite an event that does not exist
SELECT must_fail('a transaction citing a nonexistent event', $q$
    INSERT INTO ledger_transactions (tenant_id,event_id,kind,status,effective_at)
    VALUES ('t1','00000000-0000-7000-8000-0000000000ee','neg','posted',now());
$q$, 'fk_txn__event');

-- normal_balance was reachable ONLY through trial_balance.balance_minor, and no
-- assertion read it -- so flipping the flagship contra account, the one the chart
-- cites as proof that normal_balance is not derivable from category, was invisible
DO $$
DECLARE v_presented bigint; v_arith bigint; t uuid;
BEGIN
    t := txn('t1','contra_pair');
    PERFORM entry('t1', t, acct('t1','credit_loss_expense'),         'debit',  700);
    PERFORM entry('t1', t, acct('t1','allowance_for_credit_losses'), 'credit', 700);
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;   -- restore, or every later txn() fires at INSERT
    SELECT balance_minor, balance_debit_positive INTO v_presented, v_arith
      FROM trial_balance WHERE tenant_id='t1' AND purpose='allowance_for_credit_losses';
    -- asset with a CREDIT normal balance: presented POSITIVE, arithmetic NEGATIVE
    IF v_presented <> 700 OR v_arith <> -700 THEN
        RAISE EXCEPTION 'contra account presented %/arithmetic % (expected 700/-700)',
            v_presented, v_arith;
    END IF;
    RAISE NOTICE 'ok  a contra asset presents +700 and computes -700';
END $$;

-- ---------------------------------------------------------------- completeness
--
-- ADR-0009's headline -- "reports enumerate from the chart outward" -- was not
-- attested at all: turning the CROSS JOIN into an INNER JOIN, and reverting the
-- scope set from ledger_accounts back to ledger_entries, both left the suite green.
-- Every balance-sheet assertion was a BALANCING assertion, and a report that drops
-- a line or a whole scope still balances.

-- a statement line with NO activity must appear as a zero, not vanish
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM balance_sheet
     WHERE tenant_id='t1' AND currency='USD' AND fs_line='customer_funds' AND amount_minor = 0;
    IF n <> 1 THEN
        RAISE EXCEPTION 'a balance-sheet line with no activity did not appear as zero (got % rows)', n;
    END IF;
    SELECT count(*) INTO n FROM income_statement
     WHERE tenant_id='t1' AND currency='USD' AND fs_line='interest' AND amount_minor = 0;
    IF n <> 1 THEN
        RAISE EXCEPTION 'an income-statement line with no activity did not appear as zero (got %)', n;
    END IF;
    RAISE NOTICE 'ok  statement lines with no activity report zero rather than vanishing';
END $$;

-- ...and a SCOPE that has been opened but has not posted must appear too. This is
-- the dropped-sub-book threat ADR-0009 names as the real one.
DO $$
DECLARE n int;
BEGIN
    INSERT INTO ledger_accounts (tenant_id,owner_type,owner_id,purpose,category,normal_balance,currency)
    SELECT 'ghost','house',NULL,code,category,normal_balance,'USD'
      FROM account_types WHERE code='operating_cash';
    SELECT count(*) INTO n FROM balance_sheet WHERE tenant_id='ghost';
    IF n = 0 THEN
        RAISE EXCEPTION 'a scope with accounts but no entries vanished from the balance sheet';
    END IF;
    SELECT count(*) INTO n FROM accounting_equation('ghost');
    IF n <> 1 THEN
        RAISE EXCEPTION 'the equation returned % rows for a scope with no entries', n;
    END IF;
    RAISE NOTICE 'ok  a scope with accounts and no entries reports zeros, not nothing';
END $$;

-- ---------------------------------------------------------------- ENABLE ALWAYS
--
-- "A subscriber must enforce the same invariant as its publisher, or replication
-- is a laundering channel for corrupt rows." That property was attested for ONE
-- trigger out of six: only ck_entries__balances had a replica-role control, so
-- dropping ENABLE ALWAYS from any of the others was free.
--
-- session_replication_role='replica' is the logical-replication apply path and
-- what `pg_restore --disable-triggers` sets.

SELECT must_fail('replica: a transaction with too few entries', $q$
    SET LOCAL session_replication_role = 'replica';
    SELECT txn('t1','repl_empty');
$q$, 'needs at least two');
RESET ROLE;

SELECT must_fail('replica: appending to a committed transaction', $q$
    SET LOCAL session_replication_role = 'replica';
    INSERT INTO ledger_events (tenant_id,kind,source,idempotency_key,idempotency_hash,
                               payload,effective_at)
    VALUES ('t1','neg','internal','repl_seal',sha256(convert_to('repl_seal','UTF8')),'{}',now());
    INSERT INTO ledger_transactions (tenant_id,id,event_id,kind,status,effective_at,xact_id)
    SELECT 't1','0c0c0c0c-0000-7000-8000-00000000c0de',id,'neg','posted',now(),
           pg_current_xact_id()::text::bigint - 1
      FROM ledger_events WHERE tenant_id='t1' AND idempotency_key='repl_seal';
    INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,
                                currency,account_seq,balance_after,effective_at)
    SELECT 't1','0c0c0c0c-0000-7000-8000-00000000c0de',
           acct('t1','customer_receivable'),'debit',10,'USD',900,10,
           (SELECT effective_at FROM ledger_transactions
             WHERE id='0c0c0c0c-0000-7000-8000-00000000c0de');
$q$, 'sealed');
RESET ROLE;

SELECT must_fail('replica: an account disagreeing with its type', $q$
    SET LOCAL session_replication_role = 'replica';
    INSERT INTO ledger_accounts (tenant_id,owner_type,owner_id,purpose,category,normal_balance,currency)
    VALUES ('t1','house',NULL,'fbo_cash','liability','credit','USD');
$q$, 'but type');
RESET ROLE;

SELECT must_fail('replica: re-pointing an account that has entries', $q$
    SET LOCAL session_replication_role = 'replica';
    INSERT INTO ledger_accounts (tenant_id,owner_type,owner_id,purpose,category,normal_balance,currency)
    SELECT 't4','house',NULL,code,category,normal_balance,'USD'
      FROM account_types WHERE code IN ('interchange_revenue','customer_receivable');
    DO $d$ DECLARE t uuid := txn('t4','rp_repl'); BEGIN
        PERFORM entry('t4', t, acct('t4','customer_receivable'), 'debit',  200);
        PERFORM entry('t4', t, acct('t4','interchange_revenue'), 'credit', 200);
    END $d$;
    SET CONSTRAINTS ALL IMMEDIATE;
    UPDATE ledger_accounts SET purpose='fee_revenue'
     WHERE tenant_id='t4' AND purpose='interchange_revenue';
$q$, 'cannot re-point');
RESET ROLE;

SELECT must_fail('replica: reclassifying a type that has accounts', $q$
    SET LOCAL session_replication_role = 'replica';
    UPDATE account_types SET category='expense', normal_balance='debit'
     WHERE code='interchange_revenue';
$q$, 'cannot reclassify');
RESET ROLE;

SELECT must_fail('replica: moving a statement line', $q$
    SET LOCAL session_replication_role = 'replica';
    UPDATE fs_lines SET statement='balance_sheet' WHERE code='revenue';
$q$, 'cannot move statement line');
RESET ROLE;

-- account_seq is ASSIGNED, so under replica the property to check is that the
-- assignment still happens -- a client-chosen sequence must be discarded there too,
-- which is what ENABLE ALWAYS on ck_entries__seq buys.
DO $$
DECLARE t uuid; v_seq bigint;
BEGIN
    SET LOCAL session_replication_role = 'replica';
    t := txn('t1','repl_seq');
    PERFORM entry('t1', t, acct('t1','fee_revenue'),         'credit', 5, 'USD', 777);
    PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  5, 'USD', 888);
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    SELECT max(account_seq) INTO v_seq FROM ledger_entries
     WHERE tenant_id='t1' AND account_id = acct('t1','fee_revenue');
    IF v_seq > 100 THEN
        RAISE EXCEPTION 'under replica, a client-supplied account_seq survived: %', v_seq;
    END IF;
    RAISE NOTICE 'ok  replica: a client-supplied account_seq is still discarded (got %)', v_seq;
    -- ...and PUT IT BACK. `SET LOCAL` in a DO block that SUCCEEDS persists for the
    -- rest of the transaction, and `RESET ROLE` does not touch it -- they are
    -- different settings. This block was the leak: every control after it, more
    -- than two hundred lines of them, ran on the replication apply path ONLY.
    -- Decisive proof, from the reviewer: `ALTER TABLE account_types ENABLE REPLICA
    -- TRIGGER ck_types__matches_fs_line` -- which makes the trigger fire on the
    -- replica path and NOWHERE ELSE -- passed the entire suite.
    RESET session_replication_role;
END $$;

CREATE FUNCTION on_origin(p_where text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF current_setting('session_replication_role') <> 'origin' THEN
        RAISE EXCEPTION
            'session_replication_role is % at %: every control from here on runs '
            'on the replication apply path only, and the ordinary write path is '
            'untested', current_setting('session_replication_role'), p_where;
    END IF;
    RAISE NOTICE 'ok  still on the ordinary write path at %', p_where;
END $$;

SELECT on_origin('the end of the replica block');

SELECT must_fail('replica: mutating a committed transaction', $q$
    SET LOCAL session_replication_role = 'replica';
    DO $d$ DECLARE t uuid := txn('t1','repl_mut'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  15);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 15);
        UPDATE ledger_transactions SET kind='changed' WHERE id = t;
    END $d$;
$q$, 'is immutable');
RESET ROLE;

-- ---------------------------------------------------------------- undefended guards
--
-- Mutation testing found several guards that are the SOLE defence of a property
-- and are themselves undefended: no-op them and nothing fails. Each now has a
-- control that makes it the reason a test fails.

-- ck_types__matches_fs_line is the only thing standing between a revenue type and
-- an expense caption -- the harm ADR-0009 is entirely about. Every seed-chart side
-- mutation was caught BY THIS TRIGGER at migration time, so the trigger defended
-- the chart and nothing defended the trigger.
SELECT must_fail('a revenue type on an expense line', $q$
    INSERT INTO account_types (code,category,normal_balance,description,fs_line)
    VALUES ('probe_rev','revenue','credit','x','cost_of_revenue');
$q$, 'cannot report under statement line');
SELECT must_fail('an asset type on an income-statement line', $q$
    INSERT INTO account_types (code,category,normal_balance,description,fs_line)
    VALUES ('probe_ast','asset','debit','x','revenue');
$q$, 'cannot report under statement line');
SELECT must_fail('a liability type on the asset side', $q$
    INSERT INTO account_types (code,category,normal_balance,description,fs_line)
    VALUES ('probe_liab','liability','credit','x','cash');
$q$, 'cannot report under statement line');
SELECT must_fail('an expense type on the credit side', $q$
    INSERT INTO account_types (code,category,normal_balance,description,fs_line)
    VALUES ('probe_exp','expense','debit','x','revenue');
$q$, 'cannot report under statement line');
SELECT must_fail('a statement line whose side does not belong to its statement', $q$
    INSERT INTO fs_lines (code,caption,statement,side,sort_order)
    VALUES ('probe_line','x','balance_sheet','credit',9999);
$q$, 'ck_fs_lines__side_matches_statement');

-- ...and the side half of the stability guard, which was separately dead
SELECT must_fail('flipping a live statement line''s side', $q$
    UPDATE fs_lines SET side='liability_equity' WHERE code='receivables';
$q$, 'cannot move statement line');

-- enforce_triggers_on_replicas() is the round-3 critical fix and shipped with no
-- test: no-op its body, or delete any CALL, and nothing failed. Assert the state
-- it exists to produce.
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM pg_trigger tg
      JOIN pg_class c ON c.oid = tg.tgrelid
      JOIN pg_namespace ns ON ns.oid = c.relnamespace
     WHERE ns.nspname = 'public' AND tg.tgisinternal AND tg.tgenabled = 'O';
    IF n > 0 THEN
        RAISE EXCEPTION
            '% internal trigger(s) are still ENABLE ORIGIN, so their foreign keys '
            'are skipped on the replication apply path: %', n,
            (SELECT string_agg(c.relname||'.'||tg.tgname, ', ') FROM pg_trigger tg
               JOIN pg_class c ON c.oid=tg.tgrelid
               JOIN pg_namespace ns ON ns.oid=c.relnamespace
              WHERE ns.nspname='public' AND tg.tgisinternal AND tg.tgenabled='O');
    END IF;
    RAISE NOTICE 'ok  every foreign key is enforced on the replication apply path';
END $$;

-- assign_recorded_at could be no-op'd undetected, because DEFAULT now() masks it.
-- The property is that a SUPPLIED value is overwritten.
DO $$
DECLARE t uuid; v_rec timestamptz;
BEGIN
    INSERT INTO ledger_events (tenant_id,kind,source,idempotency_key,idempotency_hash,
                               payload,effective_at,recorded_at)
    VALUES ('t1','neg','internal','rec_probe',sha256(convert_to('rec_probe','UTF8')),
            '{}',now(),'1999-01-01');
    SELECT recorded_at INTO v_rec FROM ledger_events
     WHERE tenant_id='t1' AND idempotency_key='rec_probe';
    IF v_rec < '2020-01-01' THEN
        RAISE EXCEPTION 'a supplied recorded_at survived on ledger_events: %', v_rec;
    END IF;

    t := txn('t1','rec_probe2');
    PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  40);
    PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 40);
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    SELECT min(recorded_at) INTO v_rec FROM ledger_entries WHERE transaction_id = t;
    IF v_rec < '2020-01-01' THEN
        RAISE EXCEPTION 'a supplied recorded_at survived on ledger_entries: %', v_rec;
    END IF;
    RAISE NOTICE 'ok  a supplied recorded_at is overwritten, not honoured';
END $$;

-- the alarm's 'cached balance with no entries' branch was unreachable from the
-- suite, so FULL OUTER could be demoted to LEFT undetected
SELECT must_fail('a cached balance for an account with no journal', $q$
    INSERT INTO ledger_account_balances (tenant_id,account_id,currency,input,output,last_seq)
    VALUES ('t1', acct('t1','fbo_cash'), 'USD', 7777, 0, 1);
    DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM ledger_balance_drift
                    WHERE problem LIKE '%no entries%') THEN
            RAISE EXCEPTION 'ORPHAN CACHE DETECTED';
        END IF;
    END $d$;
$q$, 'orphan cache detected');

-- ===================================== round 4: erasure, and false linkage
--
-- Four of these made every report GREEN while the books were false. That is the
-- shape worth the most controls: not an error, but a silence.

-- The journal cannot be emptied. TRUNCATE left 11 transactions standing with zero
-- entries, all three currencies reporting balanced = t, and every drift view at
-- zero rows -- there was nothing left to disagree with. The comment beside the
-- REVOKEs used to say "nothing in SQL can stop that", which was false.
SELECT must_fail('truncating the entries', $q$ TRUNCATE ledger_entries CASCADE; $q$, 'is history');
SELECT must_fail('truncating the transactions', $q$ TRUNCATE ledger_transactions CASCADE; $q$, 'is history');
SELECT must_fail('truncating the event log', $q$ TRUNCATE ledger_events CASCADE; $q$, 'is history');
SELECT must_fail('truncating the accounts', $q$ TRUNCATE ledger_accounts CASCADE; $q$, 'is history');
SELECT must_fail('truncating as the app role', $q$
    GRANT ALL ON ledger_entries TO openledger_app;
    SET LOCAL ROLE openledger_app;
    TRUNCATE ledger_entries CASCADE;
$q$, 'is history');
RESET ROLE;
SELECT must_fail('truncating on the replication apply path', $q$
    SET LOCAL session_replication_role = 'replica';
    TRUNCATE ledger_entries CASCADE;
$q$, 'is history');
RESET ROLE;

-- ...and the standing cross-check that would have SEEN it, since a deferred
-- constraint trigger cannot: TRUNCATE is not a statement it fires on.
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM ledger_transaction_drift) THEN
        RAISE EXCEPTION 'a transaction stands without its entries';
    END IF;
    RAISE NOTICE 'ok  no transaction stands without its entries';
END $$;

-- ledger_events was the ONE table with an assign-on-insert trigger and no
-- immutability guard, so idempotency_hash -- the column whose whole job is
-- "same key, DIFFERENT body -> refuse" -- was freely rewritable, and so was the
-- recorded_at the engine had just assigned.
SELECT must_fail('rewriting an event''s idempotency hash', $q$
    UPDATE ledger_events SET idempotency_hash = sha256(convert_to('other','UTF8'));
$q$, 'is immutable');
SELECT must_fail('rewriting an event''s recorded_at', $q$
    UPDATE ledger_events SET recorded_at = '2001-01-01';
$q$, 'is immutable');
SELECT must_fail('deleting an event', $q$ DELETE FROM ledger_events; $q$, 'is immutable');
SELECT must_fail('replica: rewriting an event', $q$
    SET LOCAL session_replication_role = 'replica';
    UPDATE ledger_events SET payload = '{"x":1}';
$q$, 'is immutable');
RESET ROLE;

-- An account's OWNER was mutable while its purpose and currency were frozen.
-- 110,000 of receivable became owed by nobody: every balance identical, the trial
-- balance still balanced, drift silent -- none of them read the owner.
SELECT must_fail('re-owning an account that has entries', $q$
    UPDATE ledger_accounts SET owner_id = NULL, owner_type = 'house'
     WHERE tenant_id='t1' AND purpose='customer_receivable';
$q$, 'cannot be re-owned');
SELECT must_fail('moving an account to another tenant', $q$
    UPDATE ledger_accounts SET tenant_id='t2'
     WHERE tenant_id='t1' AND purpose='customer_receivable';
$q$, 'cannot be re-owned');
SELECT must_fail('re-denominating an account', $q$
    UPDATE ledger_accounts SET currency='EUR'
     WHERE tenant_id='t1' AND purpose='customer_receivable';
$q$, 'cannot be re-owned');
SELECT must_fail('replica: re-owning an account', $q$
    SET LOCAL session_replication_role = 'replica';
    UPDATE ledger_accounts SET owner_id = NULL WHERE tenant_id='t1';
$q$, 'cannot be re-owned');
RESET ROLE;
-- ...and annotation is still annotation
DO $$ BEGIN
    UPDATE ledger_accounts SET metadata = '{"note":"still writable"}'
     WHERE tenant_id='t1' AND purpose='customer_receivable';
    RAISE NOTICE 'ok  metadata stays mutable -- it is annotation, not identity';
END $$;

-- resolves_id and reverses_id had a foreign key, so the target had to EXIST.
-- Nothing required it to be in a state the correction makes sense against:
-- revenue went to -49,223 with drift 0 and the equation balanced, because both
-- halves were internally consistent journal entries.
SELECT must_fail('resolving an already-posted transaction', $q$
    DO $d$ DECLARE a uuid := txn('t1','r4_posted'); b uuid; BEGIN
        PERFORM entry('t1', a, acct('t1','customer_receivable'), 'debit',  100);
        PERFORM entry('t1', a, acct('t1','interchange_revenue'), 'credit', 100);
        INSERT INTO ledger_transactions (tenant_id,kind,status,effective_at,resolves_id)
        VALUES ('t1','neg','posted',now(),a) RETURNING id INTO b;
    END $d$;
$q$, 'cannot resolve');

SELECT must_fail('reversing a transaction that was never posted', $q$
    DO $d$ DECLARE a uuid; BEGIN
        INSERT INTO ledger_transactions (tenant_id,kind,status,effective_at)
        VALUES ('t1','neg','pending',now()) RETURNING id INTO a;
        PERFORM entry('t1', a, acct('t1','customer_receivable'), 'debit',  100);
        PERFORM entry('t1', a, acct('t1','interchange_revenue'), 'credit', 100);
        INSERT INTO ledger_transactions (tenant_id,kind,status,effective_at,reverses_id)
        VALUES ('t1','neg','posted',now(),a);
    END $d$;
$q$, 'cannot reverse');

SELECT must_fail('replica: reversing a pending transaction', $q$
    SET LOCAL session_replication_role = 'replica';
    DO $d$ DECLARE a uuid; BEGIN
        INSERT INTO ledger_transactions (tenant_id,kind,status,effective_at)
        VALUES ('t1','neg','pending',now()) RETURNING id INTO a;
        PERFORM entry('t1', a, acct('t1','customer_receivable'), 'debit',  100);
        PERFORM entry('t1', a, acct('t1','interchange_revenue'), 'credit', 100);
        INSERT INTO ledger_transactions (tenant_id,kind,status,effective_at,reverses_id)
        VALUES ('t1','neg','posted',now(),a);
    END $d$;
$q$, 'cannot reverse');
RESET ROLE;

-- ...and the legitimate shapes still work, or the guard above is just a wall
DO $$ DECLARE a uuid; b uuid; BEGIN
    INSERT INTO ledger_transactions (tenant_id,kind,status,effective_at)
    VALUES ('t1','neg','pending',now()) RETURNING id INTO a;
    PERFORM entry('t1', a, acct('t1','customer_receivable'), 'debit',  100);
    PERFORM entry('t1', a, acct('t1','interchange_revenue'), 'credit', 100);
    INSERT INTO ledger_transactions (tenant_id,kind,status,effective_at,resolves_id)
    VALUES ('t1','neg','posted',now(),a) RETURNING id INTO b;
    PERFORM entry('t1', b, acct('t1','customer_receivable'), 'debit',  100);
    PERFORM entry('t1', b, acct('t1','interchange_revenue'), 'credit', 100);
    INSERT INTO ledger_transactions (tenant_id,kind,status,effective_at,reverses_id)
    VALUES ('t1','neg','posted',now(),b);
    RAISE NOTICE 'ok  pending->resolved and posted->reversed are both still legal';
END $$;

-- One event, at most one transaction. Without this the "idempotency spine" does
-- not by itself prevent double-posting.
SELECT must_fail('two transactions from one event', $q$
    DO $d$ DECLARE e uuid; BEGIN
        SELECT event_id INTO e FROM ledger_transactions
         WHERE tenant_id='t1' AND event_id IS NOT NULL LIMIT 1;
        INSERT INTO ledger_transactions (tenant_id,event_id,kind,status,effective_at)
        VALUES ('t1',e,'neg','posted',now());
    END $d$;
$q$, 'uq_txn__one_per_event');

-- The derived balance-sheet plug may not be shadowed by a real chart line.
SELECT must_fail('declaring a real line called current_year_earnings', $q$
    INSERT INTO fs_lines (code,caption,statement,side,sort_order)
    VALUES ('current_year_earnings','Earnings','balance_sheet','liability_equity',999);
$q$, 'ck_fs_lines__code_reserved');

-- An EMPTY report is not a balanced one. On a freshly migrated and seeded
-- database this returned zero rows, and bool_and over zero rows is NULL.
SELECT must_fail('asking an empty ledger whether it balances', $q$
    DO $d$ BEGIN
        CREATE TEMP TABLE _probe AS SELECT * FROM accounting_equation('nobody');
    END $d$;
$q$, 'unknown tenant');

SELECT on_origin('the end of the file');

DO $$ BEGIN RAISE NOTICE 'ok  every breakage above was refused, for the stated reason'; END $$;
DO $$ BEGIN RAISE NOTICE 'ok  SUITE-COMPLETE negative_controls'; END $$;

ROLLBACK;
