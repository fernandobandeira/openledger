-- F4c -- THE WINDOW BOUND IS WALL-CLOCK: a break that clears itself.
--
-- The upper bound of the sane window is `now() + interval '1 year'`, evaluated
-- when the view is read. Nothing else in this schema classifies an entry against
-- the clock: trial_balance_at, income_statement_for and balance_sheet_at all take
-- their window as parameters, and a cursor pins the commit horizon precisely so
-- that a reissued report is reproducible (ADR-0011). Here the bucket is a
-- function of when the SELECT ran.
--
-- Two consequences, both shown below:
--
--   * a `journal_to_reports` break clears with no write and no repair. As now()
--     advances, now() + 1 year advances with it, so a fixed effective_at slides
--     from `out_of_window` into `reported` on its own. An operator who sees exit
--     1, opens a ticket, and re-runs the sweep gets exit 0 -- and the entry that
--     caused it is now reported into every statement forever, which is the
--     outcome the bucket was added to prevent.
--   * the classification is untestable at a fixed input. Two entries whose
--     effective dates differ by four minutes land in opposite buckets on the
--     same book, and which side of the bound either one is on is not a property
--     of the book.
--
-- The transition is shown at a bound twenty-five seconds away rather than
-- asserted; the waits are bounded server-side polls.
--
-- Assumes a freshly restored spike025_f4. To see the same transition as exit
-- codes, run the compiled sweep from a shell either side of section 3:
--   DATABASE_URL="postgres://openledger:openledger@localhost:5455/spike025_f4?sslmode=disable" \
--     ./target/debug/openledger reconcile; echo "exit=$?"

\set ON_ERROR_STOP on

\echo
\echo '=== 1. the negative control: ten checks, zero breaks'
SELECT * FROM reconciliation;

\echo
\echo '=== 2. one balanced posted transaction, effective twenty-five seconds above the bound'
-- Honest in every other respect: real event, balanced legs, account_seq
-- continued, cache advanced. Its effective_at is computed from now() so the
-- distance to the bound is fixed at twenty-five seconds whenever this file runs.
BEGIN;

CREATE TEMP TABLE injected (label text PRIMARY KEY, effective_at timestamptz);
INSERT INTO injected VALUES ('C', now() + interval '1 year' + interval '25 seconds');

INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                           idempotency_hash, payload, effective_at)
SELECT 't1', '01a05d75-0000-7000-8000-00000000c0c1', 'fee', 'internal', 'clock-C',
       decode('00', 'hex'), '{}'::jsonb, effective_at FROM injected WHERE label = 'C';

INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
SELECT 't1', '01a05d75-0000-7000-8000-00000000c0c2',
       '01a05d75-0000-7000-8000-00000000c0c1', 'fee', 'posted', effective_at
FROM injected WHERE label = 'C';

INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, account_seq, effective_at)
SELECT 't1', '01a05d75-0000-7000-8000-00000000c0c2', a.id, v.dir, 33000, 'USD',
       v.seq, i.effective_at
FROM injected i,
     (VALUES ('customer_receivable', 'debit'::ledger_direction,  4::bigint),
             ('fee_revenue',         'credit'::ledger_direction, 2::bigint))
     AS v(purpose, dir, seq)
JOIN ledger_accounts a ON a.tenant_id = 't1' AND a.purpose = v.purpose
WHERE i.label = 'C';

UPDATE ledger_account_balances b SET input = b.input + 33000, last_seq = 4
 WHERE b.tenant_id = 't1'
   AND b.account_id = (SELECT id FROM ledger_accounts
                       WHERE tenant_id = 't1' AND purpose = 'customer_receivable');
UPDATE ledger_account_balances b SET output = b.output + 33000, last_seq = 2
 WHERE b.tenant_id = 't1'
   AND b.account_id = (SELECT id FROM ledger_accounts
                       WHERE tenant_id = 't1' AND purpose = 'fee_revenue');

COMMIT;

DO $$
DECLARE tries int := 0;
BEGIN
    WHILE tries < 600 LOOP
        EXIT WHEN (SELECT coalesce(max(xact_id) <= pg_snapshot_xmin(pg_current_snapshot()), true)
                   FROM ledger_entries);
        -- COMMIT, for the reason section 3 explains: a poll that never ends its
        -- transaction re-reads the same frozen clock and the same frozen horizon.
        COMMIT;
        PERFORM pg_sleep(0.1);
        tries := tries + 1;
    END LOOP;
END $$;

\echo '--- the check is red, and the whole 330.00 is disclosed as out_of_window'
SELECT * FROM reconciliation;
SELECT tenant_id, currency, out_of_window_debits, reported_debits, tb_debits,
       unexplained_debits, unexplained_credits
FROM recon_journal_to_reports WHERE tenant_id = 't1';

\echo '--- the journal as it stands, so the after-state can be held against it'
CREATE TEMP TABLE before_the_wait AS
SELECT (SELECT count(*) FROM ledger_events)       AS events,
       (SELECT count(*) FROM ledger_transactions) AS transactions,
       (SELECT count(*) FROM ledger_entries)      AS entries,
       (SELECT max(xact_id)::text FROM ledger_entries) AS max_xact_id,
       (SELECT sum(input - output) FROM ledger_account_balances) AS cache_net;
SELECT * FROM before_the_wait;

\echo
\echo '=== 3. wait for the clock, write nothing, read the view again'
-- The exit condition is the bucket, not a duration: the loop ends when the view
-- stops classifying the entry as out-of-window. Only now() moved.
--
-- The COMMIT in the loop is load-bearing, and is itself a fact about the view:
-- now() is the TRANSACTION timestamp, so inside one transaction the bucket is
-- frozen however long the poll runs. The classification is stable within a
-- transaction and unstable between them -- which is the wrong way round for a
-- check whose whole purpose is to be re-run.
DO $$
DECLARE tries int := 0;
BEGIN
    WHILE tries < 600 LOOP
        EXIT WHEN NOT EXISTS (SELECT 1 FROM recon_journal_to_reports
                              WHERE out_of_window_debits <> 0);
        COMMIT;
        PERFORM pg_sleep(0.2);
        tries := tries + 1;
    END LOOP;
    RAISE NOTICE 'the bucket changed after % poll(s) of 0.2s', tries;
END $$;

\echo '--- ten checks, zero breaks: the break repaired itself'
SELECT * FROM reconciliation;
SELECT tenant_id, currency, out_of_window_debits, reported_debits, tb_debits,
       unexplained_debits, unexplained_credits
FROM recon_journal_to_reports WHERE tenant_id = 't1';

\echo '--- and nothing was written between the two readings'
SELECT b.events = (SELECT count(*) FROM ledger_events)             AS events_unchanged,
       b.transactions = (SELECT count(*) FROM ledger_transactions) AS transactions_unchanged,
       b.entries = (SELECT count(*) FROM ledger_entries)           AS entries_unchanged,
       b.max_xact_id = (SELECT max(xact_id)::text FROM ledger_entries) AS journal_high_water_unchanged,
       b.cache_net = (SELECT sum(input - output) FROM ledger_account_balances) AS cache_unchanged
FROM before_the_wait b;

\echo '--- the entry is now REPORTED, and is in every statement as at infinity'
SELECT currency, chart_version, fs_line, side, amount_minor
FROM balance_sheet_at('t1', 'infinity', report_cursor()) ORDER BY sort_order;

\echo
\echo '=== 4. the bound is not a property of the book'
-- Two more balanced posted transactions, two minutes either side of the bound as
-- it stands now. A and B differ by four minutes of effective date and by nothing
-- else; they land in opposite buckets.
BEGIN;

INSERT INTO injected VALUES
  ('A', now() + interval '1 year' - interval '2 minutes'),
  ('B', now() + interval '1 year' + interval '2 minutes');

INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key,
                           idempotency_hash, payload, effective_at)
SELECT 't1', ('01a05d75-0000-7000-8000-00000000c0' || label || '1')::uuid, 'fee',
       'internal', 'clock-' || label, decode('00', 'hex'), '{}'::jsonb, effective_at
FROM injected WHERE label IN ('A', 'B');

INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
SELECT 't1', ('01a05d75-0000-7000-8000-00000000c0' || label || '2')::uuid,
       ('01a05d75-0000-7000-8000-00000000c0' || label || '1')::uuid,
       'fee', 'posted', effective_at
FROM injected WHERE label IN ('A', 'B');

INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction,
                            amount_minor, currency, account_seq, effective_at)
SELECT 't1', ('01a05d75-0000-7000-8000-00000000c0' || i.label || '2')::uuid,
       a.id, v.dir, i.amt, 'USD', v.seq + i.bump, i.effective_at
FROM (SELECT label, effective_at,
             CASE label WHEN 'A' THEN 11000 ELSE 22000 END AS amt,
             CASE label WHEN 'A' THEN 1 ELSE 2 END AS bump
      FROM injected WHERE label IN ('A', 'B')) i,
     (VALUES ('customer_receivable', 'debit'::ledger_direction,  4::bigint),
             ('fee_revenue',         'credit'::ledger_direction, 2::bigint))
     AS v(purpose, dir, seq)
JOIN ledger_accounts a ON a.tenant_id = 't1' AND a.purpose = v.purpose;

UPDATE ledger_account_balances b SET input = b.input + 33000, last_seq = 6
 WHERE b.tenant_id = 't1'
   AND b.account_id = (SELECT id FROM ledger_accounts
                       WHERE tenant_id = 't1' AND purpose = 'customer_receivable');
UPDATE ledger_account_balances b SET output = b.output + 33000, last_seq = 4
 WHERE b.tenant_id = 't1'
   AND b.account_id = (SELECT id FROM ledger_accounts
                       WHERE tenant_id = 't1' AND purpose = 'fee_revenue');

COMMIT;

\echo '--- the CTE predicate spelled out per entry, with the bound it is compared to'
SELECT e.amount_minor, e.effective_at,
       now() + interval '1 year' AS bound_when_this_ran,
       e.effective_at - (now() + interval '1 year') AS distance_from_bound,
       CASE WHEN e.effective_at >= now() + interval '1 year'
            THEN 'out_of_window' ELSE 'reported' END AS bucket,
       e.effective_at - interval '1 year' AS becomes_reported_at
FROM ledger_entries e
WHERE e.tenant_id = 't1' AND e.direction = 'debit' AND e.effective_at > now()
ORDER BY e.effective_at;

\echo '--- so the check is red again, on the 220.00 that is two minutes too far out'
SELECT * FROM reconciliation;
SELECT tenant_id, currency, out_of_window_debits, unexplained_debits
FROM recon_journal_to_reports WHERE tenant_id = 't1';
