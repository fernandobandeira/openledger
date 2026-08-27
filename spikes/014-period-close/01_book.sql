-- Spike 014 -- the book, and a posting helper that mirrors the writer ADR-0005 specifies.
--
-- SPIKE CODE. It is here so the numbers below are reproducible, not because a ledger
-- should post from PL/pgSQL -- ADR-0004 is explicit that it should not. The real writer
-- is Rust; this function does exactly what that writer is specified to do and nothing
-- more: one event, one transaction, two entries, account_seq issued under the lock the
-- balance-row upsert already takes.
--
-- BALANCE CONVENTION, stated once: `input` is credits, `output` is debits, so
-- input - output is the credit-positive balance. The baseline does not say which; this
-- spike had to pick one.

-- one tenant, one currency, house accounts on every purpose the experiments touch
INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose, category, normal_balance, currency)
SELECT 't1', 'house', NULL, t.code, t.category, t.normal_balance, 'USD'
FROM account_types t
WHERE t.code IN ('operating_cash','fbo_cash','customer_wallet','retained_earnings',
                 'paid_in_capital','fee_revenue','interchange_revenue',
                 'interest_expense','credit_loss_expense','platform_rev_share_expense');

CREATE FUNCTION sp_acct(p_tenant text, p_purpose text, p_currency char(3) DEFAULT 'USD')
RETURNS uuid LANGUAGE sql STABLE AS $$
    SELECT id FROM ledger_accounts
    WHERE tenant_id = p_tenant AND purpose = p_purpose AND currency = p_currency
      AND owner_type = 'house'
$$;

-- One posting: a source and a destination, so one leg is unconstructible (ADR-0005).
CREATE FUNCTION sp_post(p_tenant text, p_kind text, p_effective timestamptz,
                        p_debit_purpose text, p_credit_purpose text,
                        p_amount bigint, p_currency char(3) DEFAULT 'USD')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_event uuid; v_txn uuid;
    v_dr uuid := sp_acct(p_tenant, p_debit_purpose,  p_currency);
    v_cr uuid := sp_acct(p_tenant, p_credit_purpose, p_currency);
    v_dr_seq bigint; v_cr_seq bigint;
BEGIN
    INSERT INTO ledger_events (tenant_id, kind, source, idempotency_key, idempotency_hash,
                               payload, effective_at)
    VALUES (p_tenant, p_kind, 'internal', gen_random_uuid()::text, '\x00'::bytea,
            '{}'::jsonb, p_effective)
    RETURNING id INTO v_event;

    INSERT INTO ledger_transactions (tenant_id, event_id, kind, status, effective_at)
    VALUES (p_tenant, v_event, p_kind, 'posted', p_effective)
    RETURNING id INTO v_txn;

    -- account_seq under the lock the upsert already takes -- no SELECT max(), no
    -- advisory lock, no retry loop. This is the one thing the helper must get right.
    INSERT INTO ledger_account_balances AS b (tenant_id, account_id, currency, input, output, last_seq)
    VALUES (p_tenant, v_dr, p_currency, 0, p_amount, 1)
    ON CONFLICT (tenant_id, account_id, currency) DO UPDATE
       SET output = b.output + p_amount, last_seq = b.last_seq + 1, updated_at = now()
    RETURNING b.last_seq INTO v_dr_seq;

    INSERT INTO ledger_account_balances AS b (tenant_id, account_id, currency, input, output, last_seq)
    VALUES (p_tenant, v_cr, p_currency, p_amount, 0, 1)
    ON CONFLICT (tenant_id, account_id, currency) DO UPDATE
       SET input = b.input + p_amount, last_seq = b.last_seq + 1, updated_at = now()
    RETURNING b.last_seq INTO v_cr_seq;

    INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                                amount_minor, currency, account_seq, effective_at)
    VALUES (p_tenant, v_txn, v_dr, 'debit',  p_amount, p_currency, v_dr_seq, p_effective),
           (p_tenant, v_txn, v_cr, 'credit', p_amount, p_currency, v_cr_seq, p_effective);
    RETURN v_txn;
END $$;

-- ------------------------------------------------------------------ the reports,
-- parameterised. ADR-0011 s4: a view cannot take a parameter, and a WHERE contract
-- cannot reach inside an aggregating view, so the three statements become functions.
-- Their bodies are the baseline views' bodies plus four parameters and two predicates:
--     effective_at >= p_from AND effective_at < p_to   -- half-open, the business axis
--     xact_id      <  p_cursor                          -- the commit-ordered cursor
-- Everything else -- the chart-outward enumeration, the currency in every join, the
-- sort_order -- is copied verbatim from migrations/00001_baseline.sql.

-- The cursor a report pins itself to. Everything strictly below this xid8 is decided
-- and can never grow; a row invisible now carries a HIGHER one. ADR-0011 s1.
CREATE FUNCTION report_cursor() RETURNS xid8 LANGUAGE sql VOLATILE AS $$
    SELECT pg_snapshot_xmin(pg_current_snapshot())
$$;

-- SPIKE PLUMBING, and it is here because it cost this spike three runs.
-- report_cursor() is pg_snapshot_xmin, and the snapshot horizon is CLUSTER-WIDE: a
-- transaction held open in ANOTHER DATABASE on the same server pins it, so a report can
-- exclude a posting it has just committed itself. That is exactly the lag ADR-0011
-- records as a cost -- but the experiments that are about something else should not be
-- silently measuring it, so they wait for the horizon to catch up first.
CREATE FUNCTION sp_wait_for_cursor(p_seconds int DEFAULT 60) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE i int; hi xid8;
BEGIN
    FOR i IN 1..(p_seconds*5) LOOP
        SELECT COALESCE(max(xact_id), '0'::xid8) INTO hi FROM ledger_entries;
        IF pg_snapshot_xmin(pg_current_snapshot()) > hi THEN
            RETURN 'commit horizon caught up after ' || round(i/5.0,1) || 's';
        END IF;
        PERFORM pg_sleep(0.2);
    END LOOP;
    RETURN 'WARNING: horizon still behind after ' || p_seconds || 's -- something holds a transaction open';
END $$;

CREATE FUNCTION trial_balance_at(p_tenant text, p_from timestamptz, p_to timestamptz,
                                 p_cursor xid8)
RETURNS TABLE (tenant_id text, account_id uuid, purpose text, category ledger_category,
               currency char(3), debits bigint, credits bigint, balance_debit_positive bigint)
LANGUAGE sql STABLE AS $$
SELECT a.tenant_id, a.id, a.purpose, t.category, e.currency,
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'), 0),
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'), 0),
       SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END)
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                          AND x.status = 'posted'
JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                      AND a.currency = e.currency
JOIN account_types   t ON t.code = a.purpose
WHERE a.tenant_id = p_tenant
  AND e.effective_at >= p_from AND e.effective_at < p_to
  AND e.xact_id < p_cursor
GROUP BY a.tenant_id, a.id, a.purpose, t.category, e.currency;
$$;

-- The income statement OVER A PERIOD. It excludes the closing transaction of any
-- period it covers -- otherwise a closed period reports zero revenue, because the
-- close is exactly the entry that zeroes revenue. ledger_period_closes names it, so
-- this is a key lookup rather than a match on a free-text `kind`.
CREATE FUNCTION income_statement_for(p_tenant text, p_from timestamptz, p_to timestamptz,
                                     p_cursor xid8)
RETURNS TABLE (tenant_id text, currency char(3), fs_line text, caption text,
               sort_order int, amount_minor bigint, side text)
LANGUAGE sql STABLE AS $$
WITH dp AS (
    SELECT e.tenant_id, e.currency, t.fs_line,
           SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END) AS v
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                              AND x.status = 'posted'
    JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                          AND a.currency = e.currency
    JOIN account_types   t ON t.code = a.purpose
    WHERE e.tenant_id = p_tenant
      AND e.effective_at >= p_from AND e.effective_at < p_to
      AND e.xact_id < p_cursor
      AND NOT EXISTS (SELECT 1 FROM ledger_period_closes c
                      WHERE c.tenant_id = x.tenant_id AND c.transaction_id = x.id)
    GROUP BY e.tenant_id, e.currency, t.fs_line
), scopes AS (SELECT DISTINCT l.tenant_id, l.currency FROM ledger_accounts l WHERE l.tenant_id = p_tenant)
SELECT s.tenant_id, s.currency, f.code, f.caption, f.sort_order,
       (CASE WHEN f.side = 'credit' THEN -1 ELSE 1 END * COALESCE(SUM(d.v), 0))::bigint,
       f.side
FROM scopes s
CROSS JOIN fs_lines f
LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency AND d.fs_line = f.code
WHERE f.statement = 'income_statement'
GROUP BY s.tenant_id, s.currency, f.code, f.caption, f.sort_order, f.side
ORDER BY 1, 2, 5;
$$;

-- The balance sheet AS AT AN INSTANT, on both axes. Its earnings plug is bounded by
-- the last close rather than running to inception: retained earnings are in the
-- retained_earnings ACCOUNT after a close, and the plug holds only the open period.
CREATE FUNCTION balance_sheet_at(p_tenant text, p_asof timestamptz, p_cursor xid8)
RETURNS TABLE (tenant_id text, currency char(3), fs_line text, caption text,
               sort_order int, amount_minor bigint, side text)
LANGUAGE sql STABLE AS $$
WITH scopes AS (SELECT DISTINCT l.tenant_id, l.currency FROM ledger_accounts l WHERE l.tenant_id = p_tenant),
-- WHERE THE OPEN PERIOD STARTS: the end of the latest period closed at or before the
-- as-of instant, per currency. NULL (no close yet) means since inception, which is
-- the baseline's behaviour and now says so per currency instead of universally.
open_from AS (
    SELECT s.tenant_id, s.currency,
           (SELECT max(c.ends_at) FROM ledger_period_closes c
            WHERE c.tenant_id = s.tenant_id AND c.currency = s.currency
              AND c.ends_at <= p_asof) AS since
    FROM scopes s
), dp AS (
    SELECT e.tenant_id, e.currency, t.fs_line, t.category, e.effective_at,
           SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END) AS v
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                              AND x.status = 'posted'
    JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                          AND a.currency = e.currency
    JOIN account_types   t ON t.code = a.purpose
    WHERE e.tenant_id = p_tenant AND e.effective_at <= p_asof AND e.xact_id < p_cursor
    GROUP BY e.tenant_id, e.currency, t.fs_line, t.category, e.effective_at
), lines AS (
    SELECT s.tenant_id, s.currency, f.code AS fs_line, f.caption, f.sort_order, f.side,
           COALESCE(SUM(CASE WHEN d.category = 'asset' THEN d.v ELSE -d.v END), 0)::bigint AS amount_minor
    FROM scopes s
    CROSS JOIN fs_lines f
    LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency AND d.fs_line = f.code
    WHERE f.statement = 'balance_sheet'
    GROUP BY s.tenant_id, s.currency, f.code, f.caption, f.sort_order, f.side
)
SELECT l.tenant_id, l.currency, l.fs_line, l.caption, l.sort_order, l.amount_minor, l.side FROM lines l
UNION ALL
SELECT o.tenant_id, o.currency, 'current_year_earnings',
       CASE WHEN o.since IS NULL THEN 'Undistributed earnings (since inception)'
            ELSE 'Earnings since last close' END,
       9000,
       (-COALESCE(SUM(d.v), 0))::bigint, 'liability_equity'
FROM open_from o
LEFT JOIN dp d ON d.tenant_id = o.tenant_id AND d.currency = o.currency
              AND d.category IN ('revenue','expense')
              AND (o.since IS NULL OR d.effective_at >= o.since)
GROUP BY o.tenant_id, o.currency, o.since
ORDER BY 1, 2, 5;
$$;

-- ------------------------------------------------------- the close
--
-- SPIKE CODE standing in for the Rust writer. Everything it does is an ordinary
-- posting: it takes no lock the write path does not already take, writes no UPDATE to
-- the journal, and adds no trigger. Its four steps are the whole design:
--   1. pin a cursor C at the snapshot horizon -- everything below it is decided
--   2. write the checkpoint from entries with xact_id < C and effective_at < ends_at
--   3. post ONE transaction whose postings zero every temporary account into
--      retained_earnings, effective at the last representable instant of the period
--   4. record the close, naming its transaction and its cursor
CREATE FUNCTION sp_close_period(p_tenant text, p_period text, p_currency char(3) DEFAULT 'USD')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_starts timestamptz; v_ends timestamptz; v_cursor xid8;
    v_event uuid; v_txn uuid; v_re uuid := sp_acct(p_tenant,'retained_earnings',p_currency);
    r record; v_seq bigint; v_re_seq bigint; v_effective timestamptz;
BEGIN
    SELECT starts_at, ends_at INTO STRICT v_starts, v_ends
    FROM ledger_periods WHERE tenant_id = p_tenant AND code = p_period;

    -- 1. THE CURSOR. Everything strictly below has committed or aborted and can never
    -- grow. A later arrival backdated into this period gets a HIGHER xid8, so it lands
    -- in the tail rather than invalidating the checkpoint.
    v_cursor := pg_snapshot_xmin(pg_current_snapshot());

    -- The last representable instant INSIDE a half-open period. timestamptz resolves to
    -- 1 microsecond, so this is exact rather than a "23:59:59" approximation, and it
    -- cannot leak into the next period the way `ends_at` itself would.
    v_effective := v_ends - interval '1 microsecond';

    INSERT INTO ledger_events (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
    VALUES (p_tenant,'period_close','internal', p_tenant||':close:'||p_period||':'||p_currency,
            '\x00'::bytea, jsonb_build_object('period',p_period,'currency',p_currency), v_effective)
    RETURNING id INTO v_event;
    INSERT INTO ledger_transactions (tenant_id, event_id, kind, status, effective_at)
    VALUES (p_tenant, v_event, 'period_close', 'posted', v_effective) RETURNING id INTO v_txn;

    -- 2. THE CHECKPOINT -- every account, cumulative to the period end, at cursor C.
    INSERT INTO ledger_period_closes (tenant_id, period_code, currency, starts_at, ends_at,
                                      transaction_id, computed_at_xid)
    VALUES (p_tenant, p_period, p_currency, v_starts, v_ends, v_txn, v_cursor);

    INSERT INTO ledger_period_balances (tenant_id, period_code, currency, account_id, input, output)
    SELECT p_tenant, p_period, p_currency, e.account_id,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'),0),
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'), 0)
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
    WHERE e.tenant_id=p_tenant AND e.currency=p_currency
      AND e.effective_at < v_ends AND e.xact_id < v_cursor
    GROUP BY e.account_id;

    -- 3. THE CLOSING ENTRIES. One POSTING per temporary account -- a source and a
    -- destination, so no leg is constructible on its own (ADR-0005) -- and the
    -- destination is always retained_earnings.
    FOR r IN
        SELECT a.id AS account_id,
               SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END) AS dr_pos
        FROM ledger_entries e
        JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
        JOIN ledger_accounts a ON a.tenant_id=e.tenant_id AND a.id=e.account_id AND a.currency=e.currency
        JOIN account_types t ON t.code=a.purpose
        WHERE e.tenant_id=p_tenant AND e.currency=p_currency
          AND t.category IN ('revenue','expense')
          AND e.effective_at < v_ends AND e.xact_id < v_cursor
        GROUP BY a.id
        HAVING SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END) <> 0
    LOOP
        -- the leg that zeroes the temporary account
        INSERT INTO ledger_account_balances AS b (tenant_id, account_id, currency, input, output, last_seq)
        VALUES (p_tenant, r.account_id, p_currency,
                CASE WHEN r.dr_pos > 0 THEN r.dr_pos ELSE 0 END,
                CASE WHEN r.dr_pos < 0 THEN -r.dr_pos ELSE 0 END, 1)
        ON CONFLICT (tenant_id, account_id, currency) DO UPDATE
           SET input  = b.input  + CASE WHEN r.dr_pos > 0 THEN r.dr_pos  ELSE 0 END,
               output = b.output + CASE WHEN r.dr_pos < 0 THEN -r.dr_pos ELSE 0 END,
               last_seq = b.last_seq + 1 RETURNING b.last_seq INTO v_seq;
        -- ...and its counter-leg on retained_earnings
        INSERT INTO ledger_account_balances AS b (tenant_id, account_id, currency, input, output, last_seq)
        VALUES (p_tenant, v_re, p_currency,
                CASE WHEN r.dr_pos < 0 THEN -r.dr_pos ELSE 0 END,
                CASE WHEN r.dr_pos > 0 THEN r.dr_pos  ELSE 0 END, 1)
        ON CONFLICT (tenant_id, account_id, currency) DO UPDATE
           SET input  = b.input  + CASE WHEN r.dr_pos < 0 THEN -r.dr_pos ELSE 0 END,
               output = b.output + CASE WHEN r.dr_pos > 0 THEN r.dr_pos  ELSE 0 END,
               last_seq = b.last_seq + 1 RETURNING b.last_seq INTO v_re_seq;

        INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                                    amount_minor, currency, account_seq, effective_at)
        VALUES (p_tenant, v_txn, r.account_id,
                CASE WHEN r.dr_pos < 0 THEN 'debit' ELSE 'credit' END::ledger_direction,
                abs(r.dr_pos), p_currency, v_seq, v_effective),
               (p_tenant, v_txn, v_re,
                CASE WHEN r.dr_pos < 0 THEN 'credit' ELSE 'debit' END::ledger_direction,
                abs(r.dr_pos), p_currency, v_re_seq, v_effective);
    END LOOP;
    RETURN v_txn;
END $$;
