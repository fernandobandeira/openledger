-- Spike 024 -- helpers. NOT product; nothing here is proposed for a migration.
--
-- Two of them:
--   spike_account  -- creates an account with a DETERMINISTIC id, so the shell
--                     script can name accounts without round-tripping ids.
--   spike_close    -- the period close, EXACTLY as spike 020 runs it (which is
--                     ADR-0011's sp_close_period with the retained_earnings
--                     lookup inlined, post-fix input=debit/output=credit
--                     convention). The close is the one operation the shipped
--                     HTTP writer cannot express -- POST /v1/transactions has no
--                     `kind`, and fk_closes__txn_kind requires
--                     kind='period_close' -- so it stays SQL here, as it did
--                     there. Every OTHER write in this spike goes through the
--                     compiled binary over HTTP.
\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION spike_account(
    p_tenant text, p_name text, p_owner text, p_purpose text,
    p_category text, p_normal text, p_scope text, p_currency char(3))
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE
    v_id uuid := md5(p_tenant || ':' || p_name || ':' || p_currency)::uuid;
BEGIN
    INSERT INTO ledger_accounts
        (tenant_id, id, owner_type, owner_id, purpose, category, normal_balance,
         counterparty_scope, currency)
    VALUES (p_tenant, v_id,
            CASE WHEN p_owner IS NULL THEN 'house' ELSE 'company' END::account_owner_type,
            p_owner, p_purpose, p_category::ledger_category,
            p_normal::ledger_normal_balance, p_scope, p_currency);
    RETURN v_id;
END $fn$;

-- retained_earnings has to carry the id spike_close derives, because the close
-- writes to it without looking it up.
CREATE OR REPLACE FUNCTION spike_retained_earnings(p_tenant text, p_currency char(3))
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE
    v_id uuid := md5('re:' || p_tenant || ':' || p_currency)::uuid;
BEGIN
    INSERT INTO ledger_accounts
        (tenant_id, id, owner_type, owner_id, purpose, category, normal_balance,
         counterparty_scope, currency)
    VALUES (p_tenant, v_id, 'house', NULL, 'retained_earnings', 'equity', 'credit',
            'none', p_currency);
    RETURN v_id;
END $fn$;


-- ------------------------------------------------------------ the close
-- Verbatim from spikes/020-close-cost-at-scale/00_functions.sql, which took it
-- from ADR-0011 / spike 014's sp_close_period. Unchanged so the two spikes'
-- books are the same object.
CREATE OR REPLACE FUNCTION spike_close(p_tenant text, p_period text, p_currency char(3))
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE
    v_starts timestamptz; v_ends timestamptz; v_cursor xid8;
    v_event uuid; v_txn uuid; v_re uuid := md5('re:'||p_tenant||':'||p_currency)::uuid;
    r record; v_seq bigint; v_re_seq bigint; v_effective timestamptz;
BEGIN
    SELECT starts_at, ends_at INTO STRICT v_starts, v_ends
    FROM ledger_periods WHERE tenant_id = p_tenant AND code = p_period;

    v_cursor := pg_snapshot_xmin(pg_current_snapshot());
    v_effective := v_ends - interval '1 microsecond';

    INSERT INTO ledger_events (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
    VALUES (p_tenant,'period_close','internal', p_tenant||':close:'||p_period||':'||p_currency,
            '\x00'::bytea, jsonb_build_object('period',p_period,'currency',p_currency), v_effective)
    RETURNING id INTO v_event;
    INSERT INTO ledger_transactions (tenant_id, event_id, kind, status, effective_at)
    VALUES (p_tenant, v_event, 'period_close', 'posted', v_effective) RETURNING id INTO v_txn;

    INSERT INTO ledger_period_closes (tenant_id, period_code, currency, starts_at, ends_at, transaction_id, txn_effective_at, computed_at_xid)
    VALUES (p_tenant, p_period, p_currency, v_starts, v_ends, v_txn, v_effective, v_cursor);

    INSERT INTO ledger_period_balances (tenant_id, period_code, currency, account_id, input, output)
    SELECT p_tenant, p_period, p_currency, e.account_id,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'), 0),
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'),0)
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
    WHERE e.tenant_id=p_tenant AND e.currency=p_currency
      AND e.effective_at < v_ends AND e.xact_id < v_cursor
    GROUP BY e.account_id;

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
        INSERT INTO ledger_account_balances AS b (tenant_id, account_id, currency, input, output, last_seq, owner_type, owner_id_key, purpose, category, normal_balance)
        SELECT p_tenant, r.account_id, p_currency,
               CASE WHEN r.dr_pos < 0 THEN -r.dr_pos ELSE 0 END,
               CASE WHEN r.dr_pos > 0 THEN r.dr_pos ELSE 0 END, 1,
               a.owner_type, a.owner_id_key, a.purpose, a.category, a.normal_balance
        FROM ledger_accounts a WHERE a.tenant_id=p_tenant AND a.id=r.account_id AND a.currency=p_currency
        ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
           SET input  = b.input  + CASE WHEN r.dr_pos < 0 THEN -r.dr_pos ELSE 0 END,
               output = b.output + CASE WHEN r.dr_pos > 0 THEN r.dr_pos  ELSE 0 END,
               last_seq = b.last_seq + 1 RETURNING b.last_seq INTO v_seq;
        INSERT INTO ledger_account_balances AS b (tenant_id, account_id, currency, input, output, last_seq, owner_type, owner_id_key, purpose, category, normal_balance)
        VALUES (p_tenant, v_re, p_currency,
                CASE WHEN r.dr_pos > 0 THEN r.dr_pos  ELSE 0 END,
                CASE WHEN r.dr_pos < 0 THEN -r.dr_pos ELSE 0 END, 1,
                'house', '', 'retained_earnings', 'equity', 'credit')
        ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
           SET input  = b.input  + CASE WHEN r.dr_pos > 0 THEN r.dr_pos  ELSE 0 END,
               output = b.output + CASE WHEN r.dr_pos < 0 THEN -r.dr_pos ELSE 0 END,
               last_seq = b.last_seq + 1 RETURNING b.last_seq INTO v_re_seq;

        INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction, amount_minor, currency, account_seq, effective_at)
        VALUES (p_tenant, v_txn, r.account_id,
                CASE WHEN r.dr_pos < 0 THEN 'debit' ELSE 'credit' END::ledger_direction,
                abs(r.dr_pos), p_currency, v_seq, v_effective),
               (p_tenant, v_txn, v_re,
                CASE WHEN r.dr_pos < 0 THEN 'credit' ELSE 'debit' END::ledger_direction,
                abs(r.dr_pos), p_currency, v_re_seq, v_effective);
    END LOOP;
    RETURN v_txn;
END $fn$;


-- ------------------------------------------------------------ the close, three arms
-- Added after the audit finding on `computed_at_xid`. The same close under the
-- three values a one-transaction close can bind, so the question "what can a
-- close actually store" is settled by running it rather than by reading:
--
--   'xmin_strict'  computed_at_xid = pg_snapshot_xmin(pg_current_snapshot()),
--                  checkpoint written BEFORE the closing entries, recompute
--                  bound strict. This is spike_close above, i.e. spike 020's
--                  close, i.e. ADR-0011 as implemented.
--   'own_xid'      computed_at_xid = pg_current_xact_id(), checkpoint written
--                  AFTER the closing entries with `e.xact_id <= C` -- the arm
--                  the audit's cheapest proposal implies.
--   'identity'     computed_at_xid = pg_snapshot_xmin(...) as in the first arm,
--                  checkpoint written AFTER the closing entries, and the close's
--                  OWN transaction included BY IDENTITY rather than through the
--                  cursor: `e.xact_id < C OR e.transaction_id = <this close>`.
--
-- Everything else -- the event, the transaction, the closing postings, the
-- balance-cache upserts -- is byte-identical across the three.
CREATE OR REPLACE FUNCTION spike_close_mode(p_tenant text, p_period text,
                                            p_currency char(3), p_mode text)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE
    v_starts timestamptz; v_ends timestamptz; v_cursor xid8;
    v_event uuid; v_txn uuid; v_re uuid := md5('re:'||p_tenant||':'||p_currency)::uuid;
    r record; v_seq bigint; v_re_seq bigint; v_effective timestamptz;
BEGIN
    IF p_mode NOT IN ('xmin_strict','own_xid','identity') THEN
        RAISE EXCEPTION 'unknown close mode %', p_mode;
    END IF;
    SELECT starts_at, ends_at INTO STRICT v_starts, v_ends
    FROM ledger_periods WHERE tenant_id = p_tenant AND code = p_period;
    v_effective := v_ends - interval '1 microsecond';

    INSERT INTO ledger_events (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
    VALUES (p_tenant,'period_close','internal', p_tenant||':close:'||p_period||':'||p_currency,
            '\x00'::bytea, jsonb_build_object('period',p_period,'currency',p_currency), v_effective)
    RETURNING id INTO v_event;
    INSERT INTO ledger_transactions (tenant_id, event_id, kind, status, effective_at)
    VALUES (p_tenant, v_event, 'period_close', 'posted', v_effective) RETURNING id INTO v_txn;

    -- THE CURSOR. Captured AFTER the two inserts above, so this transaction
    -- already holds an xid and pg_snapshot_xmin can be compared against it.
    v_cursor := CASE p_mode WHEN 'own_xid' THEN pg_current_xact_id()
                            ELSE pg_snapshot_xmin(pg_current_snapshot()) END;

    INSERT INTO ledger_period_closes (tenant_id, period_code, currency, starts_at, ends_at, transaction_id, txn_effective_at, computed_at_xid)
    VALUES (p_tenant, p_period, p_currency, v_starts, v_ends, v_txn, v_effective, v_cursor);

    -- the checkpoint, for the arm that writes it FIRST (pre-close by construction)
    IF p_mode = 'xmin_strict' THEN
        INSERT INTO ledger_period_balances (tenant_id, period_code, currency, account_id, input, output)
        SELECT p_tenant, p_period, p_currency, e.account_id,
               COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'), 0),
               COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'),0)
        FROM ledger_entries e
        JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
        WHERE e.tenant_id=p_tenant AND e.currency=p_currency
          AND e.effective_at < v_ends AND e.xact_id < v_cursor
        GROUP BY e.account_id;
    END IF;

    -- the closing entries, identical in all three arms
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
        INSERT INTO ledger_account_balances AS b (tenant_id, account_id, currency, input, output, last_seq, owner_type, owner_id_key, purpose, category, normal_balance)
        SELECT p_tenant, r.account_id, p_currency,
               CASE WHEN r.dr_pos < 0 THEN -r.dr_pos ELSE 0 END,
               CASE WHEN r.dr_pos > 0 THEN r.dr_pos ELSE 0 END, 1,
               a.owner_type, a.owner_id_key, a.purpose, a.category, a.normal_balance
        FROM ledger_accounts a WHERE a.tenant_id=p_tenant AND a.id=r.account_id AND a.currency=p_currency
        ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
           SET input  = b.input  + CASE WHEN r.dr_pos < 0 THEN -r.dr_pos ELSE 0 END,
               output = b.output + CASE WHEN r.dr_pos > 0 THEN r.dr_pos  ELSE 0 END,
               last_seq = b.last_seq + 1 RETURNING b.last_seq INTO v_seq;
        INSERT INTO ledger_account_balances AS b (tenant_id, account_id, currency, input, output, last_seq, owner_type, owner_id_key, purpose, category, normal_balance)
        VALUES (p_tenant, v_re, p_currency,
                CASE WHEN r.dr_pos > 0 THEN r.dr_pos  ELSE 0 END,
                CASE WHEN r.dr_pos < 0 THEN -r.dr_pos ELSE 0 END, 1,
                'house', '', 'retained_earnings', 'equity', 'credit')
        ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
           SET input  = b.input  + CASE WHEN r.dr_pos > 0 THEN r.dr_pos  ELSE 0 END,
               output = b.output + CASE WHEN r.dr_pos < 0 THEN -r.dr_pos ELSE 0 END,
               last_seq = b.last_seq + 1 RETURNING b.last_seq INTO v_re_seq;

        INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction, amount_minor, currency, account_seq, effective_at)
        VALUES (p_tenant, v_txn, r.account_id,
                CASE WHEN r.dr_pos < 0 THEN 'debit' ELSE 'credit' END::ledger_direction,
                abs(r.dr_pos), p_currency, v_seq, v_effective),
               (p_tenant, v_txn, v_re,
                CASE WHEN r.dr_pos < 0 THEN 'credit' ELSE 'debit' END::ledger_direction,
                abs(r.dr_pos), p_currency, v_re_seq, v_effective);
    END LOOP;

    -- the checkpoint, for the two arms that write it LAST -- so the closing
    -- entries exist to be aggregated. The ONLY difference between the two is how
    -- those entries are admitted: 'own_xid' by `<= C` (which is only the closing
    -- entries because C IS this transaction's id), 'identity' by naming the
    -- transaction, which needs no relationship between C and this xid at all.
    IF p_mode = 'own_xid' THEN
        INSERT INTO ledger_period_balances (tenant_id, period_code, currency, account_id, input, output)
        SELECT p_tenant, p_period, p_currency, e.account_id,
               COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'), 0),
               COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'),0)
        FROM ledger_entries e
        JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
        WHERE e.tenant_id=p_tenant AND e.currency=p_currency
          AND e.effective_at < v_ends AND e.xact_id <= v_cursor
        GROUP BY e.account_id;
    ELSIF p_mode = 'identity' THEN
        INSERT INTO ledger_period_balances (tenant_id, period_code, currency, account_id, input, output)
        SELECT p_tenant, p_period, p_currency, e.account_id,
               COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'), 0),
               COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'),0)
        FROM ledger_entries e
        JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
        WHERE e.tenant_id=p_tenant AND e.currency=p_currency
          AND e.effective_at < v_ends
          AND (e.xact_id < v_cursor OR e.transaction_id = v_txn)
        GROUP BY e.account_id;
    END IF;
    RETURN v_txn;
END $fn$;


-- ------------------------------------------------------------ a raw two-leg posting
-- Needed for ONE thing only: the concurrency arm has to hold a posting
-- UNCOMMITTED across another session's close, and the HTTP writer commits before
-- it returns. This is not a model of the writer and is not proposed as one --
-- ADR-0004 is why the real one is Rust. It exists so that "an older transaction
-- committed below the close's cursor after the close ran" is reachable from a
-- shell script.
CREATE OR REPLACE FUNCTION spike_post_raw(p_tenant text, p_currency char(3),
                                          p_src uuid, p_dst uuid,
                                          p_amount bigint, p_effective timestamptz,
                                          p_key text)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v_event uuid; v_txn uuid;
BEGIN
    INSERT INTO ledger_events (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
    VALUES (p_tenant, 'posting', 'internal', p_key, '\x00'::bytea, '{}'::jsonb, p_effective)
    RETURNING id INTO v_event;
    INSERT INTO ledger_transactions (tenant_id, event_id, kind, status, effective_at)
    VALUES (p_tenant, v_event, 'posting', 'posted', p_effective) RETURNING id INTO v_txn;
    -- account order, because that is the lock order (roadmap M2)
    WITH d AS (
        SELECT * FROM (VALUES (p_src, 0::bigint, p_amount), (p_dst, p_amount, 0::bigint))
                 AS t(acct, dr, cr)
    ), up AS (
        INSERT INTO ledger_account_balances AS b
            (tenant_id, account_id, currency, input, output, last_seq,
             owner_type, owner_id_key, purpose, category, normal_balance)
        SELECT p_tenant, d.acct, p_currency, d.dr, d.cr, 1,
               a.owner_type, a.owner_id_key, a.purpose, a.category, a.normal_balance
        FROM d JOIN ledger_accounts a
          ON a.tenant_id = p_tenant AND a.id = d.acct AND a.currency = p_currency
        ORDER BY d.acct
        ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
           SET input = b.input + EXCLUDED.input, output = b.output + EXCLUDED.output,
               last_seq = b.last_seq + 1
        RETURNING b.account_id, b.last_seq
    )
    INSERT INTO ledger_entries
        (tenant_id, transaction_id, account_id, direction, amount_minor, currency,
         account_seq, effective_at)
    SELECT p_tenant, v_txn, up.account_id,
           CASE WHEN up.account_id = p_dst THEN 'debit' ELSE 'credit' END::ledger_direction,
           p_amount, p_currency, up.last_seq, p_effective
    FROM up;
    RETURN v_txn;
END $fn$;
