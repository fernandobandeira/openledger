-- The queries the docs promise are O(1) must actually plan that way.
--
-- WHY THIS FILE EXISTS. ADR-0006 ships a schema snapshot test, and a schema
-- snapshot cannot catch the defect that motivated this: `ix_entries__asof_recorded`
-- has existed since migration 0001, and NO QUERY IN THE REPOSITORY COULD USE IT.
-- The as-of read documented in reference-product.md ordered by `account_seq DESC`
-- while filtering on `recorded_at`, so the planner walked the balance index
-- backwards discarding rows: 253 ms and 1,439,915 rows removed by filter on a
-- 2M-entry account, against 0.066 ms for the same question asked correctly.
--
-- The index was present, the constraint list was unchanged, every test passed, and
-- the headline "balances are a lookup, not a recomputation" was false on the axis
-- that matters most for reporting. Only a PLAN assertion can see that.

\set ON_ERROR_STOP on
\o /dev/null
BEGIN;

-- MODE GUARD. `SET LOCAL session_replication_role = 'replica'` prepended to this
-- file's BEGIN made the whole suite run on the replication apply path, where a
-- guard marked ENABLE REPLICA fires and the ordinary write path is untested. That
-- is how an earlier leak went unnoticed for two hundred lines of negative
-- controls. One line per suite, at both ends.
DO $$ BEGIN
    IF current_setting('session_replication_role') <> 'origin' THEN
        RAISE EXCEPTION
            'this suite is running as %, not origin: every guard it exercises may be '
            'the replica-path one', current_setting('session_replication_role');
    END IF;
    RAISE NOTICE 'ok  running on the ordinary write path';
END $$;

CREATE FUNCTION plan_uses(p_label text, p_sql text, p_index text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_plan text;
BEGIN
    -- FORMAT JSON so the whole plan arrives as ONE value. With FORMAT TEXT,
    -- `EXECUTE ... INTO` silently captures only the first line -- which here is the
    -- Limit node, containing no index name at all, so every assertion in this file
    -- would have failed for the wrong reason.
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || p_sql INTO v_plan;

    IF position(p_index in v_plan) = 0 THEN
        RAISE EXCEPTION E'% -- expected the plan to use %, got:\n%',
            p_label, p_index, v_plan;
    END IF;

    -- A plan that uses the right index but still discards most of what it reads is
    -- the same defect wearing the right index name.
    IF v_plan ~ 'Rows Removed by Filter"?: [0-9]{4,}' THEN
        RAISE EXCEPTION E'% -- uses % but scans and discards:\n%',
            p_label, p_index, v_plan;
    END IF;

    RAISE NOTICE 'ok  % -> %', p_label, p_index;
END $$;

-- enough history that the planner has a real choice to make
INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose, category, normal_balance, currency)
SELECT 'p1','company','acme',code,category,normal_balance,'USD'
  FROM account_types WHERE code = 'customer_receivable';
-- Disable BEFORE inserting the transaction: ck_txn__has_entries is deferred, so an
-- insert leaves a pending trigger event and ALTER TABLE then refuses to run. The
-- point of this file is plan shape, not the balance invariant, which has its own
-- suite; this is one synthetic 200k-leg transaction.
ALTER TABLE ledger_entries      DISABLE TRIGGER ck_entries__balances;
ALTER TABLE ledger_transactions DISABLE TRIGGER ck_txn__has_entries;
-- recorded_at and account_seq are both assigned by the engine now (the sequence
-- from the journal, never from the cache). Both are correct and both make a 200k-row synthetic fixture
-- impossible, so they are off for the load only. This file asserts PLAN SHAPE;
-- the invariants have their own suites.
ALTER TABLE ledger_entries DISABLE TRIGGER ck_entries__recorded_at;
ALTER TABLE ledger_entries DISABLE TRIGGER ck_entries__seq;

INSERT INTO ledger_events (tenant_id,kind,source,idempotency_key,idempotency_hash,payload,effective_at)
VALUES ('p1','bulk','internal','bulk',sha256('bulk'),'{}',now());
INSERT INTO ledger_transactions (tenant_id,event_id,kind,status,effective_at)
SELECT 'p1',id,'bulk','posted',now() FROM ledger_events WHERE tenant_id='p1';

INSERT INTO ledger_entries (tenant_id,transaction_id,account_id,direction,amount_minor,
                            currency,account_seq,balance_after,effective_at,recorded_at)
SELECT 'p1', t.id, a.id, 'debit', 1, 'USD', g, g,
       t.effective_at, now() - (200000-g) * interval '1 second'
  FROM generate_series(1,200000) g
 CROSS JOIN (SELECT id, effective_at FROM ledger_transactions WHERE tenant_id='p1') t
 CROSS JOIN (SELECT id FROM ledger_accounts WHERE tenant_id='p1') a;
ALTER TABLE ledger_entries      ENABLE ALWAYS TRIGGER ck_entries__balances;
ALTER TABLE ledger_transactions ENABLE ALWAYS TRIGGER ck_txn__has_entries;
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ck_entries__recorded_at;
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ck_entries__seq;
ANALYZE ledger_entries;

-- 1. the current balance: one lookup, no sort. tenant_id is not optional -- it
--    leads every index, and omitting it adds a Sort.
SELECT plan_uses('current balance', $q$
    SELECT balance_after FROM ledger_entries
     WHERE tenant_id = 'p1'
       AND account_id = (SELECT id FROM ledger_accounts WHERE tenant_id='p1')
     ORDER BY account_seq DESC LIMIT 1
$q$, 'uq_entries__account_seq');

-- 2. THE ONE THAT WAS WRONG. Ordering must match the index that serves the
--    recorded-axis question, or this degenerates into a backwards scan.
SELECT plan_uses('balance as of a recording instant', $q$
    SELECT balance_after FROM ledger_entries
     WHERE tenant_id = 'p1'
       AND account_id = (SELECT id FROM ledger_accounts WHERE tenant_id='p1')
       AND recorded_at <= now() - interval '10 hours'
     ORDER BY recorded_at DESC, account_seq DESC LIMIT 1
$q$, 'ix_entries__asof_recorded');

-- 3. ...and the shape the docs used to prescribe must be REFUSED by this file,
--    or it will come back. It plans on the wrong index and discards ~36k rows.
DO $$
DECLARE v_plan text;
BEGIN
    EXECUTE $q$EXPLAIN (ANALYZE, FORMAT JSON)
        SELECT balance_after FROM ledger_entries
         WHERE tenant_id = 'p1'
           AND account_id = (SELECT id FROM ledger_accounts WHERE tenant_id='p1')
           AND recorded_at <= now() - interval '10 hours'
         ORDER BY account_seq DESC LIMIT 1$q$ INTO v_plan;
    IF v_plan !~ 'Rows Removed by Filter"?: [0-9]{4,}' THEN
        RAISE EXCEPTION E'the bad as-of shape no longer scans -- if the planner or '
            'the indexes changed, revisit this file:\n%', v_plan;
    END IF;
    RAISE NOTICE 'ok  the documented-but-wrong as-of shape still degenerates (%)',
        substring(v_plan from 'Rows Removed by Filter"?: [0-9]+');
END $$;

-- 4. The effective-axis aggregate is deliberately NOT plan-asserted, and the
--    reason is worth writing down rather than quietly omitting.
--
--    Measured on this fixture it is a **Parallel Seq Scan**, 3,280 buffers, 17 ms
--    -- and that is the planner being right, not wrong: one account holds the whole
--    table and `effective_at <= now()` matches every row, so an index scan would
--    read the same pages with more indirection. `ix_entries__effective` earns its
--    place when the account predicate is selective, which this fixture cannot make
--    it without a much larger multi-transaction setup.
--
--    The honest statement is the one ADR-0003 already makes: the business-date
--    aggregate is **linear in history and nothing bounds it**. Period-close
--    checkpoints are the fix and are not built. Asserting an index here would
--    manufacture reassurance about the one read path that genuinely has no bound.
DO $$
DECLARE v_plan text; v_rows bigint;
BEGIN
    -- SERIALLY, so the numbers below are exact. Under a parallel plan "Actual Rows"
    -- is a PER-WORKER average, and the assertion would move with the worker count
    -- rather than with the ledger.
    SET LOCAL max_parallel_workers_per_gather = 0;
    EXECUTE $q$EXPLAIN (ANALYZE, FORMAT JSON)
        SELECT SUM(CASE WHEN direction='debit' THEN amount_minor ELSE -amount_minor END)
          FROM ledger_entries
         WHERE tenant_id = 'p1'
           AND account_id = (SELECT id FROM ledger_accounts WHERE tenant_id='p1')
           AND effective_at <= now()$q$ INTO v_plan;
    -- BOTH BRANCHES USED TO EMIT A NOTICE, so this assertion could not fail --
    -- it was pinned only by coincidence, because the file emitted exactly as many
    -- `ok` lines as its floor and the note branch would have tripped it. Adding
    -- one more assertion anywhere in this file re-vacated it. The claim is
    -- ADR-0003's, and it is falsifiable: state it as one.
    --
    -- ...AND IT IS A CLAIM ABOUT WORK DONE, NOT ABOUT WHICH OPERATOR THE PLANNER
    -- PICKED. Matching the string `Seq Scan` made this assertion a hostage to the
    -- planner: a Bitmap Heap Scan over the same 200,000 rows is equally unbounded
    -- and equally the thing ADR-0003 describes, and under machine load the planner
    -- chose one, turning a correct tree red. Assert the rows READ instead.
    SELECT max((m[1])::bigint) INTO v_rows
      FROM regexp_matches(v_plan, '"Actual Rows": ([0-9]+)', 'g') m;
    IF v_rows IS NULL OR v_rows < 100000 THEN
        RAISE EXCEPTION E'the business-date aggregate read only % row(s) of a '
            '200,000-row account. That is not a failure -- it means period '
            'checkpoints or a bounding index landed, and ADR-0003''s "linear in '
            'history, nothing bounds it" is now wrong. Update the ADR and assert '
            'the new plan here:\n%', COALESCE(v_rows::text,'no'), v_plan;
    END IF;
    RESET max_parallel_workers_per_gather;
    RAISE NOTICE 'ok  business-date aggregate reads % rows -- linear in history, as '
                 'ADR-0003 says (unbounded, M5)', v_rows;
END $$;

-- 5. The indexes the ledger's hot reads depend on must EXIST. Dropping
--    ix_entries__balance_lookup, ix_entries__effective or ix_entries__txn changed
--    no plan this file asserts and no answer any other file checks -- a silently
--    slower ledger, which is the failure mode 0006 is written about ("dropping a
--    column silently drops its indexes -- Formance lost a hot-path index that way
--    for thirty migrations").
DO $$
DECLARE want text; missing text := '';
BEGIN
    FOREACH want IN ARRAY ARRAY['ix_entries__balance_lookup','ix_entries__effective',
                                'ix_entries__txn','ix_entries__asof_recorded',
                                'uq_entries__account_seq','ix_hold_groups__held']
    LOOP
        IF to_regclass(want) IS NULL THEN missing := missing || want || ' '; END IF;
    END LOOP;
    IF missing <> '' THEN
        RAISE EXCEPTION 'index(es) gone: %', missing;
    END IF;
    RAISE NOTICE 'ok  every hot-path index still exists';
END $$;

-- ...AND STILL INDEXES WHAT ITS NAME SAYS. Checking `to_regclass(name) IS NOT
-- NULL` attests a name, and a name survives the loss: re-pointing
-- ix_entries__effective at `recorded_at`, and dropping `INCLUDE (balance_after)`
-- from the balance lookup, both left every assertion in this file green. That is
-- the same failure class 0006 cites -- "Formance lost a hot-path index that way
-- for thirty migrations" -- where the object stayed and its usefulness did not.
DO $$
DECLARE r record; want text; got text; bad text := '';
BEGIN
    FOR r IN SELECT * FROM (VALUES
        ('ix_entries__effective',       'effective_at'),
        ('ix_entries__balance_lookup',  'INCLUDE (balance_after)'),
        ('ix_entries__asof_recorded',   'recorded_at'),
        ('ix_entries__txn',             'transaction_id'),
        ('uq_entries__account_seq',     'account_seq'),
        ('ix_hold_groups__held',        'held_minor > 0'),
        -- ...and 0003's own indexes, which the census did not reach. Dropping
        -- ix_event_group__group turned recompute_hold_group from a per-group index
        -- scan into a parallel seq scan over the tenant's whole history (measured
        -- at 200k events: 402 shared hits against 4,679) with the suite green --
        -- the same failure class this file exists for, on tables it did not police.
        ('ix_event_group__group',       'group_key'),
        ('uq_auth_events__msg',         'processor_msg_id'),
        ('uq_event_group__current',     'event_id')
    ) AS q(idx, needle)
    LOOP
        SELECT indexdef INTO got FROM pg_indexes
         WHERE schemaname='public' AND indexname = r.idx;
        -- ...WITH THE INDEX'S OWN NAME REMOVED FIRST. `indexdef` starts with
        -- `CREATE ... INDEX <name> ON ...`, so a needle that is a substring of the
        -- name matches the name and never reaches the column list: re-pointing
        -- uq_entries__account_seq at (tenant_id, account_id, balance_after) still
        -- printed `ok`, because 'account_seq' was right there in the name. This is
        -- the same "the object stayed and its usefulness did not" failure the
        -- census above exists to catch, inside the census.
        got := replace(COALESCE(got, ''), r.idx, '');
        IF got = '' OR position(r.needle in got) = 0 THEN
            bad := bad || format('%s (wanted %L in %L) ', r.idx, r.needle, got);
        END IF;
    END LOOP;
    IF bad <> '' THEN
        RAISE EXCEPTION 'index definition(s) no longer index what the name says: %', bad;
    END IF;
    RAISE NOTICE 'ok  every hot-path index still indexes what its name says';
END $$;

-- ...and the hold index is PARTIAL on a strict inequality. Widening `> 0` to
-- `>= 0` keeps the name, keeps the word `held_minor` in the predicate, and turns
-- the ~1s authorization read from 6,667 rows into 20,000 -- a partial index
-- become total, which is the regression held_for_company's own comment warns of.
DO $$
DECLARE v_pred text;
BEGIN
    SELECT pg_get_expr(i.indpred, i.indrelid) INTO v_pred
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
     WHERE c.relname = 'ix_hold_groups__held';
    IF v_pred IS NULL OR v_pred !~ 'held_minor > 0' THEN
        RAISE EXCEPTION 'ix_hold_groups__held is no longer partial on held_minor > 0: %',
            COALESCE(v_pred, '<total index>');
    END IF;
    RAISE NOTICE 'ok  the hold index is partial on a strict inequality (%)', v_pred;
END $$;

-- 6. held_for_company is the ~1s real-time authorization read -- the whole reason
--    the hold total is materialised at all -- and it had no plan coverage. Only
--    ledger_entries did.
INSERT INTO card_hold_groups (tenant_id, company_id, group_key, currency, total_minor)
SELECT 'p1', 'co'||(g % 200), 'k'||g, 'USD', 100 FROM generate_series(1,20000) g;
UPDATE card_hold_groups SET expired_at = now()
 WHERE tenant_id='p1' AND group_key <> 'k1' AND (substring(group_key from 2))::int % 3 <> 0;
ANALYZE card_hold_groups;
--    AND THE QUERY UNDER TEST IS THE FUNCTION'S OWN BODY, read from pg_proc.
--    A hand-retyped copy is not a plan guard for the function it names: dropping
--    `AND held_minor > 0` from `held_for_company` moves it off the partial index
--    onto the primary key -- scanning every group the company has ever had,
--    expired ones included -- and a retyped copy carrying the predicate still
--    planned correctly, so the guard could not see the change. The predicate is
--    value-equivalent (`held_minor` is never negative) and plan-critical, which is
--    exactly the combination a hand-written copy cannot catch.
DO $$
DECLARE v_src text; v_sql text;
BEGIN
    SELECT substring(prosrc from 'PLAN-QUERY-BEGIN(.*)-- PLAN-QUERY-END')
      INTO v_src FROM pg_proc WHERE proname = 'held_for_company';
    IF v_src IS NULL THEN
        RAISE EXCEPTION 'held_for_company has no PLAN-QUERY marked region -- either '
                        'the function is gone or its body was rewritten without the '
                        'markers, and this guard is reading nothing';
    END IF;
    v_src := replace(v_src, 'INTO v', '');
    v_sql := replace(replace(replace(v_src,
                 'p_tenant',   quote_literal('p1')),
                 'p_company',  quote_literal('co1')),
                 'p_currency', quote_literal('USD'));
    PERFORM plan_uses('held_for_company (its own shipped body)', v_sql,
                      'ix_hold_groups__held');
END $$;

-- ...and again at the end, because a SET LOCAL in a DO block that SUCCEEDS
-- persists for the rest of the transaction. MODE GUARD. `SET LOCAL session_replication_role = 'replica'` prepended to this
-- file's BEGIN made the whole suite run on the replication apply path, where a
-- guard marked ENABLE REPLICA fires and the ordinary write path is untested. That
-- is how an earlier leak went unnoticed for two hundred lines of negative
-- controls. One line per suite, at both ends.
DO $$ BEGIN
    IF current_setting('session_replication_role') <> 'origin' THEN
        RAISE EXCEPTION
            'this suite is running as %, not origin: every guard it exercises may be '
            'the replica-path one', current_setting('session_replication_role');
    END IF;
    RAISE NOTICE 'ok  running on the ordinary write path';
END $$;

ROLLBACK;

DO $$ BEGIN RAISE NOTICE 'ok  SUITE-COMPLETE query_plans'; END $$;
