-- Spike 024 -- the acceptance run for PROPOSAL.sql, on a book the proposal has
-- actually been applied to. The comparison is now the OTHER way round: the
-- shipped names carry the checkpoint form, and the _ref names carry the
-- from-inception bodies extracted from the baseline.
\set ON_ERROR_STOP on

\echo '=== 1. THE GATE ==='
SELECT * FROM reconciliation ORDER BY check_name;
SELECT COALESCE(SUM(breaks),0) AS total_breaks FROM reconciliation;

\echo
\echo '=== 2. the checkpoint lives in partitions, and the rows are all there ==='
SELECT tableoid::regclass AS lives_in, count(*) FROM ledger_period_balances
GROUP BY 1 ORDER BY 1;
SELECT pg_get_partkeydef('ledger_period_balances'::regclass) AS partition_key;

\echo
\echo '=== 3. the AT-CLOSE property, which is now what the comment claims ==='
SELECT b.period_code, a.purpose, b.input - b.output AS dr_pos
FROM ledger_period_balances b
JOIN ledger_accounts a ON a.tenant_id=b.tenant_id AND a.id=b.account_id AND a.currency=b.currency
JOIN account_types t ON t.code=a.purpose
WHERE b.tenant_id='bk' AND b.currency='USD' AND t.category IN ('revenue','expense','equity')
ORDER BY 1,2;

\echo
\echo '=== 4. the differential, 60 points, shipped(checkpoint) vs _ref(from inception) ==='
CREATE OR REPLACE FUNCTION bs_disagreements2(p_tenant text, p_asof timestamptz, p_cursor xid8)
RETURNS TABLE (currency char(3), fs_line text, checkpoint_form bigint, inception_form bigint)
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(c.currency, s.currency), COALESCE(c.fs_line, s.fs_line),
           c.amount_minor, s.amount_minor
    FROM balance_sheet_at(p_tenant, p_asof, p_cursor) c
    FULL JOIN balance_sheet_at_ref(p_tenant, p_asof, p_cursor) s
      ON s.currency = c.currency AND s.fs_line = c.fs_line
    WHERE s.amount_minor IS DISTINCT FROM c.amount_minor
       OR s.caption IS DISTINCT FROM c.caption OR s.side IS DISTINCT FROM c.side
       OR s.sort_order IS DISTINCT FROM c.sort_order;
$$;
CREATE OR REPLACE FUNCTION tb_disagreements2(p_tenant text, p_from timestamptz,
                                             p_to timestamptz, p_cursor xid8)
RETURNS TABLE (account_id uuid, currency char(3), c_dr bigint, s_dr bigint,
               c_cr bigint, s_cr bigint)
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(c.account_id, s.account_id), COALESCE(c.currency, s.currency),
           c.debits, s.debits, c.credits, s.credits
    FROM trial_balance_at(p_tenant, p_from, p_to, p_cursor) c
    FULL JOIN trial_balance_at_ref(p_tenant, p_from, p_to, p_cursor) s
      ON s.account_id = c.account_id AND s.currency = c.currency
    WHERE s.debits IS DISTINCT FROM c.debits OR s.credits IS DISTINCT FROM c.credits
       OR s.balance_debit_positive IS DISTINCT FROM c.balance_debit_positive;
$$;

SELECT COALESCE(SUM((SELECT count(*) FROM bs_disagreements2(g.tenant, g.asof, g.cur))),0)
         AS balance_sheet_disagreements
FROM spike_grid g;
SELECT g.tenant, g.cursor_name, g.label, d.*
FROM spike_grid g, LATERAL bs_disagreements2(g.tenant, g.asof, g.cur) d;

WITH windows AS (
    SELECT g.tenant, g.cur, w.f, w.t FROM spike_grid g
    CROSS JOIN (VALUES
        ('-infinity'::timestamptz,'infinity'::timestamptz),
        ('-infinity','2026-02-01 00:00+00'), ('-infinity','2026-03-15 00:00+00'),
        ('2026-01-01 00:00+00','2026-02-01 00:00+00'),
        ('2026-02-01 00:00+00','2026-03-01 00:00+00'),
        ('2026-03-01 00:00+00','2026-04-01 00:00+00'),
        ('2026-04-01 00:00+00','2026-05-01 00:00+00'),
        ('2026-01-15 00:00+00','2026-02-15 00:00+00'),
        ('2026-02-10 00:00+00','2026-02-20 00:00+00')) w(f,t)
)
SELECT COALESCE(SUM((SELECT count(*) FROM tb_disagreements2(w.tenant, w.f, w.t, w.cur))),0)
         AS trial_balance_disagreements
FROM windows w;

\echo
\echo '=== 5. the inverted window is now REFUSED rather than answered with negatives ==='
DO $$
BEGIN
    PERFORM * FROM trial_balance_at('bk','2026-02-01 00:00+00','2026-01-01 00:00+00',
                                    report_cursor());
    RAISE EXCEPTION 'an inverted window was ACCEPTED -- the guard is not there';
EXCEPTION WHEN sqlstate '22023' THEN
    RAISE NOTICE 'inverted window refused, as designed: %', SQLERRM;
END $$;

\echo
\echo '=== 6. the four close-order / forgery classes, and the empty-close carve-out ==='
SELECT count(*) AS close_order_breaks FROM recon_close_breaks;
SELECT (SELECT count(*) FROM recon_checkpoint_breaks)         AS level_form,
       (SELECT count(*) FROM recon_checkpoint_breaks_bounded) AS bounded_form;

\echo
\echo '=== 7. the two new indexes exist and the old ones are untouched ==='
SELECT pg_get_indexdef(x.indexrelid) FROM pg_index x
JOIN pg_class i ON i.oid=x.indexrelid JOIN pg_class t ON t.oid=x.indrelid
WHERE t.relname='ledger_entries' ORDER BY i.relname;
