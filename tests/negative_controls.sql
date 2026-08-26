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
DECLARE v_seq bigint;
BEGIN
    -- The sequence must come FROM the balance upsert, not from MAX()+1 -- the
    -- schema now enforces that, because a client-chosen seq was how a gap got
    -- created and later filled with fabricated turnover. p_seq is still honoured
    -- so the negative controls can supply a deliberately bad one.
    INSERT INTO ledger_account_balances AS b (tenant_id,account_id,currency,input,output,last_seq)
    VALUES (p_tenant,p_acct,p_ccy,
            CASE WHEN p_dir='debit'  THEN p_amt ELSE 0 END,
            CASE WHEN p_dir='credit' THEN p_amt ELSE 0 END, 1)
    ON CONFLICT (tenant_id,account_id,currency) DO UPDATE
       SET input=b.input+EXCLUDED.input, output=b.output+EXCLUDED.output,
           last_seq=b.last_seq+1
    RETURNING b.last_seq INTO v_seq;
    v_seq := COALESCE(p_seq, v_seq);

    INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,
                                currency,account_seq,balance_after,effective_at)
    VALUES (p_tenant,p_txn,p_acct,p_dir::ledger_direction,p_amt,p_ccy,v_seq,
            COALESCE(p_bal, CASE WHEN p_dir='debit' THEN p_amt ELSE -p_amt END),
            -- COALESCE: the cross-tenant control deliberately references a
            -- transaction that does not exist in this tenant, and the FK is what
            -- should reject it -- not a NOT NULL violation on the way there.
            COALESCE((SELECT effective_at FROM ledger_transactions
                       WHERE tenant_id=p_tenant AND id=p_txn), now()));

END $$;

-- The baseline must be CLEAN before any drift control runs, or those controls
-- assert nothing. This is the guard that keeps them honest.
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM ledger_balance_drift) THEN
        RAISE EXCEPTION 'drift baseline is not clean: %',
            (SELECT string_agg(problem, '; ') FROM ledger_balance_drift);
    END IF;
    RAISE NOTICE 'ok  drift baseline is clean';
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
$q$, 'does not balance');

-- 1c-bis. Deleting EVERY leg is "vacuously balanced" -- a zero-row GROUP BY finds
--     nothing, so the balance check passes. Verified before the fix: a committed
--     2-leg transaction was reduced to zero entries, the posted row survived, and
--     with its cached balances also removed the drift view returned nothing, the
--     balance sheet balanced, and the equation returned no rows at all.
SELECT must_fail('deleting EVERY leg of a committed transaction', $q$
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
SELECT must_fail('a cached balance in a currency its account does not hold', $q$
    SELECT entry('t1', txn('t1','n4'), acct('t1','customer_receivable'), 'debit', 500, 'EUR');
$q$, 'fk_balances__account');

SELECT must_fail('entry currency <> account currency', $q$
    INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,
                                currency,account_seq,balance_after,effective_at)
    SELECT 't1', txn('t1','n4b'), acct('t1','customer_receivable'), 'debit', 500, 'EUR', 1, 500,
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
SELECT must_fail('an account_seq the balance upsert did not issue', $q$
    DO $d$ DECLARE t uuid := txn('t1','n10i'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  5, 'USD', 4242);
    END $d$;
$q$, 'was not issued by the balance upsert');

SELECT must_fail('a negative account_seq', $q$
    INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,
                                currency,account_seq,balance_after,effective_at)
    SELECT 't1', txn('t1','n10i2'), acct('t1','fee_revenue'), 'credit', 5,'USD', -9999, -5, now();
$q$, 'seq_positive');

-- 10j. an entry may not disagree with its transaction about when it happened
SELECT must_fail('entry effective_at disagreeing with its transaction', $q$
    DO $d$ DECLARE t uuid := txn('t1','n10j'); BEGIN
        INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,
                                    amount_minor,currency,account_seq,balance_after,effective_at)
        VALUES ('t1', t, acct('t1','customer_receivable'), 'debit', 5,'USD',900,5,
                '1999-01-01'::timestamptz);
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
SELECT must_fail('fabricated gross turnover', $q$
    -- must_fail rolls back each control, so this one posts its own data rather
    -- than relying on a predecessor's -- otherwise the account has no entries, the
    -- UPDATE below matches nothing, and the control asserts nothing.
    DO $d$ DECLARE t uuid := txn('t1','gt1'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  600);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 600);
    END $d$;
    SET CONSTRAINTS ALL IMMEDIATE;
    UPDATE ledger_account_balances SET input = input + 999999, output = output + 999999
     WHERE tenant_id='t1' AND account_id = acct('t1','customer_receivable');
    DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM ledger_balance_drift
                    WHERE problem LIKE '%gross turnover%') THEN
            RAISE EXCEPTION 'DRIFT: gross turnover';
        END IF;
    END $d$;
$q$, 'drift: gross turnover');

-- last_seq drives the next account_seq. Poisoned downward it is a permanent
-- per-account denial of service; upward it silently corrupts balance_after.
SELECT must_fail('a poisoned last_seq', $q$
    -- must_fail rolls back each control, so this one posts its own data rather
    -- than relying on a predecessor's -- otherwise the account has no entries, the
    -- UPDATE below matches nothing, and the control asserts nothing.
    DO $d$ DECLARE t uuid := txn('t1','ls1'); BEGIN
        PERFORM entry('t1', t, acct('t1','customer_receivable'), 'debit',  600);
        PERFORM entry('t1', t, acct('t1','interchange_revenue'), 'credit', 600);
    END $d$;
    SET CONSTRAINTS ALL IMMEDIATE;
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

DO $$ BEGIN RAISE NOTICE 'ok  every breakage above was refused, for the stated reason'; END $$;

ROLLBACK;
