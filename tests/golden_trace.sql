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
        SELECT tenant_id, purpose, currency, SUM(balance_minor)::bigint AS balance_minor
        FROM trial_balance GROUP BY tenant_id, purpose, currency
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
    -- three now: _treasury/USD, t1/USD and t1/EUR. The count is asserted rather
    -- than left open because it is the only thing standing between a dropped scope
    -- and a green suite.
    IF n <> 3 THEN
        RAISE EXCEPTION 'expected a balance sheet for every scope, got %', n;
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
    IF n <> 3 THEN
        RAISE EXCEPTION 'expected an income statement per scope, got %', n;
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

ROLLBACK;

DO $$ BEGIN RAISE NOTICE 'ok  SUITE-COMPLETE golden_trace'; END $$;
