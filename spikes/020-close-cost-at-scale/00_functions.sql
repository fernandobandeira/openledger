-- Spike 020 -- functions: seed a wide book, and close a period EXACTLY as the
-- schema's write path does (ADR-0011 sp_close_period, post-fix).
--
-- Nothing here is product. The close function is a verbatim copy of the writer's
-- close primitive proven in spike 014 (01_book.sql sp_close_period): one cursor
-- pinned from pg_snapshot_xmin, one INSERT into ledger_period_closes, the
-- checkpoint written as ONE INSERT ... SELECT per currency over every account,
-- and one closing POSTING per temporary account into retained_earnings. The
-- seed builds the cache exactly as the writer would have left it, so
-- reconciliation is clean before we start.
\set ON_ERROR_STOP on

-- deterministic uuids so entries can reference accounts/txns without a lookup
-- md5(text)::uuid is total and collision-safe enough for a seed.

-- ------------------------------------------------------------ seed one currency's slice of a period
-- p_apc wallets (customer_wallet, liability, per_shard, one owner each), each
-- credited once from a shared house operating_cash account; plus p_rev revenue
-- and p_rev expense postings onto shared house accounts so the close's
-- closing-entry loop has temporary balances to zero. g0 is the running
-- account_seq base for the shared cash account across periods.
-- p_wallet_seq: the per-wallet account_seq for THIS period's deposit leg. Pass the
-- period index (1,2,3,...) when seeding the same wallets across several periods so
-- each wallet's seq stays gapless; p_g0 is the matching base for the shared cash
-- account's seq. Defaults keep the single-period Q1 call simple.
CREATE OR REPLACE FUNCTION spike_seed(p_tenant text, p_curr char(3), p_period text,
                                      p_starts timestamptz, p_ends timestamptz,
                                      p_apc int, p_rev int, p_g0 bigint,
                                      p_wallet_seq int DEFAULT 1)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
    v_cash uuid := md5('cash:'||p_tenant||':'||p_curr)::uuid;
    v_rev  uuid := md5('rev:' ||p_tenant||':'||p_curr)::uuid;
    v_exp  uuid := md5('exp:' ||p_tenant||':'||p_curr)::uuid;
    v_re   uuid := md5('re:'  ||p_tenant||':'||p_curr)::uuid;
    v_span int  := GREATEST(1, LEAST(26, (extract(epoch FROM (p_ends - p_starts))/86400)::int - 1));
BEGIN
    -- shared house accounts (one per tenant/currency), created once
    INSERT INTO ledger_accounts (tenant_id, id, owner_type, owner_id, purpose, category, normal_balance, counterparty_scope, currency)
    VALUES (p_tenant, v_cash, 'house', NULL, 'operating_cash',   'asset',   'debit',  'shared', p_curr),
           (p_tenant, v_rev,  'house', NULL, 'fee_revenue',      'revenue', 'credit', 'none',   p_curr),
           (p_tenant, v_exp,  'house', NULL, 'interest_expense', 'expense', 'debit',  'none',   p_curr),
           (p_tenant, v_re,   'house', NULL, 'retained_earnings','equity',  'credit', 'none',   p_curr)
    ON CONFLICT DO NOTHING;
    INSERT INTO ledger_account_balances (tenant_id, account_id, currency, stripe, owner_type, owner_id_key, purpose, category, normal_balance, input, output, last_seq)
    VALUES (p_tenant, v_cash, p_curr, 0, 'house', '', 'operating_cash',   'asset',   'debit',  0,0,0),
           (p_tenant, v_rev,  p_curr, 0, 'house', '', 'fee_revenue',      'revenue', 'credit', 0,0,0),
           (p_tenant, v_exp,  p_curr, 0, 'house', '', 'interest_expense', 'expense', 'debit',  0,0,0),
           (p_tenant, v_re,   p_curr, 0, 'house', '', 'retained_earnings','equity',  'credit', 0,0,0)
    ON CONFLICT DO NOTHING;

    -- the wallets and their balance rows
    INSERT INTO ledger_accounts (tenant_id, id, owner_type, owner_id, purpose, category, normal_balance, counterparty_scope, currency)
    SELECT p_tenant, md5('acct:'||p_tenant||':'||p_curr||':'||g)::uuid,
           'company', p_curr||'-c'||g, 'customer_wallet', 'liability', 'credit', 'per_shard', p_curr
    FROM generate_series(1, p_apc) g
    ON CONFLICT DO NOTHING;
    INSERT INTO ledger_account_balances (tenant_id, account_id, currency, stripe, owner_type, owner_id_key, purpose, category, normal_balance, input, output, last_seq)
    SELECT p_tenant, md5('acct:'||p_tenant||':'||p_curr||':'||g)::uuid, p_curr, 0,
           'company', p_curr||'-c'||g, 'customer_wallet', 'liability', 'credit', 0,0,0
    FROM generate_series(1, p_apc) g
    ON CONFLICT DO NOTHING;

    -- events + transactions: one deposit per wallet, plus p_rev revenue and p_rev expense postings
    INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
    SELECT p_tenant, md5('evt:'||p_tenant||':'||p_curr||':'||p_period||':'||g)::uuid,
           'deposit', 'internal', 'evt:'||p_tenant||':'||p_curr||':'||p_period||':'||g, '\x00'::bytea, '{}'::jsonb,
           p_starts + ((g % v_span) * interval '1 day') + interval '1 hour'
    FROM generate_series(1, p_apc + 2*p_rev) g;
    INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
    SELECT p_tenant, md5('txn:'||p_tenant||':'||p_curr||':'||p_period||':'||g)::uuid,
           md5('evt:'||p_tenant||':'||p_curr||':'||p_period||':'||g)::uuid, 'deposit', 'posted',
           p_starts + ((g % v_span) * interval '1 day') + interval '1 hour'
    FROM generate_series(1, p_apc + 2*p_rev) g;

    -- deposit legs: DR shared cash (seq g0+g) / CR wallet g (seq 1)
    INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction, amount_minor, currency, stripe, account_seq, effective_at)
    SELECT p_tenant, md5('txn:'||p_tenant||':'||p_curr||':'||p_period||':'||g)::uuid,
           v_cash, 'debit'::ledger_direction, 100 + (g % 900), p_curr, 0, p_g0 + g,
           p_starts + ((g % v_span) * interval '1 day') + interval '1 hour'
    FROM generate_series(1, p_apc) g
    UNION ALL
    SELECT p_tenant, md5('txn:'||p_tenant||':'||p_curr||':'||p_period||':'||g)::uuid,
           md5('acct:'||p_tenant||':'||p_curr||':'||g)::uuid, 'credit'::ledger_direction, 100 + (g % 900), p_curr, 0, p_wallet_seq,
           p_starts + ((g % v_span) * interval '1 day') + interval '1 hour'
    FROM generate_series(1, p_apc) g;

    -- revenue legs: DR shared cash (seq g0+apc+r) / CR fee_revenue (seq base+r)
    INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction, amount_minor, currency, stripe, account_seq, effective_at)
    SELECT p_tenant, md5('txn:'||p_tenant||':'||p_curr||':'||p_period||':'||(p_apc+r))::uuid,
           v_cash, 'debit'::ledger_direction, 5000, p_curr, 0, p_g0 + p_apc + r,
           p_starts + ((( p_apc+r) % v_span) * interval '1 day') + interval '1 hour'
    FROM generate_series(1, p_rev) r
    UNION ALL
    SELECT p_tenant, md5('txn:'||p_tenant||':'||p_curr||':'||p_period||':'||(p_apc+r))::uuid,
           v_rev, 'credit'::ledger_direction, 5000, p_curr, 0, (p_wallet_seq-1)*(p_rev+1) + r,
           p_starts + ((( p_apc+r) % v_span) * interval '1 day') + interval '1 hour'
    FROM generate_series(1, p_rev) r;

    -- expense legs: DR interest_expense (seq base+e) / CR shared cash (seq g0+apc+rev+e)
    INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction, amount_minor, currency, stripe, account_seq, effective_at)
    SELECT p_tenant, md5('txn:'||p_tenant||':'||p_curr||':'||p_period||':'||(p_apc+p_rev+e))::uuid,
           v_exp, 'debit'::ledger_direction, 2000, p_curr, 0, (p_wallet_seq-1)*(p_rev+1) + e,
           p_starts + (((p_apc+p_rev+e) % v_span) * interval '1 day') + interval '1 hour'
    FROM generate_series(1, p_rev) e
    UNION ALL
    SELECT p_tenant, md5('txn:'||p_tenant||':'||p_curr||':'||p_period||':'||(p_apc+p_rev+e))::uuid,
           v_cash, 'credit'::ledger_direction, 2000, p_curr, 0, p_g0 + p_apc + p_rev + e,
           p_starts + (((p_apc+p_rev+e) % v_span) * interval '1 day') + interval '1 hour'
    FROM generate_series(1, p_rev) e;

    -- rebuild the cache exactly as the writer would have left it (posted-only for
    -- input/output; last_seq over all entries) -- so recon_balance_breaks is clean.
    UPDATE ledger_account_balances b SET
        input  = j.input, output = j.output, last_seq = j.last_seq
    FROM (
        SELECT e.account_id,
               COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'),0)  AS input,
               COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'),0) AS output,
               MAX(e.account_seq) AS last_seq
        FROM ledger_entries e WHERE e.tenant_id=p_tenant AND e.currency=p_curr
        GROUP BY e.account_id
    ) j
    WHERE b.tenant_id=p_tenant AND b.currency=p_curr AND b.account_id=j.account_id;
END $fn$;


-- ------------------------------------------------------------ the close, verbatim from the write path
-- ADR-0011 / spike 014 sp_close_period, retained_earnings lookup inlined.
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

    -- THE CHECKPOINT -- one INSERT ... SELECT, every account, cumulative to period end, at cursor C.
    INSERT INTO ledger_period_closes (tenant_id, period_code, currency, starts_at, ends_at, transaction_id, txn_effective_at, computed_at_xid)
    VALUES (p_tenant, p_period, p_currency, v_starts, v_ends, v_txn, v_effective, v_cursor);

    -- input=DEBIT, output=CREDIT -- the ledger_account_balances convention the
    -- baseline's recon_checkpoint_breaks reconciles against (spike 014's helper had
    -- these two swapped; the post-fix baseline defines input=debit/output=credit).
    INSERT INTO ledger_period_balances (tenant_id, period_code, currency, account_id, input, output)
    SELECT p_tenant, p_period, p_currency, e.account_id,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'), 0),
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'),0)
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
    WHERE e.tenant_id=p_tenant AND e.currency=p_currency
      AND e.effective_at < v_ends AND e.xact_id < v_cursor
    GROUP BY e.account_id;

    -- THE CLOSING ENTRIES -- one posting per temporary account, destination retained_earnings.
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
        -- baseline convention: input=DEBIT leg, output=CREDIT leg. The temp
        -- account's closing leg is a DEBIT when it holds a credit balance (dr_pos<0).
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


-- ------------------------------------------------------------ clear the perimeter lint honestly
-- operating_cash is is_perimeter, so a wide book trips chart_lint.perimeter_unattested
-- (the documented "attestations start empty" open item) and, once attested,
-- perimeter_drift. This inserts ONE matching attestation per tenant/currency --
-- as_of past every entry, external = the ledger's own operating_cash balance -- so a
-- healthy book reconciles to zero and the sweep timings are not measuring known noise.
-- p_asof: the attestation's business date. For a multi-period book call it after
-- each close with that period's end date -- perimeter_drift compares the LATEST
-- attestation, and external = the operating_cash balance through p_asof, so the
-- newest one always matches. Default (single-period Q1) is past every entry.
CREATE OR REPLACE FUNCTION spike_attest(p_tenant text, p_curr char(3), p_asof date DEFAULT DATE '2099-12-31')
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
    v_cash uuid := md5('cash:'||p_tenant||':'||p_curr)::uuid;
    v_end timestamptz := ((p_asof + 1)::timestamp) AT TIME ZONE 'UTC';
    v_bal bigint;
BEGIN
    -- exact balance through p_asof on the effective axis, the way perimeter_drift reads it
    SELECT COALESCE(SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END),0)
      INTO v_bal
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id AND x.status='posted'
    WHERE e.tenant_id=p_tenant AND e.account_id=v_cash AND e.currency=p_curr AND e.effective_at < v_end;
    INSERT INTO perimeter_attestations (tenant_id, account_id, currency, as_of, tz, source, external_balance_minor)
    VALUES (p_tenant, v_cash, p_curr, p_asof, 'UTC', 'bank', COALESCE(v_bal,0))
    ON CONFLICT DO NOTHING;
END $fn$;
