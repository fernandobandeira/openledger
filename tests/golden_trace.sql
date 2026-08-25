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
  ('_treasury','bank_account','bank_a','operating_cash'),
  ('_treasury','house',   NULL,        'paid_in_capital'),
  ('_treasury','house',   NULL,        'due_to_tenants')
) AS v(tenant,otype,oid,purpose)
JOIN account_types t ON t.code = v.purpose;

-- ------------------------------------------------------------------ posting
--
-- One atomic upsert per leg returns the new balance AND the next sequence number
-- together, so the row lock IS the serialization -- no SELECT max(), no advisory
-- lock, no retry loop. This is the write path 0001 describes; the test exercises
-- it rather than hand-computing balances beside it.

CREATE FUNCTION post(p_tenant text, p_key text, p_legs text[]) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_event uuid; v_txn uuid; i int;
    v_acct uuid; v_dir ledger_direction; v_amt bigint;
    v_seq bigint; v_bal bigint;
BEGIN
    INSERT INTO ledger_events (tenant_id, kind, source, idempotency_key, idempotency_hash,
                               payload, effective_at)
    VALUES (p_tenant, 'trace', 'internal', p_key,
            sha256(convert_to(p_key, 'UTF8')), to_jsonb(p_legs), now())
    RETURNING id INTO v_event;

    INSERT INTO ledger_transactions (tenant_id, event_id, kind, status, effective_at)
    VALUES (p_tenant, v_event, 'trace', 'posted', now())
    RETURNING id INTO v_txn;

    FOR i IN 1 .. array_length(p_legs,1)/3 LOOP
        v_dir := p_legs[(i-1)*3+2]::ledger_direction;
        v_amt := p_legs[(i-1)*3+3]::bigint;

        SELECT id INTO STRICT v_acct FROM ledger_accounts
         WHERE tenant_id = p_tenant AND purpose = p_legs[(i-1)*3+1];

        INSERT INTO ledger_account_balances AS b (tenant_id, account_id, currency, input, output, last_seq)
        VALUES (p_tenant, v_acct, 'USD',
                CASE WHEN v_dir='debit'  THEN v_amt ELSE 0 END,
                CASE WHEN v_dir='credit' THEN v_amt ELSE 0 END, 1)
        ON CONFLICT (tenant_id, account_id, currency) DO UPDATE
           SET input    = b.input  + EXCLUDED.input,
               output   = b.output + EXCLUDED.output,
               last_seq = b.last_seq + 1,
               updated_at = now()
        RETURNING b.last_seq, b.input - b.output INTO v_seq, v_bal;

        -- debit-positive, the convention declared on ledger_entries.balance_after
        INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                                    amount_minor, currency, account_seq, balance_after, effective_at)
        VALUES (p_tenant, v_txn, v_acct, v_dir, v_amt, 'USD', v_seq, v_bal, now());
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
    -- Force the DEFERRED balance trigger to fire NOW. Without this the whole file
    -- runs inside one transaction that ends in ROLLBACK, so the trigger would
    -- never fire at all and "balanced per currency" would go entirely unchecked --
    -- a green run that never executed the check it claims to make.
    EXECUTE 'SET CONSTRAINTS ALL IMMEDIATE';
    EXECUTE 'SET CONSTRAINTS ALL DEFERRED';

    WITH want AS (
        SELECT split_part(x,'|',1) AS tenant_id,
               split_part(x,'|',2) AS purpose,
               split_part(x,'|',3)::bigint AS balance_minor
        FROM unnest(p_expect) AS x
    ), got AS (
        SELECT tenant_id, purpose, SUM(balance_minor)::bigint AS balance_minor
        FROM trial_balance GROUP BY tenant_id, purpose
    )
    SELECT string_agg(line, E'\n' ORDER BY line) INTO msg FROM (
        SELECT format('  MISSING  %s/%s expected %s', w.tenant_id, w.purpose, w.balance_minor) AS line
          FROM want w LEFT JOIN got g USING (tenant_id, purpose) WHERE g.purpose IS NULL
        UNION ALL
        -- the mutation catch: a leg posted somewhere plausible but wrong
        SELECT format('  UNEXPECTED %s/%s holds %s', g.tenant_id, g.purpose, g.balance_minor)
          FROM got g LEFT JOIN want w USING (tenant_id, purpose) WHERE w.purpose IS NULL
        UNION ALL
        SELECT format('  WRONG    %s/%s expected %s, got %s', w.tenant_id, w.purpose,
                      w.balance_minor, g.balance_minor)
          FROM want w JOIN got g USING (tenant_id, purpose)
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
    IF (SELECT count(*) FROM accounting_equation()) <> 
       (SELECT count(DISTINCT (tenant_id, currency)) FROM ledger_entries) THEN
        RAISE EXCEPTION 'step % -- equation covered % scope(s) but % have entries',
            p_step, (SELECT count(*) FROM accounting_equation()),
            (SELECT count(DISTINCT (tenant_id, currency)) FROM ledger_entries);
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

-- ------------------------------------------------------------------ the result
--
-- The program earned 9.00 of interchange and spent 2.70 of rev share and 3.54 of
-- interest, so it made 2.76 -- and its claim on the operator is exactly 2.76.
-- The profit and the intercompany position are the same number, from opposite
-- directions. That is the trace being MEANINGFUL rather than merely balanced.

DO $$
DECLARE v_profit bigint; v_due bigint;
BEGIN
    SELECT COALESCE(SUM(balance_minor) FILTER (WHERE category='revenue'),0)
         - COALESCE(SUM(balance_minor) FILTER (WHERE category='expense'),0)
      INTO v_profit FROM trial_balance WHERE tenant_id='t1';
    SELECT balance_minor INTO v_due FROM trial_balance
     WHERE tenant_id='t1' AND purpose='due_from_treasury';
    IF v_profit <> v_due THEN
        RAISE EXCEPTION 't1 profit % <> intercompany claim %', v_profit, v_due;
    END IF;
    RAISE NOTICE 'ok  t1 profit % == its claim on treasury', v_profit;
END $$;

-- Completeness: the roll-up must lose nothing. Every account type carries a
-- NOT NULL financial-statement line, so summing by fs_line must reproduce the
-- trial balance exactly. If a report could omit an account, the equation would
-- STILL hold -- the missing account drops out of both sides (ADR-0009).
DO $$
DECLARE v_tb bigint; v_fs bigint; v_lines bigint;
BEGIN
    SELECT COALESCE(SUM(debits),0) INTO v_tb FROM trial_balance;
    SELECT COALESCE(SUM(t.debits),0), count(DISTINCT ty.fs_line) INTO v_fs, v_lines
      FROM trial_balance t
      JOIN account_types ty ON ty.code = t.purpose
      JOIN fs_lines f ON f.code = ty.fs_line;
    IF v_tb <> v_fs THEN
        RAISE EXCEPTION 'roll-up lost %: trial balance % vs by-statement-line %',
            v_tb - v_fs, v_tb, v_fs;
    END IF;
    RAISE NOTICE 'ok  roll-up complete: % over % statement line(s)', v_tb, v_lines;
END $$;

ROLLBACK;
