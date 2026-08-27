-- 02_isolation_contention.sql -- the same property under load, and what a retry
-- loop does about it.
--
-- Three retry strategies against the one contended balance row:
--
--   'none'    -- one attempt per posting. Counts what a deployment that raised its
--                isolation default would simply LOSE.
--   'inline'  -- catch 40001 inside the transaction (a savepoint) and try again.
--                This is the loop most people write. Under REPEATABLE READ and
--                SERIALIZABLE the snapshot does not move, so every retry fails
--                exactly as the first did.
--   'restart' -- COMMIT the aborted transaction and start a fresh one, which gets
--                a new snapshot. This one works, and turns the write path into the
--                optimistic-concurrency shape spike 003 measured as WORSE than the
--                pessimistic one it replaces.
--
-- Counters are plpgsql variables, which survive COMMIT inside a procedure, so the
-- tally is not lost when a transaction rolls back.

\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS wse_bench_results (
    run_label   text    NOT NULL,
    isolation   text    NOT NULL,
    strategy    text    NOT NULL,
    worker      int     NOT NULL,
    postings    int     NOT NULL,   -- attempted
    committed   int     NOT NULL,   -- succeeded
    serfails    int     NOT NULL,   -- 40001 could not serialize access
    attempts    int     NOT NULL,   -- upsert executions, retries included
    rescued     int     NOT NULL,   -- commits that took MORE than one attempt
    elapsed_ms  numeric NOT NULL
);

CREATE OR REPLACE PROCEDURE wse_bench(
    p_label     text,
    p_strategy  text,     -- none | inline | restart
    p_worker    int,
    p_postings  int,
    p_max_retry int DEFAULT 20
) LANGUAGE plpgsql AS $$
DECLARE
    acct      constant uuid := '22222222-0000-0000-0000-000000000001';
    ok        int := 0;
    ser       int := 0;
    att       int := 0;
    resc      int := 0;
    i         int;
    r         int;
    done      boolean;
    t0        timestamptz := clock_timestamp();
    iso       text;
BEGIN
    SELECT current_setting('default_transaction_isolation') INTO iso;

    FOR i IN 1..p_postings LOOP
        done := false;
        FOR r IN 0..p_max_retry LOOP
            EXIT WHEN done;
            BEGIN
                att := att + 1;
                INSERT INTO ledger_account_balances AS b
                       (tenant_id, account_id, currency, input, output, last_seq)
                VALUES ('t2', acct, 'USD', 0, 1, 1)
                ON CONFLICT (tenant_id, account_id, currency) DO UPDATE
                   SET input    = b.input  + excluded.input,
                       output   = b.output + excluded.output,
                       last_seq = b.last_seq + 1;
                done := true;
                ok := ok + 1;
                IF r > 0 THEN resc := resc + 1; END IF;
            EXCEPTION WHEN serialization_failure OR deadlock_detected THEN
                ser := ser + 1;
            END;
            EXIT WHEN p_strategy = 'none';
            -- 'restart' ends the transaction between attempts, so the next one
            -- reads a NEW snapshot. 'inline' does not, so it cannot.
            IF p_strategy = 'restart' AND NOT done THEN
                COMMIT;
            END IF;
        END LOOP;
        COMMIT;
    END LOOP;

    INSERT INTO wse_bench_results
    VALUES (p_label, iso, p_strategy, p_worker, p_postings, ok, ser, att, resc,
            round(extract(epoch FROM clock_timestamp() - t0) * 1000, 1));
    COMMIT;
END $$;
