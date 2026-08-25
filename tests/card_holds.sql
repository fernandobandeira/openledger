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
-- Six of eleven processors surveyed report an incremental authorization as a
-- cumulative TOTAL rather than a delta. The adapter converts at the boundary,
-- under the group's lock, so the stored model stays pure deltas.

SELECT record_auth_event('t1','msg_tip_auth','g_tip','acme','card_3',
        'authorization', 10000,'USD',false, now());
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
SELECT record_auth_event('t1','msg_tip_auth','g_tip','acme','card_3',
        'authorization', 10000,'USD',false, now());
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

-- and the alarm must SEE a group that exists only as membership
SELECT must_fail('membership pointing at a group that was never materialised', $q$
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
            'incremental', 1000,'EUR',false, now());
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

DO $$ BEGIN RAISE NOTICE 'ok  card hold flow attested'; END $$;

ROLLBACK;
