-- Spike 024 -- does the bounded form catch every drift class the level form
-- catches? A cheaper check that misses one is a regression, not an optimization.
--
-- Five cells. Each mutates the checkpoint inside a transaction, runs BOTH views,
-- and rolls back, so the cells are independent and the book is unchanged at the
-- end. The first cell is the negative control: ADR-0010 opens with "a check that
-- returns nothing because it was never run is indistinguishable from one that
-- passed", so a bounded form that reports zero on a clean book has proved
-- nothing until it has also been shown red.
\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION spike_drift_cell(p_label text)
RETURNS TABLE (cell text, level_form bigint, bounded_form bigint,
               level_reasons text, bounded_reasons text)
LANGUAGE sql STABLE AS $$
    SELECT p_label,
           (SELECT count(*) FROM recon_checkpoint_breaks),
           (SELECT count(*) FROM recon_checkpoint_breaks_bounded),
           COALESCE((SELECT string_agg(DISTINCT reason, ',' ORDER BY reason)
                       FROM recon_checkpoint_breaks), '-'),
           COALESCE((SELECT string_agg(DISTINCT reason, ',' ORDER BY reason)
                       FROM recon_checkpoint_breaks_bounded), '-');
$$;

\echo '=== 0. NEGATIVE CONTROL -- the clean book. Both must be 0. ==='
SELECT * FROM spike_drift_cell('clean book');

\echo
\echo '=== 1. VALUE DRIFT -- one stored input moved by one minor unit ==='
BEGIN;
UPDATE ledger_period_balances SET input = input + 1
WHERE (tenant_id, period_code, currency, account_id) = (
    SELECT b.tenant_id, b.period_code, b.currency, b.account_id
    FROM ledger_period_balances b WHERE b.tenant_id='bk' AND b.currency='USD'
      AND b.period_code='2026-02' AND b.input > 0
    ORDER BY b.account_id LIMIT 1);
SELECT * FROM spike_drift_cell('value_drift (+1 on a middle close)');
ROLLBACK;

\echo
\echo '=== 2. SPURIOUS ROW -- a checkpoint row for an account with no window entries ==='
BEGIN;
-- any account that has NO stored row for that close, chosen from the data so the
-- cell works under either close convention
INSERT INTO ledger_period_balances (tenant_id, period_code, currency, account_id, input, output)
SELECT 'bk', '2026-01', 'USD', a.id, 4242, 0
FROM ledger_accounts a
WHERE a.tenant_id='bk' AND a.currency='USD'
  AND NOT EXISTS (SELECT 1 FROM ledger_period_balances b
                   WHERE b.tenant_id='bk' AND b.period_code='2026-01'
                     AND b.currency='USD' AND b.account_id=a.id)
ORDER BY a.id LIMIT 1;
SELECT * FROM spike_drift_cell('spurious_row (4242 on an unused account)');
ROLLBACK;

\echo
\echo '=== 3. MISSING ROW, MIDDLE -- delete a row for a close where the account DID move ==='
BEGIN;
DELETE FROM ledger_period_balances b
WHERE (b.tenant_id, b.period_code, b.currency, b.account_id) = (
    -- an account whose stored level CHANGED between 2026-01 and 2026-02, so the
    -- period really has arrivals for it
    SELECT b2.tenant_id, b2.period_code, b2.currency, b2.account_id
    FROM ledger_period_balances b2
    JOIN ledger_period_balances b1
      ON b1.tenant_id=b2.tenant_id AND b1.currency=b2.currency
     AND b1.account_id=b2.account_id AND b1.period_code='2026-01'
    WHERE b2.tenant_id='bk' AND b2.currency='USD' AND b2.period_code='2026-02'
      AND (b2.input, b2.output) <> (b1.input, b1.output)
    ORDER BY b2.account_id LIMIT 1);
SELECT * FROM spike_drift_cell('missing_row, middle close, account moved');
ROLLBACK;

\echo
\echo '=== 4. MISSING ROW, TRAILING, NO ARRIVALS -- the case a difference cannot see ==='
-- The adversarial cell. Delete the LAST close''s row for an account that did NOT
-- move in that period: the stored difference and the recomputed arrivals are both
-- zero, so a pure difference comparison has nothing to disagree about. The level
-- form sees a missing row against a non-zero recomputed LEVEL.
BEGIN;
DELETE FROM ledger_period_balances b
WHERE (b.tenant_id, b.period_code, b.currency, b.account_id) = (
    SELECT b3.tenant_id, b3.period_code, b3.currency, b3.account_id
    FROM ledger_period_balances b3
    JOIN ledger_period_balances b2
      ON b2.tenant_id=b3.tenant_id AND b2.currency=b3.currency
     AND b2.account_id=b3.account_id AND b2.period_code='2026-02'
    WHERE b3.tenant_id='bk' AND b3.currency='USD' AND b3.period_code='2026-03'
      AND (b3.input, b3.output) = (b2.input, b2.output)   -- did NOT move in 2026-03
      AND (b3.input + b3.output) > 0                      -- but holds a real position
    ORDER BY b3.account_id LIMIT 1);
SELECT * FROM spike_drift_cell('missing_row, trailing close, account did NOT move');
ROLLBACK;

\echo
\echo '=== 5. the same trailing deletion, with the SPAN half of the bounded form ==='
\echo '    (this is cell 4 again; the bounded form above already carries the span'
\echo '     check, so cell 4 is the proof it is load-bearing -- see FINDINGS)'

\echo
\echo '=== 6. equivalence on the clean book, row for row rather than count for count ==='
-- The two forms report different GRAINS (levels vs per-close arrivals), so they
-- are not comparable row for row in general. What IS comparable, and is the
-- equivalence that matters: the set of (tenant, period, currency, account) keys
-- either form reports.
SELECT 'level_only' AS side, l.tenant_id, l.period_code, l.currency, l.account_id
FROM recon_checkpoint_breaks l
WHERE NOT EXISTS (SELECT 1 FROM recon_checkpoint_breaks_bounded b
                   WHERE (b.tenant_id,b.period_code,b.currency,b.account_id)
                       = (l.tenant_id,l.period_code,l.currency,l.account_id))
UNION ALL
SELECT 'bounded_only', b.tenant_id, b.period_code, b.currency, b.account_id
FROM recon_checkpoint_breaks_bounded b
WHERE NOT EXISTS (SELECT 1 FROM recon_checkpoint_breaks l
                   WHERE (b.tenant_id,b.period_code,b.currency,b.account_id)
                       = (l.tenant_id,l.period_code,l.currency,l.account_id));

\echo
\echo '=== 7. the invariant checks the bounded form needs, on the clean book ==='
SELECT * FROM recon_close_order;
