-- The acceptance test for the card hold / authorization flow (migrations/0003).
--
-- The claim under test is narrow and specific: a hold is the SUM of an immutable
-- append-only event log, so the same set of processor messages produces the same
-- held amount REGARDLESS of the order they arrive in. Everything else here exists
-- to check that the claim survives the messy parts of the domain -- cumulative
-- totals, re-delivery, over-capture, expiry, and clearings that arrive with no
-- reliable way to tell which authorization they belong to.

\set ON_ERROR_STOP on
\o /dev/null
BEGIN;

CREATE FUNCTION must_fail(p_label text, p_sql text, p_expect text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_msg text;
BEGIN
    BEGIN
        EXECUTE p_sql;
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'NOT_REFUSED';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg = 'NOT_REFUSED' THEN
            RAISE EXCEPTION 'NOT CAUGHT -- %: the ledger accepted it', p_label;
        END IF;
        IF position(lower(p_expect) in lower(v_msg)) = 0 THEN
            RAISE EXCEPTION 'WRONG REASON -- %: expected to contain "%", got "%"',
                p_label, p_expect, v_msg;
        END IF;
        RAISE NOTICE 'refused  %  (%)', p_label, left(v_msg, 66);
    END;
END $$;

CREATE FUNCTION eq(p_label text, p_got bigint, p_want bigint) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_got IS DISTINCT FROM p_want THEN
        RAISE EXCEPTION '% -- expected %, got %', p_label, p_want, p_got;
    END IF;
    RAISE NOTICE 'ok  % = %', p_label, p_got;
END $$;

CREATE FUNCTION no_drift(p_label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM card_hold_drift) THEN
        RAISE EXCEPTION '% -- materialised total disagrees with the event log: %',
            p_label, (SELECT string_agg(format('%s stored=%s recomputed=%s',
                      group_key, COALESCE(stored::text,'<no group>'), recomputed), '; ')
                      FROM card_hold_drift);
    END IF;
END $$;

-- =========================================================== the reference trace

-- 01 authorization $500. The terminal beeps; nothing is owed.
SELECT record_auth_event('t1','msg_auth','g_500','acme','card_1',
        'authorization', 50000,'USD',false, now());
SELECT eq('auth 500.00 held', held_for_company('t1','acme','USD'), 50000);

-- ...and it writes NO ledger entry. This is the single most counter-intuitive
-- property of the design, so it is asserted rather than described.
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM ledger_entries) THEN
        RAISE EXCEPTION 'an authorization wrote a ledger entry';
    END IF;
    RAISE NOTICE 'ok  authorization wrote no ledger entry';
END $$;

-- 02 partial clearing $300 -- the hold shrinks by what actually cleared
SELECT record_auth_event('t1','msg_clear_1','g_500','acme','card_1',
        'clearing', 30000,'USD',false, now());
SELECT eq('after 300.00 cleared', held_for_company('t1','acme','USD'), 20000);

-- 03 final clearing $200
SELECT record_auth_event('t1','msg_clear_2','g_500','acme','card_1',
        'clearing', 20000,'USD',false, now());
SELECT eq('after 200.00 cleared', held_for_company('t1','acme','USD'), 0);
SELECT no_drift('reference trace');

-- =========================================================== order tolerance
--
-- THE CENTRAL CLAIM. The same four messages, applied in four different orders,
-- must produce the same total. v2 stored a mix of deltas and absolutes and
-- resolved them by occurred_at with an insertion-order tiebreak, so the same
-- facts produced different holds depending on which webhook's TCP connection
-- finished first -- silently UNDER-reserving credit.

CREATE FUNCTION apply_perm(p_group text, p_order int[]) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    kinds auth_event_kind[] := ARRAY['authorization','incremental','reversal','clearing'];
    amts  bigint[]          := ARRAY[10000, 2000, 3000, 5000];
    i int; k int;
BEGIN
    FOREACH i IN ARRAY p_order LOOP
        k := i;
        PERFORM record_auth_event('t1', p_group||'_'||k, p_group, 'acme','card_2',
                kinds[k], amts[k], 'USD', false, now());
    END LOOP;
    RETURN (SELECT total_minor FROM card_hold_groups
             WHERE tenant_id='t1' AND group_key=p_group);
END $$;

SELECT eq('order 1,2,3,4', apply_perm('p1', ARRAY[1,2,3,4]), 4000);
SELECT eq('order 4,3,2,1', apply_perm('p2', ARRAY[4,3,2,1]), 4000);
SELECT eq('order 3,1,4,2', apply_perm('p3', ARRAY[3,1,4,2]), 4000);
SELECT eq('order 2,4,1,3', apply_perm('p4', ARRAY[2,4,1,3]), 4000);
SELECT no_drift('order tolerance');

-- A group whose events arrive clearing-first dips negative in passing. The total
-- is unaffected -- that is the point -- and the over-capture flag must not have
-- latched on the transient, or every out-of-order delivery raises a false alarm.
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM card_hold_groups
                WHERE group_key IN ('p1','p2','p3','p4') AND overcaptured_at IS NOT NULL) THEN
        RAISE EXCEPTION 'a transient negative latched the over-capture alarm';
    END IF;
    RAISE NOTICE 'ok  transient negative did not latch the over-capture alarm';
END $$;

-- =========================================================== cumulative totals
--
-- Processors disagree on whether an incremental authorization carries a delta or a
-- cumulative TOTAL. (An earlier comment here said "six of eleven processors
-- surveyed" -- no such survey exists, and it is struck.) The adapter converts at the boundary,
-- under the group's lock, so the stored model stays pure deltas.

-- is_total on the authorization too: a processor that reports increments as
-- cumulative totals reports the opening authorization as one as well (the total
-- after the first message IS the authorization amount). A group may not mix the
-- two conventions -- see the refusal control below for why that is not pedantry.
SELECT record_auth_event('t1','msg_tip_auth','g_tip','acme','card_3',
        'authorization', 10000,'USD',true, now());
-- restaurant adds a 20% tip; the processor restates the TOTAL as 120.00
SELECT record_auth_event('t1','msg_tip_inc','g_tip','acme','card_3',
        'incremental', 12000,'USD',true, now());
SELECT eq('tip: total 120.00 became a +20.00 delta',
          (SELECT total_minor FROM card_hold_groups WHERE group_key='g_tip'), 12000);
SELECT eq('...stored as a delta, not the wire value',
          (SELECT amount_delta FROM card_auth_events WHERE processor_msg_id='msg_tip_inc'), 2000);

-- The same total re-delivered under a NEW message id. A routine re-delivery, and
-- a genuine zero-delta fact. It used to die on the sign CHECK.
SELECT record_auth_event('t1','msg_tip_inc_redelivered','g_tip','acme','card_3',
        'incremental', 12000,'USD',true, now());
SELECT eq('re-delivered total is a no-op',
          (SELECT total_minor FROM card_hold_groups WHERE group_key='g_tip'), 12000);

-- The SAME message id twice -- processor retry. Idempotent, not double-counted.
-- is_total on the authorization too: a processor that reports increments as
-- cumulative totals reports the opening authorization as one as well (the total
-- after the first message IS the authorization amount). A group may not mix the
-- two conventions -- see the refusal control below for why that is not pedantry.
SELECT record_auth_event('t1','msg_tip_auth','g_tip','acme','card_3',
        'authorization', 10000,'USD',true, now());
SELECT eq('duplicate message id did not double-count',
          (SELECT total_minor FROM card_hold_groups WHERE group_key='g_tip'), 12000);
SELECT no_drift('cumulative totals');

-- =========================================================== over-capture
--
-- A $1 fuel-pump authorization that clears at $95. The hold must contribute 0 to
-- available credit -- never RAISE it -- and the condition must be recorded rather
-- than silently swallowed by the clamp.

SELECT record_auth_event('t1','msg_fuel_auth','g_fuel','acme','card_4',
        'authorization', 100,'USD',false, now());
SELECT record_auth_event('t1','msg_fuel_clear','g_fuel','acme','card_4',
        'clearing', 9500,'USD',false, now());
SELECT eq('over-captured group holds 0',
          (SELECT held_minor FROM card_hold_groups WHERE group_key='g_fuel'), 0);
SELECT eq('...but the log keeps the real total',
          (SELECT total_minor FROM card_hold_groups WHERE group_key='g_fuel'), -9400);
DO $$ BEGIN
    IF (SELECT overcaptured_at FROM card_hold_groups WHERE group_key='g_fuel') IS NULL THEN
        RAISE EXCEPTION 'over-capture was swallowed by the clamp instead of recorded';
    END IF;
    RAISE NOTICE 'ok  over-capture recorded as an alarmable state';
END $$;

-- =========================================================== expiry
--
-- Expiry is a FLAG, not an event carrying -remaining: computing that amount means
-- reading the aggregate, which is a read-modify-write smuggled into an append-only
-- log, and a read does not commute.

SELECT record_auth_event('t1','msg_exp_auth','g_exp','acme','card_5',
        'authorization', 7500,'USD',false, now());
SELECT eq('before expiry', (SELECT held_minor FROM card_hold_groups WHERE group_key='g_exp'), 7500);
SELECT expire_hold_group('t1','acme','g_exp');
SELECT eq('after expiry, held is 0',
          (SELECT held_minor FROM card_hold_groups WHERE group_key='g_exp'), 0);
SELECT eq('...and the log is untouched',
          (SELECT total_minor FROM card_hold_groups WHERE group_key='g_exp'), 7500);
SELECT no_drift('expiry');

-- =========================================================== unmatched + regroup
--
-- "No clean foreign key. Network IDs don't reliably agree across messages." So a
-- clearing can arrive with nothing to attach it to. It goes to an explicit
-- unmatched queue and contributes nothing -- never a silent guess.

SELECT record_auth_event('t1','msg_orphan', NULL, 'acme','card_6',
        'clearing', 2500,'USD',false, now());
SELECT eq('orphan clearing is in the unmatched queue',
          (SELECT count(*) FROM card_auth_unmatched WHERE processor_msg_id='msg_orphan'), 1);

SELECT record_auth_event('t1','msg_late_auth','g_late','acme','card_6',
        'authorization', 4000,'USD',false, now());
SELECT eq('the group it should have joined', 
          (SELECT total_minor FROM card_hold_groups WHERE group_key='g_late'), 4000);

-- an operator attaches it. Membership is superseded, never updated: the event
-- stays immutable and the inference about it stays auditable.
SELECT regroup_auth_event('t1',
        (SELECT id FROM card_auth_events WHERE processor_msg_id='msg_orphan'),
        'g_late', 'operator:fernando');
SELECT eq('after re-grouping, the total is rebuilt from the log',
          (SELECT total_minor FROM card_hold_groups WHERE group_key='g_late'), 1500);
SELECT eq('the unmatched queue is now empty',
          (SELECT count(*) FROM card_auth_unmatched), 0);
SELECT eq('exactly one live assignment for that event',
          (SELECT count(*) FROM card_auth_event_group
            WHERE event_id = (SELECT id FROM card_auth_events WHERE processor_msg_id='msg_orphan')
              AND superseded_at IS NULL), 1);
SELECT no_drift('re-grouping an unmatched event');

-- The other corrective case, and the one that broke: an event mis-grouped onto an
-- existing authorization has to be SPLIT into its own group. The destination does
-- not exist yet -- if re-grouping does not materialise it, the membership row
-- points at nothing, the hold vanishes from held_for_company, and credit is
-- UNDER-reserved. It also has to be visible to the drift alarm.
SELECT regroup_auth_event('t1',
        (SELECT id FROM card_auth_events WHERE processor_msg_id='msg_orphan'),
        'g_split', 'operator:fernando');
SELECT eq('the source group is rebuilt without it',
          (SELECT total_minor FROM card_hold_groups WHERE group_key='g_late'), 4000);
SELECT eq('the destination group was materialised',
          (SELECT total_minor FROM card_hold_groups WHERE group_key='g_split'), -2500);
SELECT eq('...carrying the event''s currency and company',
          (SELECT count(*) FROM card_hold_groups
            WHERE group_key='g_split' AND currency='USD' AND company_id='acme'), 1);
SELECT eq('exactly one live assignment after two moves',
          (SELECT count(*) FROM card_auth_event_group
            WHERE event_id = (SELECT id FROM card_auth_events WHERE processor_msg_id='msg_orphan')
              AND superseded_at IS NULL), 1);
SELECT eq('...and the superseded assignment is retained',
          (SELECT count(*) FROM card_auth_event_group
            WHERE event_id = (SELECT id FROM card_auth_events WHERE processor_msg_id='msg_orphan')
              AND superseded_at IS NOT NULL), 1);
SELECT no_drift('splitting into a new group');

-- A group row may not be DELETED: expired_at, its expired_* snapshots and
-- low_water_minor are not in the event log, so a recompute rebuilds the row WRONG
-- rather than failing -- an expired group came back live with its post-expiry drift
-- branch disarmed, and an ordinary incremental after a delete had ingest report
-- 70.00 against 1070.00 of live exposure.
SELECT must_fail('deleting a materialised hold group', $q$
    DELETE FROM card_hold_groups WHERE tenant_id='t1' AND group_key='g_split';
$q$, 'cannot be deleted');

SELECT must_fail('truncating the auth event log', $q$
    TRUNCATE card_auth_events CASCADE;
$q$, 'is history');

SELECT must_fail('rewriting a stored auth event', $q$
    UPDATE card_auth_events SET amount_delta = 1 WHERE processor_msg_id='msg_orphan';
$q$, 'is immutable');

-- The three fixtures below still need the missing-group state, which the guard
-- above now makes unreachable through any API. They disable the trigger for the
-- length of one statement -- the state is defended in production and still
-- attested here, rather than the branch going untested because it became legal
-- nowhere.
-- and the alarm must SEE a group that exists only as membership
SELECT must_fail('membership pointing at a group that was never materialised', $q$
    ALTER TABLE card_hold_groups DISABLE TRIGGER ck_hold_groups__no_delete;
    DELETE FROM card_hold_groups WHERE group_key='g_split';
    SELECT no_drift('missing group');
$q$, 'disagrees with the event log');

-- =========================================================== refusals

-- A cumulative total below what the group already holds arrived out of order
-- relative to totals already applied. Unresolvable from the message alone -- a
-- total carries no sequence -- so it is refused rather than guessed. v2 guessed.
SELECT must_fail('out-of-order cumulative total', $q$
    SELECT record_auth_event('t1','msg_ooo','g_tip','acme','card_3',
            'incremental', 5000,'USD',true, now());
$q$, 'out-of-order cumulative total');

-- A hold total is only meaningful in one currency.
SELECT must_fail('event in another currency joining a group', $q$
    SELECT record_auth_event('t1','msg_eur','g_tip','acme','card_3',
            'incremental', 1000,'EUR',true, now());
$q$, 'cannot join group');

-- The sign is a property of the kind, enforced by the database.
SELECT must_fail('a clearing with a positive delta', $q$
    INSERT INTO card_auth_events (tenant_id,processor_msg_id,company_id,card_id,kind,
                                  amount_delta,currency,occurred_at)
    VALUES ('t1','msg_bad_sign','acme','card_7','clearing', 500,'USD', now());
$q$, 'ck_auth_events__sign');

-- An event belongs to at most one group at a time.
SELECT must_fail('two live group assignments for one event', $q$
    INSERT INTO card_auth_event_group (tenant_id,event_id,group_key,method,assigned_by)
    SELECT 't1', id, 'g_somewhere_else', 'manual', 'test'
      FROM card_auth_events WHERE processor_msg_id='msg_tip_auth';
$q$, 'uq_event_group__current');

-- The alarm itself: tamper with a materialised total.
SELECT must_fail('materialised total tampered with', $q$
    UPDATE card_hold_groups SET total_minor = total_minor + 1 WHERE group_key='g_tip';
    SELECT no_drift('tamper');
$q$, 'disagrees with the event log');


-- =========================================================== the multiplicities
--
-- Everything above this line is one tenant, one company, one currency, one
-- session. Mutation testing showed that is exactly the shape that cannot see the
-- defects that matter: dropping the currency filter, the company filter, the
-- tenant filter and the ingest lock from the shipped code all left the suite
-- green. held_for_company -- the number the authorization decision is made on --
-- was called three times, all before any of the conditions that make its
-- correctness matter existed.

-- Capture acme's USD number first, then introduce a second company, a second
-- currency and a second tenant. The number must not move by one minor unit.
-- Asserted as a DELTA rather than a literal, so it keeps testing isolation as the
-- trace above it evolves.
CREATE TEMP TABLE baseline AS SELECT held_for_company('t1','acme','USD') AS h;

SELECT record_auth_event('t1','m_other_co','g_oc','globex','card_x',
        'authorization', 11100,'USD',false, now());
SELECT record_auth_event('t1','m_eur','g_eur','acme','card_e',
        'authorization', 22200,'EUR',false, now());
SELECT record_auth_event('t2','m_other_tn','g_ot','acme','card_t',
        'authorization', 33300,'USD',false, now());

SELECT eq('another company, currency and tenant move acme USD by',
          held_for_company('t1','acme','USD') - (SELECT h FROM baseline), 0);
SELECT eq('acme EUR is its own number',   held_for_company('t1','acme','EUR'), 22200);
SELECT eq('globex USD is its own number', held_for_company('t1','globex','USD'), 11100);
SELECT eq('tenant t2 is its own world',   held_for_company('t2','acme','USD'), 33300);
SELECT no_drift('multiplicities');

-- ...and the clamp and the expiry flag must apply THROUGH the function, not only
-- to the column. Replacing SUM(held_minor) with SUM(total_minor) inside
-- held_for_company bypassed both, and the suite never noticed, because nothing
-- ever read them through here. g_fuel is over-captured, so the function must
-- report strictly less than the raw sum of totals.
DO $$
DECLARE v_fn bigint; v_raw bigint;
BEGIN
    v_fn := held_for_company('t1','acme','USD');
    -- Sum of held_minor over ALL groups, including those the function's
    -- `held_minor > 0` predicate skips. Comparing against SUM(total_minor) did not
    -- kill the mutation it names -- swapping held_minor for total_minor leaves that
    -- predicate in place, which already excludes the over-captured group, so both
    -- sums came out identical. This comparison has no such escape.
    SELECT COALESCE(SUM(held_minor),0) INTO v_raw FROM card_hold_groups
     WHERE tenant_id='t1' AND company_id='acme' AND currency='USD';
    IF v_fn IS DISTINCT FROM v_raw THEN
        RAISE EXCEPTION 'held_for_company (%) disagrees with the sum of held_minor (%)',
            v_fn, v_raw;
    END IF;
    IF (SELECT COALESCE(SUM(total_minor),0) FROM card_hold_groups
         WHERE tenant_id='t1' AND company_id='acme' AND currency='USD') >= v_fn THEN
        RAISE EXCEPTION 'the clamp is not reducing anything: held % vs raw totals %',
            v_fn, (SELECT SUM(total_minor) FROM card_hold_groups
                    WHERE tenant_id='t1' AND company_id='acme' AND currency='USD');
    END IF;
    RAISE NOTICE 'ok  held_for_company clamps and honours expiry: % vs raw %', v_fn, v_raw;
END $$;

-- =========================================================== expiry is not terminal

SELECT record_auth_event('t1','r_auth','g_reopen','zeta','card_r',
        'authorization', 30000,'USD',false, now());
SELECT expire_hold_group('t1','zeta','g_reopen');
SELECT eq('expired', held_for_company('t1','zeta','USD'), 0);
-- A processor sends an increment on the same lifecycle id: a hotel guest extends
-- their stay. Our release was premature. expired_at was a one-way latch that
-- nothing ever cleared, so this event was silently voided -- 300.00 genuinely
-- held, reported as 0.00, with no drift anywhere.
SELECT record_auth_event('t1','r_inc','g_reopen','zeta','card_r',
        'incremental', 5000,'USD',false, now());
SELECT eq('an increment after expiry re-opens the hold',
          held_for_company('t1','zeta','USD'), 35000);
-- ...but a late CLEARING must not resurrect a released hold.
SELECT expire_hold_group('t1','zeta','g_reopen');
SELECT record_auth_event('t1','r_clr','g_reopen','zeta','card_r',
        'clearing', 1000,'USD',false, now());
SELECT eq('a late clearing does not resurrect it',
          held_for_company('t1','zeta','USD'), 0);
SELECT no_drift('expiry re-open');

-- =========================================================== company isolation
--
-- group_key is INFERRED from network values (RRN, lifecycle id) which are not
-- per-company, so two companies colliding on one is a real state. recompute_hold_group
-- filtered on (tenant, group_key) only, for both its SUM and its UPDATE, so a
-- different company's clearing reduced acme's held amount -- and running the repair
-- again never converged.
SELECT record_auth_event('t1','s_a','shared_key','acme','card_sa',
        'authorization', 50000,'USD',false, now());
SELECT record_auth_event('t1','s_b','shared_key','globex','card_sb',
        'authorization', 70000,'USD',false, now());
SELECT eq('two companies may share an inferred group key: acme',
          (SELECT total_minor FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='acme' AND group_key='shared_key'), 50000);
SELECT eq('...and globex is unaffected',
          (SELECT total_minor FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='globex' AND group_key='shared_key'), 70000);
SELECT recompute_hold_group('t1','acme','shared_key');
SELECT recompute_hold_group('t1','globex','shared_key');
SELECT eq('the repair is company-scoped and converges: acme',
          (SELECT total_minor FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='acme' AND group_key='shared_key'), 50000);
SELECT eq('...globex',
          (SELECT total_minor FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='globex' AND group_key='shared_key'), 70000);
SELECT no_drift('company isolation');

-- =========================================================== over-capture evidence

SELECT eq('the over-capture low-water mark is durable',
          (SELECT low_water_minor FROM card_hold_groups WHERE group_key='g_fuel'), -9400);
-- overcaptured_at is deliberately non-latching (a transient dip must not alarm),
-- which means it is erased by the next event that lifts the total. The low-water
-- mark is what keeps "did this ever over-capture" answerable.
SELECT record_auth_event('t1','g_fuel_more','g_fuel','acme','card_4',
        'authorization', 20000,'USD',false, now());
SELECT eq('...and survives the total going positive again',
          (SELECT low_water_minor FROM card_hold_groups WHERE group_key='g_fuel'), -9400);
SELECT eq('while the live flag correctly clears',
          (SELECT count(*) FROM card_hold_groups
            WHERE group_key='g_fuel' AND overcaptured_at IS NULL), 1);

-- =========================================================== zero-amount messages

-- A $0.00 authorization is account verification (AVS / card-on-file). It is a real
-- message on every network and was refused outright with an opaque CHECK error.
SELECT record_auth_event('t1','v0','g_verify','acme','card_v',
        'authorization', 0,'USD',false, now());
SELECT eq('a $0.00 verification authorization is accepted',
          (SELECT count(*) FROM card_auth_events WHERE processor_msg_id='v0'), 1);
SELECT eq('...and its group holds nothing',
          (SELECT held_minor FROM card_hold_groups WHERE group_key='g_verify'), 0);

-- =========================================================== more refusals

-- Mixing conventions inside one group is irreconcilable, not merely awkward:
-- {auth +100.00 delta, incremental 120.00 total} gives 120.00 in one order and
-- 220.00 in the other, because a total arriving BEFORE the delta it restates
-- carries no information saying it already includes it.
SELECT must_fail('a cumulative total in a group that reports deltas', $q$
    SELECT record_auth_event('t1','mix1','g_late','acme','card_6',
            'incremental', 9999,'USD',true, now());
$q$, 'cannot mix the two');

SELECT must_fail('re-grouping an event into another currency''s group', $q$
    SELECT regroup_auth_event('t1',
        (SELECT id FROM card_auth_events WHERE processor_msg_id='m_eur'),
        'g_late', 'operator:fernando');
$q$, 'only meaningful in one currency');

-- a DELTA event, matching g_late's convention, so the expiry guard is what fires
-- rather than the convention guard that now precedes it
SELECT must_fail('re-grouping an event into an EXPIRED group', $q$
    SELECT record_auth_event('t1','exp_probe', NULL,'acme','card_6',
            'authorization', 1500,'USD',false, now());
    SELECT expire_hold_group('t1','acme','g_late');
    SELECT regroup_auth_event('t1',
        (SELECT id FROM card_auth_events WHERE processor_msg_id='exp_probe'),
        'g_late', 'operator:fernando');
$q$, 'which expired at');

SELECT must_fail('an expiry_reversal with a negative delta', $q$
    INSERT INTO card_auth_events (tenant_id,processor_msg_id,company_id,card_id,kind,
                                  amount_delta,currency,occurred_at)
    VALUES ('t1','neg_exprev','acme','card_z','expiry_reversal', -999999,'USD', now());
$q$, 'ck_auth_events__sign');

-- The alarm must see a group whose events are not all in its declared currency --
-- the state re-grouping used to be able to create. It compared total_minor and
-- nothing else, so two currencies in one group reported no drift at all.
SELECT must_fail('a group holding two currencies', $q$
    INSERT INTO card_auth_events (tenant_id,processor_msg_id,company_id,card_id,kind,
                                  amount_delta,currency,occurred_at)
    VALUES ('t1','sneak_eur','acme','card_6','authorization', 100,'EUR', now());
    INSERT INTO card_auth_event_group (tenant_id,event_id,group_key,method,assigned_by)
    SELECT 't1', id, 'g_oc', 'manual', 'test'
      FROM card_auth_events WHERE processor_msg_id='sneak_eur';
    SELECT no_drift('two currencies');
$q$, 'disagrees with the event log');

-- =========================================================== more refusals
--
-- Each of these was a live under-reservation found by adversarial review, and
-- none was reachable from the suite as it stood: `advice` appeared nowhere in any
-- test file, `expiry_reversal` only inside a sign-CHECK refusal, and `is_total`
-- was never passed with a decrease-side kind.

-- A cumulative total restates the AUTHORIZED subtotal. Applied to a clearing it
-- computed `amount - authorized_minor` against a base the message has nothing to
-- do with: a 100.00 authorization with a cumulative-cleared field of 30.00 held
-- 30.00 where 70.00 was live, with no drift, because total_minor genuinely
-- equalled the sum of the wrongly-derived deltas.
SELECT must_fail('a clearing carrying a cumulative total', $q$
    SELECT record_auth_event('t1','ct_clr','g_late','acme','card_6',
            'clearing', 3000,'USD',true, now());
$q$, 'only meaningful on an authorization');

-- Expiry is a flag. The enum and the sign CHECK both admitted it as an EVENT
-- carrying the remainder, which double-releases: once in the log, once in the
-- flag, and a later re-open restores only what the flag suppressed.
SELECT must_fail('an expiry EVENT alongside the expiry flag', $q$
    SELECT record_auth_event('t1','ev_exp','g_late','acme','card_6',
            'expiry', 100,'USD',false, now());
$q$, 'expiry is a flag');

-- The conversion needs the group whose subtotal it restates.
SELECT must_fail('a cumulative total on an unmatched event', $q$
    SELECT record_auth_event('t1','ct_orphan', NULL,'acme','card_6',
            'authorization', 5000,'USD',true, now());
$q$, 'unmatched event');

-- `advice` is an increase-side kind everywhere -- it sets the convention and moves
-- authorized_minor -- but was missing from the un-expire list, so an advice after
-- expiry added exposure that held_for_company reported as 0 while
-- record_auth_event returned the true total to its own caller. The two lists must
-- be one list.
SELECT record_auth_event('t1','adv_auth','g_advice','zeta','card_a',
        'authorization', 30000,'USD',false, now());
SELECT expire_hold_group('t1','zeta','g_advice');
SELECT eq('expired', held_for_company('t1','zeta','USD'), 0);
SELECT record_auth_event('t1','adv_ev','g_advice','zeta','card_a',
        'advice', 5000,'USD',false, now());
SELECT eq('an advice after expiry re-opens the hold too',
          held_for_company('t1','zeta','USD'), 35000);

-- A late clearing on an expired group is NORMAL and must not alarm; exposure
-- added after a release must.
SELECT expire_hold_group('t1','zeta','g_advice');
SELECT record_auth_event('t1','adv_clr','g_advice','zeta','card_a',
        'clearing', 1000,'USD',false, now());
SELECT no_drift('a late clearing on an expired group');

-- The repair must repair the state the alarm was extended to detect. It locked
-- nothing when the row was absent and its UPDATE matched nothing, so it RETURNED
-- the correct total while changing nothing -- the alarm fired, the operator ran
-- the repair, and the drift stayed.
SELECT record_auth_event('t1','rep_a','g_repair','acme','card_r',
        'authorization', 8000,'USD',false, now());
ALTER TABLE card_hold_groups DISABLE TRIGGER ck_hold_groups__no_delete;
DELETE FROM card_hold_groups WHERE tenant_id='t1' AND group_key='g_repair';
ALTER TABLE card_hold_groups ENABLE ALWAYS TRIGGER ck_hold_groups__no_delete;
SELECT recompute_hold_group('t1','acme','g_repair');
SELECT eq('a deleted group row is rebuilt from the log',
          (SELECT total_minor FROM card_hold_groups WHERE group_key='g_repair'), 8000);
SELECT no_drift('repairing a missing group');

-- Re-delivery WITH better matching information is the case the unmatched queue
-- exists to serve, and it was the one path that could never take effect: the
-- event was already stored, so ingest returned before writing the assignment.
SELECT record_auth_event('t1','redeliv', NULL,'acme','card_d',
        'authorization', 7000,'USD',false, now());
SELECT eq('unmatched on first delivery',
          (SELECT count(*) FROM card_auth_unmatched WHERE processor_msg_id='redeliv'), 1);
SELECT record_auth_event('t1','redeliv','g_redeliv','acme','card_d',
        'authorization', 7000,'USD',false, now());
SELECT eq('re-delivery with a group attaches it',
          (SELECT total_minor FROM card_hold_groups WHERE group_key='g_redeliv'), 7000);
SELECT eq('...and it leaves the unmatched queue',
          (SELECT count(*) FROM card_auth_unmatched WHERE processor_msg_id='redeliv'), 0);
SELECT no_drift('re-delivery with better matching');

-- =========================================================== the conversion base
--
-- THE ROOT-CAUSE BUG THIS FILE EXISTS FOR, and it had no control: deriving a
-- cumulative total's delta from the group's NET total instead of its AUTHORIZED
-- subtotal. Mutation testing showed both that mutation and its sibling
-- (authorized_minor accumulating every delta rather than the increase side) passed
-- the entire suite.
--
-- A group that reports totals, with a partial clearing in between:
--   authorization total 100.00      -> authorized 10000, total 10000
--   clearing delta       30.00      -> authorized 10000, total  7000
--   incremental total   120.00      -> delta is 120.00 - 100.00 = 20.00
--                                      NOT 120.00 - 70.00 = 50.00
SELECT record_auth_event('t1','cb_auth','g_base','acme','card_b',
        'authorization', 10000,'USD',true, now());
SELECT record_auth_event('t1','cb_clr','g_base','acme','card_b',
        'clearing', 3000,'USD',false, now());
SELECT eq('after a partial clearing, the net total moves',
          (SELECT total_minor FROM card_hold_groups WHERE group_key='g_base'), 7000);
SELECT eq('...but the authorized subtotal does NOT',
          (SELECT authorized_minor FROM card_hold_groups WHERE group_key='g_base'), 10000);
SELECT record_auth_event('t1','cb_inc','g_base','acme','card_b',
        'incremental', 12000,'USD',true, now());
SELECT eq('a later total converts against AUTHORIZED, not the net total',
          (SELECT amount_delta FROM card_auth_events WHERE processor_msg_id='cb_inc'), 2000);
SELECT eq('...so the hold is 120.00 authorized less 30.00 cleared',
          (SELECT total_minor FROM card_hold_groups WHERE group_key='g_base'), 9000);
SELECT eq('...and the authorized subtotal tracks the restatement',
          (SELECT authorized_minor FROM card_hold_groups WHERE group_key='g_base'), 12000);
SELECT no_drift('the conversion base');

-- =========================================================== the attach path
--
-- The re-delivery block is the ONLY path that attaches an event to a group without
-- going through fresh ingest, and it used to sit before every guard and consult
-- none of them. Three under-reservations came out of that one placement, and the
-- suite's single re-delivery test used the one shape where the missing guards did
-- not matter: same currency, same company, not expired, delta convention.
--
-- The strongest single assertion here is the last one: what ingest RETURNS to its
-- caller must equal what held_for_company reports. Those two numbers disagreeing by
-- the entire exposure is what several of these defects looked like from outside.

-- an expiry_reversal -- the message whose meaning is "your release was premature" --
-- re-delivered onto an expired group must re-open it, not be swallowed by the clamp
SELECT record_auth_event('t1','ar_auth','g_ar','zeta','card_ar',
        'authorization', 10000,'USD',false, now());
SELECT expire_hold_group('t1','zeta','g_ar');
SELECT record_auth_event('t1','ar_rev', NULL,'zeta','card_ar',
        'expiry_reversal', 10000,'USD',false, now());
SELECT eq('an expiry_reversal re-delivered with its group re-opens the hold',
          (SELECT record_auth_event('t1','ar_rev','g_ar','zeta','card_ar',
                   'expiry_reversal', 10000,'USD',false, now())), 20000);
SELECT eq('...and what ingest returned is what the company actually holds',
          held_for_company('t1','zeta','USD'), 20000);
SELECT no_drift('re-delivery onto an expired group');

-- ...and the same message on the FRESH-INGEST path. The two paths have separate
-- un-expire lists, so a test that only covers one leaves the other deletable --
-- which it was: dropping expiry_reversal from the main list changed nothing.
SELECT record_auth_event('t1','fr_auth','g_fr','zeta','card_fr',
        'authorization', 4000,'USD',false, now());
SELECT expire_hold_group('t1','zeta','g_fr');
SELECT eq('expired', (SELECT held_minor FROM card_hold_groups WHERE group_key='g_fr'), 0);
SELECT record_auth_event('t1','fr_rev','g_fr','zeta','card_fr',
        'expiry_reversal', 1000,'USD',false, now());
SELECT eq('an expiry_reversal on first delivery re-opens the hold',
          (SELECT held_minor FROM card_hold_groups WHERE group_key='g_fr'), 5000);

-- a cumulative RESTATEMENT is itself the liveness signal: its delta is zero
SELECT record_auth_event('t1','sr_auth','g_sr','hotel','card_sr',
        'authorization', 30000,'USD',true, now());
SELECT expire_hold_group('t1','hotel','g_sr');
SELECT record_auth_event('t1','sr_again','g_sr','hotel','card_sr',
        'authorization', 30000,'USD',true, now());
SELECT eq('a cumulative restatement re-opens an expired hold (its delta is 0)',
          held_for_company('t1','hotel','USD'), 30000);

-- ...and the alarm must see exposure raised after a release by REMOVING a
-- decrease-side event, which never moves the authorized subtotal
SELECT must_fail('splitting a clearing out of an expired group', $q$
    SELECT record_auth_event('t1','xc_auth','g_xc','acme','card_xc',
            'authorization', 10000,'USD',false, now());
    SELECT record_auth_event('t1','xc_clr','g_xc','acme','card_xc',
            'clearing', 8000,'USD',false, now());
    SELECT expire_hold_group('t1','acme','g_xc');
    SELECT regroup_auth_event('t1',
            (SELECT id FROM card_auth_events WHERE processor_msg_id='xc_clr'),
            'g_xc2','operator');
    SELECT no_drift('exposure raised after a release');
$q$, 'disagrees with the event log');

-- a $0.00 status advice must not fix the group's convention: doing so refused the
-- processor's own opening authorization forever
SELECT record_auth_event('t1','adv0','g_adv0','acme','card_a0',
        'advice', 0,'USD',false, now());
SELECT eq('a $0.00 advice leaves the convention unset',
          (SELECT count(*) FROM card_hold_groups
            WHERE group_key='g_adv0' AND total_convention IS NULL), 1);
SELECT record_auth_event('t1','adv0_auth','g_adv0','acme','card_a0',
        'authorization', 10000,'USD',true, now());
SELECT eq('...so the opening cumulative total is still accepted',
          (SELECT held_minor FROM card_hold_groups WHERE group_key='g_adv0'), 10000);

-- the re-delivery path must honour the currency and convention guards
SELECT must_fail('re-delivery attaching a EUR event to a USD group', $q$
    SELECT record_auth_event('t1','rd_eur', NULL,'acme','card_rd',
            'authorization', 5000,'EUR',false, now());
    SELECT record_auth_event('t1','rd_eur','g_late','acme','card_rd',
            'authorization', 5000,'EUR',false, now());
$q$, 'cannot join group');

SELECT must_fail('re-delivery attaching a delta to a totals group', $q$
    SELECT record_auth_event('t1','rd_delta', NULL,'acme','card_rd',
            'incremental', 5000,'USD',false, now());
    SELECT record_auth_event('t1','rd_delta','g_tip','acme','card_rd',
            'incremental', 5000,'USD',false, now());
$q$, 'cannot mix the two');

-- ...and must not attach an event under a company it does not belong to
SELECT must_fail('re-delivery under a different company', $q$
    SELECT record_auth_event('t1','rd_co', NULL,'acme','card_rd',
            'authorization', 5000,'USD',false, now());
    SELECT record_auth_event('t1','rd_co','g_co','globex','card_rd',
            'authorization', 5000,'USD',false, now());
$q$, 'already exists for company');

-- 'expiry' as an EVENT must be refused by the CONSTRAINT, not only the function --
-- an operator backfill or a second adapter bypasses the function entirely
SELECT must_fail('an expiry event written directly', $q$
    INSERT INTO card_auth_events (tenant_id,processor_msg_id,company_id,card_id,kind,
                                  amount_delta,currency,occurred_at)
    VALUES ('t1','direct_expiry','acme','card_x','expiry', -100,'USD', now());
$q$, 'ck_auth_events__sign');

-- the repair must work in the state the alarm exists to detect: no group row
SELECT record_auth_event('t1','mr_auth','g_missing','acme','card_mr',
        'authorization', 8000,'USD',false, now());
ALTER TABLE card_hold_groups DISABLE TRIGGER ck_hold_groups__no_delete;
DELETE FROM card_hold_groups WHERE tenant_id='t1' AND group_key='g_missing';
ALTER TABLE card_hold_groups ENABLE ALWAYS TRIGGER ck_hold_groups__no_delete;
SELECT recompute_hold_group('t1','acme','g_missing');
SELECT eq('a missing group is materialised and repaired, not just returned',
          (SELECT total_minor FROM card_hold_groups WHERE group_key='g_missing'), 8000);
SELECT no_drift('repairing a missing group');

-- =========================================================== the alarm's branches
--
-- card_hold_drift has four branches and only two were tested. The control labelled
-- "a group holding two currencies" was catching on the TOTAL-MISMATCH branch, not
-- the currency one: its EUR event carried a non-zero delta, and its group row
-- belonged to a different company, so the currency clause -- which is qualified
-- `AND e.company_id = g.company_id` -- never evaluated at all.

-- the CURRENCY branch, in isolation: same company, zero delta, so the totals agree
-- and only a currency disagreement can fire.
SELECT must_fail('a group holding two currencies, with totals agreeing', $q$
    SELECT record_auth_event('t1','cb_usd','g_ccy','acme','card_c',
            'authorization', 5000,'USD',false, now());
    INSERT INTO card_auth_events (tenant_id,processor_msg_id,company_id,card_id,kind,
                                  amount_delta,currency,raw_is_total,occurred_at)
    VALUES ('t1','cb_eur0','acme','card_c','advice', 0,'EUR',false, now());
    INSERT INTO card_auth_event_group (tenant_id,event_id,group_key,method,assigned_by)
    SELECT 't1', id, 'g_ccy', 'manual', 'test'
      FROM card_auth_events WHERE tenant_id='t1' AND processor_msg_id='cb_eur0';
    DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM card_hold_drift WHERE group_key='g_ccy') THEN
            RAISE EXCEPTION 'CURRENCY DRIFT: %',
                (SELECT stored||'/'||recomputed FROM card_hold_drift WHERE group_key='g_ccy');
        END IF;
    END $d$;
$q$, 'currency drift');

-- the POST-EXPIRY branch, as a POSITIVE control. It was only ever asserted by
-- `no_drift(...) = 0`, an assertion of ABSENCE, which passes trivially when the
-- branch is deleted.
SELECT must_fail('exposure raised after a release', $q$
    SELECT record_auth_event('t1','pe_auth','g_pe','acme','card_p',
            'authorization', 6000,'USD',false, now());
    SELECT expire_hold_group('t1','acme','g_pe');
    UPDATE card_hold_groups SET authorized_minor = authorized_minor + 100
     WHERE tenant_id='t1' AND group_key='g_pe';
    DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM card_hold_drift WHERE group_key='g_pe') THEN
            RAISE EXCEPTION 'POST-EXPIRY DRIFT detected';
        END IF;
    END $d$;
$q$, 'post-expiry drift');

-- =========================================================== expire_hold_group
--
-- Three mutations survived: re-expiring an already-expired group, dropping its
-- tenant filter (cross-tenant expiry), and dropping the snapshot columns the
-- post-expiry alarm keys on.

SELECT record_auth_event('t1','ex1','g_ex1','acme','card_e1',
        'authorization', 9000,'USD',false, now());
-- ...and the COMPANY filter, which the tenant test cannot reach: two companies in
-- ONE tenant sharing an inferred group key, which is a real state because group_key
-- comes from network values that are not per-company. Expiring one must not release
-- the other.
SELECT record_auth_event('t1','exc_a','g_share_exp','acme','card_x1',
        'authorization', 4400,'USD',false, now());
SELECT record_auth_event('t1','exc_b','g_share_exp','globex','card_x2',
        'authorization', 5500,'USD',false, now());
SELECT expire_hold_group('t1','acme','g_share_exp');
SELECT eq('expiring one company''s group leaves the other company''s alone',
          (SELECT held_minor FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='globex' AND group_key='g_share_exp'), 5500);
SELECT eq('...and the expired one is released',
          (SELECT held_minor FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_share_exp'), 0);

-- a tenant of its own: t2 already carries a hold from the multiplicities block
SELECT record_auth_event('t3','ex2','g_ex1','acme','card_e2',
        'authorization', 3000,'USD',false, now());
SELECT expire_hold_group('t1','acme','g_ex1');
SELECT eq('expiring in one tenant leaves the other alone',
          held_for_company('t3','acme','USD'), 3000);
SELECT eq('...and snapshots the subtotal the alarm keys on',
          (SELECT expired_authorized FROM card_hold_groups
            WHERE tenant_id='t1' AND group_key='g_ex1'), 9000);
SELECT eq('...and the total',
          (SELECT expired_total FROM card_hold_groups
            WHERE tenant_id='t1' AND group_key='g_ex1'), 9000);

-- Expiry is idempotent: a second call must not move the release time or the
-- snapshot it took. "Exposure added since the release" is measured against both,
-- so a re-expiry that resets them blinds the alarm to everything in between --
-- and a sweep that runs every minute would reset them every minute.
-- NOT ASSERTED HERE, deliberately. This whole file is one transaction and
-- expire_hold_group stamps now(), which is transaction-start time, so a second
-- call inside it is indistinguishable from the first whether the guard is present
-- or not -- an assertion here would pass either way. It is asserted in
-- tests/concurrency.sh, which has real sessions and real clock time.

-- =========================================================== recompute fidelity
--
-- The repair was asserted only on total_minor, so it could recompute the
-- authorized subtotal over ALL kinds, drop the LEAST on the low-water mark, or
-- zero open_events, with the suite green.
SELECT record_auth_event('t1','rf_auth','g_rf','acme','card_rf',
        'authorization', 10000,'USD',false, now());
SELECT record_auth_event('t1','rf_clr','g_rf','acme','card_rf',
        'clearing', 12000,'USD',false, now());
SELECT eq('over-captured: the low-water mark records it',
          (SELECT low_water_minor FROM card_hold_groups WHERE group_key='g_rf'), -2000);
SELECT record_auth_event('t1','rf_more','g_rf','acme','card_rf',
        'authorization', 5000,'USD',false, now());
SELECT recompute_hold_group('t1','acme','g_rf');
SELECT eq('the repair keeps the authorized subtotal to increase-side kinds',
          (SELECT authorized_minor FROM card_hold_groups WHERE group_key='g_rf'), 15000);
SELECT eq('...preserves the low-water mark rather than overwriting it',
          (SELECT low_water_minor FROM card_hold_groups WHERE group_key='g_rf'), -2000);
SELECT eq('...and counts the live events',
          (SELECT open_events FROM card_hold_groups WHERE group_key='g_rf'), 3);

-- =========================================================== the STORED event
--
-- The attach path used to validate the CALLER'S PARAMETERS. On fresh ingest those
-- are the event, so the guards were sound; on re-delivery the event already exists
-- and is immutable, and checking the caller's claims about it checks the wrong
-- thing. The suite could not see this because both deliveries in its tests passed
-- the SAME values -- it only ever varied them together.

SELECT record_auth_event('t1','sv_jpy', NULL,'acme','card_s',
        'clearing', 50000,'JPY',false, now());
SELECT record_auth_event('t1','sv_auth','g_stored','acme','card_s',
        'authorization', 10000,'USD',false, now());
SELECT must_fail('a stored JPY event re-delivered as USD', $q$
    SELECT record_auth_event('t1','sv_jpy','g_stored','acme','card_s',
            'clearing', 50000,'USD',false, now());
$q$, 'stored event sv_jpy is in JPY');

SELECT record_auth_event('t1','sv_tot','g_conv','acme','card_s',
        'authorization', 10000,'USD',true, now());
SELECT record_auth_event('t1','sv_delta', NULL,'acme','card_s',
        'incremental', 30000,'USD',false, now());
SELECT must_fail('a stored DELTA re-delivered as a total, into a totals group', $q$
    SELECT record_auth_event('t1','sv_delta','g_conv','acme','card_s',
            'incremental', 30000,'USD',true, now());
$q$, 'reports a delta, but group');

-- the sharpest one: an expiry_reversal normalised as a clearing by a second
-- adapter, landing on an expired group and swallowed by the clamp
SELECT record_auth_event('t1','sv_ea','g_rev','zeta','card_s',
        'authorization', 100000,'USD',false, now());
SELECT expire_hold_group('t1','zeta','g_rev');
SELECT record_auth_event('t1','sv_er', NULL,'zeta','card_s',
        'expiry_reversal', 90000,'USD',false, now());
SELECT eq('a stored expiry_reversal re-opens even when re-delivered as a clearing',
          (SELECT record_auth_event('t1','sv_er','g_rev','zeta','card_s',
                   'clearing', 90000,'USD',false, now())), 190000);
-- zeta already holds from earlier blocks, so assert the GROUP, not the company
SELECT eq('...and the group holds what ingest returned',
          (SELECT held_minor FROM card_hold_groups WHERE group_key='g_rev'), 190000);
SELECT no_drift('the stored-event guards');

-- =========================================================== the alarm, again

-- authorized_minor is the base every cumulative conversion uses and the sole input
-- to the out-of-order refusal. Nothing compared it to anything.
SELECT must_fail('a tampered authorized subtotal', $q$
    SELECT record_auth_event('t1','am1','g_am','acme','card_a',
            'authorization', 10000,'USD',false, now());
    UPDATE card_hold_groups SET authorized_minor = 999999
     WHERE tenant_id='t1' AND group_key='g_am';
    SELECT no_drift('authorized subtotal');
$q$, 'disagrees with the event log');

-- exposure restored by REMOVING a decrease that arrived AFTER the release. The
-- snapshot taken at expiry never sees it, so the snapshot ratchets down.
SELECT must_fail('removing a late clearing from an expired group', $q$
    SELECT record_auth_event('t1','lc1','g_lc','acme','card_l',
            'authorization', 100000,'USD',false, now());
    SELECT expire_hold_group('t1','acme','g_lc');
    SELECT record_auth_event('t1','lc2','g_lc','acme','card_l',
            'clearing', 100000,'USD',false, now());
    SELECT regroup_auth_event('t1',
            (SELECT id FROM card_auth_events WHERE processor_msg_id='lc2'),
            'g_lc2','operator');
    SELECT no_drift('exposure restored on an expired group');
$q$, 'disagrees with the event log');

-- re-grouping must guard convention too: the operator's routine correction
-- poisoned the authorized subtotal exactly as a mixed ingest does
SELECT must_fail('re-grouping across conventions', $q$
    SELECT record_auth_event('t1','rc_t','g_rct','acme','card_r',
            'authorization', 10000,'USD',true, now());
    SELECT record_auth_event('t1','rc_d','g_rcd','acme','card_r',
            'authorization', 20000,'USD',false, now());
    SELECT regroup_auth_event('t1',
            (SELECT id FROM card_auth_events WHERE processor_msg_id='rc_d'),
            'g_rct','operator');
$q$, 'reports increases as');

DO $$ BEGIN RAISE NOTICE 'ok  card hold flow attested'; END $$;

ROLLBACK;
