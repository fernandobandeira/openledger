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
DECLARE v_plan text;
BEGIN
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
    IF v_plan !~ 'Seq Scan' THEN
        RAISE EXCEPTION E'the business-date aggregate no longer scans. That is not '
            'a failure -- it means period checkpoints or a new index landed, and '
            'ADR-0003''s "linear in history, nothing bounds it" is now wrong. '
            'Update the ADR and assert the new plan here:\n%', v_plan;
    END IF;
    RAISE NOTICE 'ok  business-date aggregate is a scan, as ADR-0003 says (unbounded, M5)';
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

-- 6. held_for_company is the ~1s real-time authorization read -- the whole reason
--    the hold total is materialised at all -- and it had no plan coverage. Only
--    ledger_entries did.
INSERT INTO card_hold_groups (tenant_id, company_id, group_key, currency, total_minor)
SELECT 'p1', 'co'||(g % 200), 'k'||g, 'USD', 100 FROM generate_series(1,20000) g;
UPDATE card_hold_groups SET expired_at = now()
 WHERE tenant_id='p1' AND group_key <> 'k1' AND (substring(group_key from 2))::int % 3 <> 0;
ANALYZE card_hold_groups;
SELECT plan_uses('held_for_company', $q$
    SELECT SUM(held_minor) FROM card_hold_groups
     WHERE tenant_id='p1' AND company_id='co1' AND currency='USD' AND held_minor > 0
$q$, 'ix_hold_groups__held');

ROLLBACK;

DO $$ BEGIN RAISE NOTICE 'ok  SUITE-COMPLETE query_plans'; END $$;
