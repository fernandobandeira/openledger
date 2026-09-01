-- Spike 024 -- the SHIPPED bodies of trial_balance_at and balance_sheet_at,
-- extracted verbatim from migrations/00001_baseline.sql and renamed with a _ref
-- suffix, so the from-inception form is still callable after PROPOSAL.sql has
-- replaced the real ones. This is how the differential is re-run against the
-- migration as it would actually land.
\set ON_ERROR_STOP on

CREATE FUNCTION trial_balance_at_ref(p_tenant text, p_from timestamptz, p_to timestamptz,
                                 p_cursor xid8)
RETURNS TABLE (tenant_id text, account_id uuid, purpose text, category ledger_category,
               currency char(3), debits bigint, credits bigint, balance_debit_positive bigint)
LANGUAGE sql STABLE AS $$
-- amount_minor is summed as `numeric` and cast back at the end (ADR-0013): a
-- single huge-but-legal row overflows a running bigint SUM and raises the whole
-- SELECT, and a report that dies on one large row reports nothing.
SELECT a.tenant_id, a.id, a.purpose, t.category, e.currency,
       COALESCE(SUM(e.amount_minor::numeric) FILTER (WHERE e.direction='debit'), 0)::bigint,
       COALESCE(SUM(e.amount_minor::numeric) FILTER (WHERE e.direction='credit'), 0)::bigint,
       SUM(CASE WHEN e.direction='debit' THEN e.amount_minor::numeric ELSE -e.amount_minor::numeric END)::bigint
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

CREATE FUNCTION balance_sheet_at_ref(p_tenant text, p_asof timestamptz, p_cursor xid8,
                                 p_chart_version int DEFAULT NULL)
RETURNS TABLE (tenant_id text, currency char(3), chart_version int, fs_line text,
               caption text, sort_order int, amount_minor bigint, side text,
               pinned_cursor xid8)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cv int;
BEGIN
    v_cv := COALESCE(p_chart_version, (SELECT max(cvx.version) FROM chart_versions cvx));
    IF v_cv IS NULL THEN
        RAISE EXCEPTION 'no chart version exists: seed a chart before running a statement'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM chart_versions cvx WHERE cvx.version = v_cv) THEN
        RAISE EXCEPTION 'chart version % does not exist', v_cv USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM ledger_entries e
        JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                                  AND x.status = 'posted'
        JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                              AND a.currency = e.currency
        WHERE e.tenant_id = p_tenant
          AND e.effective_at < p_asof
          AND e.xact_id < p_cursor
          AND NOT EXISTS (SELECT 1 FROM chart_presentation p
                          WHERE p.chart_version = v_cv AND p.type_code = a.purpose)
    ) THEN
        RAISE EXCEPTION
          'chart version % does not present every account type with posted entries as at this instant (chart_lint.type_unpresented)',
          v_cv USING ERRCODE = '23514';
    END IF;

    RETURN QUERY
    WITH scopes AS (
        -- Enumerated from the ACCOUNTS, not from the entries. A scope that has been
        -- opened but has not yet posted anything is still a scope, and a report that
        -- cannot name it cannot claim completeness over it. HONEST LIMIT: this is
        -- still enumeration from data, one level further out -- there is no tenant
        -- registry, so a scope with no accounts at all remains invisible.
        SELECT DISTINCT l.tenant_id, l.currency FROM ledger_accounts l
        WHERE l.tenant_id = p_tenant
    ), pos AS (
        -- HALF-OPEN (effective_at < p_asof), to match the period model and the
        -- income statement: a balance sheet "as at ends_at" is the period's closing
        -- position, [starts_at, ends_at) (ADR-0011).
        SELECT e.tenant_id, e.currency, e.account_id,
               p.category, p.counterparty_scope, p.fs_line, p.fs_line_contra,
               SUM(CASE WHEN e.direction='debit' THEN e.amount_minor::numeric
                        ELSE -e.amount_minor::numeric END) AS v
        FROM ledger_entries e
        JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                                  AND x.status = 'posted'
        JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                              AND a.currency  = e.currency
        JOIN chart_presentation p ON p.chart_version = v_cv AND p.type_code = a.purpose
        WHERE e.tenant_id = p_tenant AND e.effective_at < p_asof AND e.xact_id < p_cursor
        GROUP BY e.tenant_id, e.currency, e.account_id,
                 p.category, p.counterparty_scope, p.fs_line, p.fs_line_contra
    ), dp AS (
        -- ROUTE ON POSITION SIGN (ADR-0012, amended by A10). A position that has
        -- swung to the opposite side of its normal presents on its declared CONTRA
        -- line -- for ANY balance-sheet type that declares one, not only per_shard.
        -- Sign-swing is orthogonal to sharding: a `shared` payable that has gone
        -- into a receivable position must present gross under its contra line, not
        -- net to zero against another payable on the same line.
        SELECT pos.tenant_id, pos.currency, pos.category,
               CASE WHEN pos.fs_line_contra IS NOT NULL
                         AND ((pos.category = 'asset'     AND pos.v < 0)
                           OR (pos.category = 'liability' AND pos.v > 0))
                    THEN pos.fs_line_contra ELSE pos.fs_line END AS fs_line,
               pos.v
        FROM pos
    ), lines AS (
        SELECT s.tenant_id, s.currency,
               f.code AS fs_line, f.caption, f.sort_order, f.side,
               COALESCE(SUM(CASE WHEN f.side = 'asset' THEN d.v ELSE -d.v END), 0)::bigint
                   AS amount_minor
        FROM scopes s
        JOIN fs_lines f ON f.chart_version = v_cv
        LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency
                      AND d.fs_line = f.code
        WHERE f.statement = 'balance_sheet'
        GROUP BY s.tenant_id, s.currency, f.code, f.caption, f.sort_order, f.side
    ), plug AS (
        -- THE UN-CLOSED-EARNINGS PLUG (A3, replacing the max(ends_at) watermark).
        -- The net of ALL temporary (revenue/expense) positions at the cursor,
        -- INCLUDING closing entries. A closed period's operational entries and its
        -- closing reversal cancel, so what remains is exactly earnings not yet
        -- closed at this cursor: no watermark to walk, no ledger_period_closes read,
        -- and a caption that cannot move under a fixed cursor (a caption that moves
        -- under a fixed cursor is itself a reproducibility break). A backdated
        -- arrival above a close cursor is un-closed until a later close sweeps it,
        -- and shows here rather than dropping from equity forever.
        SELECT s.tenant_id, s.currency,
               (-COALESCE((
                   SELECT SUM(CASE WHEN e.direction='debit' THEN e.amount_minor::numeric
                                   ELSE -e.amount_minor::numeric END)
                   FROM ledger_entries e
                   JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                                             AND x.status = 'posted'
                   JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                                         AND a.currency = e.currency
                   JOIN chart_presentation p ON p.chart_version = v_cv AND p.type_code = a.purpose
                   WHERE e.tenant_id = s.tenant_id AND e.currency = s.currency
                     AND e.effective_at < p_asof AND e.xact_id < p_cursor
                     AND p.category IN ('revenue','expense')
               ), 0))::bigint AS amount_minor
        FROM scopes s
    )
    SELECT l.tenant_id, l.currency, v_cv, l.fs_line, l.caption, l.sort_order,
           l.amount_minor, l.side, p_cursor
    FROM lines l
    UNION ALL
    -- The synthesised un-closed-earnings plug. Its side is 'equity'. The caption is
    -- CONSTANT (A3): the plug always means "earnings not yet closed to retained
    -- earnings", so it does not change with whether a close has happened.
    SELECT g.tenant_id, g.currency, v_cv, 'current_year_earnings',
           'Undistributed earnings (since inception)', 9000,
           g.amount_minor, 'equity', p_cursor
    FROM plug g
    ORDER BY 1, 2, 6;
END $$;
