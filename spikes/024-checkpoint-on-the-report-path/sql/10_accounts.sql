-- Spike 024 -- the account register and the period register for the book.
--
-- Two tenants:
--   bk  -- the full book: four monthly periods, USD closed through 2026-03,
--          EUR closed only through 2026-01 (so "the latest close at or before
--          the as-of point" MUST be chosen per currency, not per tenant), and
--          2026-04 left open.
--   nc  -- the same account shape and the same postings, and NO CLOSE AT ALL.
--          The "no closes" case cannot be a phase of `bk`: once bk is closed,
--          its pre-close state is not reachable again.
--
-- Every account type used here is NON-PERIMETER, deliberately: operating_cash
-- and fbo_cash are is_perimeter, so chart_lint.perimeter_unattested fires for
-- them on every book until the attestation feed exists (unowned, roadmap M7),
-- which would put one of the ten reconciliation checks permanently non-zero and
-- destroy the correctness gate. Same substitution spike 022 made and recorded.
-- The asset side is therefore customer_receivable rather than cash.
--
-- No due_from_treasury / due_to_tenants either: they are the one mirror pair in
-- the chart, so recon_scope_breaks has a population only if they are used, and
-- a cross-scope pair posted on one side is a break that has nothing to do with
-- this spike.
\set ON_ERROR_STOP on

SELECT spike_account(t, 'recv_1', 'co_1', 'customer_receivable', 'asset',     'debit',  'per_shard', c),
       spike_account(t, 'recv_2', 'co_2', 'customer_receivable', 'asset',     'debit',  'per_shard', c),
       spike_account(t, 'wallet_1', 'co_1', 'customer_wallet',   'liability', 'credit', 'per_shard', c),
       spike_account(t, 'fee',    NULL,   'fee_revenue',         'revenue',   'credit', 'none',      c),
       spike_account(t, 'inter',  NULL,   'interchange_revenue', 'revenue',   'credit', 'none',      c),
       spike_account(t, 'loss',   NULL,   'credit_loss_expense', 'expense',   'debit',  'none',      c),
       spike_account(t, 'pic',    NULL,   'paid_in_capital',     'equity',    'credit', 'none',      c),
       spike_retained_earnings(t, c)
FROM (VALUES ('bk'), ('nc')) AS tn(t),
     (VALUES ('USD'::char(3)), ('EUR'::char(3))) AS cu(c);

-- The periods. Half-open, resolved once, UTC (the zone is provenance; ADR-0011
-- §5). Both tenants get them -- a period is not a close, and `nc` having periods
-- with no closes is exactly the state the "no closes" arm has to be in.
INSERT INTO ledger_periods (tenant_id, code, starts_at, ends_at, tz) VALUES
    ('bk', '2026-01', '2026-01-01 00:00+00', '2026-02-01 00:00+00', 'UTC'),
    ('bk', '2026-02', '2026-02-01 00:00+00', '2026-03-01 00:00+00', 'UTC'),
    ('bk', '2026-03', '2026-03-01 00:00+00', '2026-04-01 00:00+00', 'UTC'),
    ('bk', '2026-04', '2026-04-01 00:00+00', '2026-05-01 00:00+00', 'UTC'),
    ('nc', '2026-01', '2026-01-01 00:00+00', '2026-02-01 00:00+00', 'UTC'),
    ('nc', '2026-02', '2026-02-01 00:00+00', '2026-03-01 00:00+00', 'UTC'),
    ('nc', '2026-03', '2026-03-01 00:00+00', '2026-04-01 00:00+00', 'UTC'),
    ('nc', '2026-04', '2026-04-01 00:00+00', '2026-05-01 00:00+00', 'UTC');

-- The account ids the shell script posts against, so nothing has to be
-- round-tripped: id = md5(tenant:name:currency).
\echo '--- account ids ---'
SELECT tenant_id, purpose, owner_id, currency, id FROM ledger_accounts
ORDER BY tenant_id, currency, purpose, owner_id;
