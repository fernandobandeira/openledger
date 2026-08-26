-- The acceptance test for the ledger core: the reference product's §06 trace,
-- one $500 purchase, end to end.
--
-- Supersedes spikes/004-chart-of-accounts/golden_trace.sql, which targeted the
-- older spike schema (it posted an idempotency_key onto ledger_transactions, a
-- column that never existed here -- idempotency lives on ledger_events, ADR-0004).
--
-- WHAT MAKES THIS A TEST. The spike version asserted only that the accounting
-- equation held. That assertion is nearly worthless on its own: re-routing
-- interchange from interchange_revenue to fee_revenue left all thirteen steps
-- reporting BALANCED with identical category totals, because both are revenue.
-- So every step here asserts the COMPLETE state -- every account, exact minor
-- amount -- and fails on an account that should not exist just as loudly as on
-- one that is missing. A mis-routed leg has nowhere to hide.

\set ON_ERROR_STOP on
-- result sets to /dev/null; the RAISE NOTICEs are the output
\o /dev/null
BEGIN;

-- MODE GUARD. `SET LOCAL session_replication_role = 'replica'` prepended to this
-- file's BEGIN made the whole suite run on the replication apply path, where a
-- guard marked ENABLE REPLICA fires and the ordinary write path is untested. That
-- is how an earlier leak went unnoticed for two hundred lines of negative
-- controls. One line per suite, at both ends.
DO $$ BEGIN
    IF current_setting('session_replication_role') <> 'origin' THEN
        RAISE EXCEPTION
            'this suite is running as %, not origin: every guard it exercises may be '
            'the replica-path one', current_setting('session_replication_role');
    END IF;
    RAISE NOTICE 'ok  running on the ordinary write path';
END $$;

-- ------------------------------------------------------------------ scopes
--
-- Two scopes, because the tenant-locality rule is a correctness rule: a
-- transaction touching one tenant's account and another's leaves BOTH views
-- unbalanced, so no transaction may span them.
--
--   t1         the card program
--   _treasury  the operator: the real bank account and the equity behind it
--
-- Perimeter accounts (operating_cash) mirror ONE external balance and therefore
-- cannot be split per tenant. That is why the intercompany pair exists.

INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose, category, normal_balance, currency)
SELECT v.tenant, v.otype::account_owner_type, v.oid, t.code, t.category, t.normal_balance, 'USD'
FROM (VALUES
  ('t1',       'company', 'acme',      'customer_receivable'),
  ('t1',       'house',   NULL,        'network_settlement_payable'),
  ('t1',       'house',   NULL,        'interchange_revenue'),
  ('t1',       'house',   NULL,        'facility_borrowings'),
  ('t1',       'house',   NULL,        'accrued_interest_payable'),
  ('t1',       'house',   NULL,        'interest_expense'),
  ('t1',       'house',   NULL,        'ach_pull_returnable'),
  ('t1',       'house',   NULL,        'due_from_treasury'),
  ('t1',       'platform','platform_a','platform_rev_share_payable'),
  ('t1',       'house',   NULL,        'platform_rev_share_expense'),
  -- opened but never posted to by the trace, so it appears in no expectation set.
  -- The stray-posting check at the end needs somewhere legitimate to go wrong.
  ('t1',       'house',   NULL,        'fee_revenue'),
  ('_treasury','bank_account','bank_a','operating_cash'),
  ('_treasury','house',   NULL,        'paid_in_capital'),
  ('_treasury','house',   NULL,        'due_to_tenants')
) AS v(tenant,otype,oid,purpose)
JOIN account_types t ON t.code = v.purpose;

-- The same PURPOSE in a second currency. Without this the trace is 100% USD, so
-- expect_state's per-currency logic is dead code and trial_balance can be made
-- currency-blind undetected -- the exact vacuity 0002 exists to remove, in the
-- assertion that checks it.
INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose, category, normal_balance, currency)
SELECT 't1', 'house', NULL, t.code, t.category, t.normal_balance, 'EUR'
FROM account_types t WHERE t.code IN ('interchange_revenue','customer_receivable');

-- ------------------------------------------------------------------ posting
--
-- One atomic upsert per leg returns the new balance AND the next sequence number
-- together, so the row lock IS the serialization -- no SELECT max(), no advisory
-- lock, no retry loop. This is the write path 0001 describes; the test exercises
-- it rather than hand-computing balances beside it.

CREATE FUNCTION post(p_tenant text, p_key text, p_legs text[]) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_event uuid; v_txn uuid; r record; v_seq bigint; v_bal bigint;
BEGIN
    INSERT INTO ledger_events (tenant_id, kind, source, idempotency_key, idempotency_hash,
                               payload, effective_at)
    VALUES (p_tenant, 'trace', 'internal', p_key,
            sha256(convert_to(p_key, 'UTF8')), to_jsonb(p_legs), now())
    RETURNING id INTO v_event;

    INSERT INTO ledger_transactions (tenant_id, event_id, kind, status, effective_at)
    VALUES (p_tenant, v_event, 'trace', 'posted', now())
    RETURNING id INTO v_txn;

    -- ORDER BY a.id IS LOAD-BEARING, not tidiness.
    --
    -- Each leg takes a row lock on its account's balance row. Two concurrent
    -- transactions touching the same two accounts in OPPOSITE leg order deadlock:
    -- measured 138 deadlocks and 138 rollbacks from 8 writers on 2 accounts, half
    -- posting the legs reversed. Every failure was a deadlock.
    --
    -- Sorting by account id gives every writer the same lock order, so one waits
    -- instead of both dying. This is what roadmap M2 means by "deterministic lock
    -- ordering" -- it was documented as a requirement and not implemented here,
    -- which is exactly the sort of gap a single-threaded suite cannot see.
    FOR r IN
        -- MATERIALIZED so the leg list drives the join. Without it the planner
        -- scans ledger_accounts on its primary key and hands back account-id order
        -- for free -- which meant `ORDER BY a.id` below could be deleted with no
        -- deadlock and no test failure. The property was being attested by the
        -- planner, not by the code.
        WITH legs AS MATERIALIZED (
            SELECT i AS ord,
                   p_legs[(i-1)*3+1] AS purpose,
                   p_legs[(i-1)*3+2]::ledger_direction AS dir,
                   p_legs[(i-1)*3+3]::bigint AS amt
            FROM generate_series(1, array_length(p_legs,1)/3) AS i)
        SELECT a.id AS account_id, l.dir, l.amt
        FROM legs l
        -- currency is part of the lookup: once the same purpose exists in two
        -- currencies, a purpose alone no longer identifies an account, and posting
        -- a USD leg against the EUR row is a foreign-key violation at best
        JOIN ledger_accounts a ON a.tenant_id = p_tenant AND a.purpose = l.purpose
                              AND a.currency = 'USD'
        ORDER BY a.id
    LOOP
        INSERT INTO ledger_account_balances AS b (tenant_id, account_id, currency, input, output, last_seq)
        VALUES (p_tenant, r.account_id, 'USD',
                CASE WHEN r.dir='debit'  THEN r.amt ELSE 0 END,
                CASE WHEN r.dir='credit' THEN r.amt ELSE 0 END, 1)
        ON CONFLICT (tenant_id, account_id, currency) DO UPDATE
           SET input    = b.input  + EXCLUDED.input,
               output   = b.output + EXCLUDED.output,
               last_seq = b.last_seq + 1,
               updated_at = now()
        RETURNING b.last_seq, b.input - b.output INTO v_seq, v_bal;

        -- debit-positive, the convention declared on ledger_entries.balance_after
        INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                                    amount_minor, currency, account_seq, balance_after, effective_at)
        VALUES (p_tenant, v_txn, r.account_id, r.dir, r.amt, 'USD', v_seq, v_bal,
                (SELECT effective_at FROM ledger_transactions
                  WHERE tenant_id = p_tenant AND id = v_txn));
    END LOOP;
END $$;

-- A cross-scope movement is TWO ledger transactions -- one per scope, each
-- balanced on its own -- committed in ONE database transaction. Both halves or
-- neither: the intercompany position is never observably one-sided.
CREATE FUNCTION post_pair(p_a text, p_ka text, p_la text[],
                          p_b text, p_kb text, p_lb text[]) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM post(p_a, p_ka, p_la);
    PERFORM post(p_b, p_kb, p_lb);
END $$;

-- ------------------------------------------------------------------ assertions

-- Compares the COMPLETE trial balance against an expected set, in both
-- directions. 'tenant|purpose|minor', natural sign (positive = more of what the
-- account normally holds). Accounts with no entries are legitimately absent.
CREATE FUNCTION expect_state(p_step text, p_expect text[]) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE r record; msg text := '';
BEGIN
    -- The expectation key is (tenant, purpose, currency), and uq_accounts__owned
    -- permits two accounts of one purpose in a tenant under different owners. Those
    -- would SUM into a single row here, so a leg mis-routed between them would be
    -- invisible. Rather than widen every expectation, refuse the ambiguity: if it
    -- ever arises, this assertion stops describing the books and must be rewritten.
    -- Enumerated from ledger_ACCOUNTS, not from trial_balance. trial_balance is
    -- built from entries, so a version keyed on it only fired once BOTH accounts
    -- had activity -- and the dangerous case is routing EVERY leg to the wrong
    -- owner, which leaves the right one empty and the guard silent. Proven: the
    -- whole $500 purchase booked against the wrong customer, entire suite green.
    IF EXISTS (
        SELECT 1 FROM ledger_accounts
         GROUP BY tenant_id, purpose, currency HAVING count(*) > 1) THEN
        RAISE EXCEPTION
            'step % -- two accounts share (tenant, purpose, currency), so expect_state '
            'can no longer identify them: %', p_step,
            (SELECT string_agg(tenant_id||'/'||purpose||'/'||currency, ', ')
               FROM (SELECT tenant_id, purpose, currency FROM ledger_accounts
                      GROUP BY tenant_id, purpose, currency
                     HAVING count(*) > 1) q);
    END IF;

    -- Force the DEFERRED balance trigger to fire NOW. Without this the whole file
    -- runs inside one transaction that ends in ROLLBACK, so the trigger would
    -- never fire at all and "balanced per currency" would go entirely unchecked --
    -- a green run that never executed the check it claims to make.
    EXECUTE 'SET CONSTRAINTS ALL IMMEDIATE';
    EXECUTE 'SET CONSTRAINTS ALL DEFERRED';

    -- PER CURRENCY. This grouped by (tenant, purpose) only, summing minor units
    -- across denominations -- the exact vacuity 0002 exists to remove from the
    -- accounting equation, sitting in the assertion that checks it. An account
    -- holding 100.00 USD and 100.00 EUR read as 20000 and matched an expectation
    -- of 20000. Expectations are 'tenant|purpose|amount' (USD implied) or
    -- 'tenant|purpose|CCY|amount'.
    WITH want AS (
        SELECT split_part(x,'|',1) AS tenant_id,
               split_part(x,'|',2) AS purpose,
               CASE WHEN split_part(x,'|',4) = '' THEN 'USD'
                    ELSE split_part(x,'|',3) END::char(3) AS currency,
               CASE WHEN split_part(x,'|',4) = '' THEN split_part(x,'|',3)
                    ELSE split_part(x,'|',4) END::bigint AS balance_minor
        FROM unnest(p_expect) AS x
    ), got AS (
        -- WHOLE-LEDGER, ONE NAMED EXCLUSION. The UNEXPECTED branch below is what
        -- catches a leg posted somewhere plausible but wrong, and it only catches
        -- it because this reads every scope rather than this file's own. The single
        -- exclusion is tests/fixtures/recorded_axis.sql's tenant, which is committed
        -- before any suite runs so that the recorded axis has a boundary that is not
        -- now() -- see the fixture's own header. It is stated here rather than left
        -- implicit, and it is asserted on its own immediately after this function,
        -- so the exclusion cannot hide a write.
        SELECT tenant_id, purpose, currency, SUM(balance_minor)::bigint AS balance_minor
        FROM trial_balance WHERE tenant_id <> 'bt0'
        GROUP BY tenant_id, purpose, currency
    )
    SELECT string_agg(line, E'\n' ORDER BY line) INTO msg FROM (
        SELECT format('  MISSING  %s/%s/%s expected %s', w.tenant_id, w.purpose,
                      w.currency, w.balance_minor) AS line
          FROM want w LEFT JOIN got g USING (tenant_id, purpose, currency)
         WHERE g.purpose IS NULL
        UNION ALL
        -- the mutation catch: a leg posted somewhere plausible but wrong
        SELECT format('  UNEXPECTED %s/%s/%s holds %s', g.tenant_id, g.purpose,
                      g.currency, g.balance_minor)
          FROM got g LEFT JOIN want w USING (tenant_id, purpose, currency)
         WHERE w.purpose IS NULL
        UNION ALL
        SELECT format('  WRONG    %s/%s/%s expected %s, got %s', w.tenant_id, w.purpose,
                      w.currency, w.balance_minor, g.balance_minor)
          FROM want w JOIN got g USING (tenant_id, purpose, currency)
         WHERE w.balance_minor <> g.balance_minor
    ) q;

    IF msg IS NOT NULL AND msg <> '' THEN
        RAISE EXCEPTION E'step % -- state does not match:\n%', p_step, msg;
    END IF;

    -- Every scope balances on its own, per currency. Checked at every step,
    -- because a ledger that is only right at the end is wrong.
    FOR r IN SELECT * FROM accounting_equation() LOOP
        IF NOT r.balanced THEN
            RAISE EXCEPTION 'step % -- % / % does not balance: A=% vs L+E+R-X=%',
                p_step, r.tenant_id, r.currency, r.lhs, r.rhs;
        END IF;
    END LOOP;

    -- ...and the check actually ran. An empty report is trivially "balanced" --
    -- the exact failure this project cites Formance for.
    -- Compared against ACCOUNTS, not entries: the equation now enumerates scopes
    -- from the chart, so a scope that exists but has not posted yet reports zeros
    -- rather than vanishing. That is the fix for "an as-of before any activity
    -- returned an empty, trivially-balanced report".
    --
    -- HONEST LIMIT: with no as-of passed, accounting_equation()'s scope set IS
    -- `SELECT DISTINCT tenant_id, currency FROM ledger_accounts`, so this
    -- comparison is an identity and cannot detect the failure the sentence above
    -- names -- that needs an as-of, and lives in tests/bitemporal.sql. What it
    -- does still catch is the function losing a scope through its JOINs, which is
    -- how it was written and is worth keeping.
    IF (SELECT count(*) FROM accounting_equation()) <>
       (SELECT count(DISTINCT (tenant_id, currency)) FROM ledger_accounts) THEN
        RAISE EXCEPTION 'step % -- equation covered % scope(s) but % exist',
            p_step, (SELECT count(*) FROM accounting_equation()),
            (SELECT count(DISTINCT (tenant_id, currency)) FROM ledger_accounts);
    END IF;

    -- Intercompany elimination: the two sides of every cross-scope movement must
    -- cancel exactly. This is what proves the two-transaction split lost nothing.
    IF (SELECT COALESCE(SUM(CASE WHEN e.direction='debit' THEN e.amount_minor
                                 ELSE -e.amount_minor END),0)
          FROM ledger_entries e
          JOIN ledger_accounts a ON a.tenant_id=e.tenant_id AND a.id=e.account_id
         WHERE a.purpose IN ('due_from_treasury','due_to_tenants')) <> 0 THEN
        RAISE EXCEPTION 'step % -- intercompany does not eliminate', p_step;
    END IF;

    -- The stored running balance and a recomputation from history must agree.
    IF EXISTS (SELECT 1 FROM ledger_balance_drift WHERE stored <> recomputed) THEN
        RAISE EXCEPTION 'step % -- balance_after has drifted from the journal', p_step;
    END IF;

    RAISE NOTICE 'ok  %', p_step;
END $$;

-- THE EXCLUSION, ASSERTED. state() skips tenant 'bt0' -- the committed fixture that
-- gives the recorded axis a boundary other than now() -- so this file would not see
-- a write landing there. One assertion closes that: the fixture holds exactly what
-- it was created with, 50.00 of receivable against 50.00 of wallet, and nothing else.
DO $$
DECLARE v_rows int; v_recv bigint; v_wallet bigint;
BEGIN
    SELECT count(*) INTO v_rows FROM trial_balance WHERE tenant_id='bt0';
    SELECT SUM(balance_minor) INTO v_recv   FROM trial_balance
     WHERE tenant_id='bt0' AND purpose='customer_receivable';
    SELECT SUM(balance_minor) INTO v_wallet FROM trial_balance
     WHERE tenant_id='bt0' AND purpose='customer_wallet';
    IF v_rows <> 2 OR v_recv IS DISTINCT FROM 5000 OR v_wallet IS DISTINCT FROM 5000 THEN
        RAISE EXCEPTION 'the recorded-axis fixture tenant has been written to: '
                        '% rows, receivable %, wallet %', v_rows, v_recv, v_wallet;
    END IF;
    RAISE NOTICE 'ok  the one scope state() excludes still holds exactly its fixture';
END $$;

-- ------------------------------------------------------------------ the trace

-- opening: equity funds the 15% the advance rate will not cover
SELECT post('_treasury','open', ARRAY['operating_cash','debit','6600',
                                      'paid_in_capital','credit','6600']);
SELECT expect_state('open', ARRAY[
  '_treasury|operating_cash|6600', '_treasury|paid_in_capital|6600']);

-- 01 authorization: NOTHING. An auth creates no obligation and moves no money.
SELECT expect_state('01 authorization writes nothing', ARRAY[
  '_treasury|operating_cash|6600', '_treasury|paid_in_capital|6600']);

-- 02 partial clearing $300 -- the first time the ledger hears about the purchase
SELECT post('t1','evt_clear_1:posting', ARRAY['customer_receivable','debit','30000',
        'network_settlement_payable','credit','29460','interchange_revenue','credit','540']);
SELECT post('t1','evt_clear_1:revshare', ARRAY['platform_rev_share_expense','debit','162',
        'platform_rev_share_payable','credit','162']);
SELECT expect_state('02 partial clearing 300.00', ARRAY[
  '_treasury|operating_cash|6600', '_treasury|paid_in_capital|6600',
  't1|customer_receivable|30000', 't1|network_settlement_payable|29460',
  't1|interchange_revenue|540', 't1|platform_rev_share_expense|162',
  't1|platform_rev_share_payable|162']);

-- 03 final clearing $200
SELECT post('t1','evt_clear_2:posting', ARRAY['customer_receivable','debit','20000',
        'network_settlement_payable','credit','19640','interchange_revenue','credit','360']);
SELECT post('t1','evt_clear_2:revshare', ARRAY['platform_rev_share_expense','debit','108',
        'platform_rev_share_payable','credit','108']);
SELECT expect_state('03 final clearing 200.00', ARRAY[
  '_treasury|operating_cash|6600', '_treasury|paid_in_capital|6600',
  't1|customer_receivable|50000', 't1|network_settlement_payable|49100',
  't1|interchange_revenue|900', 't1|platform_rev_share_expense|270',
  't1|platform_rev_share_payable|270']);

-- 04 facility draw at an 85% advance rate. Cash lands in the OPERATOR's bank, but
-- the borrowing belongs to the program -- so this is a cross-scope movement.
SELECT post_pair(
  't1','evt_draw:tenant',   ARRAY['due_from_treasury','debit','42500',
                                  'facility_borrowings','credit','42500'],
  '_treasury','evt_draw:treasury', ARRAY['operating_cash','debit','42500',
                                  'due_to_tenants','credit','42500']);
SELECT expect_state('04 facility draw 425.00', ARRAY[
  '_treasury|operating_cash|49100', '_treasury|paid_in_capital|6600',
  '_treasury|due_to_tenants|42500',
  't1|customer_receivable|50000', 't1|network_settlement_payable|49100',
  't1|interchange_revenue|900', 't1|platform_rev_share_expense|270',
  't1|platform_rev_share_payable|270', 't1|due_from_treasury|42500',
  't1|facility_borrowings|42500']);

-- 05 network settlement: we wire 491.00, not 500.00. The 9.00 gap was never cash.
SELECT post_pair(
  't1','evt_settle:tenant',   ARRAY['network_settlement_payable','debit','49100',
                                    'due_from_treasury','credit','49100'],
  '_treasury','evt_settle:treasury', ARRAY['due_to_tenants','debit','49100',
                                    'operating_cash','credit','49100']);
-- due_from_treasury is now NEGATIVE: the program has drawn 425.00 but settled
-- 491.00, so it owes the operator the 66.00 of equity that covered the gap. An
-- intercompany balance is a net bilateral position and swings both ways by
-- nature -- unlike ach_pull_returnable, which is one obligation and must not.
SELECT expect_state('05 network settlement 491.00', ARRAY[
  '_treasury|operating_cash|0', '_treasury|paid_in_capital|6600',
  '_treasury|due_to_tenants|-6600',
  't1|customer_receivable|50000', 't1|network_settlement_payable|0',
  't1|interchange_revenue|900', 't1|platform_rev_share_expense|270',
  't1|platform_rev_share_payable|270', 't1|due_from_treasury|-6600',
  't1|facility_borrowings|42500']);

-- interest accrues: 425.00 x 10% x 30/360
SELECT post('t1','evt_accrue', ARRAY['interest_expense','debit','354',
                                     'accrued_interest_payable','credit','354']);
SELECT expect_state('interest accrual 3.54', ARRAY[
  '_treasury|operating_cash|0', '_treasury|paid_in_capital|6600',
  '_treasury|due_to_tenants|-6600',
  't1|customer_receivable|50000', 't1|network_settlement_payable|0',
  't1|interchange_revenue|900', 't1|platform_rev_share_expense|270',
  't1|platform_rev_share_payable|270', 't1|due_from_treasury|-6600',
  't1|facility_borrowings|42500', 't1|interest_expense|354',
  't1|accrued_interest_payable|354']);

-- 06 statement closes: NOTHING. A statement is a read.
-- 7.1 repayment initiated: NOTHING. Money in commits at settlement.

-- 7.2 funds land and are still reversible. Corporate ACH can come back R01 for
-- ~2 banking days, so we hold a matching LIABILITY rather than extinguishing the
-- debt. The receivable is untouched.
SELECT post_pair(
  't1','evt_pull:settle:tenant',   ARRAY['due_from_treasury','debit','50000',
                                         'ach_pull_returnable','credit','50000'],
  '_treasury','evt_pull:settle:treasury', ARRAY['operating_cash','debit','50000',
                                         'due_to_tenants','credit','50000']);
SELECT expect_state('7.2 ACH funds land 500.00', ARRAY[
  '_treasury|operating_cash|50000', '_treasury|paid_in_capital|6600',
  '_treasury|due_to_tenants|43400',
  't1|customer_receivable|50000', 't1|network_settlement_payable|0',
  't1|interchange_revenue|900', 't1|platform_rev_share_expense|270',
  't1|platform_rev_share_payable|270', 't1|due_from_treasury|43400',
  't1|facility_borrowings|42500', 't1|interest_expense|354',
  't1|accrued_interest_payable|354', 't1|ach_pull_returnable|50000']);

-- 7.3 return window closes. ONLY NOW is the debt extinguished.
SELECT post('t1','evt_pull:final', ARRAY['ach_pull_returnable','debit','50000',
                                         'customer_receivable','credit','50000']);
SELECT expect_state('7.3 return window closes', ARRAY[
  '_treasury|operating_cash|50000', '_treasury|paid_in_capital|6600',
  '_treasury|due_to_tenants|43400',
  't1|customer_receivable|0', 't1|network_settlement_payable|0',
  't1|interchange_revenue|900', 't1|platform_rev_share_expense|270',
  't1|platform_rev_share_payable|270', 't1|due_from_treasury|43400',
  't1|facility_borrowings|42500', 't1|interest_expense|354',
  't1|accrued_interest_payable|354', 't1|ach_pull_returnable|0']);

-- 08 repay the facility, the interest and the platform
SELECT post_pair(
  't1','evt_repay:principal:tenant',   ARRAY['facility_borrowings','debit','42500',
                                             'due_from_treasury','credit','42500'],
  '_treasury','evt_repay:principal:treasury', ARRAY['due_to_tenants','debit','42500',
                                             'operating_cash','credit','42500']);
SELECT post_pair(
  't1','evt_repay:interest:tenant',   ARRAY['accrued_interest_payable','debit','354',
                                            'due_from_treasury','credit','354'],
  '_treasury','evt_repay:interest:treasury', ARRAY['due_to_tenants','debit','354',
                                            'operating_cash','credit','354']);
SELECT post_pair(
  't1','evt_repay:revshare:tenant',   ARRAY['platform_rev_share_payable','debit','270',
                                            'due_from_treasury','credit','270'],
  '_treasury','evt_repay:revshare:treasury', ARRAY['due_to_tenants','debit','270',
                                            'operating_cash','credit','270']);
SELECT expect_state('08 repayment complete', ARRAY[
  '_treasury|operating_cash|6876', '_treasury|paid_in_capital|6600',
  '_treasury|due_to_tenants|276',
  't1|customer_receivable|0', 't1|network_settlement_payable|0',
  't1|interchange_revenue|900', 't1|platform_rev_share_expense|270',
  't1|platform_rev_share_payable|0', 't1|due_from_treasury|276',
  't1|facility_borrowings|0', 't1|interest_expense|354',
  't1|accrued_interest_payable|0', 't1|ach_pull_returnable|0']);

-- A EUR clearing, so the final state carries two currencies for one purpose.
CREATE FUNCTION post_eur(p_key text, p_legs text[]) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_event uuid; v_txn uuid; r record; v_seq bigint; v_bal bigint;
BEGIN
    INSERT INTO ledger_events (tenant_id,kind,source,idempotency_key,idempotency_hash,payload,effective_at)
    VALUES ('t1','trace','internal',p_key,sha256(convert_to(p_key,'UTF8')),'{}',now())
    RETURNING id INTO v_event;
    INSERT INTO ledger_transactions (tenant_id,event_id,kind,status,effective_at)
    VALUES ('t1',v_event,'trace','posted',now()) RETURNING id INTO v_txn;
    FOR r IN SELECT a.id AS account_id, l.dir, l.amt
             FROM (SELECT p_legs[(i-1)*3+1] AS purpose,
                          p_legs[(i-1)*3+2]::ledger_direction AS dir,
                          p_legs[(i-1)*3+3]::bigint AS amt
                   FROM generate_series(1, array_length(p_legs,1)/3) AS i) l
             JOIN ledger_accounts a ON a.tenant_id='t1' AND a.purpose=l.purpose
                                   AND a.currency='EUR'
             ORDER BY a.id
    LOOP
        INSERT INTO ledger_account_balances AS b (tenant_id,account_id,currency,input,output,last_seq)
        VALUES ('t1',r.account_id,'EUR',
                CASE WHEN r.dir='debit'  THEN r.amt ELSE 0 END,
                CASE WHEN r.dir='credit' THEN r.amt ELSE 0 END,1)
        ON CONFLICT (tenant_id,account_id,currency) DO UPDATE
           SET input=b.input+EXCLUDED.input, output=b.output+EXCLUDED.output,
               last_seq=b.last_seq+1
        RETURNING b.last_seq, b.input-b.output INTO v_seq, v_bal;
        INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,
                                    currency,account_seq,balance_after,effective_at)
        VALUES ('t1',v_txn,r.account_id,r.dir,r.amt,'EUR',v_seq,v_bal,
                (SELECT effective_at FROM ledger_transactions WHERE id=v_txn));
    END LOOP;
END $$;

SELECT post_eur('evt_clear_eur', ARRAY['customer_receivable','debit','4000',
                                       'interchange_revenue','credit','4000']);
SELECT expect_state('a EUR clearing, alongside the USD books', ARRAY[
  '_treasury|operating_cash|6876', '_treasury|paid_in_capital|6600',
  '_treasury|due_to_tenants|276',
  't1|customer_receivable|0', 't1|network_settlement_payable|0',
  't1|interchange_revenue|900', 't1|platform_rev_share_expense|270',
  't1|platform_rev_share_payable|0', 't1|due_from_treasury|276',
  't1|facility_borrowings|0', 't1|interest_expense|354',
  't1|accrued_interest_payable|0', 't1|ach_pull_returnable|0',
  -- the same purposes again, in EUR. If the assertion or trial_balance summed
  -- across currencies these would merge into the USD rows and the trace would
  -- still pass.
  't1|customer_receivable|EUR|4000', 't1|interchange_revenue|EUR|4000']);

-- ------------------------------------------------------------------ the result
--
-- The program earned 9.00 of interchange and spent 2.70 of rev share and 3.54 of
-- interest, so it made 2.76 -- and its claim on the operator is exactly 2.76.
-- The profit and the intercompany position are the same number, from opposite
-- directions. That is the trace being MEANINGFUL rather than merely balanced.

DO $$
DECLARE v_profit bigint; v_due bigint;
BEGIN
    -- debit-positive: revenue carries a negative sign and expense a positive one,
    -- so profit is the NEGATED sum of the two. PER CURRENCY -- this summed across
    -- them, which is the vacuity 0002 exists to remove, in the assertion the trace
    -- calls its most meaningful.
    SELECT -COALESCE(SUM(balance_debit_positive)
                     FILTER (WHERE category IN ('revenue','expense')), 0)
      INTO v_profit FROM trial_balance WHERE tenant_id='t1' AND currency='USD';
    SELECT balance_debit_positive INTO v_due FROM trial_balance
     WHERE tenant_id='t1' AND currency='USD' AND purpose='due_from_treasury';
    -- IS DISTINCT FROM, not <>. Pointed at an account that does not exist, v_due is
    -- NULL, `0 <> NULL` is NULL, and the assertion silently passed -- including on
    -- an empty database.
    IF v_profit IS DISTINCT FROM v_due THEN
        RAISE EXCEPTION 't1 profit % <> intercompany claim %', v_profit, v_due;
    END IF;
    IF v_profit IS NULL THEN
        RAISE EXCEPTION 't1 profit is NULL -- the trace did not run';
    END IF;
    RAISE NOTICE 'ok  t1 profit % == its claim on treasury', v_profit;
END $$;

-- Completeness, for real this time.
--
-- The previous check compared SUM(debits) from trial_balance against SUM(debits)
-- from trial_balance joined to account_types and fs_lines. Both joins are
-- FK-guaranteed to preserve every row -- purpose is a FK to account_types, and
-- fs_line is NOT NULL with a FK to fs_lines -- so the two sides were the same
-- number by construction and the check could never fail. It read `0 = 0` on an
-- empty database too. That is precisely the "green check that did not execute"
-- this project criticises elsewhere.
--
-- The replacement enumerates every balance-sheet line FROM THE CHART and requires
-- assets to equal liabilities plus equity, per scope and per currency. It fails
-- loudly, and it did: before `current_year_earnings` existed, the sheet was out by
-- exactly net income, because un-closed revenue and expense had nowhere to go.
DO $$
DECLARE r record; n int := 0;
BEGIN
    FOR r IN SELECT * FROM balance_sheet_balances() LOOP
        n := n + 1;
        IF NOT r.balanced THEN
            RAISE EXCEPTION 'balance sheet for %/% is out by %: assets % vs L+E %',
                r.tenant_id, r.currency, r.assets - r.liabilities_and_equity,
                r.assets, r.liabilities_and_equity;
        END IF;
        RAISE NOTICE 'ok  balance sheet %/%: assets % = liabilities + equity %',
            r.tenant_id, r.currency, r.assets, r.liabilities_and_equity;
    END LOOP;
    -- EVERY scope, counted from the chart rather than typed as a literal. The count
    -- is asserted because it is the only thing standing between a dropped scope and
    -- a green suite; it is derived because "there are three" is a fact about today's
    -- fixtures and "one balance sheet per scope that exists" is the claim.
    IF n <> (SELECT count(DISTINCT (tenant_id, currency)) FROM ledger_accounts) THEN
        RAISE EXCEPTION 'expected a balance sheet for every scope, got % of %', n,
            (SELECT count(DISTINCT (tenant_id, currency)) FROM ledger_accounts);
    END IF;
END $$;

-- The income statement must tie to the earnings line the balance sheet carries --
-- PER SCOPE and PER CURRENCY.
--
-- This was a single ungrouped sum on both sides. Against a ledger holding
-- 5.40 USD, 10.00 USD and 100.00 EUR it added them to 11540, compared 11540 to
-- 11540, and printed "ok". Adding euros to dollars and calling it green is
-- precisely the failure ADR-0009 documents as measured and fixed -- reintroduced
-- in the assertion that is supposed to guard against it.
DO $$
DECLARE r record; n int := 0;
BEGIN
    FOR r IN
        SELECT COALESCE(i.tenant_id, b.tenant_id) AS tenant_id,
               COALESCE(i.currency,  b.currency)  AS currency,
               COALESCE(i.profit, 0) AS profit, COALESCE(b.earnings, 0) AS earnings
        FROM (SELECT tenant_id, currency, SUM(amount_minor) AS profit
                FROM income_statement
               GROUP BY tenant_id, currency) i
        FULL OUTER JOIN (SELECT tenant_id, currency, SUM(amount_minor) AS earnings
                           FROM balance_sheet WHERE fs_line='current_year_earnings'
                          GROUP BY tenant_id, currency) b
          ON b.tenant_id = i.tenant_id AND b.currency = i.currency
        -- A SCOPE WITH NOTHING ON EITHER SIDE HAS NOTHING TO TIE. Both sides zero
        -- ties trivially, so counting such a scope adds no coverage and does make
        -- the count below depend on which scopes merely EXIST -- which is how the
        -- committed fixture tenant (asset against liability, no P&L at all) started
        -- appearing here.
        WHERE COALESCE(i.profit, 0) <> 0 OR COALESCE(b.earnings, 0) <> 0
    LOOP
        n := n + 1;
        -- income_statement presents revenue and expense both positive, so profit
        -- is revenue less the expense lines; compare against the derived equity line
        IF r.earnings IS DISTINCT FROM (
             SELECT COALESCE(SUM(CASE WHEN side='credit' THEN amount_minor
                                      ELSE -amount_minor END), 0)
               FROM income_statement
              WHERE tenant_id = r.tenant_id AND currency = r.currency) THEN
            RAISE EXCEPTION 'income statement does not tie for %/%: earnings line %',
                r.tenant_id, r.currency, r.earnings;
        END IF;
    END LOOP;
    -- ...and the count is derived from the JOURNAL, not typed as a literal and not
    -- read back from the report under test: every scope that has posted a revenue or
    -- expense entry must appear above. A literal 3 is a fact about today's fixtures;
    -- reading income_statement itself would agree with whatever the report produced.
    IF n <> (SELECT count(*) FROM (
                SELECT DISTINCT en.tenant_id, en.currency
                  FROM ledger_entries en
                  JOIN ledger_accounts a
                    ON a.tenant_id = en.tenant_id AND a.id = en.account_id
                 WHERE a.category IN ('revenue','expense')) z) THEN
        RAISE EXCEPTION 'expected an income statement per scope that has posted one, got %', n;
    END IF;
    RAISE NOTICE 'ok  income statement ties to the balance sheet in % scope(s)', n;
END $$;


-- The income statement must depend on the CHART, not merely be self-consistent.
--
-- The tie-out below compares (side='credit' ? -1 : 1) * v against
-- SUM(side='credit' ? +amount : -amount) -- and those two `side` factors CANCEL,
-- so both sides evaluate to -v whatever the chart says. Moving interchange to a
-- cost-of-revenue line, or flipping the revenue line's side, tied perfectly. This
-- asserts the caption an amount actually lands under.
DO $$
DECLARE v_rev bigint; v_cost bigint; v_int bigint;
BEGIN
    SELECT amount_minor INTO v_rev  FROM income_statement
     WHERE tenant_id='t1' AND currency='USD' AND fs_line='revenue';
    SELECT amount_minor INTO v_cost FROM income_statement
     WHERE tenant_id='t1' AND currency='USD' AND fs_line='cost_of_revenue';
    SELECT amount_minor INTO v_int  FROM income_statement
     WHERE tenant_id='t1' AND currency='USD' AND fs_line='interest';
    IF v_rev <> 900 THEN
        RAISE EXCEPTION 'interchange is not reporting on the Revenue line: got %', v_rev;
    END IF;
    IF v_cost <> 270 THEN
        RAISE EXCEPTION 'the rev share is not reporting on Cost of revenue: got %', v_cost;
    END IF;
    IF v_int <> 354 THEN
        RAISE EXCEPTION 'interest is not reporting on Interest expense: got %', v_int;
    END IF;
    RAISE NOTICE 'ok  each amount reports under its own caption: rev %, cost %, interest %',
        v_rev, v_cost, v_int;
END $$;

-- expect_state's UNEXPECTED branch -- the one its own comment calls "the mutation
-- catch" -- was DEAD: no step in this trace ever produces an account outside the
-- expectation set, so deleting the branch changed nothing. Here is a step that does.
DO $$
DECLARE v_caught text;
BEGIN
    PERFORM post('t1','stray_posting', ARRAY['fee_revenue','credit','50',
                                             'customer_receivable','debit','50']);
    BEGIN
        PERFORM expect_state('this must not pass', ARRAY[
          '_treasury|operating_cash|6876', '_treasury|paid_in_capital|6600',
          '_treasury|due_to_tenants|276',
          't1|customer_receivable|50', 't1|network_settlement_payable|0',
          't1|interchange_revenue|900', 't1|platform_rev_share_expense|270',
          't1|platform_rev_share_payable|0', 't1|due_from_treasury|276',
          't1|facility_borrowings|0', 't1|interest_expense|354',
          't1|accrued_interest_payable|0', 't1|ach_pull_returnable|0',
          't1|customer_receivable|EUR|4000', 't1|interchange_revenue|EUR|4000']);
        RAISE EXCEPTION 'expect_state accepted a state containing an account it was '
            'not told about -- the UNEXPECTED branch is dead';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_caught = MESSAGE_TEXT;
        IF position('UNEXPECTED t1/fee_revenue' in v_caught) = 0 THEN
            RAISE EXCEPTION 'expect_state failed, but not on the stray account: %', v_caught;
        END IF;
    END;
    RAISE NOTICE 'ok  expect_state catches an account it was not told about';
END $$;

-- ============================================ round 4: what the reports present
--
-- Every assertion above reads a BALANCE or a `balanced` flag. None read a
-- caption, a statement line, or which of two output columns a number came out
-- of -- so a report could present the right numbers in the wrong places and stay
-- green. These are the presentation properties the chart's comments say were
-- found the expensive way.

-- Reg S-X 5-02.1 and ASC 230-10-45-4: customer funds held FBO are RESTRICTED and
-- must not share a caption with the operator's own liquidity. Mapped to `cash`,
-- unrestricted liquidity is overstated by the entire float -- the number a lender
-- and a covenant both read. Re-pointing fbo_cash from restricted_cash to cash is
-- asset-to-asset, so every trigger is happy and every balance is unchanged.
-- The trace does not otherwise hold customer float, so open the two accounts and
-- move 700.00 into them: this control needs a NON-ZERO restricted balance or it
-- passes vacuously.
DO $$ BEGIN
    INSERT INTO ledger_accounts (tenant_id,owner_type,owner_id,purpose,category,normal_balance,currency)
    SELECT 't1','house',NULL,code,category,normal_balance,'USD'
      FROM account_types WHERE code IN ('fbo_cash','customer_wallet')
    ON CONFLICT DO NOTHING;
END $$;
SELECT post('t1','fbo_float', ARRAY['fbo_cash','debit','70000',
                                    'customer_wallet','credit','70000']);

DO $$
DECLARE v_cash bigint; v_restricted bigint; v_fbo bigint;
BEGIN
    SELECT COALESCE(amount_minor,0) INTO v_cash FROM balance_sheet
     WHERE tenant_id='t1' AND currency='USD' AND fs_line='cash';
    SELECT COALESCE(amount_minor,0) INTO v_restricted FROM balance_sheet
     WHERE tenant_id='t1' AND currency='USD' AND fs_line='restricted_cash';
    SELECT COALESCE(SUM(balance_minor),0) INTO v_fbo FROM trial_balance
     WHERE tenant_id='t1' AND currency='USD' AND purpose='fbo_cash';
    IF v_fbo = 0 THEN
        RAISE EXCEPTION 'the trace holds no FBO cash, so this control proves nothing';
    END IF;
    IF v_restricted <> v_fbo THEN
        RAISE EXCEPTION 'restricted cash presents % against % of FBO balance',
            v_restricted, v_fbo;
    END IF;
    -- t1 holds no operating_cash, so an earlier version of this guarded the real
    -- check behind `IF v_cash <> 0 AND ...` and never executed it. State the
    -- property unconditionally instead: whatever unrestricted cash reports, it must
    -- not contain the float.
    -- Two rewrites of this were dead: the first guarded the real check behind a
    -- condition t1 never meets, and the second reduced to `v_cash = v_cash + v_fbo`
    -- because v_cash is read from the very row it compares against. State the
    -- property directly and unconditionally: the float is on the restricted line
    -- and is NOT inside the unrestricted one, whatever either happens to hold.
    IF v_cash = v_fbo AND v_fbo <> 0 THEN
        RAISE EXCEPTION 'unrestricted cash equals the float exactly -- it is the float';
    END IF;
    IF (SELECT fs_line FROM account_types WHERE code='fbo_cash') = 'cash' THEN
        RAISE EXCEPTION 'customer float is mapped to the unrestricted cash line';
    END IF;
    RAISE NOTICE 'ok  customer float presents as restricted cash (%), not as cash (%)',
        v_restricted, v_cash;
END $$;

-- ...and EVERY account type reports under the line the chart says, not only the
-- ones this trace happens to post to. Two seed mutants survived every assertion
-- here: `platform_rev_share_payable` re-pointed to `customer_funds` presented
-- money owed a platform partner as RESTRICTED CUSTOMER FUNDS, and
-- `credit_loss_expense` re-pointed to `cost_of_revenue` erased the "Provision for
-- credit losses" caption entirely. Both are liability-to-liability and
-- expense-to-expense, so every chart trigger is satisfied; the first nets to zero
-- in expect_state, and the second is never posted to at all. These are the
-- disclosures the seed cites Reg S-X and lender reporting for, so assert the
-- mapping itself rather than only the totals that happen to move.
DO $$
DECLARE r record; bad text := '';
BEGIN
    FOR r IN SELECT * FROM (VALUES
        ('customer_receivable','receivables'),   ('operating_cash','cash'),
        ('fbo_cash','restricted_cash'),          ('customer_wallet','customer_funds'),
        ('network_settlement_payable','payables'),('facility_borrowings','borrowings'),
        ('accrued_interest_payable','payables'), ('platform_rev_share_payable','payables'),
        ('ach_pull_returnable','payables'),      ('due_to_tenants','payables'),
        ('due_from_treasury','other_assets'),    ('paid_in_capital','equity'),
        ('retained_earnings','retained_earnings'),('interchange_revenue','revenue'),
        ('fee_revenue','revenue'),               ('interest_expense','interest'),
        ('platform_rev_share_expense','cost_of_revenue'),
        ('credit_loss_expense','credit_losses'),
        ('allowance_for_credit_losses','receivables')
    ) AS q(code, want)
    LOOP
        IF (SELECT fs_line FROM account_types WHERE code = r.code) IS DISTINCT FROM r.want THEN
            bad := bad || format('%s -> %s (wanted %s) ', r.code,
                    (SELECT fs_line FROM account_types WHERE code = r.code), r.want);
        END IF;
    END LOOP;
    IF bad <> '' THEN
        RAISE EXCEPTION 'account type(s) report under the wrong statement line: %', bad;
    END IF;
    RAISE NOTICE 'ok  every account type reports under the line the chart declares';
END $$;

-- ...and the chart's DECLARED ORDER, not merely that the view is sorted. The
-- ordering controls check the rows come out non-decreasing in sort_order, which is
-- a property of the view's ORDER BY -- so any permutation of the seed's numbers
-- passes, and one put Cash ninth, between Retained earnings and the equity plug.
-- A statement whose lines come out in an arbitrary order is not a statement.
DO $$
DECLARE r record; prev text := ''; bad text := '';
BEGIN
    FOR r IN SELECT code FROM fs_lines WHERE statement='balance_sheet' ORDER BY sort_order
    LOOP
        prev := prev || r.code || ' ';
    END LOOP;
    IF btrim(prev) <> 'cash restricted_cash receivables other_assets payables '
                      'customer_funds borrowings equity retained_earnings' THEN
        RAISE EXCEPTION 'the balance sheet''s declared order is now: %', btrim(prev);
    END IF;
    prev := '';
    FOR r IN SELECT code FROM fs_lines WHERE statement='income_statement' ORDER BY sort_order
    LOOP
        prev := prev || r.code || ' ';
    END LOOP;
    IF btrim(prev) <> 'revenue cost_of_revenue credit_losses interest' THEN
        RAISE EXCEPTION 'the income statement''s declared order is now: %', btrim(prev);
    END IF;
    RAISE NOTICE 'ok  the chart declares assets before liabilities, revenue before costs';
END $$;

-- THE DERIVED PLUG'S CAPTION IS EMITTED AS A VIEW LITERAL AND GUARDED BY A CHECK
-- KEYED TO THE SAME STRING, and nothing read either -- so one edit could rename
-- the view's literal and leave ck_fs_lines__caption_reserved protecting a string
-- nothing emits. Renaming it back to "Current year earnings" passed the whole
-- suite, and then a chart line could take the caption the view actually uses:
-- 44,000.00 of customer suspense folded into the plug, which is verbatim the
-- defect the CHECK exists for. Tie the two together here.
DO $$
DECLARE v_caption text; v_missing text;
BEGIN
    SELECT caption INTO v_caption FROM balance_sheet
     WHERE fs_line = 'current_year_earnings' LIMIT 1;
    IF v_caption IS NULL THEN
        RAISE EXCEPTION 'the balance sheet no longer emits a current_year_earnings line';
    END IF;
    -- ...IN EVERY SCOPE, NOT SOMEWHERE. `LIMIT 1` over all scopes was the whole of
    -- this check, and the golden trace's tenants all have revenue, so the row was
    -- always found. Turning the plug's `LEFT JOIN dp` into a plain `JOIN` in 0002
    -- makes the line VANISH for any scope with no posted revenue or expense -- a
    -- deposit-only book, a new tenant, a currency that has only seen transfers --
    -- and the suite stayed green, because the vanished line is zero for exactly
    -- the scopes it vanishes from, so the sheet still balances. The promise 0002
    -- and ADR-0009 both make is that a line with no activity appears as a ZERO
    -- rather than vanishing; presence is the property, and it is per scope.
    SELECT string_agg(z.tenant_id || '/' || z.currency, ', ') INTO v_missing
      FROM (SELECT DISTINCT a.tenant_id, a.currency FROM ledger_accounts a) z
     WHERE NOT EXISTS (SELECT 1 FROM balance_sheet b
                        WHERE b.tenant_id = z.tenant_id AND b.currency = z.currency
                          AND b.fs_line = 'current_year_earnings');
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'the earnings line is absent from scope(s) %  -- a line with '
                        'no activity must report zero, not vanish', v_missing;
    END IF;
    RAISE NOTICE 'ok  every scope gets an earnings line, including the ones with no P&L';
    -- the CHECK must refuse exactly the string the view emits
    BEGIN
        INSERT INTO fs_lines (code,caption,statement,side,sort_order)
        VALUES ('plug_probe', v_caption, 'balance_sheet','liability_equity',9500);
        RAISE EXCEPTION 'a chart line took the caption the balance sheet emits (%) -- '
                        'the reserved-caption CHECK and the view literal have drifted '
                        'apart', v_caption;
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;
    IF v_caption ~ '^Current year' THEN
        RAISE EXCEPTION 'the plug is captioned %, which claims a period this ledger '
                        'has no close for', v_caption;
    END IF;
    RAISE NOTICE 'ok  the reserved caption is the one the balance sheet actually emits (%)',
        v_caption;
END $$;

-- ...and the two captions are distinguishable at all. Nothing anywhere read one.
DO $$
DECLARE v_dupes int;
BEGIN
    SELECT count(*) INTO v_dupes FROM (
        SELECT caption FROM fs_lines GROUP BY caption HAVING count(*) > 1) q;
    IF v_dupes > 0 THEN
        RAISE EXCEPTION '% caption(s) appear on more than one statement line -- the '
                        'split is real in the chart and invisible in the report', v_dupes;
    END IF;
    RAISE NOTICE 'ok  every statement line has its own caption';
END $$;

-- balance_sheet_balances ignoring its tenant argument passed the suite: every
-- assertion read `balanced`, which is true of the whole book AND of each tenant.
DO $$
DECLARE v_t1 bigint; v_t2 bigint; v_all bigint; v_scopes int;
BEGIN
    -- ASSERT THE FILTER, not a consequence of it. A first version compared the
    -- per-tenant assets against the whole book's, which survived the mutation:
    -- with the WHERE deleted the function returns every tenant's row and
    -- `SELECT ... INTO` silently takes the first, so the numbers still differed.
    SELECT count(DISTINCT bsb.tenant_id) INTO v_scopes FROM balance_sheet_balances('t1') bsb;
    IF v_scopes <> 1 THEN
        RAISE EXCEPTION 'balance_sheet_balances(''t1'') reports on % tenants', v_scopes;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM balance_sheet_balances('t1') bsb WHERE bsb.tenant_id='t1') THEN
        RAISE EXCEPTION 'balance_sheet_balances(''t1'') does not report on t1 at all';
    END IF;
    SELECT assets INTO v_t1  FROM balance_sheet_balances('t1') WHERE currency='USD';
    SELECT assets INTO v_t2  FROM balance_sheet_balances('_treasury') WHERE currency='USD';
    SELECT SUM(assets) INTO v_all FROM balance_sheet_balances() WHERE currency='USD';
    IF v_t1 = v_all OR v_t2 = v_all THEN
        RAISE EXCEPTION 'balance_sheet_balances ignores its tenant argument: '
                        't1=%, _treasury=%, all=%', v_t1, v_t2, v_all;
    END IF;
    IF v_t1 + v_t2 > v_all THEN
        RAISE EXCEPTION 'the per-tenant reports exceed the whole book';
    END IF;
    RAISE NOTICE 'ok  balance_sheet_balances is per tenant (t1=%, _treasury=%, book=%)',
        v_t1, v_t2, v_all;
END $$;

-- The income statement must enumerate its scopes from the CHART, like the balance
-- sheet -- from ledger_accounts, not from ledger_entries. Scoped from entries, a
-- tenant that has opened accounts but posted nothing to an income-statement line
-- VANISHES from the report rather than reporting zeros. The balance sheet's
-- version of this is asserted; its sibling's was not.
DO $$
DECLARE v_n int;
BEGIN
    INSERT INTO ledger_accounts (tenant_id,owner_type,owner_id,purpose,category,normal_balance,currency)
    SELECT 't_quiet','house',NULL,code,category,normal_balance,'USD'
      FROM account_types WHERE code='interchange_revenue';
    SELECT count(*) INTO v_n FROM income_statement
     WHERE tenant_id='t_quiet' AND currency='USD';
    IF v_n = 0 THEN
        RAISE EXCEPTION 'a tenant with accounts and no postings vanished from the '
                        'income statement instead of reporting zeros';
    END IF;
    IF EXISTS (SELECT 1 FROM income_statement
                WHERE tenant_id='t_quiet' AND amount_minor IS NULL) THEN
        RAISE EXCEPTION 'a quiet income-statement line reports NULL rather than 0';
    END IF;
    RAISE NOTICE 'ok  a tenant with no postings still reports % income-statement lines', v_n;
END $$;

-- trial_balance's COALESCE on debits and credits: an account with only debits
-- reports NULL credits without it, and NULL propagates through every arithmetic
-- a consumer does with it.
DO $$
DECLARE v_bad int;
BEGIN
    SELECT count(*) INTO v_bad FROM trial_balance
     WHERE debits IS NULL OR credits IS NULL OR balance_minor IS NULL
        OR balance_debit_positive IS NULL;
    IF v_bad > 0 THEN
        RAISE EXCEPTION '% trial-balance row(s) report NULL where they must report 0', v_bad;
    END IF;
    RAISE NOTICE 'ok  no trial-balance row reports NULL for a zero';
END $$;

-- ================================================ the pending -> posted lifecycle
--
-- THE ONE PLACE THE LEDGER DESIGN WAS NOT ATTESTED. A mutation audit deleted
-- `status = 'posted'` from ALL FOUR reporting paths -- trial_balance,
-- accounting_equation, balance_sheet, income_statement -- and widened it to
-- `IN ('posted','pending')`, and the whole suite stayed green. So could making
-- uq_txn__one_resolution non-unique, and dropping fk_txn__resolves and
-- fk_txn__reverses. No file anywhere created a pending transaction.
--
-- 0002 records that this exact defect was MEASURED: "a pending authorization was
-- recognised as revenue, and its posted resolution then counted it AGAIN --
-- 500.00 of interchange twice, every check green." A fix with a story and no
-- witness is free to regress, and the reversal half of the model was tested while
-- the resolution half was not tested at all.
CREATE FUNCTION post_status(p_tenant text, p_key text, p_status ledger_txn_status,
                            p_resolves uuid, p_legs text[]) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_event uuid; v_txn uuid; r record; v_seq bigint; v_bal bigint;
BEGIN
    INSERT INTO ledger_events (tenant_id, kind, source, idempotency_key, idempotency_hash,
                               payload, effective_at)
    VALUES (p_tenant,'trace','internal',p_key,sha256(convert_to(p_key,'UTF8')),
            to_jsonb(p_legs), now())
    RETURNING id INTO v_event;
    INSERT INTO ledger_transactions (tenant_id,event_id,kind,status,effective_at,resolves_id)
    VALUES (p_tenant,v_event,'trace',p_status,now(),p_resolves) RETURNING id INTO v_txn;
    FOR r IN
        WITH legs AS MATERIALIZED (
            SELECT i AS ord, p_legs[(i-1)*3+1] AS purpose,
                   p_legs[(i-1)*3+2]::ledger_direction AS dir,
                   p_legs[(i-1)*3+3]::bigint AS amt
            FROM generate_series(1, array_length(p_legs,1)/3) AS i)
        SELECT a.id AS account_id, l.dir, l.amt FROM legs l
        JOIN ledger_accounts a ON a.tenant_id=p_tenant AND a.purpose=l.purpose
                              AND a.currency='USD'
        ORDER BY a.id
    LOOP
        INSERT INTO ledger_account_balances AS b (tenant_id,account_id,currency,input,output,last_seq)
        VALUES (p_tenant, r.account_id, 'USD',
                CASE WHEN r.dir='debit'  THEN r.amt ELSE 0 END,
                CASE WHEN r.dir='credit' THEN r.amt ELSE 0 END, 1)
        ON CONFLICT (tenant_id,account_id,currency) DO UPDATE
           SET input=b.input+EXCLUDED.input, output=b.output+EXCLUDED.output,
               last_seq=b.last_seq+1, updated_at=now()
        RETURNING b.last_seq, b.input - b.output INTO v_seq, v_bal;
        INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,
                                    amount_minor,currency,account_seq,balance_after,effective_at)
        VALUES (p_tenant, v_txn, r.account_id, r.dir, r.amt, 'USD', v_seq, v_bal,
                (SELECT effective_at FROM ledger_transactions
                  WHERE tenant_id=p_tenant AND id=v_txn));
    END LOOP;
    RETURN v_txn;
END $$;

CREATE FUNCTION rev_t1() RETURNS bigint LANGUAGE sql STABLE AS $$
    SELECT revenue FROM accounting_equation('t1', now(), 'effective') WHERE currency='USD';
$$;
CREATE FUNCTION tb_t1(p_purpose text) RETURNS bigint LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(balance_minor),0) FROM trial_balance
     WHERE tenant_id='t1' AND purpose=p_purpose AND currency='USD';
$$;

DO $$
DECLARE v_rev0 bigint; v_recv0 bigint; v_pending uuid; v_n_entries int;
        v_is0 bigint; v_bs0 bigint;
BEGIN
    SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED;
    v_rev0  := rev_t1();
    v_recv0 := tb_t1('customer_receivable');
    SELECT COALESCE(SUM(amount_minor),0) INTO v_is0 FROM income_statement
     WHERE tenant_id='t1' AND currency='USD' AND fs_line='revenue';
    SELECT COALESCE(SUM(amount_minor),0) INTO v_bs0 FROM balance_sheet
     WHERE tenant_id='t1' AND currency='USD' AND fs_line='receivables';

    v_pending := post_status('t1','life_pending','pending',NULL,
        ARRAY['customer_receivable','debit','50000',
              'interchange_revenue','credit','50000']);
    SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED;

    -- the entries EXIST. What must not happen is their being reported.
    SELECT count(*) INTO v_n_entries FROM ledger_entries
     WHERE tenant_id='t1' AND transaction_id=v_pending;
    IF v_n_entries <> 2 THEN
        RAISE EXCEPTION 'the pending transaction has % entries, not 2 -- this test '
                        'would then prove nothing about the status filter', v_n_entries;
    END IF;
    RAISE NOTICE 'ok  a pending transaction writes its entries (%)', v_n_entries;

    IF rev_t1() <> v_rev0 THEN
        RAISE EXCEPTION 'a PENDING transaction was recognised as revenue: % -> %',
            v_rev0, rev_t1();
    END IF;
    RAISE NOTICE 'ok  accounting_equation does not recognise pending revenue = %', v_rev0;

    IF tb_t1('customer_receivable') <> v_recv0 THEN
        RAISE EXCEPTION 'trial_balance counted a PENDING transaction: % -> %',
            v_recv0, tb_t1('customer_receivable');
    END IF;
    RAISE NOTICE 'ok  trial_balance does not count a pending transaction = %', v_recv0;

    IF (SELECT COALESCE(SUM(amount_minor),0) FROM income_statement
         WHERE tenant_id='t1' AND currency='USD' AND fs_line='revenue') <> v_is0 THEN
        RAISE EXCEPTION 'the income statement recognised pending revenue';
    END IF;
    RAISE NOTICE 'ok  the income statement does not recognise pending revenue = %', v_is0;

    IF (SELECT COALESCE(SUM(amount_minor),0) FROM balance_sheet
         WHERE tenant_id='t1' AND currency='USD' AND fs_line='receivables') <> v_bs0 THEN
        RAISE EXCEPTION 'the balance sheet counted a pending receivable';
    END IF;
    RAISE NOTICE 'ok  the balance sheet does not count a pending receivable = %', v_bs0;

    -- ...and the resolution counts it EXACTLY ONCE. The measured defect was a
    -- DOUBLE count: pending recognised, then its resolution recognised again.
    PERFORM post_status('t1','life_resolved','posted',v_pending,
        ARRAY['customer_receivable','debit','50000',
              'interchange_revenue','credit','50000']);
    SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED;

    IF rev_t1() <> v_rev0 + 50000 THEN
        RAISE EXCEPTION 'resolution recognised % of revenue, expected exactly 50000 '
                        '(% -> %)', rev_t1() - v_rev0, v_rev0, rev_t1();
    END IF;
    RAISE NOTICE 'ok  resolution recognises the revenue exactly once = %', rev_t1();
    IF tb_t1('customer_receivable') <> v_recv0 + 50000 THEN
        RAISE EXCEPTION 'trial_balance counted the resolution % times',
            (tb_t1('customer_receivable') - v_recv0) / 50000;
    END IF;
    RAISE NOTICE 'ok  trial_balance counts the resolution exactly once';
END $$;

-- one pending transaction, one resolution
DO $$
DECLARE v_p uuid; v_caught text;
BEGIN
    SELECT resolves_id INTO v_p FROM ledger_transactions
     WHERE tenant_id='t1' AND resolves_id IS NOT NULL LIMIT 1;
    BEGIN
        PERFORM post_status('t1','life_double','posted',v_p,
            ARRAY['customer_receivable','debit','1','interchange_revenue','credit','1']);
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'NOT_REFUSED';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_caught = MESSAGE_TEXT;
        IF v_caught = 'NOT_REFUSED' THEN
            RAISE EXCEPTION 'one pending transaction was resolved TWICE';
        END IF;
        IF position('uq_txn__one_resolution' in v_caught) = 0 THEN
            RAISE EXCEPTION 'refused, but not by uq_txn__one_resolution: %', v_caught;
        END IF;
    END;
    RAISE NOTICE 'ok  refused  a second resolution of one pending transaction';
END $$;
SET CONSTRAINTS ALL DEFERRED;

-- ...and the target has to exist at all
DO $$
DECLARE v_caught text;
BEGIN
    BEGIN
        PERFORM post_status('t1','life_ghost','posted',
            '00000000-0000-0000-0000-0000000000ff'::uuid,
            ARRAY['customer_receivable','debit','1','interchange_revenue','credit','1']);
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'NOT_REFUSED';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_caught = MESSAGE_TEXT;
        IF v_caught = 'NOT_REFUSED' THEN
            RAISE EXCEPTION 'a transaction resolved one that does not exist';
        END IF;
        IF position('fk_txn__resolves' in v_caught) = 0 THEN
            RAISE EXCEPTION 'refused, but not by fk_txn__resolves: %', v_caught;
        END IF;
    END;
    RAISE NOTICE 'ok  refused  resolving a transaction that does not exist';
END $$;
SET CONSTRAINTS ALL DEFERRED;

-- ...and again at the end, because a SET LOCAL in a DO block that SUCCEEDS
-- persists for the rest of the transaction. MODE GUARD. `SET LOCAL session_replication_role = 'replica'` prepended to this
-- file's BEGIN made the whole suite run on the replication apply path, where a
-- guard marked ENABLE REPLICA fires and the ordinary write path is untested. That
-- is how an earlier leak went unnoticed for two hundred lines of negative
-- controls. One line per suite, at both ends.
DO $$ BEGIN
    IF current_setting('session_replication_role') <> 'origin' THEN
        RAISE EXCEPTION
            'this suite is running as %, not origin: every guard it exercises may be '
            'the replica-path one', current_setting('session_replication_role');
    END IF;
    RAISE NOTICE 'ok  running on the ordinary write path';
END $$;

ROLLBACK;

DO $$ BEGIN RAISE NOTICE 'ok  SUITE-COMPLETE golden_trace'; END $$;
