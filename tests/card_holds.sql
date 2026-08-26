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
    -- ...AND IT MUST PRINT. Silent on success meant not one of these calls counted
    -- toward the file's assertion floor, so every no_drift() line in the file could
    -- be deleted with the floor satisfied and the build green -- which is precisely
    -- the erosion the floor exists to catch, in the helper that carries the alarm.
    RAISE NOTICE 'ok  no drift: %', p_label;
END $$;

-- =========================================================== the reference trace

-- 01 authorization $500. The terminal beeps; nothing is owed.
SELECT record_auth_event('t1','msg_auth','g_500','acme','card_1',
        'authorization', 50000,'USD',false, now());
SELECT eq('auth 500.00 held', held_for_company('t1','acme','USD'), 50000);

-- ...and it writes NO ledger entry. This is the single most counter-intuitive
-- property of the design, so it is asserted rather than described.
DO $$ BEGIN
    -- scoped to this suite's tenant: the claim is that THIS authorization wrote no
    -- entry, and a committed fixture under another tenant (tests/fixtures) is not a
    -- counter-example to it.
    IF EXISTS (SELECT 1 FROM ledger_entries WHERE tenant_id = 't1') THEN
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

-- NAME THE TABLE. `refuse_truncate()` prints "<table> is history", and expecting
-- the bare suffix meant CASCADE could answer for a guard that was gone: with
-- ck_auth_events__no_truncate deleted, TRUNCATE card_auth_events CASCADE is still
-- refused -- by card_auth_event_group's guard, naming a different table -- and the
-- control passed. All three of 0003's truncate guards could be deleted with the
-- build green. tests/negative_controls.sql records this exact defect and its fix
-- for the ledger tables; the card suite carried the same control and not the fix.
SELECT must_fail('truncating the auth event log', $q$
    TRUNCATE card_auth_events CASCADE;
$q$, 'card_auth_events is history');
SELECT must_fail('truncating the materialised hold groups', $q$
    TRUNCATE card_hold_groups CASCADE;
$q$, 'card_hold_groups is history');
-- ...and the membership table, which had no truncate control at all. It is the
-- only record of WHICH group an event belongs to; the log cannot rebuild it.
SELECT must_fail('truncating the membership table', $q$
    TRUNCATE card_auth_event_group CASCADE;
$q$, 'card_auth_event_group is history');

-- ...AND THE DELETE ARM OF THE IMMUTABILITY TRIGGER, AS THE OWNER. The only DELETE
-- control in this file runs as openledger_app and expects `permission denied` -- so
-- it is answered by the missing GRANT, never by the trigger, and the trigger could
-- be narrowed to BEFORE UPDATE with the whole build green. 0001 states the lesson
-- in as many words: "REVOKE is a grant, not a constraint, and migrations run as a
-- privileged role." An unmatched event has no membership, so the foreign key is
-- not a second defence for it either -- and unmatched events are exactly what the
-- review queue is made of.
-- ...on an UNMATCHED event, which has no membership, so `fk_event_group__event` is
-- not a second defence and the trigger is the only thing that can refuse. On a
-- matched event the FK answers first and the control names the wrong guard.
-- Unmatched events are exactly what the review queue is made of.
SELECT record_auth_event('t1','del_probe', NULL,'acme','card_del',
        'clearing', 50000,'USD',false, now());
SELECT must_fail('deleting a stored auth event as the table OWNER', $q$
    DELETE FROM card_auth_events WHERE processor_msg_id='del_probe';
$q$, 'card_auth_events is an event log and is immutable: DELETE');

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
    -- `held_minor > 0` predicate skips.
    --
    -- BE HONEST ABOUT WHAT THIS CATCHES. An earlier version of this comment said
    -- the comparison "has no such escape" from the held_minor -> total_minor
    -- mutation. It has exactly that escape, and for the reason stated one line
    -- above: under `held_minor > 0` the two columns are the SAME NUMBER --
    -- held_minor is GREATEST(total_minor,0) on a live group -- so no assertion
    -- comparing their sums can tell them apart. That mutation is EQUIVALENT, not
    -- uncaught. What this assertion does have teeth on is the second half: that
    -- the function is not quietly reducing what the column reports.
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
-- ...AND THE POSITIVE SIDE, WHICH IS THE SIDE THAT WAS THE BUG. The constraint is
-- `amount_delta = 0`, and -999999 above violates `= 0` and `>= 0` alike -- so
-- widening the constraint to `>= 0` left the whole suite green. The defect the
-- constraint's own comment names is the POSITIVE one: carrying +remaining made a
-- 100.00 authorization hold 200.00, and after the full 100.00 capture it still
-- held 100.00, with drift silent because the log genuinely contained the +10000.
-- Going through record_auth_event cannot test this: the function normalises an
-- expiry_reversal's delta to 0 whatever the wire says, and the constraint exists
-- because 0003 says the function gate is not enough -- "an operator backfill or a
-- second adapter produced the double release". So this INSERTs directly, which is
-- the path the constraint is for.
SELECT must_fail('an expiry_reversal that adds the remaining hold back', $q$
    INSERT INTO card_auth_events (tenant_id,processor_msg_id,company_id,card_id,kind,
                                  amount_delta,currency,occurred_at)
    VALUES ('t1','pos_exprev','acme','card_z','expiry_reversal', 10000,'USD', now());
$q$, 'ck_auth_events__sign');

-- The alarm must see a group whose events are not all in its declared currency --
-- the state re-grouping used to be able to create. It compared total_minor and
-- nothing else, so two currencies in one group reported no drift at all.
--
-- THIS CONTROL USED TO CATCH ON A DIFFERENT DISJUNCT THAN THE ONE IT NAMES. It
-- attached an `acme` event carrying 100 to `g_oc`, which is `globex`'s group (see
-- the ingest above) -- so the drift view's live CTE, which groups by the EVENT's
-- company, produced a ('t1','acme','g_oc') row with no materialised group at all,
-- and the alarm fired on stored-IS-NULL. Delete the currency disjunct and this
-- still passed. Two changes isolate it: the event joins a group of its OWN
-- company, and it carries delta 0 -- so the stored total, the stored authorized
-- total and the convention flags (which filter `amount_delta <> 0`) all still
-- agree with the log, and the currency EXISTS is the only disjunct left that can
-- speak.
SELECT record_auth_event('t1','cur_base','g_cur','acme','card_c',
        'authorization', 5000,'USD',false, now());
SELECT must_fail('a group holding two currencies', $q$
    INSERT INTO card_auth_events (tenant_id,processor_msg_id,company_id,card_id,kind,
                                  amount_delta,currency,occurred_at)
    VALUES ('t1','sneak_eur','acme','card_c','authorization', 0,'EUR', now());
    INSERT INTO card_auth_event_group (tenant_id,event_id,group_key,method,assigned_by)
    SELECT 't1', id, 'g_cur', 'manual', 'test'
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
-- ...to the amount that was live BEFORE the premature release, not that amount
-- doubled. expiry_reversal used to carry +remaining as a delta against a total the
-- flag had never reduced, so one 100.00 authorization held 200.00 and, after the
-- full 100.00 capture, still held 100.00 -- with drift silent, because the log
-- genuinely contained the +10000. This assertion asserted the 200.00.
SELECT eq('an expiry_reversal re-delivered with its group re-opens the hold',
          (SELECT record_auth_event('t1','ar_rev','g_ar','zeta','card_ar',
                   'expiry_reversal', 10000,'USD',false, now())), 10000);
SELECT eq('...and what ingest returned is what the company actually holds',
          held_for_company('t1','zeta','USD'), 10000);
SELECT no_drift('re-delivery onto an expired group');

-- ...and the same message on the FRESH-INGEST path. The two paths have separate
-- un-expire lists, so a test that only covers one leaves the other deletable --
-- which it was: dropping expiry_reversal from the main list changed nothing.
-- The hold comes back to what it was, 40.00, NOT 40.00 plus the message's wire
-- amount: expiry never subtracted anything, so its reversal adds nothing back.
SELECT record_auth_event('t1','fr_auth','g_fr','zeta','card_fr',
        'authorization', 4000,'USD',false, now());
SELECT expire_hold_group('t1','zeta','g_fr');
SELECT eq('expired', (SELECT held_minor FROM card_hold_groups WHERE group_key='g_fr'), 0);
SELECT record_auth_event('t1','fr_rev','g_fr','zeta','card_fr',
        'expiry_reversal', 1000,'USD',false, now());
SELECT eq('an expiry_reversal on first delivery re-opens the hold',
          (SELECT held_minor FROM card_hold_groups WHERE group_key='g_fr'), 4000);
SELECT eq('...and its wire amount is recorded without being added to the hold',
          (SELECT raw_amount FROM card_auth_events WHERE processor_msg_id='fr_rev'), 1000);
SELECT eq('...with a zero delta, because the flag is what it reverses',
          (SELECT amount_delta FROM card_auth_events WHERE processor_msg_id='fr_rev'), 0);

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
-- NOTE: this one catches on the CALLER-PARAMETER currency guard, which fires
-- first -- the stored-event guard it was once labelled for is covered by 'a stored
-- JPY event re-delivered as USD' below, whose expected string names the stored
-- row. Kept because refusing on either is correct; renamed so it is not read as
-- coverage it does not provide.
SELECT must_fail('re-delivery in a currency the group does not hold', $q$
    SELECT record_auth_event('t1','rd_eur', NULL,'acme','card_rd',
            'authorization', 5000,'EUR',false, now());
    SELECT record_auth_event('t1','rd_eur','g_late','acme','card_rd',
            'authorization', 5000,'EUR',false, now());
$q$, 'cannot join group');

-- ...and likewise: this catches the FRESH-INGEST mixing guard. The stored-event
-- convention guard is covered by 'a stored DELTA re-delivered as a total'.
SELECT must_fail('a delta message naming a totals group', $q$
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
--
-- ...and it must ISOLATE that branch. The first version of this control raised
-- authorized_minor, which ALSO makes the stored total disagree with the log --
-- so the alarm fired on the stored-vs-log branch and the post-expiry disjunct
-- could be deleted with this test still passing. Lower the SNAPSHOT instead: the
-- stored figures still match the log exactly, and only `authorized_minor >
-- expired_authorized` can speak.
SELECT must_fail('exposure above the authorized snapshot', $q$
    SELECT record_auth_event('t1','pe_auth','g_pe','acme','card_p',
            'authorization', 6000,'USD',false, now());
    SELECT expire_hold_group('t1','acme','g_pe');
    UPDATE card_hold_groups SET expired_authorized = expired_authorized - 100
     WHERE tenant_id='t1' AND group_key='g_pe';
    DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM card_hold_drift WHERE group_key='g_pe') THEN
            RAISE EXCEPTION 'POST-EXPIRY DRIFT detected';
        END IF;
    END $d$;
$q$, 'post-expiry drift');

-- ...and the other disjunct, which the control above cannot reach either
SELECT must_fail('exposure above the total snapshot', $q$
    SELECT record_auth_event('t1','pe_auth2','g_pe2','acme','card_p2',
            'authorization', 6000,'USD',false, now());
    SELECT expire_hold_group('t1','acme','g_pe2');
    UPDATE card_hold_groups SET expired_total = expired_total - 100
     WHERE tenant_id='t1' AND group_key='g_pe2';
    DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM card_hold_drift WHERE group_key='g_pe2') THEN
            RAISE EXCEPTION 'POST-EXPIRY DRIFT detected';
        END IF;
    END $d$;
$q$, 'post-expiry drift');

-- A SECOND SWEEP MUST NOT RE-SNAPSHOT. `expire_hold_group`'s `AND expired_at IS
-- NULL` guard protects TWO things, and the only control on it -- in
-- tests/concurrency.sh -- checks the release TIMESTAMP. The other thing it protects
-- is the snapshot the post-expiry alarm measures against, and a mutant that pinned
-- expired_at while re-snapshotting on every call passed the entire build. Expiry
-- sweeps run repeatedly by design, so this is one ordinary sweep with arguments it
-- already has:
--
--   auth 100.00 + reversal 80.00 -> total 2000; expire -> expired_total 2000
--   move the reversal OUT        -> total 10000, ABOVE the snapshot, so the
--                                   post-expiry alarm fires: 100.00 of live
--                                   exposure on a group reported as released
--   sweep again                  -> shipped keeps 2000 and the alarm keeps firing;
--                                   re-snapshotting to 10000 silences it, and the
--                                   100.00 is then invisible to everything.
--
-- Inside must_fail so the deliberate drift is rolled back: no_drift() is global,
-- and a fixture that leaves a group alarming disables every later drift check in
-- this file.
SELECT must_fail('a second expiry sweep re-snapshotting the group silent', $q$
    SELECT record_auth_event('t1','sw_a','g_sweep','acme','card_sw',
            'authorization', 10000,'USD',false, now());
    SELECT record_auth_event('t1','sw_b','g_sweep','acme','card_sw',
            'reversal', 8000,'USD',false, now());
    SELECT expire_hold_group('t1','acme','g_sweep');
    DO $d$ BEGIN
        IF (SELECT expired_total FROM card_hold_groups
             WHERE tenant_id='t1' AND group_key='g_sweep') <> 2000 THEN
            RAISE EXCEPTION 'the first sweep did not snapshot the group as it stands';
        END IF;
    END $d$;
    SELECT regroup_auth_event('t1',
        (SELECT id FROM card_auth_events WHERE tenant_id='t1' AND processor_msg_id='sw_b'),
        'g_sweep_out', 'operator:test');
    DO $d$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM card_hold_drift WHERE group_key='g_sweep') THEN
            RAISE EXCEPTION 'moving the reversal out did not raise the group above '
                            'its snapshot, so this control tests nothing';
        END IF;
    END $d$;
    SELECT expire_hold_group('t1','acme','g_sweep');
    DO $d$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM card_hold_drift WHERE group_key='g_sweep') THEN
            RAISE EXCEPTION 'A SECOND SWEEP SILENCED THE POST-EXPIRY ALARM';
        END IF;
        IF (SELECT expired_total FROM card_hold_groups
             WHERE tenant_id='t1' AND group_key='g_sweep') <> 2000 THEN
            RAISE EXCEPTION 'THE SECOND SWEEP MOVED THE SNAPSHOT';
        END IF;
        RAISE EXCEPTION 'SWEEP-KEPT-ITS-SNAPSHOT';
    END $d$;
$q$, 'sweep-kept-its-snapshot');

-- WHAT THE REPAIR RETURNS, on an expired group. Round 9 changed this RETURN from
-- `GREATEST(total_minor,0)` to `held_minor` -- and reverting that change verbatim
-- left the whole build green, because not one of this file's recompute_hold_group
-- calls compared the return value to anything. It is a public function returning a
-- bigint documented as a hold; the other three return sites and held_for_company
-- all say 0 here.
SELECT record_auth_event('t1','rr_a','g_rrexp','omega','card_rr',
        'authorization', 10000,'USD',false, now());
SELECT expire_hold_group('t1','omega','g_rrexp');
SELECT eq('the repair returns the CLAMPED hold, like the other three return sites',
          recompute_hold_group('t1','omega','g_rrexp'), 0);
SELECT eq('...and the group it repaired contributes nothing to the company total',
          (SELECT COALESCE(held_minor,0) FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='omega' AND group_key='g_rrexp'), 0);

-- Both snapshots must RATCHET DOWN when a recompute lowers the group. The only
-- way to lower an expired group's subtotal is to move an event out of it, which
-- goes through recompute_hold_group and nowhere else -- so with the ratchet
-- deleted the snapshots sit above the live figures and the branch above can never
-- fire again for that group.
SELECT record_auth_event('t1','rt_a','g_ratchet','acme','card_rt',
        'authorization', 5000,'USD',false, now());
SELECT record_auth_event('t1','rt_b','g_ratchet','acme','card_rt',
        'incremental', 2000,'USD',false, now());
SELECT expire_hold_group('t1','acme','g_ratchet');
SELECT regroup_auth_event('t1',
        (SELECT id FROM card_auth_events WHERE processor_msg_id='rt_b'),
        'g_ratchet_dest','operator');
SELECT eq('regrouping out of an expired group ratchets the authorized snapshot',
          (SELECT expired_authorized FROM card_hold_groups
            WHERE tenant_id='t1' AND group_key='g_ratchet'), 5000);
SELECT eq('...and the total snapshot',
          (SELECT expired_total FROM card_hold_groups
            WHERE tenant_id='t1' AND group_key='g_ratchet'), 5000);
SELECT no_drift('ratcheting an expired group down');

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
-- adapter, landing on an expired group and swallowed by the clamp. It re-opens the
-- group to the 1000.00 that was live before the premature release -- its own wire
-- amount adds nothing, because expiry never subtracted anything.
SELECT record_auth_event('t1','sv_ea','g_rev','zeta','card_s',
        'authorization', 100000,'USD',false, now());
SELECT expire_hold_group('t1','zeta','g_rev');
SELECT record_auth_event('t1','sv_er', NULL,'zeta','card_s',
        'expiry_reversal', 90000,'USD',false, now());
SELECT eq('a stored expiry_reversal re-opens even when re-delivered as a clearing',
          (SELECT record_auth_event('t1','sv_er','g_rev','zeta','card_s',
                   'clearing', 90000,'USD',false, now())), 100000);
-- zeta already holds from earlier blocks, so assert the GROUP, not the company
SELECT eq('...and the group holds what ingest returned',
          (SELECT held_minor FROM card_hold_groups WHERE group_key='g_rev'), 100000);
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

-- ================================ round 4: constraints nothing was defending
--
-- A mutation audit could delete each of these with the whole suite green. Most
-- are CHECKs -- the cheapest guards in the schema, and the easiest to leave
-- untested precisely because writing the bad value feels absurd. The currency one
-- is not absurd at all: `'usd'` and `'USD'` are two different hold groups, and the
-- held amount is the number an authorization decision is made on.

SELECT must_fail('a lowercase currency on an auth event', $q$
    INSERT INTO card_auth_events (tenant_id,processor_msg_id,company_id,card_id,kind,
                                  amount_delta,currency,occurred_at)
    VALUES ('t1','iso_lc','acme','card_i','authorization',100,'usd',now());
$q$, 'ck_auth_events__currency_iso');

SELECT must_fail('a NEGATIVE authorization stored directly', $q$
    INSERT INTO card_auth_events (tenant_id,processor_msg_id,company_id,card_id,kind,
                                  amount_delta,currency,occurred_at)
    VALUES ('t1','sign_neg','acme','card_i','authorization',-100,'USD',now());
$q$, 'ck_auth_events__sign');

SELECT must_fail('an auth event with no occurrence time', $q$
    INSERT INTO card_auth_events (tenant_id,processor_msg_id,company_id,card_id,kind,
                                  amount_delta,currency,occurred_at)
    VALUES ('t1','no_when','acme','card_i','authorization',100,'USD',NULL);
$q$, 'occurred_at');

SELECT must_fail('a lowercase currency on a hold group', $q$
    INSERT INTO card_hold_groups (tenant_id,company_id,group_key,currency)
    VALUES ('t1','acme','g_iso','eur');
$q$, 'ck_hold_groups__currency_iso');

SELECT must_fail('a third convention', $q$
    INSERT INTO card_hold_groups (tenant_id,company_id,group_key,currency,total_convention)
    VALUES ('t1','acme','g_conv','USD','absolute');
$q$, 'ck_hold_groups__total_convention');

SELECT must_fail('a grouping method nobody defined', $q$
    INSERT INTO card_auth_event_group (tenant_id,event_id,group_key,method,assigned_by)
    SELECT 't1', id, 'g_m', 'guess', 'x' FROM card_auth_events LIMIT 1;
$q$, 'ck_event_group__method');

SELECT must_fail('re-grouping an event that does not exist', $q$
    SELECT regroup_auth_event('t1','00000000-0000-0000-0000-0000000000aa'::uuid,
                              'g_any','operator');
$q$, 'no such auth event');

-- ------------------------------------------------------- what ingest RETURNS
-- An unmatched event has no group, so there is no exposure to report. Returning
-- the event's own delta instead passed every test: nothing asserted the value on
-- that path, and it is the number the adapter decides on.
SELECT eq('an unmatched event reports NO held amount',
          record_auth_event('t1','r4_unmatched', NULL,'acme','card_u',
                            'authorization', 30000,'USD',false, now()), 0);
-- ...and so does the RE-DELIVERY of one that is still unmatched. That is a
-- separate branch of the function -- the dedup returns before the group block --
-- and nothing exercised it, so it could report the event's own delta while the
-- adapter was deciding on it.
SELECT eq('...and so does re-delivering it while it is still unmatched',
          record_auth_event('t1','r4_unmatched', NULL,'acme','card_u',
                            'authorization', 30000,'USD',false, now()), 0);
SELECT eq('...and it is still exactly one event',
          (SELECT count(*) FROM card_auth_events
            WHERE tenant_id='t1' AND processor_msg_id='r4_unmatched'), 1);
SELECT eq('...and still in the unmatched queue',
          (SELECT count(*) FROM card_auth_unmatched
            WHERE tenant_id='t1' AND processor_msg_id='r4_unmatched'), 1);

-- `abs()` on the increase side silently normalises a negative wire amount into a
-- positive hold. That over-reserves rather than under-reserves, so it is not the
-- cardinal sin -- but it must be visible in the audit trail rather than inferred,
-- and dropping the abs() changes a 500.00 hold into a -500.00 one with no alarm.
DO $$
DECLARE v_held bigint; v_raw bigint; v_delta bigint;
BEGIN
    v_held := record_auth_event('t1','r4_negauth','g_neg','acme','card_n',
                                'authorization', -50000,'USD',false, now());
    SELECT raw_amount, amount_delta INTO v_raw, v_delta
      FROM card_auth_events WHERE processor_msg_id='r4_negauth';
    IF v_held <> 50000 OR v_delta <> 50000 THEN
        RAISE EXCEPTION 'a negative authorization was not normalised: held %, delta %',
            v_held, v_delta;
    END IF;
    IF v_raw <> -50000 THEN
        RAISE EXCEPTION 'the wire amount was not preserved: raw_amount = %', v_raw;
    END IF;
    RAISE NOTICE 'ok  a negative authorization holds % and records the wire % verbatim',
        v_held, v_raw;
END $$;

-- ------------------------------------------- the counters on the group row
-- Both could stop being maintained with the suite green. `last_event_seq` is
-- described as "the monotonic counter the alarm keys on" and nothing read it.
SELECT record_auth_event('t1','cnt_a','g_count','acme','card_c','authorization',1000,'USD',false,now());
SELECT record_auth_event('t1','cnt_b','g_count','acme','card_c','incremental',  500,'USD',false,now());
SELECT record_auth_event('t1','cnt_c','g_count','acme','card_c','clearing',     200,'USD',false,now());
SELECT eq('open_events counts the live memberships',
          (SELECT open_events FROM card_hold_groups WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_count'), 3);
SELECT eq('last_event_seq advances once per applied event',
          (SELECT last_event_seq FROM card_hold_groups WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_count'), 3);
SELECT recompute_hold_group('t1','acme','g_count');
SELECT eq('...and open_events survives a repair',
          (SELECT open_events FROM card_hold_groups WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_count'), 3);
-- ...AND IS RECOMPUTED, NOT MERELY PRESERVED. Both controls above are built so the
-- ingest counter already equals the live membership count, so a repair that stops
-- maintaining open_events passes them unchanged -- the assertion the block claims
-- to make ("zero open_events") is not the one it makes. Move the count away from
-- the counter first: supersede one membership directly, which is the operator
-- workflow 0003 prescribes, and then require the repair to bring it back.
UPDATE card_auth_event_group SET superseded_at = now()
 WHERE tenant_id='t1' AND group_key='g_count' AND superseded_at IS NULL
   AND event_id = (SELECT id FROM card_auth_events
                    WHERE tenant_id='t1' AND processor_msg_id='cnt_c');
SELECT eq('superseding a membership leaves the stale counter behind',
          (SELECT open_events FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_count'), 3);
SELECT recompute_hold_group('t1','acme','g_count');
SELECT eq('...and the repair brings it back to the live membership count',
          (SELECT open_events FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_count'), 2);
SELECT no_drift('a repair after a membership was superseded');

-- advice is increase-SIDE, and the repair must agree with ingest about that or
-- the two disagree about authorized_minor -- the base every cumulative
-- conversion is computed against and the sole input to the out-of-order refusal.
SELECT record_auth_event('t1','adv_a','g_adv','acme','card_a','authorization',4000,'USD',false,now());
SELECT record_auth_event('t1','adv_b','g_adv','acme','card_a','advice',       1000,'USD',false,now());
SELECT recompute_hold_group('t1','acme','g_adv');
SELECT eq('the repair counts a positive advice toward the authorized subtotal',
          (SELECT authorized_minor FROM card_hold_groups WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_adv'), 5000);

-- overcaptured_at is the durable evidence that a clearing exceeded its
-- authorization. The repair could stop maintaining it entirely.
SELECT record_auth_event('t1','r4oc_a','g_r4oc','acme','card_o','authorization',1000,'USD',false,now());
SELECT record_auth_event('t1','r4oc_b','g_r4oc','acme','card_o','clearing',     3000,'USD',false,now());
-- Clear it first. Ingest already set the flag on the way in, so a repair that
-- merely LEAVES IT ALONE passed -- the assertion was reading ingest's work.
UPDATE card_hold_groups SET overcaptured_at = NULL
 WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_r4oc';
SELECT recompute_hold_group('t1','acme','g_r4oc');
DO $$ BEGIN
    IF (SELECT overcaptured_at FROM card_hold_groups
         WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_r4oc') IS NULL THEN
        RAISE EXCEPTION 'an over-capture left no durable evidence after a repair';
    END IF;
    RAISE NOTICE 'ok  the repair records over-capture evidence';
END $$;

-- ------------------------------------------------------- the alarm's own joins
-- The drift view's currency clause is qualified by company_id, and the repair's
-- materialising INSERT is too. Without those, two companies sharing an inferred
-- group_key -- which is a real state, because group_key comes from network values
-- that are not per-company -- read each other's events.
SELECT record_auth_event('t1','sh_a','g_shared_ccy','acme',  'card_s1','authorization',1000,'USD',false,now());
SELECT record_auth_event('t1','sh_b','g_shared_ccy','globex','card_s2','authorization',2000,'EUR',false,now());
SELECT no_drift('two companies on one inferred group key, in different currencies');
SELECT eq('...and the USD company holds only the USD number',
          (SELECT held_minor FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_shared_ccy'), 1000);
SELECT eq('...and the EUR company only the EUR one',
          (SELECT held_minor FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='globex' AND group_key='g_shared_ccy'), 2000);

-- The repair's MATERIALISING insert is company-scoped too, and losing that filter
-- is invisible to every other control: it picks a currency from whichever event
-- the LIMIT 1 happens to reach, which may belong to the other company sharing the
-- key. Currency is not repairable afterwards -- it is fixed on the group row -- so
-- every subsequent genuine message for that company is refused forever.
-- globex FIRST, deliberately: an unfiltered `LIMIT 1` takes whichever row it
-- reaches first, so with acme's own event inserted first the mutant picks the
-- right currency by luck and the control proves nothing.
SELECT record_auth_event('t1','z08_b','g_z08','globex','card_z2','authorization',2200,'EUR',false,now());
SELECT record_auth_event('t1','z08_a','g_z08','acme',  'card_z1','authorization',1100,'USD',false,now());
SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED;
ALTER TABLE card_hold_groups DISABLE TRIGGER ck_hold_groups__no_delete;
DELETE FROM card_hold_groups WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_z08';
ALTER TABLE card_hold_groups ENABLE ALWAYS TRIGGER ck_hold_groups__no_delete;
SELECT recompute_hold_group('t1','acme','g_z08');
SELECT eq('the repair rebuilds the group in ITS OWN company''s currency',
          (SELECT CASE currency WHEN 'USD' THEN 1 ELSE 0 END FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_z08'), 1);
SELECT eq('...and with its own company''s total',
          (SELECT total_minor FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_z08'), 1100);
SELECT no_drift('repairing one company''s half of a shared group key');

-- FULL OUTER, both halves. The membership-without-a-group half is controlled
-- above; the OTHER half -- a materialised group whose members have ALL been moved
-- away, still holding a stale total -- would vanish under a RIGHT JOIN.
SELECT record_auth_event('t1','stale_a','g_stale','acme','card_st','authorization',7000,'USD',false,now());
SELECT must_fail('a group whose members have all moved away', $q$
    UPDATE card_auth_event_group SET superseded_at = now()
     WHERE tenant_id='t1' AND group_key='g_stale' AND superseded_at IS NULL;
    DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM card_hold_drift WHERE group_key='g_stale') THEN
            RAISE EXCEPTION 'STALE GROUP DETECTED';
        END IF;
    END $d$;
$q$, 'stale group detected');


-- ============================== round 5: what a ZERO-amount message may decide
--
-- A $0.00 authorization is a real message -- account verification, AVS,
-- card-on-file -- and it says NOTHING about whether the processor reports
-- increases as deltas or as cumulative totals. Letting one fix the convention
-- locked a group to 'delta', after which the processor's own opening cumulative
-- total and its incremental were BOTH refused forever: 200.00 live, 0.00 held,
-- drift 0 rows, and nothing in the review queue either, because a refused message
-- is never stored. The same two messages in the other order held 150.00.
--
-- This was already fixed for `advice` on reasoning that applies identically to
-- all three increase-side kinds. It was not applied to the other two.
SELECT eq('a $0.00 authorization holds nothing',
          record_auth_event('t1','z_avs','g_zero','acme','card_z','authorization',
                            0,'USD',false, now()), 0);
DO $$ BEGIN
    IF (SELECT total_convention FROM card_hold_groups
         WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_zero') IS NOT NULL THEN
        RAISE EXCEPTION 'a $0.00 authorization fixed the group''s convention';
    END IF;
    RAISE NOTICE 'ok  ...and does not decide the convention';
END $$;
SELECT eq('...so the processor''s own cumulative total is still accepted',
          record_auth_event('t1','z_tot','g_zero','acme','card_z','authorization',
                            10000,'USD',true, now()), 10000);
SELECT eq('...and its incremental total after it',
          record_auth_event('t1','z_inc','g_zero','acme','card_z','incremental',
                            15000,'USD',true, now()), 15000);

-- ...AND THE REPAIR PATH DERIVES THE CONVENTION TOO, from its own copy of the same
-- filter. The drift view's copy is controlled above; recompute_hold_group's was
-- not, so dropping `amount_delta <> 0` there passed the whole build -- and any
-- routine repair after a $0.00 AVS authorization then locks the group to 'delta',
-- after which every real cumulative total from that processor is refused FOREVER.
-- Refused messages are never stored, so they never reach the review queue either.
-- The group must carry ONLY the zero-amount message when the repair runs: with a
-- real message of either convention already in it the derivation has something
-- else to read and the filter is not the thing under test.
SELECT eq('a $0.00 AVS authorization on a group of its own holds nothing',
          record_auth_event('t1','zc_a','g_zconv','acme','card_zc','authorization',
                            0,'USD',false, now()), 0);
SELECT eq('a repair does not let a $0.00 message decide the convention',
          recompute_hold_group('t1','acme','g_zconv'), 0);
DO $$ BEGIN
    IF (SELECT total_convention FROM card_hold_groups
         WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_zconv') IS NOT NULL THEN
        RAISE EXCEPTION 'the repair fixed the convention from a zero-amount message: %',
            (SELECT total_convention FROM card_hold_groups
              WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_zconv');
    END IF;
    RAISE NOTICE 'ok  ...and the group is still convention-neutral after the repair';
END $$;
SELECT eq('...so the processor''s real cumulative total is still accepted after a repair',
          record_auth_event('t1','zc_b','g_zconv','acme','card_zc','authorization',
                            7000,'USD',true, now()), 7000);
SELECT no_drift('a repair on a group carrying only a zero-amount message');

-- ...and the mirror image: a $0.00 CUMULATIVE TOTAL must not lock a group to
-- 'total' and refuse every real delta after it.
SELECT eq('a $0.00 cumulative total holds nothing',
          record_auth_event('t1','z_ztot','g_zero2','acme','card_z2','authorization',
                            0,'USD',true, now()), 0);
SELECT eq('...and the processor''s real delta is still accepted',
          record_auth_event('t1','z_delta','g_zero2','acme','card_z2','authorization',
                            5000,'USD',false, now()), 5000);

-- ...and a GENUINE mix is still refused, or the fix above is just a hole
SELECT must_fail('a real convention mix, after the zero-amount fix', $q$
    SELECT record_auth_event('t1','z_m1','g_zmix','acme','card_z3','authorization',
                             5000,'USD',false, now());
    SELECT record_auth_event('t1','z_m2','g_zmix','acme','card_z3','incremental',
                             9000,'USD',true, now());
$q$, 'cannot mix the two');

-- ...and a repair must not put back what ingest declined to decide
SELECT recompute_hold_group('t1','acme','g_zero2');
SELECT eq('a repair derives the convention from real messages only',
          (SELECT CASE total_convention WHEN 'delta' THEN 1 ELSE 0 END
             FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_zero2'), 1);
SELECT no_drift('zero-amount messages');

-- ================================ round 5: guards that survived mutation
--
-- Each of these could be deleted with the whole suite green.

-- A cumulative total cannot be re-grouped: its stored delta is relative to the
-- SOURCE group's base, so re-summing it against another base is arithmetic on two
-- unrelated numbers. Deleting the refusal reproduced ADR-0010's own scenario --
-- 100.00 under-reserved, drift 0 rows -- and no test noticed.
SELECT record_auth_event('t1','r5t_a','g_r5t','acme','card_r5','authorization',10000,'USD',true,now());
SELECT record_auth_event('t1','r5t_b','g_r5t','acme','card_r5','authorization',25000,'USD',true,now());
SELECT must_fail('re-grouping a cumulative-total event', $q$
    SELECT regroup_auth_event('t1',
        (SELECT id FROM card_auth_events WHERE tenant_id='t1' AND processor_msg_id='r5t_b'),
        'g_r5t_dest','operator');
$q$, 'delivered as a cumulative total');

-- A re-delivery naming a DIFFERENT group than the one the event was corrected
-- into is the processor and the operator disagreeing about where the message
-- belongs. Swallowing it silently is what regroup_auth_event exists to prevent.
SELECT record_auth_event('t1','r5g_a','g_r5g','acme','card_r5g','authorization',6000,'USD',false,now());
SELECT must_fail('re-delivering an already-grouped event under another key', $q$
    SELECT record_auth_event('t1','r5g_a','g_r5g_other','acme','card_r5g',
                             'authorization',6000,'USD',false,now());
$q$, 'already grouped as');

-- low_water_minor is the DURABLE evidence of over-capture, and the repair is the
-- only writer of it for an over-capture produced by re-grouping. Its ratchet in
-- recompute_hold_group was asserted nowhere: the ingest path had already set the
-- mark in every existing control.
SELECT record_auth_event('t1','r5w_a','g_r5w','acme','card_r5w','authorization',1000,'USD',false,now());
SELECT record_auth_event('t1','r5w_b','g_r5w_other','acme','card_r5w','clearing',4000,'USD',false,now());
UPDATE card_hold_groups SET low_water_minor = 0
 WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_r5w';
SELECT regroup_auth_event('t1',
        (SELECT id FROM card_auth_events WHERE tenant_id='t1' AND processor_msg_id='r5w_b'),
        'g_r5w','operator');
SELECT eq('re-grouping a clearing in records the low-water mark it creates',
          (SELECT low_water_minor FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='acme' AND group_key='g_r5w'), -3000);
SELECT no_drift('re-grouping into an over-capture');

-- ================= round 5: the alarm branches that were assertions of absence
--
-- card_hold_drift's convention branch and card_auth_unmatched's superseded filter
-- were each covered only by `no_drift(...)` or a count that happened to be right.
-- Both could be deleted with the whole suite green, and both are the layer that
-- exists to catch what the ingest guards structurally cannot.

-- THE IRRECONCILABLE STATE, as a POSITIVE control. A group holding one
-- raw_is_total=false and one raw_is_total=true increase is what 0003's header
-- calls irreconcilable. Ingest refuses to create it and every recompute re-derives
-- the convention, so it is not reachable through the API -- which is exactly why
-- the alarm for it went untested and could be deleted. Build it underneath the
-- guards, the way a bad backfill or a second adapter would.
SELECT record_auth_event('t1','mx_a','g_mixed','acme','card_mx','authorization',5000,'USD',false,now());
SELECT must_fail('a group holding both conventions at once', $q$
    INSERT INTO card_auth_events (tenant_id,processor_msg_id,company_id,card_id,kind,
                                  amount_delta,raw_amount,raw_is_total,currency,occurred_at)
    VALUES ('t1','mx_b','acme','card_mx','incremental',3000,3000,true,'USD',now());
    INSERT INTO card_auth_event_group (tenant_id,event_id,group_key,method,assigned_by)
    SELECT 't1', id, 'g_mixed', 'manual', 'backfill'
      FROM card_auth_events WHERE tenant_id='t1' AND processor_msg_id='mx_b';
    -- RECOMPUTE FIRST, or this control catches on the wrong branch. Attaching a
    -- membership by hand leaves the stored total disagreeing with the log, so the
    -- stored-vs-log branch fires and the convention branch could be deleted with
    -- this test still green -- which is exactly what happened the first time.
    SELECT recompute_hold_group('t1','acme','g_mixed');
    DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM card_hold_drift WHERE group_key='g_mixed') THEN
            RAISE EXCEPTION 'MIXED CONVENTION DETECTED';
        END IF;
    END $d$;
$q$, 'mixed convention detected');

-- THE REVIEW QUEUE MUST KEEP WHAT THE OPERATOR PUTS BACK INTO IT. Superseding a
-- membership is the workflow 0003 itself prescribes for a cumulative-total event
-- ("supersede it and re-ingest the wire amount against the correct group"). Drop
-- `superseded_at IS NULL` from card_auth_unmatched and the event silently leaves
-- the queue that exists so nothing is ever a silent guess.
SELECT record_auth_event('t1','sq_a','g_squeue','acme','card_sq','authorization',2500,'USD',false,now());
SELECT eq('an event with a live membership is not in the review queue',
          (SELECT count(*) FROM card_auth_unmatched
            WHERE tenant_id='t1' AND processor_msg_id='sq_a'), 0);
UPDATE card_auth_event_group SET superseded_at = now()
 WHERE tenant_id='t1' AND group_key='g_squeue' AND superseded_at IS NULL;
SELECT eq('...and superseding its only membership puts it BACK in the queue',
          (SELECT count(*) FROM card_auth_unmatched
            WHERE tenant_id='t1' AND processor_msg_id='sq_a'), 1);
-- ...AND THEN PUT THE LEDGER BACK, because no_drift() is GLOBAL. It takes a label
-- and the label is decoration: the body is `EXISTS (SELECT 1 FROM card_hold_drift)`
-- with no scope at all. The supersede above left g_squeue materialised at 2500
-- with no live membership, i.e. permanent drift -- so from this line to the end of
-- the file any no_drift() would have fired on a fixture three hundred lines away,
-- which is why there is not one, which means the last ~60 assertions in this file
-- ran with no drift check at all. Reconciling through the shipped repair path is
-- both the fix and a control on that path: recompute must bring a group whose
-- memberships were all superseded back to zero.
SELECT eq('the repair reconciles a group whose only membership was superseded',
          recompute_hold_group('t1','acme','g_squeue'), 0);
SELECT no_drift('after superseding the review queue fixture''s membership');

-- ix_hold_groups__held is a PARTIAL index, and the plan assertion pins its NAME.
-- Dropping its predicate leaves the name intact and the index covering every group
-- the company ever had, expired ones included -- the read the whole materialised
-- total exists to make fast.
DO $$
DECLARE v_pred text;
BEGIN
    SELECT pg_get_expr(i.indpred, i.indrelid) INTO v_pred
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
     WHERE c.relname = 'ix_hold_groups__held';
    IF v_pred IS NULL OR position('held_minor' in v_pred) = 0 THEN
        RAISE EXCEPTION 'ix_hold_groups__held is no longer partial on held_minor (%)', v_pred;
    END IF;
    RAISE NOTICE 'ok  the hold index is still partial: %', v_pred;
END $$;

-- raw_is_total defaults to false, and an INSERT that omits it must not silently
-- become a cumulative total -- that flips the meaning of every amount it carries.
DO $$
DECLARE v_is_total boolean;
BEGIN
    INSERT INTO card_auth_events (tenant_id,processor_msg_id,company_id,card_id,kind,
                                  amount_delta,currency,occurred_at)
    VALUES ('t1','dflt','acme','card_d','authorization',100,'USD',now());
    SELECT raw_is_total INTO v_is_total FROM card_auth_events
     WHERE tenant_id='t1' AND processor_msg_id='dflt';
    IF v_is_total THEN
        RAISE EXCEPTION 'an event that did not say so was stored as a cumulative total';
    END IF;
    RAISE NOTICE 'ok  an amount is a DELTA unless the message says otherwise';
END $$;

-- A DECREASE-SIDE MESSAGE OF AN INCREASE-SIDE KIND MUST NOT RE-OPEN A RELEASE.
-- Every existing un-expire control uses a positive delta or a cumulative
-- restatement, so `AND (v_delta > 0 OR p_is_total)` could be dropped and a
-- NEGATIVE advice would resurrect a released hold -- which also nulls
-- expired_authorized and expired_total, permanently disarming the post-expiry
-- drift branch for that group.
SELECT record_auth_event('t1','r6_ue_a','g_unexp','omega','card_ue','authorization',9000,'USD',false,now());
SELECT expire_hold_group('t1','omega','g_unexp');
SELECT eq('released', (SELECT held_minor FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='omega' AND group_key='g_unexp'), 0);
SELECT eq('a NEGATIVE advice does not resurrect a released hold',
          record_auth_event('t1','r6_ue_b','g_unexp','omega','card_ue','advice',-500,'USD',false,now()), 0);
SELECT eq('...and the group is still expired',
          (SELECT CASE WHEN expired_at IS NULL THEN 1 ELSE 0 END FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='omega' AND group_key='g_unexp'), 0);
SELECT eq('...so the post-expiry snapshots survive',
          (SELECT CASE WHEN expired_authorized IS NULL THEN 1 ELSE 0 END FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='omega' AND group_key='g_unexp'), 0);

-- gap: card_auth_event_group's FOREIGN KEY had a control for its `method` CHECK
-- and none for the FK itself. Without it a membership row can name an event that
-- does not exist; every derivation INNER JOINs events, so the orphan is invisible
-- to card_hold_drift AND to the unmatched queue. It is also the source of the
-- implicit FOR KEY SHARE that the attach path's lock ordering depends on.
SELECT must_fail('a membership row naming an event that does not exist', $q$
    INSERT INTO card_auth_event_group (tenant_id,event_id,group_key,method,assigned_by)
    VALUES ('t1','00000000-0000-7000-8000-0000000000ee','g_orphan','manual','backfill');
$q$, 'fk_event_group__event');

-- ============ round 6: a decrease that moved no money, and a NULL that meant zero

-- AN OVER-REVERSAL IS NOT AN OVER-CAPTURE. ADR-0010 declines the over-capture
-- report on the argument that a clearing has already POSTED to the ledger, so the
-- cleared money is a receivable and exposure is posted + held. That argument is
-- sound and it covers `clearing` and nothing else: `reversal` and negative
-- `advice` post nothing at all. Two reversals against one authorization left the
-- total at -10000 with ZERO clearings in the log, and the next genuine incremental
-- was absorbed by the residue -- 100.00 live, 0.00 held, 0.00 posted, drift
-- silent, and the non-latching over-capture flag erased by the very message that
-- hid the money.
SELECT record_auth_event('t1','r6_ov_a','g_overrev','omega','card_ov','authorization',10000,'USD',false,now());
SELECT record_auth_event('t1','r6_ov_b','g_overrev','omega','card_ov','reversal',10000,'USD',false,now());
-- ...IN THE REGION ONLY THE SECOND DISJUNCT COVERS. The control below is
-- authorization + two reversals, where bloodless (20000) exceeds increases
-- (10000) -- so BOTH disjuncts fire and either could be deleted with the suite
-- green. The one that matters is the second: a group under water where a CLEARING
-- accounts for part of the dip, which is the state 0003 records as
-- "300.00 under-reserved, drift 0 rows at every step" and the reason that line
-- was added. Here bloodless (10000) does NOT exceed increases (10000); only
-- `total_minor < 0 AND bloodless > 0` can speak.
SELECT record_auth_event('t1','d2_a','g_d2','omega','card_d2','authorization',10000,'USD',false,now());
SELECT record_auth_event('t1','d2_b','g_d2','omega','card_d2','clearing',10000,'USD',false,now());
SELECT must_fail('an over-reversal on a group that has also cleared', $q$
    SELECT record_auth_event('t1','d2_c','g_d2','omega','card_d2','reversal',10000,'USD',false,now());
    DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM card_hold_drift WHERE group_key='g_d2') THEN
            RAISE EXCEPTION 'UNDER-WATER GROUP DETECTED';
        END IF;
    END $d$;
$q$, 'under-water group detected');
-- ...and an out-of-order clearing that lands before its authorization must NOT
-- fire it: that dip is order tolerance, not an over-reversal.
SELECT record_auth_event('t1','d2_x','g_d2ok','omega','card_d2b','clearing',4000,'USD',false,now());
SELECT record_auth_event('t1','d2_y','g_d2ok','omega','card_d2b','authorization',9000,'USD',false,now());
SELECT eq('an out-of-order clearing does not look like an over-reversal',
          (SELECT count(*) FROM card_hold_drift WHERE group_key='g_d2ok'), 0);
-- ...AND THE BOUNDARY ITSELF, which neither control above touches. Both sit well
-- away from zero, so `total_minor < 0` could be widened to `<= 0` with the suite
-- green -- and then every fully-reversed authorization, the most ordinary shape
-- there is, becomes a permanent alarm. Exactly zero, with a bloodless decrease
-- present, must be silent.
SELECT record_auth_event('t1','d2_z1','g_d2zero','omega','card_d2c','authorization',7000,'USD',false,now());
SELECT record_auth_event('t1','d2_z2','g_d2zero','omega','card_d2c','reversal',7000,'USD',false,now());
SELECT eq('a FULLY reversed authorization sits at exactly zero and does not alarm',
          (SELECT count(*) FROM card_hold_drift WHERE group_key='g_d2zero'), 0);
SELECT eq('...and it really is at zero with a bloodless decrease behind it',
          (SELECT total_minor FROM card_hold_groups
            WHERE tenant_id='t1' AND group_key='g_d2zero'), 0);

SELECT must_fail('reversing more than was ever authorized', $q$
    SELECT record_auth_event('t1','r6_ov_c','g_overrev','omega','card_ov','reversal',10000,'USD',false,now());
    DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM card_hold_drift WHERE group_key='g_overrev') THEN
            RAISE EXCEPTION 'OVER-REVERSED GROUP DETECTED';
        END IF;
    END $d$;
$q$, 'over-reversed group detected');
-- ...and a genuine over-CAPTURE, which the ledger does account for, is not flagged
SELECT record_auth_event('t1','r6_oc2_a','g_realoc','omega','card_oc','authorization',100,'USD',false,now());
SELECT record_auth_event('t1','r6_oc2_b','g_realoc','omega','card_oc','clearing',9500,'USD',false,now());
-- scoped: earlier fixtures in this file leave deliberate drift elsewhere
SELECT eq('no drift on g_realoc -- a real over-capture, whose money posted to the ledger',
          (SELECT count(*) FROM card_hold_drift WHERE group_key='g_realoc'), 0);

-- EXPIRY IS A FLAG, SO ITS REVERSAL ADDS NOTHING BACK. Carrying +remaining as a
-- delta against a total the flag never reduced made one 100.00 authorization hold
-- 200.00, and after the full 100.00 capture it still held 100.00 -- with drift
-- silent, because the log genuinely contained the +10000 and the alarm can only
-- compare the total against the log.
SELECT record_auth_event('t1','r6_xr_a','g_xrev','omega','card_xr','authorization',10000,'USD',false,now());
SELECT expire_hold_group('t1','omega','g_xrev');
SELECT eq('an expiry_reversal restores the hold that was live, not that plus its own amount',
          record_auth_event('t1','r6_xr_b','g_xrev','omega','card_xr','expiry_reversal',10000,'USD',false,now()),
          10000);
SELECT eq('...so the full capture closes it out at zero',
          record_auth_event('t1','r6_xr_c','g_xrev','omega','card_xr','clearing',10000,'USD',false,now()), 0);
-- scoped: earlier fixtures in this file leave deliberate drift elsewhere
SELECT eq('no drift on g_xrev -- expiry reversal',
          (SELECT count(*) FROM card_hold_drift WHERE group_key='g_xrev'), 0);

-- WHAT INGEST RETURNS IS THE NUMBER THE DECISION IS MADE ON, so it must be the
-- clamped hold and never the raw total. It returned -9400 on an over-capture while
-- held_for_company reported 0: 94.00 of phantom credit for an adapter computing
-- `available = limit - returned`. The file calls this its strongest single
-- assertion and was exercising it on one branch only.
SELECT record_auth_event('t1','r6_rt_a','g_rettot','omega','card_rt','authorization',100,'USD',false,now());
SELECT eq('ingest never returns a negative hold',
          record_auth_event('t1','r6_rt_b','g_rettot','omega','card_rt','clearing',9500,'USD',false,now()), 0);
SELECT eq('...and it agrees with what that group actually holds',
          (SELECT held_minor FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='omega' AND group_key='g_rettot'), 0);

-- A NULL CURRENCY IS THE DEFAULTED CURRENCY THIS FUNCTION REFUSES TO HAVE, and it
-- returned the most dangerous possible answer: `currency = NULL` matches no row,
-- so live exposure came back as 0.
SELECT must_fail('asking what is held, without saying in what currency', $q$
    DO $d$ BEGIN PERFORM held_for_company('t1','omega',NULL); END $d$;
$q$, 'requires tenant, company and currency');

-- ADVICE IS BIDIRECTIONAL, which is the sole stated reason it is exempt from
-- ck_auth_events__sign -- and nothing passed a negative amount anywhere, so
-- `p_amount` could be replaced by `abs(p_amount)` with the suite green, turning a
-- 50.00 decline advice into a 50.00 INCREASE.
SELECT record_auth_event('t1','r6_ab_a','g_advneg','omega','card_ab','authorization',10000,'USD',false,now());
SELECT eq('a NEGATIVE advice reduces the hold',
          record_auth_event('t1','r6_ab_b','g_advneg','omega','card_ab','advice',-4000,'USD',false,now()), 6000);
SELECT eq('...and is stored with its sign intact',
          (SELECT amount_delta FROM card_auth_events WHERE processor_msg_id='r6_ab_b'), -4000);
SELECT eq('...without moving the authorized subtotal',
          (SELECT authorized_minor FROM card_hold_groups
            WHERE tenant_id='t1' AND company_id='omega' AND group_key='g_advneg'), 10000);
-- scoped: earlier fixtures in this file leave deliberate drift elsewhere
SELECT eq('no drift on g_advneg -- a negative advice',
          (SELECT count(*) FROM card_hold_drift WHERE group_key='g_advneg'), 0);

-- A NEGATIVE ADVICE MUST NOT FIX THE CONVENTION. `v_increases` exempts advice
-- unless its amount is positive, and the file's own comment says why: "an advice
-- of zero or negative amount says nothing about which convention the processor
-- uses". The zero case is controlled; the NEGATIVE case was not, so making advice
-- always count as an increase left the suite green -- and then a legitimate
-- cumulative-total authorization is REFUSED OUTRIGHT, holding 0 against 95.00
-- live.
SELECT record_auth_event('t1','r7_na','g_r7adv','omega','card_na','advice',-2000,'USD',false,now());
DO $$ BEGIN
    IF (SELECT total_convention FROM card_hold_groups
         WHERE tenant_id='t1' AND company_id='omega' AND group_key='g_r7adv') IS NOT NULL THEN
        RAISE EXCEPTION 'a NEGATIVE advice fixed the group''s convention';
    END IF;
    RAISE NOTICE 'ok  a negative advice does not decide the convention either';
END $$;
SELECT eq('...so the processor''s own cumulative total is still accepted',
          record_auth_event('t1','r7_nb','g_r7adv','omega','card_na',
                            'authorization', 9500,'USD',true, now()), 7500);

-- overcaptured_at's VALUE, not merely its nullness. Every existing control tests
-- IS NULL / IS NOT NULL, so dropping the COALESCE that preserves the FIRST
-- over-capture instant -- losing "since when" -- was invisible.
SELECT record_auth_event('t1','r7_oa','g_r7oc2','omega','card_oc2','authorization',100,'USD',false,now());
SELECT record_auth_event('t1','r7_ob','g_r7oc2','omega','card_oc2','clearing',9500,'USD',false,now());
DO $$
DECLARE v_first timestamptz; v_second timestamptz;
BEGIN
    SELECT overcaptured_at INTO v_first FROM card_hold_groups
     WHERE tenant_id='t1' AND company_id='omega' AND group_key='g_r7oc2';
    UPDATE card_hold_groups SET overcaptured_at = v_first - interval '1 hour'
     WHERE tenant_id='t1' AND company_id='omega' AND group_key='g_r7oc2';
    PERFORM record_auth_event('t1','r7_oc','g_r7oc2','omega','card_oc2','clearing',100,'USD',false,now());
    SELECT overcaptured_at INTO v_second FROM card_hold_groups
     WHERE tenant_id='t1' AND company_id='omega' AND group_key='g_r7oc2';
    IF v_second IS DISTINCT FROM v_first - interval '1 hour' THEN
        RAISE EXCEPTION 'the over-capture instant moved: % -> % (it records SINCE WHEN)',
            v_first - interval '1 hour', v_second;
    END IF;
    RAISE NOTICE 'ok  over-capture records the FIRST instant, not the latest';
END $$;

-- ================= round 7: three RETURN sites, and a read that took anything

-- WHAT INGEST RETURNS, ON ALL THREE PATHS. The fix for this reached one of the
-- three RETURN sites -- and its own comment said so, in the words "was only
-- exercising it on one branch" -- while the two re-delivery paths kept handing
-- back the raw total. A routine re-delivery of a cleared message returned -9400
-- while held_for_company reported 0: 94.00 of phantom credit for an adapter
-- computing `available = limit - returned`. Processor re-delivery is not an edge
-- case; the whole dedup design exists because it is routine.
SELECT record_auth_event('t1','r7_ra','g_r7ret','omega','card_r7','authorization',100,'USD',false,now());
SELECT eq('fresh ingest of an over-capture returns the clamped hold',
          record_auth_event('t1','r7_rb','g_r7ret','omega','card_r7','clearing',9500,'USD',false,now()), 0);
SELECT eq('...and RE-DELIVERING that same message returns it too',
          record_auth_event('t1','r7_rb','g_r7ret','omega','card_r7','clearing',9500,'USD',false,now()), 0);
-- ...and the third path: an unmatched message later attached to a group
SELECT record_auth_event('t1','r7_rc','g_r7att','omega','card_r7','authorization',100,'USD',false,now());
SELECT record_auth_event('t1','r7_rd', NULL,'omega','card_r7','clearing',9500,'USD',false,now());
SELECT eq('...and so does the attach path',
          record_auth_event('t1','r7_rd','g_r7att','omega','card_r7','clearing',9500,'USD',false,now()), 0);
-- ...and against a number computed a DIFFERENT way. Comparing held_for_company
-- against a hand-typed copy of its own body -- same predicate, same cast -- was a
-- restatement, not a check. Sum the LOG instead, over live memberships, which is
-- the thing the materialisation is supposed to equal.
-- ...AND THE REPLACEMENT WAS THE SAME RESTATEMENT. It read `card_hold_groups`,
-- the materialised table -- the very thing held_for_company reads -- with a
-- hand-retyped copy of the `held_minor` expression. Tampering the materialisation
-- to disagree with the log by 977,999 minor units left both sides reading 999999
-- and the assertion green. `total_minor` below now comes from SUM(amount_delta)
-- over live memberships. Currency and expiry still come from the group row
-- because neither is in the log -- that is a real limit of this check and it is
-- stated rather than hidden, which is the whole complaint about the two versions
-- before it.
SELECT eq('...all three agreeing with what the log says the company holds',
          held_for_company('t1','omega','USD'),
          (SELECT COALESCE(SUM(GREATEST(l.recomputed,0)),0)::bigint
             FROM card_hold_groups g
             JOIN (SELECT m.tenant_id, e.company_id, m.group_key,
                          SUM(e.amount_delta) AS recomputed
                     FROM card_auth_event_group m
                     JOIN card_auth_events e
                       ON e.tenant_id = m.tenant_id AND e.id = m.event_id
                    WHERE m.superseded_at IS NULL
                    GROUP BY m.tenant_id, e.company_id, m.group_key) l
               ON l.tenant_id  = g.tenant_id
              AND l.company_id = g.company_id
              AND l.group_key  = g.group_key
            WHERE g.tenant_id='t1' AND g.company_id='omega' AND g.currency='USD'
              AND g.expired_at IS NULL));

-- A NON-CANONICAL CURRENCY ON THE READ PATH. 'usd' is refused when a group is
-- written and was accepted here, matching no row and answering 0 -- the identical
-- failure the NULL guard beside it calls "the most dangerous possible answer",
-- and this file records that lowercase 'usd' already caused it once in the other
-- direction.
SELECT must_fail('asking what is held in a currency that is not an ISO code', $q$
    DO $d$ BEGIN PERFORM held_for_company('t1','omega','usd'); END $d$;
$q$, 'not an ISO code');

-- THE APP ROLE MUST BE ABLE TO INGEST. It could not: SELECT-only grants on the
-- three card tables and no SECURITY DEFINER meant record_auth_event failed with
-- `permission denied for table card_hold_groups` from inside the function. Every
-- other privilege control in this suite asserts what the role must NOT do.
DO $$
DECLARE v_held bigint;
BEGIN
    SET LOCAL ROLE openledger_app;
    v_held := record_auth_event('t1','r7_app','g_r7app','papp','c_app',
                                'authorization', 2500,'USD',false, now());
    IF v_held <> 2500 THEN
        RAISE EXCEPTION 'the app role ingested but got % back', v_held;
    END IF;
    -- the regroup needs the event id, and reading it back is part of what an
    -- operator tool does, so the role must be able to do that too
    PERFORM regroup_auth_event('t1',
        (SELECT id FROM card_auth_events
          WHERE tenant_id='t1' AND processor_msg_id='r7_app'),
        'g_r7app2','operator');
    PERFORM recompute_hold_group('t1','papp','g_r7app2');
    PERFORM expire_hold_group('t1','papp','g_r7app2');
    RESET ROLE;
    RAISE NOTICE 'ok  the app role can ingest, regroup, repair and expire';
END $$;
RESET ROLE;
-- ...and the UPDATE privilege that buys is a LOCK, not mutability. The event log
-- stays immutable for this role, by trigger rather than by grant.
SELECT must_fail('the app role rewriting a stored auth event', $q$
    SET LOCAL ROLE openledger_app;
    UPDATE card_auth_events SET amount_delta = 1 WHERE processor_msg_id='r7_app';
$q$, 'card_auth_events is an event log and is immutable: UPDATE');
-- ...and DELETE is not granted at all, so that one never reaches the trigger.
-- Two independent defences, and the control says which is answering.
SELECT must_fail('the app role deleting a stored auth event', $q$
    SET LOCAL ROLE openledger_app;
    DELETE FROM card_auth_events WHERE processor_msg_id='r7_app';
$q$, 'permission denied for table card_auth_events');
RESET ROLE;

-- THE ALARM'S CONVENTION BRANCH, as a POSITIVE control. Its sibling
-- (`any_total AND any_delta`) has one, built out-of-band on purpose because the
-- state is unreachable through the API. This branch is the same shape and did not
-- get the same treatment, so it could be deleted with the suite green -- after
-- which a group whose stored convention disagrees with its log refuses every
-- genuine message from its own processor forever, and refused messages are never
-- stored, so they never reach the review queue either.
SELECT record_auth_event('t1','r7_cv','g_r7conv','omega','card_cv','authorization',3000,'USD',false,now());
SELECT must_fail('a stored convention that disagrees with the log', $q$
    UPDATE card_hold_groups SET total_convention='total'
     WHERE tenant_id='t1' AND company_id='omega' AND group_key='g_r7conv';
    DO $d$ BEGIN
        IF EXISTS (SELECT 1 FROM card_hold_drift WHERE group_key='g_r7conv') THEN
            RAISE EXCEPTION 'STORED CONVENTION DISAGREES WITH THE LOG';
        END IF;
    END $d$;
$q$, 'stored convention disagrees with the log');

-- NOTHING IN THIS FILE MAY LEAVE THE LEDGER DRIFTING. no_drift() is global, so a
-- single call here covers every fixture in the file at once -- and it is only
-- possible because the review-queue fixture above now reconciles itself. This is
-- the assertion whose ABSENCE meant the last stretch of the file had no drift
-- check; it is cheap and it is the strongest thing this file can say at the end.
SELECT no_drift('the end of the file: no fixture left a group disagreeing with its log');

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

DO $$ BEGIN RAISE NOTICE 'ok  SUITE-COMPLETE card_holds'; END $$;
