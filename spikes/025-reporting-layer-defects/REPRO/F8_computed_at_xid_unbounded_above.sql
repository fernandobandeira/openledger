-- F8 -- computed_at_xid is bounded from below only, and the app role may supply it.
--
-- recon_close_breaks tests exactly one thing:
--     WHERE c.computed_at_xid < x.xact_id      -- 'cursor_precedes_close'
-- so a cursor at or above the closing transaction's commit position passes, and
-- "at or above" has no ceiling. close_disclosures selects the arrivals that sit
-- ABOVE the stored cursor:
--     AND e.xact_id >= c.computed_at_xid
-- A cursor set to the top of the xid8 range therefore makes that view PERMANENTLY
-- EMPTY for the period: no arrival can ever reach it, and the IAS 1.41-shaped
-- disclosure this design ships INSTEAD of a period lock is silently switched off.
--
-- computed_at_xid sits under a TABLE-WIDE INSERT grant on ledger_period_closes,
-- so the app role supplies it -- unlike ledger_entries.xact_id, which the
-- column-level grant withholds.
--
-- TWO TENANTS, so the reproduction carries its own control: t1 is closed with a
-- cursor at the top of the range, t2 with its closing transaction's own commit
-- position. One backdated arrival is then appended to each closed period, and the
-- two behave differently.
--
-- The deeper question -- whether a one-transaction close can store a value all
-- three predicates agree on -- is a separate spike's. This reproduces the bound.
\set ON_ERROR_STOP off

\echo '=== 0. the negative control'
SELECT * FROM reconciliation;

-- t2 needs somewhere for its close to sweep earnings to.
INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose, category,
                             normal_balance, counterparty_scope, currency)
VALUES ('t2','house',NULL,'retained_earnings','equity','credit','none','USD');

\echo
\echo '=== 1. two honest closes of August, differing only in computed_at_xid'
BEGIN;
SET LOCAL ROLE openledger_app;

INSERT INTO ledger_periods (tenant_id, code, starts_at, ends_at, tz) VALUES
  ('t1','2026-08','2026-08-01T00:00:00Z','2026-09-01T00:00:00Z','UTC'),
  ('t2','2026-08','2026-08-01T00:00:00Z','2026-09-01T00:00:00Z','UTC');

INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                           idempotency_hash, payload, effective_at) VALUES
  ('t1','02500000-0000-7000-8000-0000000000c1','period_close','internal','close-08',
   decode('00','hex'),'{}'::jsonb,'2026-08-31T00:00:00Z'),
  ('t2','02500000-0000-7000-8000-0000000000d1','period_close','internal','close-08',
   decode('00','hex'),'{}'::jsonb,'2026-08-31T00:00:00Z');
INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at) VALUES
  ('t1','02500000-0000-7000-8000-0000000000c2','02500000-0000-7000-8000-0000000000c1',
   'period_close','posted','2026-08-31T00:00:00Z'),
  ('t2','02500000-0000-7000-8000-0000000000d2','02500000-0000-7000-8000-0000000000d1',
   'period_close','posted','2026-08-31T00:00:00Z');

-- the stripe rows the two retained_earnings accounts have never had
INSERT INTO ledger_account_balances (tenant_id, account_id, currency, stripe,
        owner_type, owner_id_key, purpose, category, normal_balance, input, output, last_seq)
SELECT a.tenant_id, a.id, 'USD', 0, a.owner_type, a.owner_id_key, a.purpose, a.category,
       a.normal_balance, 0, CASE a.tenant_id WHEN 't1' THEN 220000 ELSE 100000 END, 1
FROM ledger_accounts a WHERE a.purpose='retained_earnings';

-- t1's sweep: revenue 250,000 out, expense 30,000 back, net 220,000 to retained.
INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, stripe, account_seq, effective_at)
SELECT 't1','02500000-0000-7000-8000-0000000000c2', a.id, v.direction::ledger_direction,
       v.amount, 'USD', 0, v.seq, '2026-08-31T00:00:00Z'
FROM (VALUES ('fee_revenue','debit',250000::bigint,2::bigint),
             ('platform_rev_share_expense','credit',30000,2),
             ('retained_earnings','credit',220000,1))
     AS v(purpose,direction,amount,seq)
JOIN ledger_accounts a ON a.tenant_id='t1' AND a.purpose=v.purpose;
UPDATE ledger_account_balances b SET input=b.input+250000, last_seq=2
FROM ledger_accounts a WHERE a.tenant_id=b.tenant_id AND a.id=b.account_id
 AND a.currency=b.currency AND b.tenant_id='t1' AND a.purpose='fee_revenue';
UPDATE ledger_account_balances b SET output=b.output+30000, last_seq=2
FROM ledger_accounts a WHERE a.tenant_id=b.tenant_id AND a.id=b.account_id
 AND a.currency=b.currency AND b.tenant_id='t1' AND a.purpose='platform_rev_share_expense';

-- t2's sweep: revenue 100,000 to retained.
INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, stripe, account_seq, effective_at)
SELECT 't2','02500000-0000-7000-8000-0000000000d2', a.id, v.direction::ledger_direction,
       100000, 'USD', 0, v.seq, '2026-08-31T00:00:00Z'
FROM (VALUES ('fee_revenue','debit',2::bigint),('retained_earnings','credit',1))
     AS v(purpose,direction,seq)
JOIN ledger_accounts a ON a.tenant_id='t2' AND a.purpose=v.purpose;
UPDATE ledger_account_balances b SET input=b.input+100000, last_seq=2
FROM ledger_accounts a WHERE a.tenant_id=b.tenant_id AND a.id=b.account_id
 AND a.currency=b.currency AND b.tenant_id='t2' AND a.purpose='fee_revenue';

-- THE ONE DIFFERENCE. t1's cursor is the top of the xid8 range; t2's is this
-- transaction's own commit position, which is what the sweep asks for.
INSERT INTO ledger_period_closes (tenant_id, period_code, currency, starts_at, ends_at,
                                  transaction_id, txn_effective_at, computed_at_xid) VALUES
  ('t1','2026-08','USD','2026-08-01T00:00:00Z','2026-09-01T00:00:00Z',
   '02500000-0000-7000-8000-0000000000c2','2026-08-31T00:00:00Z',
   '18446744073709551615'::xid8),
  ('t2','2026-08','USD','2026-08-01T00:00:00Z','2026-09-01T00:00:00Z',
   '02500000-0000-7000-8000-0000000000d2','2026-08-31T00:00:00Z',
   pg_current_xact_id());

-- checkpoints, each computed at its own stored cursor
INSERT INTO ledger_period_balances (tenant_id, period_code, currency, account_id, input, output)
SELECT c.tenant_id, c.period_code, c.currency, e.account_id,
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'),0),
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'),0)
FROM ledger_period_closes c
JOIN ledger_entries e ON e.tenant_id=c.tenant_id AND e.currency=c.currency
                     AND e.effective_at < c.ends_at AND e.xact_id < c.computed_at_xid
JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id
                          AND x.status='posted'
GROUP BY c.tenant_id, c.period_code, c.currency, e.account_id;
COMMIT;

DO $$ BEGIN
  FOR i IN 1..600 LOOP
    EXIT WHEN (SELECT coalesce(max(xact_id) <= pg_snapshot_xmin(pg_current_snapshot()), true)
               FROM ledger_entries);
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;

\echo '--- the two stored cursors against the two closing transactions'
SELECT c.tenant_id, c.period_code, c.computed_at_xid, x.xact_id AS txn_xact_id,
       pg_snapshot_xmin(pg_current_snapshot()) AS horizon_now
FROM ledger_period_closes c
JOIN ledger_transactions x ON x.tenant_id=c.tenant_id AND x.id=c.transaction_id
ORDER BY c.tenant_id;

\echo '=== 2. recon_close_breaks is GREEN on both -- the check is one-sided'
SELECT * FROM recon_close_breaks;
SELECT * FROM reconciliation;

\echo
\echo '=== 3. one backdated arrival into each closed August -- a late clearing,'
\echo '--- legal and normal, which this design accepts instead of locking the period'
BEGIN;
SET LOCAL ROLE openledger_app;
INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                           idempotency_hash, payload, effective_at) VALUES
  ('t1','02500000-0000-7000-8000-0000000000c3','posting','internal','late-clearing',
   decode('00','hex'),'{}'::jsonb,'2026-08-15T00:00:00Z'),
  ('t2','02500000-0000-7000-8000-0000000000d3','posting','internal','late-clearing',
   decode('00','hex'),'{}'::jsonb,'2026-08-15T00:00:00Z');
INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at) VALUES
  ('t1','02500000-0000-7000-8000-0000000000c4','02500000-0000-7000-8000-0000000000c3',
   'posting','posted','2026-08-15T00:00:00Z'),
  ('t2','02500000-0000-7000-8000-0000000000d4','02500000-0000-7000-8000-0000000000d3',
   'posting','posted','2026-08-15T00:00:00Z');
INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, stripe, account_seq, effective_at)
SELECT 't1','02500000-0000-7000-8000-0000000000c4', a.id, v.direction::ledger_direction,
       40000,'USD',0,v.seq,'2026-08-15T00:00:00Z'
FROM (VALUES ('customer_receivable','debit',4::bigint),
             ('platform_rev_share_payable','credit',2))
     AS v(purpose,direction,seq)
JOIN ledger_accounts a ON a.tenant_id='t1' AND a.purpose=v.purpose;
INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, stripe, account_seq, effective_at)
SELECT 't2','02500000-0000-7000-8000-0000000000d4', a.id, v.direction::ledger_direction,
       40000,'USD',0,v.seq,'2026-08-15T00:00:00Z'
FROM (VALUES ('customer_receivable','debit',2::bigint),('fee_revenue','credit',3))
     AS v(purpose,direction,seq)
JOIN ledger_accounts a ON a.tenant_id='t2' AND a.purpose=v.purpose;
UPDATE ledger_account_balances b SET input=b.input+40000, last_seq=4
FROM ledger_accounts a WHERE a.tenant_id=b.tenant_id AND a.id=b.account_id
 AND a.currency=b.currency AND b.tenant_id='t1' AND a.purpose='customer_receivable';
UPDATE ledger_account_balances b SET output=b.output+40000, last_seq=2
FROM ledger_accounts a WHERE a.tenant_id=b.tenant_id AND a.id=b.account_id
 AND a.currency=b.currency AND b.tenant_id='t1' AND a.purpose='platform_rev_share_payable';
UPDATE ledger_account_balances b SET input=b.input+40000, last_seq=2
FROM ledger_accounts a WHERE a.tenant_id=b.tenant_id AND a.id=b.account_id
 AND a.currency=b.currency AND b.tenant_id='t2' AND a.purpose='customer_receivable';
UPDATE ledger_account_balances b SET output=b.output+40000, last_seq=3
FROM ledger_accounts a WHERE a.tenant_id=b.tenant_id AND a.id=b.account_id
 AND a.currency=b.currency AND b.tenant_id='t2' AND a.purpose='fee_revenue';
COMMIT;

DO $$ BEGIN
  FOR i IN 1..600 LOOP
    EXIT WHEN (SELECT coalesce(max(xact_id) <= pg_snapshot_xmin(pg_current_snapshot()), true)
               FROM ledger_entries);
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;

\echo '=== 4. close_disclosures -- the enumeration this design ships instead of a lock'
SELECT tenant_id, period_code, entry_id, direction, amount_minor, effective_at, xact_id
FROM close_disclosures ORDER BY tenant_id, amount_minor;
\echo '--- t2 (honest cursor) discloses its arrival. t1 (cursor at the top of the'
\echo '--- range) has nothing to disclose and never will.'
SELECT tenant_id, count(*) AS disclosed FROM close_disclosures GROUP BY tenant_id ORDER BY 1;

\echo '=== 5. what the summary says about it'
SELECT * FROM reconciliation;
SELECT tenant_id, period_code, account_id, stored_input, stored_output,
       recomputed_input, recomputed_output, reason
FROM recon_checkpoint_breaks ORDER BY tenant_id, reason;
SELECT * FROM recon_close_breaks;
