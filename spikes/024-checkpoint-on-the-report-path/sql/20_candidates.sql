-- Spike 024 -- the candidate rewritten bodies, installed BESIDE the shipped ones
-- under `_ckpt` names so the two forms can be compared row for row on the same
-- book in the same snapshot. PROPOSAL.sql is where they appear as replacements.
--
-- ADR-0011 §3's specification, made exact:
--
--   position(as_of, cursor) =
--        the checkpoint of the latest close for THIS CURRENCY whose period end
--        is at or before as_of AND whose computed_at_xid is at or below the
--        report cursor
--      + tail A: posted entries effective at or after that boundary and before
--        as_of, at or below the cursor
--      + tail B: posted entries effective before the boundary whose xact_id is
--        at or above the close's cursor and below the report cursor -- the
--        backdated arrivals.
--
-- THREE things in that sentence are not in ADR-0011 §3, and each is load-bearing:
--
--  (a) PER CURRENCY. The close is per (tenant, period_code, currency)
--      (pk_closes), so a tenant can be closed through March in USD and only
--      through January in EUR. A boundary chosen per TENANT reads the wrong
--      checkpoint for one of them.
--
--  (b) AND WHOSE computed_at_xid IS AT OR BELOW THE REPORT CURSOR. A checkpoint
--      computed at C is the set {xact_id < C}. A report pinned at P < C must not
--      see rows between P and C, so a checkpoint written AFTER the report was
--      issued cannot be used to reproduce it -- it would restate the statement
--      upward. Without this predicate the rewritten form breaks exactly the
--      property the cursor exists for. §3 does not state it.
--
--  (c) THE THREE TERMS ARE DISJOINT AND THEIR UNION IS EXACT. checkpoint has
--      eff < boundary and xact < C; tail B has eff < boundary and xact >= C;
--      tail A has eff >= boundary. Disjoint. And any posted entry with
--      eff < as_of and xact < P falls in exactly one, given C <= P. So the sum
--      is the from-inception aggregate, not an approximation of it.
--
-- With NO close the form degrades to today's behaviour with no special case:
-- boundary = '-infinity' (and ck_entries__effective_finite forbids an entry
-- there), so tail B is empty, tail A is everything, and the checkpoint term
-- joins nothing.
\set ON_ERROR_STOP on


-- ------------------------------------------------------------ the anchor
-- Factored out because all three candidate readers need exactly the same choice
-- of boundary, and a second copy of it is a second place for (a) and (b) to be
-- got wrong. STABLE: it reads only committed catalog and table state.
CREATE OR REPLACE FUNCTION checkpoint_anchor(p_tenant text, p_asof timestamptz, p_cursor xid8)
RETURNS TABLE (currency char(3), period_code text, boundary timestamptz, ckpt_cursor xid8)
LANGUAGE sql STABLE AS $$
    SELECT s.currency, c.period_code,
           COALESCE(c.ends_at, '-infinity'::timestamptz),
           COALESCE(c.computed_at_xid, '0'::xid8)
    FROM (SELECT DISTINCT l.currency FROM ledger_accounts l WHERE l.tenant_id = p_tenant) s
    LEFT JOIN LATERAL (
        SELECT k.period_code, k.ends_at, k.computed_at_xid
        FROM ledger_period_closes k
        WHERE k.tenant_id = p_tenant
          AND k.currency = s.currency
          AND k.ends_at <= p_asof            -- half-open: a close AT the as-of
                                             -- instant leaves tail A empty
          AND k.computed_at_xid <= p_cursor   -- (b), the reproducibility guard
        ORDER BY k.ends_at DESC
        LIMIT 1
    ) c ON true;
$$;


-- ------------------------------------------------------------ the position
-- The per-account gross position at (as_of, cursor), from checkpoint + two
-- tails. Returned gross (debits and credits separately) rather than netted,
-- because trial_balance_at needs both halves and the balance sheet needs the
-- difference -- and a gross sum is what makes the "did this account have any
-- posted entry" question answerable at all (ck_entries__amount_positive says
-- amount_minor > 0, so debits + credits > 0 iff at least one posted entry).
CREATE OR REPLACE FUNCTION checkpoint_position(p_tenant text, p_asof timestamptz, p_cursor xid8)
RETURNS TABLE (currency char(3), account_id uuid, debits numeric, credits numeric)
LANGUAGE sql STABLE AS $$
    WITH a AS (SELECT * FROM checkpoint_anchor(p_tenant, p_asof, p_cursor)),
    terms AS (
        -- 1. the checkpoint. input = debit legs, output = credit legs, posted
        -- only -- the same convention as ledger_account_balances.
        SELECT b.currency, b.account_id, b.input::numeric AS dr, b.output::numeric AS cr
        FROM a
        JOIN ledger_period_balances b
          ON b.tenant_id = p_tenant AND b.currency = a.currency
         AND b.period_code = a.period_code
        UNION ALL
        -- 2. tail A -- effective at or after the boundary, before the as-of
        SELECT e.currency, e.account_id,
               CASE WHEN e.direction = 'debit'  THEN e.amount_minor::numeric ELSE 0 END,
               CASE WHEN e.direction = 'credit' THEN e.amount_minor::numeric ELSE 0 END
        FROM a
        JOIN ledger_entries e
          ON e.tenant_id = p_tenant AND e.currency = a.currency
         AND e.effective_at >= a.boundary AND e.effective_at < p_asof
         AND e.xact_id < p_cursor
        JOIN ledger_transactions x
          ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id AND x.status = 'posted'
        UNION ALL
        -- 3. tail B -- the backdated arrivals: effective BELOW the boundary,
        -- committed at or above the close's cursor. This is the term
        -- ix_entries__asof_commit was created for (ADR-0011 §3).
        SELECT e.currency, e.account_id,
               CASE WHEN e.direction = 'debit'  THEN e.amount_minor::numeric ELSE 0 END,
               CASE WHEN e.direction = 'credit' THEN e.amount_minor::numeric ELSE 0 END
        FROM a
        JOIN ledger_entries e
          ON e.tenant_id = p_tenant AND e.currency = a.currency
         AND e.effective_at < a.boundary
         AND e.xact_id >= a.ckpt_cursor AND e.xact_id < p_cursor
        JOIN ledger_transactions x
          ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id AND x.status = 'posted'
    )
    SELECT t.currency, t.account_id, SUM(t.dr), SUM(t.cr)
    FROM terms t
    GROUP BY t.currency, t.account_id;
$$;


-- ------------------------------------------------------------ the balance sheet
-- The shipped body with three substitutions and nothing else moved: `pos` reads
-- checkpoint_position instead of aggregating ledger_entries; the plug reads the
-- same; and the A14 guard asks the same question of the same population. The
-- chart-outward CROSS JOIN fs_lines, the contra routing, the sign-by-line rule,
-- the constant plug caption and the ORDER BY are copied verbatim.
CREATE OR REPLACE FUNCTION balance_sheet_at_ckpt(p_tenant text, p_asof timestamptz, p_cursor xid8,
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
    -- A14, over the checkpoint population. `debits + credits > 0` is what makes
    -- this equivalent to the shipped EXISTS over ledger_entries: amount_minor is
    -- CHECKed > 0, so an account with any posted entry below the boundary has a
    -- non-zero gross checkpoint row, and a dormant account the close wrote 0/0
    -- for is correctly NOT treated as having entries.
    IF EXISTS (
        SELECT 1
        FROM checkpoint_position(p_tenant, p_asof, p_cursor) q
        JOIN ledger_accounts a ON a.tenant_id = p_tenant AND a.id = q.account_id
                              AND a.currency = q.currency
        WHERE q.debits + q.credits > 0
          AND NOT EXISTS (SELECT 1 FROM chart_presentation p
                          WHERE p.chart_version = v_cv AND p.type_code = a.purpose)
    ) THEN
        RAISE EXCEPTION
          'chart version % does not present every account type with posted entries as at this instant (chart_lint.type_unpresented)',
          v_cv USING ERRCODE = '23514';
    END IF;

    RETURN QUERY
    WITH scopes AS (
        SELECT DISTINCT l.tenant_id, l.currency FROM ledger_accounts l
        WHERE l.tenant_id = p_tenant
    ), pos AS (
        SELECT p_tenant AS tenant_id, q.currency, q.account_id,
               p.category, p.counterparty_scope, p.fs_line, p.fs_line_contra,
               q.debits - q.credits AS v
        FROM checkpoint_position(p_tenant, p_asof, p_cursor) q
        JOIN ledger_accounts a ON a.tenant_id = p_tenant AND a.id = q.account_id
                              AND a.currency = q.currency
        JOIN chart_presentation p ON p.chart_version = v_cv AND p.type_code = a.purpose
    ), dp AS (
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
        -- The net of ALL temporary positions at the cursor, closing entries
        -- included (A3) -- the same population as `pos`, filtered to
        -- revenue/expense. Reads the checkpoint through the same anchor, so the
        -- plug cannot disagree with the lines above it about where the boundary
        -- is, which a second hand-written subquery could.
        SELECT s.tenant_id, s.currency,
               (-COALESCE((
                   SELECT SUM(pp.v) FROM pos pp
                   WHERE pp.tenant_id = s.tenant_id AND pp.currency = s.currency
                     AND pp.category IN ('revenue','expense')
               ), 0))::bigint AS amount_minor
        FROM scopes s
    )
    SELECT l.tenant_id, l.currency, v_cv, l.fs_line, l.caption, l.sort_order,
           l.amount_minor, l.side, p_cursor
    FROM lines l
    UNION ALL
    SELECT g.tenant_id, g.currency, v_cv, 'current_year_earnings',
           'Undistributed earnings (since inception)', 9000,
           g.amount_minor, 'equity', p_cursor
    FROM plug g
    ORDER BY 1, 2, 6;
END $$;


-- ------------------------------------------------------------ the trial balance
-- trial_balance_at is a FLOW over [p_from, p_to), not a position, so the
-- checkpoint can only enter as a DIFFERENCE of two positions:
--
--     gross over [from, to)  =  prefix(to) - prefix(from)
--
-- which is exact because prefix() sums GROSS debits and credits over
-- {eff < x, xact < cursor, posted} and that set is monotone in x. The two
-- prefixes are evaluated at the SAME cursor and independent anchors, because
-- from and to can straddle a close.
--
-- WHAT THIS COSTS, and it is not free: the two prefixes each carry a tail from
-- their own boundary, so the work is roughly (to - boundary_to) +
-- (from - boundary_from) rather than (to - from). For a window that sits well
-- inside one period that is MORE work than the shipped body does; for a window
-- whose lower bound is deep in history -- the position reading, p_from
-- '-infinity' -- it is bounded by two period lengths where the shipped body is
-- unbounded. Which side of that trade a caller is on is a NUMBER, and it is in
-- MEASUREMENT-PLAN.md, not asserted here.
CREATE OR REPLACE FUNCTION trial_balance_at_ckpt(p_tenant text, p_from timestamptz,
                                                 p_to timestamptz, p_cursor xid8)
RETURNS TABLE (tenant_id text, account_id uuid, purpose text, category ledger_category,
               currency char(3), debits bigint, credits bigint, balance_debit_positive bigint)
LANGUAGE sql STABLE AS $$
    WITH d AS (
        SELECT q.currency, q.account_id, q.debits, q.credits
        FROM checkpoint_position(p_tenant, p_to, p_cursor) q
        UNION ALL
        SELECT q.currency, q.account_id, -q.debits, -q.credits
        FROM checkpoint_position(p_tenant, p_from, p_cursor) q
    ), net AS (
        SELECT d.currency, d.account_id,
               SUM(d.debits) AS dr, SUM(d.credits) AS cr
        FROM d GROUP BY d.currency, d.account_id
    )
    SELECT p_tenant, n.account_id, a.purpose, t.category, n.currency,
           n.dr::bigint, n.cr::bigint, (n.dr - n.cr)::bigint
    FROM net n
    JOIN ledger_accounts a ON a.tenant_id = p_tenant AND a.id = n.account_id
                          AND a.currency = n.currency
    JOIN account_types   t ON t.code = a.purpose
    -- The shipped body GROUPs over entries in the window, so an account with no
    -- entry in the window produces no row. Here it produces a 0/0 row, which is
    -- the same statement said differently -- dropped, so the two outputs are
    -- comparable as multisets.
    WHERE n.dr <> 0 OR n.cr <> 0;
$$;
