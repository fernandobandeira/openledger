-- 05 -- What the checkpoint buys, and what it costs.
--
-- The register's row: "Historical balances get slower as history grows -- linear as-of
-- aggregation." This measures the SHAPE, not a benchmark: localhost, one client, warm
-- cache, no durability tuning. The ratio is the finding, not the number.

\pset border 2
\set ON_ERROR_STOP on
\timing off

-- ------------------------------------------------------- a seeded book, bulk-loaded
-- Set-based rather than through sp_post: this is a read-cost experiment, and the write
-- path is spike 003's subject, not this one.
CREATE TABLE sp_hot AS SELECT sp_acct('t1','operating_cash') AS a, sp_acct('t1','fee_revenue') AS b;

\o /dev/null
DO $$
DECLARE n int := 400000; a uuid; b uuid; t0 timestamptz := '2023-01-01 00:00+00';
BEGIN
    SELECT sp_hot.a, sp_hot.b INTO a, b FROM sp_hot;
    INSERT INTO ledger_events (tenant_id, id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
    SELECT 't1', uuidv7(), 'fee', 'internal', 'seed:'||g, '\x00'::bytea, '{}'::jsonb,
           t0 + (g * interval '3 minutes')
    FROM generate_series(1,n) g;

    INSERT INTO ledger_transactions (tenant_id, id, event_id, kind, status, effective_at)
    SELECT 't1', uuidv7(), e.id, 'fee', 'posted', e.effective_at
    FROM ledger_events e WHERE e.idempotency_key LIKE 'seed:%';

    INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction, amount_minor,
                                currency, account_seq, effective_at)
    SELECT 't1', x.id, a, 'debit', 100, 'USD',
           1000 + row_number() OVER (ORDER BY x.effective_at), x.effective_at
    FROM ledger_transactions x WHERE x.kind='fee' AND x.effective_at >= '2023-01-01+00' AND x.effective_at < '2026-01-01+00';
    INSERT INTO ledger_entries (tenant_id, transaction_id, account_id, direction, amount_minor,
                                currency, account_seq, effective_at)
    SELECT 't1', x.id, b, 'credit', 100, 'USD',
           1000 + row_number() OVER (ORDER BY x.effective_at), x.effective_at
    FROM ledger_transactions x WHERE x.kind='fee' AND x.effective_at >= '2023-01-01+00' AND x.effective_at < '2026-01-01+00';
END $$;
VACUUM ANALYZE ledger_entries;
\o

SELECT count(*) AS entries_on_the_hot_account,
       to_char(min(effective_at),'YYYY-MM-DD') AS from_date,
       to_char(max(effective_at),'YYYY-MM-DD') AS to_date
FROM ledger_entries WHERE account_id = (SELECT a FROM sp_hot);

-- ------------------------------------------------------- quarterly periods, all closed
\o /dev/null
INSERT INTO ledger_periods (tenant_id, code, starts_at, ends_at, tz)
SELECT 't1', to_char(q,'YYYY"Q"Q'), q, q + interval '3 months', 'UTC'
FROM generate_series(timestamptz '2023-01-01+00', timestamptz '2025-10-01+00', interval '3 months') q
ON CONFLICT DO NOTHING;
SELECT sp_close_period('t1', code) FROM ledger_periods WHERE tenant_id='t1' AND code LIKE '%Q%' ORDER BY starts_at;
VACUUM ANALYZE ledger_entries;
\o

-- ------------------------------------------------------- the measurement
CREATE FUNCTION sp_median_ms(p_sql text, p_runs int DEFAULT 7) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE t timestamptz; ms numeric[] := '{}'; i int;
BEGIN
    FOR i IN 1..p_runs LOOP
        t := clock_timestamp();
        EXECUTE p_sql;
        ms := ms || round(EXTRACT(epoch FROM clock_timestamp()-t)::numeric*1000, 3);
    END LOOP;
    RETURN (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v) FROM unnest(ms) v);
END $$;

-- (a) THE UNBOUNDED FORM -- ADR-0006's effective-axis aggregate, plus the cursor.
-- (b) THE CHECKPOINT FORM -- prior close's stored balance, plus two tails:
--       tail 1: entries effective after the close boundary, up to the as-of instant
--       tail 2: entries effective BEFORE it that arrived after it -- the backdated
--               ones. This is the term that needs ix_entries__asof_commit.
CREATE VIEW sp_asof_cases AS
-- Two kinds of as-of instant, and the difference matters: ON a close boundary the tail
-- is empty; MID-PERIOD it is up to one period of entries. Both are measured, because a
-- flat line drawn only through the boundary cases would be a flattering one.
SELECT 'as of ' || to_char(d,'YYYY-MM-DD') AS as_of, d AS asof FROM (VALUES
    (timestamptz '2023-04-01+00'), (timestamptz '2024-01-01+00'),
    (timestamptz '2024-02-15+00'), (timestamptz '2025-01-01+00'),
    (timestamptz '2025-02-15+00'), (timestamptz '2025-10-01+00')) v(d);

SELECT c.as_of,
       (SELECT count(*) FROM ledger_entries e
         WHERE e.tenant_id='t1' AND e.account_id=(SELECT a FROM sp_hot) AND e.effective_at <= c.asof) AS entries_in_range,
       sp_median_ms(format($f$
            SELECT COALESCE(SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END),0)
            FROM ledger_entries e
            WHERE e.tenant_id='t1' AND e.account_id=%L AND e.effective_at <= %L AND e.xact_id < %L$f$,
            (SELECT a FROM sp_hot), c.asof, report_cursor())) AS full_scan_ms,
       sp_median_ms(format($f$
            SELECT (SELECT COALESCE(pb.input - pb.output, 0)
                      FROM ledger_period_balances pb JOIN ledger_period_closes pc USING (tenant_id, period_code, currency)
                     WHERE pb.tenant_id='t1' AND pb.account_id=%1$L AND pc.ends_at <= %2$L
                     ORDER BY pc.ends_at DESC LIMIT 1)
                 + (SELECT COALESCE(SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END),0)
                      FROM ledger_entries e
                     WHERE e.tenant_id='t1' AND e.account_id=%1$L
                       AND e.effective_at >= (SELECT max(pc.ends_at) FROM ledger_period_closes pc WHERE pc.tenant_id='t1' AND pc.ends_at <= %2$L)
                       AND e.effective_at <= %2$L AND e.xact_id < %3$L)
                 + (SELECT COALESCE(SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END),0)
                      FROM ledger_entries e
                     WHERE e.tenant_id='t1' AND e.account_id=%1$L
                       AND e.xact_id >= (SELECT pc.computed_at_xid FROM ledger_period_closes pc WHERE pc.tenant_id='t1' AND pc.ends_at <= %2$L ORDER BY pc.ends_at DESC LIMIT 1)
                       AND e.xact_id < %3$L
                       AND e.effective_at < (SELECT max(pc.ends_at) FROM ledger_period_closes pc WHERE pc.tenant_id='t1' AND pc.ends_at <= %2$L))$f$,
            (SELECT a FROM sp_hot), c.asof, report_cursor())) AS checkpoint_ms
FROM sp_asof_cases c ORDER BY c.asof;

\echo '== and the two agree, to the minor unit =='
SELECT c.as_of,
       (SELECT COALESCE(SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END),0)
          FROM ledger_entries e
         WHERE e.tenant_id='t1' AND e.account_id=(SELECT a FROM sp_hot)
           AND e.effective_at <= c.asof AND e.xact_id < report_cursor()) AS full_scan,
       (SELECT COALESCE(pb.input - pb.output, 0) FROM ledger_period_balances pb
          JOIN ledger_period_closes pc USING (tenant_id, period_code, currency)
         WHERE pb.tenant_id='t1' AND pb.account_id=(SELECT a FROM sp_hot) AND pc.ends_at <= c.asof
         ORDER BY pc.ends_at DESC LIMIT 1)
     + (SELECT COALESCE(SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END),0)
          FROM ledger_entries e
         WHERE e.tenant_id='t1' AND e.account_id=(SELECT a FROM sp_hot)
           AND e.effective_at >= (SELECT max(pc.ends_at) FROM ledger_period_closes pc WHERE pc.tenant_id='t1' AND pc.ends_at <= c.asof)
           AND e.effective_at <= c.asof AND e.xact_id < report_cursor())
     + (SELECT COALESCE(SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END),0)
          FROM ledger_entries e
         WHERE e.tenant_id='t1' AND e.account_id=(SELECT a FROM sp_hot)
           AND e.xact_id >= (SELECT pc.computed_at_xid FROM ledger_period_closes pc WHERE pc.tenant_id='t1' AND pc.ends_at <= c.asof ORDER BY pc.ends_at DESC LIMIT 1)
           AND e.xact_id < report_cursor()
           AND e.effective_at < (SELECT max(pc.ends_at) FROM ledger_period_closes pc WHERE pc.tenant_id='t1' AND pc.ends_at <= c.asof)) AS checkpoint_plus_tail
FROM sp_asof_cases c ORDER BY c.asof;

\echo '== what the checkpoint costs in rows =='
SELECT (SELECT count(*) FROM ledger_entries)          AS journal_entries,
       (SELECT count(*) FROM ledger_period_balances)  AS checkpoint_rows,
       pg_size_pretty(pg_total_relation_size('ledger_entries'))         AS journal_size,
       pg_size_pretty(pg_total_relation_size('ledger_period_balances')) AS checkpoint_size;

\echo '== a posting BACKDATED INTO A CLOSED PERIOD, after that period was closed =='
-- Append-only means the entry is accepted. The checkpoint is not invalidated by it: the
-- arrival carries an xact_id ABOVE the close's cursor, so it lands in the second tail
-- term and the two forms still agree.
--
-- THE CURSOR HERE IS EXPLICIT, and the reason is itself a finding. An earlier run of
-- this file used report_cursor() and the arrival vanished from BOTH forms -- correctly,
-- and not because of anything in this schema: another workstream's benchmark was holding
-- a transaction open on the same server, so pg_snapshot_xmin sat below a row this script
-- had just committed. That is exactly the lag ADR-0011 records as a cost, and it bit the
-- spike that measured it. The gap is printed below.
\o /dev/null
SELECT sp_post('t1','late-clearing','2023-05-05 00:00+00','operating_cash','fee_revenue', 123400);
\o
SELECT report_cursor() AS report_cursor_now,
       (SELECT max(xact_id) FROM ledger_entries) AS newest_committed_entry,
       (SELECT max(xact_id::text::bigint) FROM ledger_entries) - report_cursor()::text::bigint
           AS rows_the_cursor_cannot_yet_see;

\set C '(SELECT (max(xact_id::text::bigint)+1)::text::xid8 FROM ledger_entries)'
SELECT (SELECT COALESCE(SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END),0)
          FROM ledger_entries e
         WHERE e.tenant_id='t1' AND e.account_id=(SELECT a FROM sp_hot)
           AND e.effective_at <= '2025-01-01+00' AND e.xact_id < :C ) AS full_scan,
       (SELECT COALESCE(pb.input - pb.output, 0) FROM ledger_period_balances pb
          JOIN ledger_period_closes pc USING (tenant_id, period_code, currency)
         WHERE pb.tenant_id='t1' AND pb.account_id=(SELECT a FROM sp_hot) AND pc.ends_at <= '2025-01-01+00'
         ORDER BY pc.ends_at DESC LIMIT 1)
     + (SELECT COALESCE(SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END),0)
          FROM ledger_entries e
         WHERE e.tenant_id='t1' AND e.account_id=(SELECT a FROM sp_hot)
           AND e.effective_at >= '2025-01-01+00' AND e.effective_at <= '2025-01-01+00' AND e.xact_id < :C )
     + (SELECT COALESCE(SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END),0)
          FROM ledger_entries e
         WHERE e.tenant_id='t1' AND e.account_id=(SELECT a FROM sp_hot)
           AND e.xact_id >= (SELECT pc.computed_at_xid FROM ledger_period_closes pc
                              WHERE pc.tenant_id='t1' AND pc.ends_at <= '2025-01-01+00'
                              ORDER BY pc.ends_at DESC LIMIT 1)
           AND e.xact_id < :C
           AND e.effective_at < '2025-01-01+00') AS checkpoint_plus_tail;

\echo '== the plan of the backdated-arrivals term: it is the commit-axis index =='
EXPLAIN (COSTS OFF)
SELECT SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END)
  FROM ledger_entries e
 WHERE e.tenant_id='t1' AND e.account_id=(SELECT a FROM sp_hot)
   AND e.xact_id >= (SELECT pc.computed_at_xid FROM ledger_period_closes pc
                      WHERE pc.tenant_id='t1' AND pc.ends_at <= '2025-01-01+00'
                      ORDER BY pc.ends_at DESC LIMIT 1)
   AND e.xact_id < report_cursor()
   AND e.effective_at < '2025-01-01+00';
