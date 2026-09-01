-- Spike 024 -- the differential. Both forms, every as-of point, every cursor,
-- both tenants, both currencies, compared TO THE MINOR UNIT.
--
-- Disagreement anywhere is the finding. Agreement everywhere is the result --
-- and it is only a result because the grid below includes the cases that can
-- make the two forms differ: a book with no close at all (tenant `nc`), an
-- as-of instant exactly on a close boundary and one mid-period, a currency
-- closed to a different depth than its sibling (EUR through January, USD
-- through March), and a cursor pinned BEFORE any close existed (P0), which is
-- the reproducibility case ADR-0011 is for.
--
-- The comparison is a FULL JOIN, not a subtraction: a line present in one form
-- and absent from the other is a disagreement, and `WHERE a - b <> 0` cannot
-- see it (the same NULL-swallowing class trial_balance's COALESCE comment names).
\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION bs_disagreements(p_tenant text, p_asof timestamptz, p_cursor xid8)
RETURNS TABLE (currency char(3), fs_line text, shipped bigint, candidate bigint)
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(s.currency, c.currency), COALESCE(s.fs_line, c.fs_line),
           s.amount_minor, c.amount_minor
    FROM balance_sheet_at(p_tenant, p_asof, p_cursor) s
    FULL JOIN balance_sheet_at_ckpt(p_tenant, p_asof, p_cursor) c
      ON c.currency = s.currency AND c.fs_line = s.fs_line
    WHERE s.amount_minor IS DISTINCT FROM c.amount_minor
       OR s.caption      IS DISTINCT FROM c.caption
       OR s.side         IS DISTINCT FROM c.side
       OR s.sort_order   IS DISTINCT FROM c.sort_order;
$$;

CREATE OR REPLACE FUNCTION tb_disagreements(p_tenant text, p_from timestamptz,
                                            p_to timestamptz, p_cursor xid8)
RETURNS TABLE (account_id uuid, currency char(3),
               shipped_dr bigint, cand_dr bigint, shipped_cr bigint, cand_cr bigint)
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(s.account_id, c.account_id), COALESCE(s.currency, c.currency),
           s.debits, c.debits, s.credits, c.credits
    FROM trial_balance_at(p_tenant, p_from, p_to, p_cursor) s
    FULL JOIN trial_balance_at_ckpt(p_tenant, p_from, p_to, p_cursor) c
      ON c.account_id = s.account_id AND c.currency = s.currency
    WHERE s.debits  IS DISTINCT FROM c.debits
       OR s.credits IS DISTINCT FROM c.credits
       OR s.balance_debit_positive IS DISTINCT FROM c.balance_debit_positive
       OR s.purpose  IS DISTINCT FROM c.purpose
       OR s.category IS DISTINCT FROM c.category;
$$;

-- The grid.
CREATE OR REPLACE VIEW spike_grid AS
SELECT tn.t AS tenant, cu.name AS cursor_name, cu.cur, ao.asof, ao.label
FROM (VALUES ('bk'), ('nc')) tn(t)
CROSS JOIN (SELECT name, cur FROM spike_cursors) cu
CROSS JOIN (VALUES
    ('2026-01-01 00:00+00'::timestamptz, 'before everything'),
    ('2026-01-15 00:00+00', 'mid 2026-01'),
    ('2026-02-01 00:00+00', 'ON the 2026-01 close boundary'),
    ('2026-02-15 00:00+00', 'mid 2026-02'),
    ('2026-03-01 00:00+00', 'ON the 2026-02 close boundary'),
    ('2026-03-15 00:00+00', 'mid 2026-03'),
    ('2026-04-01 00:00+00', 'ON the 2026-03 close boundary'),
    ('2026-04-15 00:00+00', 'mid 2026-04, no close'),
    ('2026-05-01 00:00+00', 'past every entry'),
    ('infinity',            'infinity -- what the sweep uses')
) ao(asof, label);

\echo
\echo '=== 1. BALANCE SHEET: shipped vs checkpoint+tails, 60 (tenant, cursor, as-of) points ==='
SELECT g.tenant, g.cursor_name, g.label,
       (SELECT count(*) FROM balance_sheet_at(g.tenant, g.asof, g.cur))      AS shipped_rows,
       (SELECT count(*) FROM balance_sheet_at_ckpt(g.tenant, g.asof, g.cur)) AS cand_rows,
       (SELECT count(*) FROM bs_disagreements(g.tenant, g.asof, g.cur))      AS disagreements
FROM spike_grid g
ORDER BY g.tenant, g.cursor_name, g.asof;

\echo
\echo '=== 2. the same, as one number. MUST be 0 ==='
SELECT COALESCE(SUM((SELECT count(*) FROM bs_disagreements(g.tenant, g.asof, g.cur))), 0)
         AS total_balance_sheet_disagreements
FROM spike_grid g;

\echo
\echo '=== 3. every disagreeing line, if any ==='
SELECT g.tenant, g.cursor_name, g.label, d.*
FROM spike_grid g, LATERAL bs_disagreements(g.tenant, g.asof, g.cur) d
ORDER BY 1,2,3;

\echo
\echo '=== 4. TRIAL BALANCE: the position reading (-infinity, asof) and the period readings ==='
SELECT g.tenant, g.cursor_name, g.label,
       (SELECT count(*) FROM tb_disagreements(g.tenant, '-infinity', g.asof, g.cur)) AS disagreements_position,
       (SELECT count(*) FROM tb_disagreements(g.tenant, '2026-02-01 00:00+00', g.asof, g.cur)) AS disagreements_from_feb
FROM spike_grid g
ORDER BY g.tenant, g.cursor_name, g.asof;

\echo
\echo '=== 5. trial balance, as one number over both readings and every period window. MUST be 0 ==='
WITH windows AS (
    SELECT g.tenant, g.cur, g.cursor_name, w.f, w.t
    FROM spike_grid g
    CROSS JOIN (VALUES
        ('-infinity'::timestamptz,          'infinity'::timestamptz),
        ('-infinity',                       '2026-02-01 00:00+00'),
        ('-infinity',                       '2026-03-15 00:00+00'),
        ('2026-01-01 00:00+00',             '2026-02-01 00:00+00'),
        ('2026-02-01 00:00+00',             '2026-03-01 00:00+00'),
        ('2026-03-01 00:00+00',             '2026-04-01 00:00+00'),
        ('2026-04-01 00:00+00',             '2026-05-01 00:00+00'),
        ('2026-01-15 00:00+00',             '2026-02-15 00:00+00'),
        ('2026-02-10 00:00+00',             '2026-02-20 00:00+00')
    ) w(f, t)
)
SELECT COALESCE(SUM((SELECT count(*) FROM tb_disagreements(w.tenant, w.f, w.t, w.cur))), 0)
         AS total_trial_balance_disagreements
FROM windows w;

\echo
\echo '=== 6. every disagreeing trial-balance row, if any ==='
WITH windows AS (
    SELECT g.tenant, g.cur, g.cursor_name, w.f, w.t
    FROM spike_grid g
    CROSS JOIN (VALUES
        ('-infinity'::timestamptz,          'infinity'::timestamptz),
        ('-infinity',                       '2026-02-01 00:00+00'),
        ('-infinity',                       '2026-03-15 00:00+00'),
        ('2026-01-01 00:00+00',             '2026-02-01 00:00+00'),
        ('2026-02-01 00:00+00',             '2026-03-01 00:00+00'),
        ('2026-03-01 00:00+00',             '2026-04-01 00:00+00'),
        ('2026-04-01 00:00+00',             '2026-05-01 00:00+00'),
        ('2026-01-15 00:00+00',             '2026-02-15 00:00+00'),
        ('2026-02-10 00:00+00',             '2026-02-20 00:00+00')
    ) w(f, t)
)
SELECT w.tenant, w.cursor_name, w.f, w.t, d.*
FROM windows w, LATERAL tb_disagreements(w.tenant, w.f, w.t, w.cur) d
ORDER BY 1,2,3,4;

\echo
\echo '=== 7. a worked column, so the numbers are visible and not merely equal ==='
SELECT currency, fs_line, caption, amount_minor, side
FROM balance_sheet_at_ckpt('bk', '2026-04-01 00:00+00', (SELECT cur FROM spike_cursors WHERE name='P2'))
WHERE amount_minor <> 0 ORDER BY currency, sort_order;

\echo
\echo '=== 8. the same statement, the shipped form, for the eyeball ==='
SELECT currency, fs_line, caption, amount_minor, side
FROM balance_sheet_at('bk', '2026-04-01 00:00+00', (SELECT cur FROM spike_cursors WHERE name='P2'))
WHERE amount_minor <> 0 ORDER BY currency, sort_order;
