-- 08_striping_bench.sql -- does the DDL in 07 actually deliver the mechanism?
--
-- Spike 003 measured striping against a bench schema of its own. This measures it
-- against the SHIPPED baseline plus the proposed columns, so the claim is about
-- this schema rather than about a schema that resembled it.
--
-- Read the RATIO, not the absolutes: the machine was not idle, and 02_run.sh's
-- own numbers moved between repetitions. localhost is not a benchmark.
--
-- Run after 07_striping.sql.

\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS wse_stripe_results (
    stripes    int     NOT NULL,
    worker     int     NOT NULL,
    postings   int     NOT NULL,
    elapsed_ms numeric NOT NULL
);

-- a dedicated account, so the striped book 07 checked stays as 07 left it
DO $$ BEGIN
    UPDATE ledger_accounts SET stripe_count = 64
     WHERE tenant_id='t2' AND id='22222222-0000-0000-0000-000000000002';
    INSERT INTO ledger_account_balances (tenant_id, account_id, currency, stripe)
    SELECT 't2','22222222-0000-0000-0000-000000000002','USD', s FROM generate_series(1,63) s
    ON CONFLICT DO NOTHING;
END $$;

CREATE OR REPLACE PROCEDURE wse_stripe_bench(p_stripes int, p_worker int, p_postings int)
LANGUAGE plpgsql AS $$
DECLARE
    acct constant uuid := '22222222-0000-0000-0000-000000000002';
    st   smallint := (p_worker % p_stripes)::smallint;   -- affinity: one stripe per writer
    i    int;
    t0   timestamptz := clock_timestamp();
BEGIN
    FOR i IN 1..p_postings LOOP
        INSERT INTO ledger_account_balances AS b
               (tenant_id, account_id, currency, stripe, input, output, last_seq)
        VALUES ('t2', acct, 'USD', st, 1, 0, 1)
        ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
           SET input = b.input + excluded.input, last_seq = b.last_seq + 1;
        COMMIT;
    END LOOP;
    INSERT INTO wse_stripe_results
    VALUES (p_stripes, p_worker, p_postings,
            round(extract(epoch FROM clock_timestamp() - t0) * 1000, 1));
    COMMIT;
END $$;

-- ----------------------------------------------------------------------
-- the read side: one PK lookup becomes a SUM over the stripes that exist
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION wse_time_balance_read(p_stripe_limit int, p_iters int)
RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz := clock_timestamp(); i int; v bigint;
BEGIN
    FOR i IN 1..p_iters LOOP
        SELECT sum(input - output) INTO v FROM ledger_account_balances
        WHERE tenant_id='t2' AND account_id='22222222-0000-0000-0000-000000000002'
          AND currency='USD' AND stripe < p_stripe_limit;
    END LOOP;
    RETURN round(extract(epoch FROM clock_timestamp() - t0) * 1000000 / p_iters, 2);  -- µs
END $$;

-- ----------------------------------------------------------------------
-- The read cost, as SHAPE. On a 134-row balance table every plan is a cache hit
-- and the difference between summing 1 stripe and summing 64 is below
-- measurement (pgbench -M prepared -c1 -T5, three repetitions each: 0.036 /
-- 0.037 / 0.037 ms at one stripe, 0.036 / 0.038 / 0.037 ms at 64). The planner
-- seq-scans a table that small, so the numbers say nothing about the mechanism.
--
-- Force the index and the cost is visible as buffers, which is the claim that
-- survives a bigger table: ONE index range scan either way, over a contiguous key
-- prefix, touching one leaf entry per stripe.
--
--   SET enable_seqscan = off; SET enable_bitmapscan = off;
--   EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
--   SELECT sum(input - output) FROM ledger_account_balances
--    WHERE tenant_id='t2' AND account_id= <1-stripe account>  AND currency='USD';
--   -- Index Scan using pk_balances, rows=1,  Buffers: shared hit=3,  0.026 ms
--   EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
--   SELECT sum(input - output) FROM ledger_account_balances
--    WHERE tenant_id='t2' AND account_id= <64-stripe account> AND currency='USD';
--   -- Index Scan using pk_balances, rows=64, Buffers: shared hit=24, 0.072 ms
--
-- 3 buffers -> 24, one scan, no sort. VACUUM (FULL, ANALYZE) first: the write
-- bench above leaves ~91 heap blocks of dead versions behind one live stripe row,
-- which is spike 009's autovacuum finding reproducing itself here.
