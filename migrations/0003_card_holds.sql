-- 0003 — authorization holds as an append-only event log.
--
-- v8. Supersedes spikes/006-append-only-holds/holds.sql, whose mixed delta/absolute
-- view was broken in four ways by adversarial review — one of them silently
-- UNDER-reserving credit, which is the worst failure available here.
--
-- THE ROOT CAUSE was mixing two conventions in the derivation. Processors disagree
-- on whether an incremental authorization carries a DELTA or a cumulative TOTAL --
-- spike 006 surveys three and they do not agree. (An earlier version of this header
-- said "six of eleven processors". No such survey exists; the disagreement is real,
-- the sample size was invented, and it is struck.) v2 stored both and resolved absolutes by `occurred_at` — but processors
-- emit second-granularity timestamps and none guarantees ordering, so ties fell
-- through to insertion order and the same facts produced different holds depending
-- on which webhook's TCP connection finished first.
--
-- THE FIX: normalise at the boundary. An adapter converts its processor's
-- convention into a delta BEFORE the row is written, under the group's lock. The
-- stored model is then pure deltas, so the derivation is a plain SUM — commutative,
-- and order-tolerant by construction rather than by timestamp.
--
-- Order-dependence does not disappear; it moves to ingest, where a lock can
-- serialise it. That is the trade, stated plainly.

BEGIN;

CREATE TYPE auth_event_kind AS ENUM (
    'authorization','incremental','advice','reversal','clearing','expiry','expiry_reversal');

CREATE TABLE card_auth_events (
    tenant_id     text NOT NULL,
    id            uuid NOT NULL DEFAULT uuidv7(),

    -- The processor's per-MESSAGE object id (Marqeta transaction token, Increase
    -- element id, Lithic events[].token) -- NOT the webhook delivery id. Stripe
    -- documents that one occurrence can emit two distinct evt_ ids, so keying on
    -- delivery would admit semantic duplicates.
    processor_msg_id text NOT NULL,

    -- NOTE: there is deliberately no group_key column. Grouping is a revisable
    -- INFERENCE, not a fact -- see card_auth_event_group below.

    company_id    text NOT NULL,
    card_id       text NOT NULL,
    kind          auth_event_kind NOT NULL,

    -- NORMALISED. Signed, always a delta, never a wire value. The adapter is
    -- responsible for converting a cumulative total into a delta.
    amount_delta  bigint NOT NULL,
    -- The minor-unit exponent is currency-dependent (JPY 0, most 2, some 3), so
    -- the code is part of the value, not metadata.
    currency      char(3) NOT NULL,
    -- What the processor actually sent, for audit of the conversion above.
    raw_amount    bigint,
    raw_is_total  boolean NOT NULL DEFAULT false,
    raw           jsonb NOT NULL DEFAULT '{}'::jsonb,

    occurred_at   timestamptz NOT NULL,   -- processor's clock; NOT a total order
    recorded_at   timestamptz NOT NULL DEFAULT now(),
    -- Our hold-release policy. NOT the network clearing deadline, which is a
    -- different clock: it drives dispute eligibility, does not extend on an
    -- increment, and is 5 days card-present on Visa where our hold is typically 7.
    hold_expires_at    timestamptz,
    clearing_deadline  timestamptz,

    CONSTRAINT pk_auth_events PRIMARY KEY (tenant_id, id),
    -- ISO 4217 is uppercase. 0001 enforces this on entries and accounts and 0003
    -- enforced it nowhere, so 'usd' created a SECOND hold group: held_for_company
    -- for 'USD' reported 1000 while 500 more was live under 'usd'. Same failure the
    -- 0001 comment describes, in the number the authorization decision is made on.
    CONSTRAINT ck_auth_events__currency_iso CHECK (currency ~ '^[A-Z]{3}$'),
    -- sign is a property of the kind. 'advice' and 'expiry_reversal' are exempt:
    -- advice is bidirectional on some processors, and an expiry reversal is a
    -- positive delta on a release.
    -- amount_delta = 0 is legal ONLY for a cumulative total that restates the
    -- amount already applied. A processor re-sending the same total under a new
    -- message id is a routine re-delivery; before this it produced a delta of 0
    -- and died on this CHECK with an opaque constraint error.
    -- A $0.00 authorization is a real message -- account verification / AVS /
    -- card-on-file -- and so is a $0.00 capture. Both were refused outright, with
    -- an opaque constraint error. An expiry_reversal is a positive delta on a
    -- release by definition, so it is no longer exempt.
    CONSTRAINT ck_auth_events__sign CHECK (
        kind = 'advice' OR
        -- expiry_reversal carries ZERO. Expiry is a flag that never subtracted
        -- anything from total_minor, so a reversal of it must not ADD anything
        -- back: it clears the flag. Carrying +remaining made one 100.00
        -- authorization hold 200.00, and after the full 100.00 capture it still
        -- held 100.00 -- with drift silent, because the log genuinely contained
        -- the +10000 and the alarm can only compare the total to the log. The
        -- header argues at length that an event carrying -remaining would be a
        -- read-modify-write smuggled into an append-only log; the mirror image
        -- shipped anyway. The wire amount is kept in raw_amount.
        (kind = 'expiry_reversal' AND amount_delta = 0) OR
        (kind IN ('authorization','incremental') AND amount_delta >= 0) OR
        -- 'expiry' is absent deliberately: expiry is a FLAG. The enum value stays
        -- (removing one is a rewrite) and no row may carry it. record_auth_event
        -- refuses it too, but that gated only the function -- an operator backfill
        -- or a second adapter produced the double release the header argues
        -- against, five lines above the constraint that used to permit it.
        (kind IN ('reversal','clearing')  AND amount_delta <= 0))
);

CREATE UNIQUE INDEX uq_auth_events__msg
    ON card_auth_events (tenant_id, processor_msg_id);

-- ------------------------------------------------------------ grouping
-- Which authorization an event belongs to is NOT a fact we receive; it is an
-- inference. The spec is explicit: "No clean foreign key. Network IDs (ARN, RRN)
-- don't reliably agree across messages. Needs exact match, then fuzzy fallback on
-- card+merchant+amount +/- tolerance+window, then an explicit unmatched queue --
-- never a silent guess."
--
-- So re-grouping is a ROUTINE corrective operation: a clearing sits unmatched and
-- is later attached; a sentinel-polluted trace merged two unrelated authorizations
-- and must be split. Storing group_key on the event would force that operation to
-- UPDATE a row we call immutable.
--
-- Membership is therefore its own bitemporal table. The event stays a genuinely
-- immutable financial fact; the inference about it is revisable and auditable.
CREATE TABLE card_auth_event_group (
    tenant_id    text NOT NULL,
    -- Identity is a uuidv7, NOT (event_id, assigned_at). now() is TRANSACTION
    -- time, so it is constant across a transaction: an operator correcting the
    -- same event twice in one transaction collided on the primary key. This is
    -- the same lesson as ADR-0005 -- a timestamp is not an ordering key -- and
    -- uuidv7 is time-ordered, so the trail still reads chronologically.
    id           uuid NOT NULL DEFAULT uuidv7(),
    event_id     uuid NOT NULL,
    group_key    text NOT NULL,
    method       text NOT NULL CONSTRAINT ck_event_group__method
                     CHECK (method IN ('lifecycle_id','rrn','fuzzy','manual')),
    assigned_at  timestamptz NOT NULL DEFAULT now(),
    assigned_by  text NOT NULL,
    -- NULL = the current assignment. Equal to assigned_at when an assignment is
    -- superseded inside the transaction that created it: a zero-width interval,
    -- correct because that assignment was never visible outside it.
    superseded_at timestamptz,
    CONSTRAINT pk_event_group PRIMARY KEY (tenant_id, id),
    CONSTRAINT fk_event_group__event FOREIGN KEY (tenant_id, event_id)
        REFERENCES card_auth_events (tenant_id, id)
);

-- exactly one live assignment per event
CREATE UNIQUE INDEX uq_event_group__current
    ON card_auth_event_group (tenant_id, event_id) WHERE superseded_at IS NULL;
CREATE INDEX ix_event_group__group
    ON card_auth_event_group (tenant_id, group_key) WHERE superseded_at IS NULL;
-- the audit trail for one event, in assignment order
CREATE INDEX ix_event_group__event ON card_auth_event_group (tenant_id, event_id, id);

-- The unmatched queue the spec calls for, as a view rather than a special value.
CREATE VIEW card_auth_unmatched AS
SELECT e.* FROM card_auth_events e
WHERE NOT EXISTS (SELECT 1 FROM card_auth_event_group g
                  WHERE g.tenant_id = e.tenant_id AND g.event_id = e.id
                    AND g.superseded_at IS NULL);

-- HTTP-layer dedup. A separate concern from ledger identity, with no ledger effect.
CREATE TABLE webhook_deliveries (
    tenant_id   text NOT NULL,
    delivery_id text NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_webhook_deliveries PRIMARY KEY (tenant_id, delivery_id)
);

-- Materialised per-group total. Every processor surveyed ships one; against a
-- ~1s real-time-decisioning budget, deriving a hold by summing an unbounded event
-- log is unbounded work. This is the design, not a contingency.
--
-- That is an ARGUMENT, not a measurement. An earlier version of this comment said
-- "measured at 1131ms on two years of history against a 1500ms budget"; neither
-- number has a source, spike 006 says the derivation "has not been benchmarked
-- here", and every other budget figure in this repo says ~1s. Both are struck.
CREATE TABLE card_hold_groups (
    tenant_id   text NOT NULL,
    company_id  text NOT NULL,
    group_key   text NOT NULL,
    -- A group holds ONE currency. Without this, total_minor summed minor units
    -- across denominations and reported 100.00 USD + 50.00 EUR as "held 15000" --
    -- the same vacuity removed from the accounting equation in 0002, but sitting
    -- in the authorization decision, where the number IS available credit.
    currency    char(3) NOT NULL CONSTRAINT ck_hold_groups__currency_iso
                    CHECK (currency ~ '^[A-Z]{3}$'),
    total_minor bigint NOT NULL DEFAULT 0,
    -- The cumulative AUTHORIZED subtotal: the running sum of increase-side deltas
    -- only. A processor restating a cumulative total is restating THIS, not the
    -- net total -- the net total also has clearings and reversals in it. Deriving
    -- the delta from the net total made the result depend on arrival order: the
    -- same three messages produced four different holds across six orders, with no
    -- error and no drift. That falsifies the headline claim of this whole file.
    authorized_minor bigint NOT NULL DEFAULT 0,
    -- Which convention this group's increase-side messages use, fixed by the first
    -- one. NULL until then.
    --
    -- MIXING THEM IS IRRECONCILABLE, and this is the honest limit of the
    -- order-tolerance claim. {authorization +100.00 as a delta, incremental 120.00
    -- as a cumulative total} yields 120.00 in one order and 220.00 in the other,
    -- because a total arriving BEFORE the delta it restates cannot be identified as
    -- already inclusive of it -- there is no information in the message that says
    -- so. No derivation can fix that; only refusing the mix can.
    --
    -- Within one convention order-tolerance holds: pure deltas commute, and pure
    -- totals resolve to the maximum total seen, with anything lower refused as
    -- out-of-order rather than guessed.
    total_convention text CONSTRAINT ck_hold_groups__total_convention
                          CHECK (total_convention IN ('delta','total')),
    -- GREATEST(total,0): an over-capture ($1 fuel auth clearing at $95) must
    -- contribute 0, never raise available credit. Increase ships the same clamp as
    -- pending_transaction.held_amount.
    held_minor  bigint GENERATED ALWAYS AS (
        CASE WHEN expired_at IS NOT NULL THEN 0 ELSE GREATEST(total_minor, 0) END) STORED,
    open_events int  NOT NULL DEFAULT 0,
    -- Expiry is a FLAG, not an event carrying -remaining. Computing that amount
    -- requires reading the aggregate, which is a read-modify-write smuggled into
    -- an append-only log -- and a read does not commute. TigerBeetle models the
    -- same thing as an interval whose expiry restores the remainder as an engine
    -- operation, for exactly this reason.
    expired_at  timestamptz,
    -- authorized_minor at the moment of expiry. The alarm needs to distinguish
    -- EXPOSURE ADDED after a release from an event merely arriving after one: a
    -- late clearing on an expired group is entirely normal and reduces the log,
    -- while an increase-side message is the thing that must never be swallowed by
    -- the clamp. Keying on "any event after expiry" flagged the normal case.
    expired_authorized bigint,
    -- ...and total_minor at that moment. authorized_minor counts increase-side
    -- deltas ONLY, so two ways of raising live exposure after a release moved it
    -- not at all: an expiry_reversal (excluded from the increase list by design),
    -- and REMOVING a decrease-side event -- splitting a mis-grouped clearing out of
    -- an expired group took exposure from 20.00 to 100.00 with the alarm's
    -- discriminator unchanged. Both are visible in the total.
    expired_total bigint,
    -- Distinguishes the three conditions the clamp otherwise maps onto one 0:
    -- legitimate over-capture, an adapter feeding a total into a delta column, and
    -- a mis-grouped clearing. Over-capture becomes a recorded, alarmable state
    -- rather than a value silently swallowed at SELECT time.
    overcaptured_at timestamptz,
    -- Durable evidence, because overcaptured_at is deliberately non-latching and
    -- was therefore ERASED by the next event that brought the total back up: a
    -- 95.00 over-capture became invisible one message later. The low-water mark
    -- cannot be erased, so "did this group ever over-capture" stays answerable.
    low_water_minor bigint NOT NULL DEFAULT 0,
    last_event_seq  bigint NOT NULL DEFAULT 0,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_hold_groups PRIMARY KEY (tenant_id, company_id, group_key)
);

CREATE INDEX ix_hold_groups__held
    ON card_hold_groups (tenant_id, company_id) WHERE held_minor > 0;

-- Ingest. The lock is what lets an adapter convert a cumulative total into a delta
-- safely, and what makes the materialised total exact rather than eventual.
CREATE FUNCTION record_auth_event(
    p_tenant text, p_msg_id text, p_group text, p_company text, p_card text,
    p_kind auth_event_kind, p_amount bigint, p_currency char(3), p_is_total boolean,
    p_occurred timestamptz, p_method text DEFAULT 'lifecycle_id',
    p_raw jsonb DEFAULT '{}'::jsonb
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_delta bigint; v_current bigint; v_authorized bigint;
        v_event uuid; v_ccy char(3); v_expired timestamptz; v_evt_company text;
        v_evt_ccy char(3); v_evt_kind auth_event_kind; v_evt_delta bigint;
        v_evt_is_total boolean; v_evt_conv text;
        v_conv text; v_incoming text; v_increases boolean; v_live text;
        v_fixes_conv boolean;
BEGIN
    -- A cumulative total is converted against the GROUP's authorized subtotal, so
    -- with no group there is no base and the wire value was stored verbatim as a
    -- delta -- then re-grouped in later, un-converted, poisoning the destination's
    -- subtotal permanently (the next genuine total is refused as out-of-order).
    IF p_is_total AND p_group IS NULL THEN
        RAISE EXCEPTION
          'cannot convert a cumulative total for an unmatched event: the conversion '
          'needs the group it restates. Match it first, or send a delta'
          USING ERRCODE = 'data_exception';
    END IF;

    -- ON LOCK ORDERING, AND AN ATTEMPT THAT MADE IT WORSE.
    --
    -- The fresh path takes the group row FOR UPDATE before it can know whether the
    -- message already exists, so ingest runs group-then-message while the attach
    -- path runs message-then-group. Two ordinary single-group ingests can deadlock
    -- on that: measured 10 of 10 trials with the group pre-created and committed,
    -- so it is a plain row lock and not a race to create anything.
    --
    -- An advisory lock on the message identity was added here to make the message
    -- the first lock everywhere. IT WAS REVERTED, because it does not remove the
    -- class -- it moves which orderings collide, and it moved them onto a commoner
    -- workload. Measured, single-group ordinary ingests throughout:
    --
    --   batch = [unmatched ingest of m, matched ingest of m2], racer attaches m
    --       with the advisory lock: 0 deadlocks    without it: 6 of 6
    --   batch = [matched ingest of mA, matched ingest of mB], racer ingests mB
    --       with the advisory lock: 6 of 6         without it: 0
    --
    -- The second is a webhook batch carrying an authorization and its increment,
    -- racing a redelivery of the increment. That is the plainest traffic this
    -- product has, and the lock made it fail every time -- aborting the adapter's
    -- whole transaction, which is the cost the lock was supposed to remove.
    --
    -- The reason is this file's own recorded lesson one level down: advisory locks
    -- are taken in CALLER ORDER, unsorted, so a multi-message caller reintroduces
    -- exactly the ordering problem ADR-0010 records for a multi-GROUP caller. A
    -- single call cannot sort a key it has not been told about. The class belongs
    -- to unsorted multi-statement callers, the fix belongs in a batch API, and it
    -- is recorded in ADR-0010 rather than half-closed here.
    --
    -- What DOES hold under every one of these interleavings, and is what
    -- tests/concurrency.sh asserts: correctness. Every deadlock aborts cleanly,
    -- each message lands exactly once, and card_hold_drift stays empty.

    -- DEDUP BEFORE ANY GROUP IS MATERIALISED.
    --
    -- The group row was created from CALLER PARAMETERS at the top of this function,
    -- before the function knew whether the message was a re-delivery. A redelivery
    -- naming a DIFFERENT group than the one the event was corrected into therefore:
    -- created a phantom group from those parameters, fell straight through to
    -- `RETURN total_minor` of that empty phantom, and told the adapter 0 while
    -- 600.00 was live -- no error, no regroup, nothing in the unmatched queue, and
    -- drift silent, because an empty group agrees with its empty log on every
    -- branch. `tests/card_holds.sql` calls "what ingest RETURNS must equal what
    -- held_for_company reports" its strongest single assertion; here they differed
    -- by the entire exposure. The phantom also FIXED A CURRENCY from unchecked
    -- caller parameters, permanently: one stray EUR re-delivery of a corrected
    -- message made every subsequent genuine USD message for that key refuse
    -- forever, and refused messages are never stored, so they never reach the
    -- review queue either.
    --
    -- So: resolve the message's identity first, and materialise a group only on a
    -- path that is actually going to put something in it.
    SELECT id, company_id, currency, kind, amount_delta, raw_is_total
      INTO v_event, v_evt_company, v_evt_ccy, v_evt_kind, v_evt_delta, v_evt_is_total
      FROM card_auth_events
     WHERE tenant_id = p_tenant AND processor_msg_id = p_msg_id;

    IF v_event IS NOT NULL THEN
        IF v_evt_company IS DISTINCT FROM p_company THEN
            RAISE EXCEPTION
              'message % already exists for company %, but was re-delivered for %; '
              'route to the review queue', p_msg_id, v_evt_company, p_company
              USING ERRCODE = 'data_exception';
        END IF;

        -- LOCK THE EVENT, AND LOCK IT BEFORE ANY GROUP. Two defects, one cause:
        -- this path moves an event between groups just as regroup_auth_event does,
        -- and it was the only mover that did not lock the thing being moved.
        --
        --   * DEADLOCK. It took the card_hold_groups row FOR UPDATE and then, via
        --     fk_event_group__event, an implicit FOR KEY SHARE on the event when
        --     inserting the membership. regroup_auth_event takes those two in the
        --     OPPOSITE order -- event first, deliberately. A matcher attaching a
        --     queued event against an operator re-grouping the same event
        --     deadlocked in 18 of 20 trials, aborting the adapter's whole webhook
        --     transaction. ADR-0010 claimed "concurrent ingest on a single group
        --     cannot deadlock -- it takes exactly one row lock". It takes two, and
        --     the second one is invisible because a foreign key takes it for you.
        --   * LOST RACE. v_live was read with no lock held, so eight concurrent
        --     re-deliveries of one unmatched event all saw NULL and all tried to
        --     insert a live membership: uq_event_group__current arbitrated, the
        --     final state was right, and SEVEN CALLERS got a raw duplicate-key
        --     error instead of the exposure they asked for.
        --
        -- Locking the event first and re-reading the membership under that lock
        -- fixes both: the order now matches regroup_auth_event, and a loser waits,
        -- then sees the winner's membership and reports the true total.
        PERFORM 1 FROM card_auth_events
         WHERE tenant_id = p_tenant AND id = v_event FOR UPDATE;

        SELECT m.group_key INTO v_live FROM card_auth_event_group m
         WHERE m.tenant_id = p_tenant AND m.event_id = v_event
           AND m.superseded_at IS NULL;

        IF v_live IS NOT NULL THEN
            -- Already grouped. A re-delivery naming a different key is not a
            -- duplicate to swallow: it is the processor and the operator
            -- disagreeing about where this message belongs, which is exactly what
            -- regroup_auth_event exists to settle deliberately.
            IF p_group IS NOT NULL AND p_group <> v_live THEN
                RAISE EXCEPTION
                  'message % is already grouped as %, but was re-delivered naming %; '
                  'use regroup_auth_event to move it, or route to the review queue',
                  p_msg_id, v_live, p_group
                  USING ERRCODE = 'data_exception';
            END IF;
            -- held_minor, not total_minor. See the fresh-ingest RETURN below for
            -- why: the raw total goes negative on an over-capture, and this is the
            -- number an adapter computes `available = limit - returned` from. That
            -- comment was written when the fix reached ONE of the three RETURN
            -- sites -- and said so, in the words "was only exercising it on one
            -- branch" -- while these two kept returning the raw total. A routine
            -- re-delivery of a cleared message handed the caller -9400.
            SELECT held_minor INTO v_current FROM card_hold_groups
             WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=v_live;
            RETURN COALESCE(v_current, 0);
        END IF;

        -- Stored, still unmatched, and the re-delivery does not name a group
        -- either: nothing to do, and nothing to create.
        IF p_group IS NULL THEN
            RETURN 0;
        END IF;
    END IF;

    IF p_group IS NOT NULL THEN
        -- Serialise the group. Converting a cumulative total into a delta requires
        -- reading the current total, so it must not race. This is where the
        -- order-dependence lives: at ingest, under a lock, rather than in the
        -- derivation where it could not be controlled.
        INSERT INTO card_hold_groups (tenant_id,company_id,group_key,currency)
        VALUES (p_tenant,p_company,p_group,p_currency) ON CONFLICT DO NOTHING;
        SELECT total_minor, authorized_minor, currency, expired_at, total_convention
          INTO v_current, v_authorized, v_ccy, v_expired, v_conv
          FROM card_hold_groups
         WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group FOR UPDATE;

        -- `advice` is increase-SIDE, but an advice of zero or negative amount says
        -- nothing about which convention the processor uses. Letting one fix the
        -- convention let a $0.00 status advice lock a group to 'delta', after which
        -- the processor's own opening authorization -- a cumulative total -- was
        -- refused forever: 100.00 live, 0.00 held.
        v_increases := p_kind IN ('authorization','incremental')
                    OR (p_kind = 'advice' AND p_amount > 0);

        -- ...and a message of ZERO says nothing about which convention the
        -- processor uses, whatever its kind. This was fixed for `advice` and not
        -- for the other two, on reasoning that applies identically to all three --
        -- and this same file insists eighty lines up that "a $0.00 authorization
        -- is a real message: account verification / AVS / card-on-file".
        --
        -- Measured with the asymmetry in place: a $0.00 AVS authorization locked a
        -- group to 'delta', after which the processor's own opening cumulative
        -- total AND its incremental were both refused forever -- 200.00 live,
        -- 0.00 held, drift 0 rows, and nothing in the review queue either, because
        -- refused messages are never stored. The same two messages in the other
        -- order held 150.00. An order-tolerance fuzz found 12 of 25 permutation
        -- sets order-dependent once a $0.00 message was in the mix, against 0 of
        -- 25 without one. The mirror image reproduced too: a $0.00 cumulative
        -- total locked a group to 'total' and refused every real delta after it.
        v_fixes_conv := v_increases AND p_amount <> 0;

        -- A cumulative total restates the AUTHORIZED subtotal, so it is only
        -- meaningful on a message that moves that subtotal. Applied to a clearing
        -- or a reversal the conversion computed `amount - authorized_minor` against
        -- a base the message has nothing to do with.
        IF p_is_total AND NOT v_increases THEN
            RAISE EXCEPTION
              'a cumulative total is only meaningful on an authorization, incremental '
              'or advice; % carries one. A cumulative CLEARED or REVERSED figure is a '
              'different quantity and has no conversion here -- route it to the review '
              'queue', p_kind
              USING ERRCODE = 'data_exception';
        END IF;

        -- one convention per group, fixed by the first message that moves the subtotal
        v_incoming  := CASE WHEN p_is_total THEN 'total' ELSE 'delta' END;
        IF v_fixes_conv AND v_conv IS NOT NULL AND v_conv <> v_incoming THEN
            RAISE EXCEPTION
              'group % reports increases as %s, but this message is a %; a group '
              'cannot mix the two -- route to the review queue',
              p_group, v_conv, v_incoming
              USING ERRCODE = 'data_exception';
        END IF;

        IF v_ccy <> p_currency THEN
            RAISE EXCEPTION
              'event in % cannot join group %, which holds %; a hold total is only '
              'meaningful in one currency -- route to the review queue',
              p_currency, p_group, v_ccy
              USING ERRCODE = 'data_exception';
        END IF;
    END IF;

    -- THE RE-DELIVERY ATTACH.
    --
    -- Reached only when the message is already stored, is still unmatched, and this
    -- delivery names a group. The guards above ran on the CALLER'S PARAMETERS: on
    -- the fresh path those parameters ARE the event, so that is sound, but here the
    -- event already exists and is immutable, and validating the caller's claims
    -- about it is validating the wrong thing. A re-delivery that says 'USD'
    -- attached a stored JPY event to a USD group; one that said 'delta' attached a
    -- stored cumulative total into a totals group and poisoned its subtotal
    -- forever; one that said 'clearing' attached a stored expiry_reversal to an
    -- expired group where the clamp swallowed it -- 900.00 held, 0.00 reported, no
    -- drift row. regroup_auth_event reads the event; this did not.
    --
    -- It must still precede the OUT-OF-ORDER guard below: a retried cumulative
    -- total is by construction lower than the subtotal the group has already
    -- reached, so it looks exactly like an out-of-order message. A retry is not new
    -- information.
    IF v_event IS NOT NULL THEN
        BEGIN
            -- every guard, re-run against the STORED row
            IF v_evt_ccy <> v_ccy THEN
                RAISE EXCEPTION
                  'stored event % is in %, and cannot join group %, which holds %',
                  p_msg_id, v_evt_ccy, p_group, v_ccy
                  USING ERRCODE = 'data_exception';
            END IF;
            -- hoisted: `CASE ... END THEN` inside an IF is ambiguous to plpgsql
            v_evt_conv := CASE WHEN v_evt_is_total THEN 'total' ELSE 'delta' END;
            IF (v_evt_kind IN ('authorization','incremental')
                OR (v_evt_kind = 'advice' AND v_evt_delta > 0))
               AND v_evt_delta <> 0
               AND v_conv IS NOT NULL AND v_conv <> v_evt_conv THEN
                RAISE EXCEPTION
                  'stored event % reports a %, but group % reports increases as %s',
                  p_msg_id, v_evt_conv, p_group, v_conv
                  USING ERRCODE = 'data_exception';
            END IF;

            INSERT INTO card_auth_event_group (tenant_id,event_id,group_key,method,assigned_by)
            VALUES (p_tenant, v_event, p_group, p_method, 'ingest:redelivery');

            -- Keyed on the STORED kind and delta, not the caller's. No
            -- `OR v_evt_is_total` here, unlike the fresh-ingest copy of this
            -- predicate: a cumulative total is refused outright when it names no
            -- group, so a STORED is_total event always already has a membership
            -- and can never reach this path. Carrying the disjunct anyway left an
            -- unreachable branch that mutation testing cannot distinguish from a
            -- tested one.
            IF v_evt_kind = 'expiry_reversal'
               OR (v_evt_kind IN ('authorization','incremental','advice')
                   AND v_evt_delta > 0) THEN
                UPDATE card_hold_groups
                   SET expired_at = NULL, expired_authorized = NULL, expired_total = NULL
                 WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group;
            END IF;
            PERFORM recompute_hold_group(p_tenant, p_company, p_group);
        END;
        -- ...and the attach path, the third of the three.
        SELECT held_minor INTO v_current FROM card_hold_groups
         WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group;
        RETURN COALESCE(v_current, 0);
    END IF;

    -- An absolute total that implies a NEGATIVE delta on an increase-only kind means
    -- it arrived out of order relative to totals already applied. This is not
    -- resolvable from the message alone -- a cumulative total carries no sequence --
    -- so refuse it explicitly rather than guess. v2 guessed, using occurred_at with
    -- an insertion-order tiebreak, and silently UNDER-reserved credit.
    IF p_is_total AND p_group IS NOT NULL
       AND p_kind IN ('authorization','incremental','advice')
       AND p_amount < v_authorized THEN
        RAISE EXCEPTION
          'out-of-order cumulative total for group %: received % but the group has '
          'already authorized %; route to the review queue rather than applying it',
          p_group, p_amount, v_authorized
          USING ERRCODE = 'data_exception';
    END IF;

    -- A cumulative total restates the AUTHORIZED subtotal, never the net total.
    -- Expiry is a FLAG (card_hold_groups.expired_at), never an event carrying the
    -- remainder -- the header argues this at length, and then the enum and the sign
    -- CHECK both admitted such an event. Shipping both mechanisms guarantees a
    -- DOUBLE RELEASE: the log releases the amount, the flag releases it again, and
    -- a later re-open restores only what the flag had suppressed. The enum value
    -- stays (removing one is a rewrite) and is refused here.
    IF p_kind = 'expiry' THEN
        RAISE EXCEPTION
          'expiry is a flag, not an event: call expire_hold_group(). An expiry event '
          'carrying the remainder double-releases the hold'
          USING ERRCODE = 'data_exception';
    END IF;

    v_delta := CASE
        WHEN p_is_total AND p_group IS NOT NULL THEN p_amount - v_authorized
        WHEN p_kind IN ('authorization','incremental')  THEN abs(p_amount)
        -- ...and so the conversion gives it zero. Same shape as a cumulative
        -- restatement whose delta is zero: the message is the liveness signal,
        -- not an amount.
        WHEN p_kind = 'expiry_reversal'                 THEN 0
        WHEN p_kind = 'advice'                          THEN p_amount
        ELSE -abs(p_amount) END;

    INSERT INTO card_auth_events (tenant_id,processor_msg_id,company_id,card_id,kind,
           amount_delta,currency,raw_amount,raw_is_total,raw,occurred_at)
    VALUES (p_tenant,p_msg_id,p_company,p_card,p_kind,
            v_delta,p_currency,p_amount,p_is_total,p_raw,p_occurred)
    ON CONFLICT (tenant_id, processor_msg_id) DO NOTHING
    RETURNING id INTO v_event;

    IF v_event IS NULL THEN
        -- Lost the race on uq_auth_events__msg. An unmatched ingest takes NO group
        -- lock, so a concurrent re-delivery carrying better matching data could
        -- reach here and simply RETURN -- told it succeeded, never retrying, while
        -- 800.00 sat in the unmatched queue and held_for_company said 0. Re-run the
        -- attach against the row the winner wrote.
        RETURN record_auth_event(p_tenant, p_msg_id, p_group, p_company, p_card,
                                 p_kind, p_amount, p_currency, p_is_total,
                                 p_occurred, p_method, p_raw);
    END IF;

    IF p_group IS NULL THEN RETURN 0; END IF;   -- unmatched queue; contributes nothing

    INSERT INTO card_auth_event_group (tenant_id,event_id,group_key,method,assigned_by)
    VALUES (p_tenant,v_event,p_group,p_method,'ingest');

    UPDATE card_hold_groups
       SET total_minor  = total_minor + v_delta,
           -- only increase-side messages move the authorized subtotal
           authorized_minor = authorized_minor
               + CASE WHEN v_increases THEN GREATEST(v_delta, 0) ELSE 0 END,
           low_water_minor = LEAST(low_water_minor, total_minor + v_delta),
           -- A new authorization, increment, advice or expiry_reversal on an
           -- EXPIRED group means our release was premature -- the hold is live
           -- again. A late CLEARING must NOT resurrect it, so only the increase
           -- side un-expires. A cumulative RESTATEMENT counts even though its delta
           -- is zero: the restatement itself is the liveness signal.
           expired_at = CASE WHEN p_kind = 'expiry_reversal'
                             OR (p_kind IN ('authorization','incremental','advice')
                                  AND (v_delta > 0 OR p_is_total))
                             THEN NULL ELSE expired_at END,
           -- No ratchet on this branch, because it is provably the identity and a
           -- reviewer proved it: expired_authorized = authorized_minor at expiry,
           -- every kind that reaches the non-reopen branch adds 0 to
           -- authorized_minor, and the only paths that LOWER it (regroup-out,
           -- attach) go through recompute_hold_group, which carries its own
           -- ratchet. Replaying 13,866 permutations against a build with the
           -- LEAST removed gave byte-identical group rows. The sibling
           -- expired_total ratchet is NOT dead -- a clearing ingested straight
           -- onto an expired group lowers total_minor with no recompute -- which
           -- is why they are no longer written as a symmetric pair.
           expired_authorized = CASE WHEN p_kind = 'expiry_reversal'
                                     OR (p_kind IN ('authorization','incremental','advice')
                                          AND (v_delta > 0 OR p_is_total))
                                     THEN NULL
                                ELSE expired_authorized END,
           -- ...and the total snapshot RATCHETS DOWN while expired. A late clearing
           -- lowered an expired group's total, and removing that clearing then
           -- restored the exposure without ever exceeding the snapshot taken at
           -- expiry: 0 to 100000 on a released hold, held_minor 0, no alarm.
           expired_total = CASE WHEN p_kind = 'expiry_reversal'
                                OR (p_kind IN ('authorization','incremental','advice')
                                     AND (v_delta > 0 OR p_is_total))
                                THEN NULL
                           WHEN expired_at IS NOT NULL
                                THEN LEAST(expired_total, total_minor + v_delta)
                           ELSE expired_total END,
           -- v_increases, not a second copy of the predicate: written out
           -- separately, this line let a $0.00 advice fix the convention after the
           -- guard above had been taught not to.
           total_convention = COALESCE(total_convention,
               CASE WHEN v_fixes_conv
                    THEN CASE WHEN p_is_total THEN 'total' ELSE 'delta' END END),
           open_events  = open_events + 1,
           last_event_seq = last_event_seq + 1,
           -- Over-capture is a RECORDED state, not a value the clamp swallows, and
           -- it must NOT latch: the SUM is order-tolerant, so a group whose events
           -- arrive out of order dips negative in passing, and a latching flag
           -- turns every such delivery into a spurious alarm. low_water_minor keeps
           -- the durable evidence.
           overcaptured_at = CASE WHEN total_minor + v_delta < 0
                                  THEN COALESCE(overcaptured_at, now()) END,
           updated_at   = now()
     WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group
    RETURNING held_minor INTO v_current;
    -- held_minor, NOT total_minor. This is the number an adapter computes
    -- `available = limit - returned` from, and the raw total goes NEGATIVE on an
    -- over-capture: a $1 authorization clearing at $95 returned -9400 while
    -- held_for_company reported 0, which is 94.00 of phantom credit for anyone who
    -- believed the return value. `tests/card_holds.sql` calls "what ingest RETURNS
    -- must equal what held_for_company reports" its strongest single assertion and
    -- was only exercising it on one branch.
    --
    -- Still per-GROUP, which the caller has to know: a company with two open groups
    -- gets this group's number back, not its total exposure. held_for_company is
    -- the company-wide question.
    RETURN COALESCE(v_current, 0);
END $$;

-- Expiry is a flag, never a computed delta (see card_hold_groups.expired_at).
-- It is NOT terminal: a later authorization or increment on the same group clears
-- it, because that means the release was premature.
CREATE FUNCTION expire_hold_group(p_tenant text, p_company text, p_group text)
RETURNS void LANGUAGE sql AS $$
    UPDATE card_hold_groups
       SET expired_at = now(),
           expired_authorized = authorized_minor, expired_total = total_minor,
           updated_at = now()
     WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group
       AND expired_at IS NULL;
$$;

-- Rebuild a group's materialised total from its log. Must be a shipped, exercised
-- operation, not a theoretical one -- if it is never run, it does not work.
CREATE FUNCTION recompute_hold_group(p_tenant text, p_company text, p_group text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_total bigint; v_auth bigint; v_n int;
        v_any_total boolean; v_any_delta boolean;
BEGIN
    -- Materialise, THEN lock. `PERFORM 1 ... FOR UPDATE` locks nothing when the row
    -- is absent, which is exactly the missing-group state this function exists to
    -- repair: it then blocked inside its own INSERT and, on waking, blind-wrote the
    -- sum computed BEFORE the block -- erasing a committed 100.00 incremental the
    -- caller had already decided on. That is the same lost update the "Lock FIRST"
    -- comment claimed to have fixed, reachable through the one case it did not lock.
    INSERT INTO card_hold_groups (tenant_id, company_id, group_key, currency)
    SELECT p_tenant, p_company, p_group, e.currency
      FROM card_auth_event_group m
      JOIN card_auth_events e ON e.tenant_id=m.tenant_id AND e.id=m.event_id
     WHERE m.tenant_id=p_tenant AND m.group_key=p_group AND m.superseded_at IS NULL
       AND e.company_id = p_company
     LIMIT 1
    ON CONFLICT DO NOTHING;

    PERFORM 1 FROM card_hold_groups
     WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group FOR UPDATE;

    -- company_id is part of the group's identity. Filtering on (tenant, group_key)
    -- alone let TWO COMPANIES sharing an inferred group_key -- and an RRN or
    -- lifecycle id is a network value, not a per-company one -- overwrite each
    -- other. A different company's clearing silently reduced acme's held amount by
    -- 300.00, and repeated repair never converged.
    SELECT COALESCE(SUM(e.amount_delta),0),
           COALESCE(SUM(GREATEST(e.amount_delta,0))
                    FILTER (WHERE e.kind IN ('authorization','incremental','advice')),0),
           count(*),
           -- total_convention was set in exactly ONE place: the fresh-ingest
           -- UPDATE. Every other path that changes a group's membership -- the
           -- re-delivery attach, regroup_auth_event, this function -- left it
           -- NULL, and the mixing guard is `v_conv IS NOT NULL AND ...`, so a
           -- group whose first increase arrived by re-delivery had NO convention
           -- and the guard never engaged. A delta processor's genuine +120.00,
           -- normalised as a total by a second adapter, then became +20.00:
           -- 100.00 under-reserved, through the public API alone, drift silent.
           -- Derive it from the log instead, so every path that recomputes also
           -- re-arms the guard.
           -- `amount_delta <> 0`: a zero-amount message is convention-neutral at
           -- ingest, so deriving a convention from one here would put back exactly
           -- what ingest now declines to fix.
           bool_or(e.raw_is_total) FILTER (
               WHERE e.amount_delta <> 0
                 AND (e.kind IN ('authorization','incremental')
                  OR (e.kind = 'advice' AND e.amount_delta > 0))),
           bool_or(NOT e.raw_is_total) FILTER (
               WHERE e.amount_delta <> 0
                 AND (e.kind IN ('authorization','incremental')
                  OR (e.kind = 'advice' AND e.amount_delta > 0)))
      INTO v_total, v_auth, v_n, v_any_total, v_any_delta
      FROM card_auth_event_group m
      JOIN card_auth_events e ON e.tenant_id=m.tenant_id AND e.id=m.event_id
     WHERE m.tenant_id=p_tenant AND m.group_key=p_group AND m.superseded_at IS NULL
       AND e.company_id = p_company;

    UPDATE card_hold_groups
       SET total_minor = v_total, authorized_minor = v_auth, open_events = v_n,
           -- A group holding both is the state the header calls irreconcilable.
           -- Do not pick one: leave what is there and let card_hold_drift say so.
           total_convention = CASE WHEN v_any_total AND v_any_delta THEN total_convention
                                   WHEN v_any_total THEN 'total'
                                   WHEN v_any_delta THEN 'delta' END,
           low_water_minor = LEAST(low_water_minor, v_total),
           -- Both snapshots ratchet DOWN while the group is expired, and both have
           -- to: regrouping an event OUT of an expired group lowers this group's
           -- subtotal through here, and nowhere else. Left un-ratcheted,
           -- expired_authorized then sat ABOVE the live subtotal, so re-attaching
           -- that exposure later never exceeded it and the post-expiry branch --
           -- which is `authorized_minor > expired_authorized` -- stayed silent.
           expired_authorized = CASE WHEN expired_at IS NOT NULL
                                THEN LEAST(expired_authorized, v_auth) ELSE expired_authorized END,
           expired_total = CASE WHEN expired_at IS NOT NULL
                                THEN LEAST(expired_total, v_total) ELSE expired_total END,
           updated_at = now(),
           overcaptured_at = CASE WHEN v_total < 0
                                  THEN COALESCE(overcaptured_at, now()) END
     WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group;

    -- ...and the FOURTH return site. Three separate fixes and twenty lines of
    -- comment established that a returned hold must be the clamped held_minor and
    -- never the raw total, because the raw total goes negative on an over-capture
    -- and an adapter computing `available = limit - returned` gains phantom
    -- credit. This one was still returning v_total: -9400, verbatim the number the
    -- other three were fixed to stop producing. It is a repair entry point rather
    -- than the hot path, but it is public and it returns a bigint that looks like
    -- a hold.
    -- ...and the clamp is held_minor's, not just GREATEST. An earlier fix here
    -- used GREATEST(v_total,0), which clamps an over-capture and NOT an expiry --
    -- so on an expired group this returned the full total while the other three
    -- return sites and held_for_company all returned 0. The comment above claimed
    -- the site now returned held_minor; it returned something that agreed with
    -- held_minor on three branches out of four. Read the column.
    SELECT held_minor INTO v_total FROM card_hold_groups
     WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group;
    RETURN COALESCE(v_total, 0);
END $$;

-- Re-grouping: the corrective operation the spec's unmatched queue requires.
-- Supersedes rather than updates, so the trail survives.
CREATE FUNCTION regroup_auth_event(
    p_tenant text, p_event uuid, p_new_group text, p_by text, p_method text DEFAULT 'manual')
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_old text; v_company text; v_ccy char(3); v_dest card_hold_groups; k text;
        v_is_total boolean;
BEGIN
    -- LOCK THE EVENT FIRST. v_old was read with no lock held and never re-read, so
    -- if the event moved in between, the supersede below removed it from a group
    -- this call holds no lock on and never recomputes. Deterministic repro: two
    -- operators moving the same event X->Y and X->Z left Y and Z each materialising
    -- the full 100.00 -- held_for_company 200.00 against true exposure of 100.00,
    -- with Y's membership already superseded. At 5 workers x 150 regroups a phantom
    -- survived every run. The event row is the natural serialisation point: it is
    -- the thing being moved.
    SELECT e.company_id, e.currency, e.raw_is_total INTO v_company, v_ccy, v_is_total
      FROM card_auth_events e WHERE e.tenant_id=p_tenant AND e.id=p_event FOR UPDATE;
    IF v_company IS NULL THEN
        RAISE EXCEPTION 'no such auth event %', p_event USING ERRCODE='data_exception';
    END IF;

    -- A CUMULATIVE TOTAL CANNOT BE MOVED. Its stored amount_delta is a RELATIVE
    -- quantity -- `wire_amount - authorized_minor`, computed under the SOURCE
    -- group's lock against the SOURCE group's base. Re-summing it against a
    -- different base is arithmetic on two unrelated numbers. Measured: two 100.00
    -- and 250.00 cumulative authorizations in one group, then moving the second
    -- out, left the destination holding 150.00 against a true 250.00 while
    -- card_auth_events still recorded raw_amount = 25000. 100.00 under-reserved,
    -- no drift row -- because the log and the total agreed, on the wrong number.
    -- The convention guard below only compares LABELS, so 'total' -> 'total' and
    -- 'total' -> (new group) both passed. It also poisoned the over-capture signal:
    -- the ordinary clearing that followed printed a permanent 100.00 over-capture,
    -- one of the three conditions ADR-0010 says the clamp must keep distinguishable.
    -- Re-deriving the delta would need the destination's base at the time the
    -- message arrived, which is not recoverable. Refuse, and route to review.
    IF v_is_total THEN
        RAISE EXCEPTION
          'event % was delivered as a cumulative total: its stored delta is relative '
          'to the group it arrived in, so moving it would restate an unrelated base. '
          'Supersede it and re-ingest the wire amount against the correct group',
          p_event USING ERRCODE='data_exception';
    END IF;

    SELECT group_key INTO v_old FROM card_auth_event_group
     WHERE tenant_id=p_tenant AND event_id=p_event AND superseded_at IS NULL;

    -- MATERIALISE THE DESTINATION FIRST, then lock, then validate -- the order
    -- record_auth_event already uses, and the reason it has no window.
    --
    -- The previous order (read FOR UPDATE, validate, then insert) was not
    -- concurrency-safe: while a concurrent transaction was mid-creation of the
    -- destination the row was invisible, FOUND was false, and BOTH guards below
    -- were skipped entirely. Demonstrated twice, against this exact function:
    --   * a USD event moved into a group being created as EUR -- 1500 "held",
    --     being 1000 EUR plus 500 USD added as if they were the same unit
    --   * a live 900-unit authorization moved into a group being expired --
    --     held_for_company reported 0 against real exposure of 1000, and
    --     card_hold_drift could not see it, because the clamp lives in
    --     held_minor while the alarm compares total_minor, and those agreed
    --
    -- Serially both are refused. The guards were correct and reachable around.
    -- Lock BOTH affected groups, in group_key order -- and MATERIALISE THE
    -- DESTINATION AT ITS PLACE IN THAT ORDER, not before it.
    --
    -- `INSERT ... ON CONFLICT DO NOTHING` IS a lock acquisition. Doing it ahead of
    -- the sort put one lock outside the ordering the sort exists to impose, so any
    -- transaction already holding the source and then touching the new destination
    -- closed a cycle: measured, an adapter processing a webhook batch deadlocked
    -- against an operator splitting an event into a not-yet-existing group, and the
    -- whole batch rolled back.
    --
    -- Destination-then-source is not a safe order: two operators moving events in
    -- opposite directions between the same two groups take the same two row locks
    -- backwards and deadlock. Measured at 198 deadlocks under mixed regroup/ingest
    -- load -- introduced by adding the lock that fixed the lost update. Same
    -- lesson as sorting the legs in post(): a deterministic order, decided up
    -- front, is what makes concurrent lockers queue instead of die.
    FOR k IN SELECT g FROM unnest(ARRAY[p_new_group, v_old]) AS g
              WHERE g IS NOT NULL ORDER BY g
    LOOP
        IF k = p_new_group THEN
            INSERT INTO card_hold_groups (tenant_id, company_id, group_key, currency)
            VALUES (p_tenant, v_company, p_new_group, v_ccy)
            ON CONFLICT DO NOTHING;
        END IF;
        PERFORM 1 FROM card_hold_groups
         WHERE tenant_id=p_tenant AND company_id=v_company AND group_key=k FOR UPDATE;
    END LOOP;

    -- The destination now certainly exists and is locked, so these always run.
    SELECT * INTO v_dest FROM card_hold_groups
     WHERE tenant_id=p_tenant AND company_id=v_company AND group_key=p_new_group;

    IF v_dest.currency <> v_ccy THEN
        RAISE EXCEPTION
          'cannot move a % event into group %, which holds %; a hold total is only '
          'meaningful in one currency', v_ccy, p_new_group, v_dest.currency
          USING ERRCODE='data_exception';
    END IF;

    IF v_dest.total_convention IS NOT NULL
       AND (SELECT e.kind IN ('authorization','incremental')
                OR (e.kind='advice' AND e.amount_delta > 0)
              FROM card_auth_events e WHERE e.tenant_id=p_tenant AND e.id=p_event)
       AND v_dest.total_convention <>
           (SELECT CASE WHEN e.raw_is_total THEN 'total' ELSE 'delta' END
              FROM card_auth_events e WHERE e.tenant_id=p_tenant AND e.id=p_event) THEN
        RAISE EXCEPTION
          'cannot move that event into group %, which reports increases as %s: the '
          'operator''s routine correction would poison the authorized subtotal the '
          'same way a mixed ingest does', p_new_group, v_dest.total_convention
          USING ERRCODE='data_exception';
    END IF;

    IF v_dest.expired_at IS NOT NULL THEN
        RAISE EXCEPTION
          'cannot move an event into group %, which expired at %; re-open it or '
          'choose another group', p_new_group, v_dest.expired_at
          USING ERRCODE='data_exception';
    END IF;

    UPDATE card_auth_event_group SET superseded_at = now()
     WHERE tenant_id=p_tenant AND event_id=p_event AND superseded_at IS NULL;
    INSERT INTO card_auth_event_group (tenant_id,event_id,group_key,method,assigned_by)
    VALUES (p_tenant,p_event,p_new_group,p_method,p_by);

    PERFORM recompute_hold_group(p_tenant, v_company, g)
       FROM (SELECT unnest(ARRAY[v_old, p_new_group]) g) x
      WHERE g IS NOT NULL;
END $$;

-- held is now an indexed sum over GROUPS, not over events.
-- Currency is REQUIRED, deliberately without a default. Available credit is the
-- number the authorization decision is made on; a defaulted currency here is
-- precisely how a cross-currency total would go unnoticed again.
CREATE FUNCTION held_for_company(p_tenant text, p_company text, p_currency char(3))
RETURNS bigint LANGUAGE plpgsql STABLE AS $$
DECLARE v bigint;
BEGIN
    -- A NULL argument IS the defaulted currency this function refuses to have, and
    -- it returned the most dangerous possible answer: `currency = NULL` matches no
    -- row, so 500.00 of live exposure came back as 0. Refusing costs nothing; the
    -- silent zero is what an authorization gets approved against.
    IF p_tenant IS NULL OR p_company IS NULL OR p_currency IS NULL THEN
        RAISE EXCEPTION
            'held_for_company requires tenant, company and currency; got (%, %, %). '
            'A missing currency is how a cross-currency total goes unnoticed',
            p_tenant, p_company, p_currency
            USING ERRCODE = 'data_exception';
    END IF;
    -- ...and 'usd' is the identical failure, refused on the WRITE path and not
    -- here. This file records that lowercase 'usd' already caused the defect once:
    -- it created a SECOND hold group, and held_for_company for 'USD' reported 1000
    -- while 500 more was live under 'usd'. The CHECK that closed it guards
    -- card_hold_groups.currency. THIS is the read the authorization decision
    -- actually calls, and it took anything and answered 0.
    IF p_currency !~ '^[A-Z]{3}$' THEN
        RAISE EXCEPTION
            'held_for_company was asked for currency %, which is not an ISO code. '
            'A non-canonical currency matches no group and returns a silent zero',
            p_currency
            USING ERRCODE = 'data_exception';
    END IF;
    -- The markers are load-bearing: tests/query_plans.sql extracts exactly this
    -- region out of pg_proc and EXPLAINs it, so the plan guard reads the shipped
    -- query rather than a hand-retyped copy of it. A retyped copy could not see
    -- `AND held_minor > 0` being dropped, which is value-equivalent and
    -- plan-critical -- it moves the read off the partial index onto the primary
    -- key, scanning every group the company has ever had.
    -- PLAN-QUERY-BEGIN
    SELECT COALESCE(SUM(held_minor),0)::bigint INTO v FROM card_hold_groups
     WHERE tenant_id = p_tenant AND company_id = p_company
       AND currency = p_currency AND held_minor > 0
    -- PLAN-QUERY-END
    ;
    RETURN v;
END $$;

-- The hold log is history, and card_hold_groups carries state that is NOT in the
-- log: expired_at, its expired_* snapshots, and low_water_minor. Deleting a group
-- row therefore destroys information no recompute can rebuild -- and both repair
-- paths then rebuilt it WRONG rather than failing. Demonstrated:
--   * DELETE the row, call recompute_hold_group: the group came back with
--     total_convention NULL, expired_at NULL and expired_total NULL -- an expired
--     group silently LIVE again, its post-expiry drift branch permanently disarmed
--     (that branch is COALESCE-guarded on the snapshots), drift 0 rows
--   * DELETE the row, then send an ordinary incremental: ingest re-materialised at
--     total_minor = 0 and returned 70.00 to the adapter against 1070.00 of live
--     exposure. Drift fires afterwards; the authorization decision does not wait
--     for it
-- Materialisations may be rewritten. History may not, and neither may the row that
-- carries the part of the state that is not history.
CREATE TRIGGER ck_auth_events__immutable BEFORE UPDATE OR DELETE ON card_auth_events
    FOR EACH ROW EXECUTE FUNCTION assert_event_immutable();
ALTER TABLE card_auth_events ENABLE ALWAYS TRIGGER ck_auth_events__immutable;

CREATE FUNCTION refuse_group_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION
        'hold group %/% cannot be deleted: expired_at, its snapshots and '
        'low_water_minor are not in the event log, so no recompute can rebuild '
        'them. Expire it or supersede its memberships instead',
        OLD.company_id, OLD.group_key
        USING ERRCODE = '23514';
END $$;

CREATE TRIGGER ck_hold_groups__no_delete BEFORE DELETE ON card_hold_groups
    FOR EACH ROW EXECUTE FUNCTION refuse_group_delete();
ALTER TABLE card_hold_groups ENABLE ALWAYS TRIGGER ck_hold_groups__no_delete;

CREATE TRIGGER ck_auth_events__no_truncate BEFORE TRUNCATE ON card_auth_events
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE card_auth_events ENABLE ALWAYS TRIGGER ck_auth_events__no_truncate;
CREATE TRIGGER ck_event_group__no_truncate BEFORE TRUNCATE ON card_auth_event_group
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE card_auth_event_group ENABLE ALWAYS TRIGGER ck_event_group__no_truncate;
CREATE TRIGGER ck_hold_groups__no_truncate BEFORE TRUNCATE ON card_hold_groups
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE card_hold_groups ENABLE ALWAYS TRIGGER ck_hold_groups__no_truncate;

-- The alarm: the materialised total must always equal the sum of its events.
--
-- FULL OUTER, not LEFT. Starting from card_hold_groups made the alarm blind to
-- the one failure that actually occurred: live membership rows pointing at a
-- group that was never materialised. `stored IS NULL` is that case, and it is
-- reported rather than skipped.
-- ...AND THESE TWO TABLES MAY NOT BE INHERITED EITHER. 0001's guard read a literal
-- list of four ledger tables; these two carry the same exposure and it did not name
-- them. A child of card_hold_groups accepted a row, held_for_company read it through
-- the parent -- 999900 of exposure out of nothing -- and ck_hold_groups__no_delete
-- did not reach the child, so it could be removed again. The list is a table for
-- exactly this reason: a migration declares its own.
INSERT INTO ledger_uninheritable (relname, reason) VALUES
  ('card_auth_events', 'the append-only authorization log the whole hold flow sums'),
  ('card_hold_groups', 'held_for_company reads it, so a child fabricates credit');

CREATE VIEW card_hold_drift AS
WITH live AS (
    SELECT m.tenant_id, e.company_id, m.group_key,
           SUM(e.amount_delta) AS recomputed,
           -- authorized_minor is the base every cumulative conversion is computed
           -- against and the sole input to the out-of-order refusal. A wrong value
           -- there refuses real increases forever, and nothing compared it to
           -- anything.
           SUM(GREATEST(e.amount_delta,0)) FILTER (
               WHERE e.kind IN ('authorization','incremental')
                  OR (e.kind = 'advice' AND e.amount_delta > 0)) AS recomputed_auth,
           bool_or(e.raw_is_total) FILTER (
               WHERE e.amount_delta <> 0
                 AND (e.kind IN ('authorization','incremental')
                  OR (e.kind = 'advice' AND e.amount_delta > 0))) AS any_total,
           bool_or(NOT e.raw_is_total) FILTER (
               WHERE e.amount_delta <> 0
                 AND (e.kind IN ('authorization','incremental')
                  OR (e.kind = 'advice' AND e.amount_delta > 0))) AS any_delta,
           -- Decreases that moved NO MONEY. A clearing posts to the ledger, so a
           -- group whose total went negative from clearings is not under-reserving
           -- -- the cleared amount is a receivable in the journal, and exposure is
           -- posted + held. ADR-0010 declines the over-capture report on exactly
           -- that argument, and the argument covers `clearing` AND NOTHING ELSE.
           -- `reversal` and negative `advice` post nothing. Two reversals against
           -- one authorization left total_minor at -10000 with zero clearings in
           -- the log, and the next genuine incremental was absorbed by the
           -- residue: 100.00 live, 0.00 held, 0.00 posted, drift silent. The
           -- non-latching overcaptured_at was erased by the very message that hid
           -- the money.
           COALESCE(-SUM(e.amount_delta) FILTER (
               WHERE e.amount_delta < 0 AND e.kind <> 'clearing'), 0) AS bloodless_decreases
           -- `increases` and `cleared` used to be computed here. `increases` was read
           -- only by the disjunct deleted below, and `cleared` by nothing at all --
           -- it was never in the outer SELECT nor in the WHERE. Two columns summed
           -- over the whole live log on every read of this view, for no reader.
      FROM card_auth_event_group m
      JOIN card_auth_events e ON e.tenant_id = m.tenant_id AND e.id = m.event_id
     WHERE m.superseded_at IS NULL
     GROUP BY m.tenant_id, e.company_id, m.group_key
)
SELECT COALESCE(g.tenant_id,  l.tenant_id)  AS tenant_id,
       COALESCE(g.company_id, l.company_id) AS company_id,
       COALESCE(g.group_key,  l.group_key)  AS group_key,
       g.total_minor          AS stored,      -- NULL = no materialised group
       g.authorized_minor     AS stored_authorized,
       COALESCE(l.recomputed_auth, 0) AS recomputed_authorized,
       COALESCE(l.recomputed, 0) AS recomputed
FROM card_hold_groups g
FULL OUTER JOIN live l
  ON  l.tenant_id  = g.tenant_id
  AND l.company_id = g.company_id
  AND l.group_key  = g.group_key
WHERE g.total_minor IS DISTINCT FROM COALESCE(l.recomputed, 0)
   OR g.authorized_minor IS DISTINCT FROM COALESCE(l.recomputed_auth, 0)
   -- ...or the group's declared currency disagrees with any of its live events.
   -- The alarm compared total_minor and nothing else, so a group holding two
   -- currencies -- the state regroup_auth_event used to be able to create --
   -- reported no drift at all.
   OR EXISTS (
        SELECT 1 FROM card_auth_event_group m
        JOIN card_auth_events e ON e.tenant_id=m.tenant_id AND e.id=m.event_id
        WHERE m.tenant_id = g.tenant_id AND m.group_key = g.group_key
          AND m.superseded_at IS NULL AND e.company_id = g.company_id
          AND e.currency <> g.currency)
   -- ...or an event was attached to a group AFTER it expired. held_minor is
   -- GENERATED to 0 once expired_at is set, so exposure attached later is
   -- invisible to held_for_company while total_minor and the log still agree --
   -- the alarm compared exactly those two and therefore reported nothing. The
   -- clamp is the thing hiding the number, so the alarm has to look past it.
   -- (An earlier version of this comment said the branch was "keyed on the
   -- monotonic counter, not on now()". It is keyed on the expired_* snapshots.
   -- `last_event_seq` is read by nothing at all -- see the open list.)
   -- Exposure added to a group AFTER it was expired. held_minor is GENERATED to 0
   -- once expired_at is set, so anything attached later is invisible to
   -- held_for_company while total_minor and the log still agree -- the two columns
   -- the alarm compares. Keyed on the monotonic counter, not on now().
   OR (g.expired_at IS NOT NULL
       AND (g.authorized_minor > COALESCE(g.expired_authorized, g.authorized_minor)
         OR g.total_minor      > COALESCE(g.expired_total,      g.total_minor)))
   -- ...or the group's declared convention disagrees with its own log. The alarm
   -- compared totals and currency and never this, so a group holding one
   -- raw_is_total=false event and one raw_is_total=true event -- the state the
   -- header calls IRRECONCILABLE -- reported nothing at all.
   -- ...or the group dipped further negative than its clearings can account for.
   --
   -- THE FIRST VERSION OF THIS ALARM WENT SILENT AT THE MOMENT THE MONEY WAS HIDDEN.
   -- It compared `bloodless_decreases > increases`, which is true in the precursor
   -- state -- two reversals against one authorization -- and FALSE the instant the
   -- next genuine incremental is absorbed by the residue, because that increase
   -- raises `increases` by exactly the amount it swallowed. The guard was defeated
   -- by the event it exists to protect against, and could only ever report the
   -- state where the money was not yet lost.
   --
   -- low_water_minor is written only as `LEAST(low_water_minor, ...)`, so it is
   -- monotone non-increasing THROUGH THESE FUNCTIONS, and group rows cannot be
   -- deleted. It is NOT unerasable: the app role holds UPDATE on this table --
   -- granted so record_auth_event can maintain it -- and one statement sets both
   -- low_water_minor and overcaptured_at back to a clean state with drift silent,
   -- because drift reads neither column. An earlier version of this comment said
   -- "it cannot be erased", which is true of the code and false of the table.
   -- It is also ORDER-DEPENDENT: across 720 permutations of one six-message set,
   -- total_minor, authorized_minor and held_minor each took ONE value and
   -- low_water_minor took TWELVE -- which is the mechanical reason the latching
   -- alarm attempted here false-positived on permutation 4,3,2,1. A dip below what clearings explain
   -- LATCHES. A genuine over-capture (a $1 authorization clearing at $95: low water
   -- -9400 against 9500 cleared) does not fire, and an out-of-order clearing that
   -- lands before its authorization does not either, because that dip never
   -- exceeds what the clearing itself accounts for.
   --
   -- AND IT SELF-HEALS, WHICH IS A REAL LIMIT AND NOT A FIXABLE ONE. The instant a
   -- genuine incremental is absorbed by the residue, `increases` rises by exactly
   -- the amount swallowed and this predicate goes false. A reviewer reported that
   -- as an under-reservation: 100.00 live, 0.00 held, drift silent.
   --
   -- I tried to latch it on low_water_minor -- monotone, unerasable -- comparing
   -- the dip against what clearings could explain. That FALSE-POSITIVES on the
   -- central claim of this whole design: a group whose messages arrive
   -- decrease-first dips below any clearing that has landed yet, which is exactly
   -- the order tolerance the file exists to provide. `tests/card_holds.sql`
   -- permutation 4,3,2,1 catches it immediately.
   --
   -- The reason no predicate works is that THE LOG CANNOT DECIDE THE QUESTION. A
   -- reversal that arrives before its authorization and a reversal that should
   -- never have been sent are the same three columns. Deciding it needs the
   -- processor's own reversal-to-authorization linkage, which this design
   -- deliberately does not model -- 0010 argues that grouping is a revisable
   -- inference precisely because that linkage is unreliable. So the alarm reports
   -- the precursor state, `low_water_minor` keeps the durable evidence that the
   -- group was ever there, and the ambiguity is recorded in ADR-0010 rather than
   -- papered over with a guard that would fire on honest traffic.
   --
   -- AND A CLEARING BLINDED IT COMPLETELY. `total_minor` is
   -- `increases - cleared - bloodless`, so a group can sit BELOW ZERO from a
   -- bloodless reversal while `bloodless <= increases` -- and then the predicate
   -- above never fires, not in the precursor state and not after. Measured:
   -- authorization 100.00, clearing 100.00 (which POSTS), spurious reversal
   -- 100.00, then a genuine incremental 100.00. True exposure 200.00 (100 posted +
   -- 100 un-cleared), reported 100.00, drift 0 rows at every step. Scaled three
   -- times over: 300.00 under-reserved, and the hidden residue is bounded only by
   -- the group's cleared amount.
   --
   -- That falsifies the precise restatement ADR-0010 wrote to close the declined
   -- over-capture report -- "an over-capture never makes held_for_company smaller
   -- than the un-cleared exposure of that group" -- in a state the system itself
   -- flags as an over-capture.
   --
   -- ONE DISJUNCT, NOT TWO. The first version compared `bloodless_decreases >
   -- increases`; the replacement is strictly stronger, because within a row where
   -- the stored total agrees with the log `total = increases - cleared - bloodless`
   -- with `cleared, increases, bloodless >= 0`, so `bloodless > increases` forces
   -- `total < -cleared <= 0` and `bloodless > 0` -- and where the stored total does
   -- NOT agree with the log the first disjunct of this WHERE has already fired. The
   -- weaker one was kept for a round as documentation of intent and was dead code:
   -- two independent reviews confirmed it, one algebraically and one by brute force
   -- over 226,981 (increases, cleared, bloodless) triples with zero counterexamples,
   -- and deleting it changes no row this view emits. The intent is this comment.
   -- The genuine $1-authorization-clearing-at-$95 over-capture still does not fire,
   -- because it has no bloodless decrease at all; a FULLY reversed authorization
   -- sits at exactly zero and does not fire either, which is why the comparison is
   -- strict.
   OR (g.total_minor < 0 AND l.bloodless_decreases > 0)
   OR (l.any_total AND l.any_delta)
   OR g.total_convention IS DISTINCT FROM
        (CASE WHEN l.any_total AND l.any_delta THEN g.total_convention
              WHEN l.any_total THEN 'total'
              WHEN l.any_delta THEN 'delta' END);

-- ...and once more, for the foreign keys this migration created. Every migration
-- that adds an FK must repeat this, or that FK is skipped on the replication apply
-- path -- which is how a whole balanced sub-book was deleted with every report
-- still green (ADR-0011).
-- The hold alarms, for the same reason 0001 grants its own: an operator role that
-- cannot read card_hold_drift or the unmatched queue cannot act on either.
GRANT SELECT ON card_hold_drift, card_auth_unmatched TO openledger_app;
GRANT SELECT ON card_auth_events, card_auth_event_group, card_hold_groups TO openledger_app;
-- ...and the DML the ingest functions perform on the caller's behalf. The app role
-- could not call record_auth_event AT ALL -- `permission denied for table
-- card_hold_groups` from inside the function -- because 0003 granted SELECT only
-- and the functions are not SECURITY DEFINER. 0001 establishes openledger_app as
-- THE application role and hunts dead grants ("0001's GRANT INSERT ON
-- ledger_accounts was dead"); this was the same defect one migration later, and
-- the alternative was a card adapter running as the table owner.
--
-- No UPDATE or DELETE on card_auth_events: it is an event log, and its
-- immutability trigger refuses both anyway. UPDATE on card_auth_event_group is
-- what supersede needs; there is no DELETE, and no TRUNCATE anywhere.
-- UPDATE on the event log is granted ONLY so the role can take a row lock:
-- Postgres requires it for every `SELECT ... FOR` locking clause, including
-- FOR KEY SHARE, and regroup_auth_event locks the event first on purpose -- that
-- ordering is what stopped a matcher and an operator deadlocking over the same
-- event. The grant does not make the log mutable: ck_auth_events__immutable is
-- ENABLE ALWAYS and refuses every UPDATE and DELETE whoever issues it, which the
-- controls in tests/card_holds.sql assert for this role specifically. The
-- privilege is the lock; the trigger is the immutability.
GRANT INSERT, UPDATE ON card_auth_events      TO openledger_app;
GRANT INSERT, UPDATE ON card_auth_event_group TO openledger_app;
GRANT INSERT, UPDATE ON card_hold_groups      TO openledger_app;

CALL enforce_triggers_on_replicas();

COMMIT;
