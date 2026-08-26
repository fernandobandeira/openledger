-- 0003 — authorization holds as an append-only event log.
--
-- v7. Supersedes spikes/006-append-only-holds/holds.sql, whose mixed delta/absolute
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
        (kind = 'expiry_reversal' AND amount_delta > 0) OR
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
    method       text NOT NULL CHECK (method IN ('lifecycle_id','rrn','fuzzy','manual')),
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
    PRIMARY KEY (tenant_id, delivery_id)
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
    currency    char(3) NOT NULL,
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
    total_convention text CHECK (total_convention IN ('delta','total')),
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
    -- last_event_seq AT THE MOMENT OF EXPIRY. The drift alarm compared
    -- `assigned_at > expired_at`, and both are now() -- TRANSACTION start time.
    -- That is the very lesson this file cites for replacing the (event_id,
    -- assigned_at) primary key, reused as the alarm's discriminator: any writer
    -- whose transaction opened before the release timer fired added exposure the
    -- clamp hid and the alarm could not see. This counter only advances under the
    -- group's row lock, so it cannot be defeated by a stale snapshot.
    expired_at_seq bigint,
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
        v_conv text; v_incoming text; v_increases boolean;
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
        IF v_increases AND v_conv IS NOT NULL AND v_conv <> v_incoming THEN
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

    -- DEDUP, AND THE RE-DELIVERY ATTACH -- placed after the ATTACH guards
    -- and before the out-of-order guard.
    --
    -- This block used to sit before all of them and consult none of them, and it is
    -- the only path that attaches an event to a group. Three under-reservations
    -- came out of that one placement: a EUR event joined a USD group (the vacuity
    -- 0002 removed, restored), a delta joined a totals group and poisoned its
    -- subtotal permanently, and an expiry_reversal -- the message whose entire
    -- meaning is "your release was premature" -- attached to an EXPIRED group and
    -- was swallowed by the clamp, 200.00 held and 0.00 reported, with the event
    -- gone from the unmatched queue too.
    --
    -- It must still precede the OUT-OF-ORDER guard: a retried cumulative total is
    -- by construction lower than the subtotal the group has already reached, so it
    -- looks exactly like an out-of-order message. A retry is not new information
    -- and must be a no-op, not a refusal.
    -- The event's OWN company, not the caller's. Dedup keys on
    -- (tenant, processor_msg_id) alone, so a re-delivery arriving under a
    -- different company_id attached the event and recomputed under the CALLER's
    -- company -- while recompute filters the log on the EVENT's. 800.00 vanished
    -- from held_for_company AND from the unmatched queue at once.
    SELECT id, company_id INTO v_event, v_evt_company FROM card_auth_events
     WHERE tenant_id = p_tenant AND processor_msg_id = p_msg_id;
    IF v_event IS NOT NULL THEN
        IF v_evt_company IS DISTINCT FROM p_company THEN
            RAISE EXCEPTION
              'message % already exists for company %, but was re-delivered for %; '
              'route to the review queue', p_msg_id, v_evt_company, p_company
              USING ERRCODE = 'data_exception';
        END IF;
        IF p_group IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM card_auth_event_group m
                            WHERE m.tenant_id = p_tenant AND m.event_id = v_event
                              AND m.superseded_at IS NULL) THEN
            INSERT INTO card_auth_event_group (tenant_id,event_id,group_key,method,assigned_by)
            VALUES (p_tenant, v_event, p_group, p_method, 'ingest:redelivery');
            -- an increase-side attach re-opens, exactly as a fresh one does
            IF p_kind IN ('authorization','incremental','advice','expiry_reversal') THEN
                UPDATE card_hold_groups
                   SET expired_at = NULL, expired_at_seq = NULL, expired_authorized = NULL,
                       expired_total = NULL
                 WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group;
            END IF;
            PERFORM recompute_hold_group(p_tenant, p_company, p_group);
        END IF;
        SELECT total_minor INTO v_current FROM card_hold_groups
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
        WHEN p_kind IN ('advice','expiry_reversal')     THEN p_amount
        ELSE -abs(p_amount) END;

    INSERT INTO card_auth_events (tenant_id,processor_msg_id,company_id,card_id,kind,
           amount_delta,currency,raw_amount,raw_is_total,raw,occurred_at)
    VALUES (p_tenant,p_msg_id,p_company,p_card,p_kind,
            v_delta,p_currency,p_amount,p_is_total,p_raw,p_occurred)
    ON CONFLICT (tenant_id, processor_msg_id) DO NOTHING
    RETURNING id INTO v_event;

    IF v_event IS NULL THEN RETURN COALESCE(v_current,0); END IF;  -- duplicate

    IF p_group IS NULL THEN RETURN 0; END IF;   -- unmatched queue; contributes nothing

    INSERT INTO card_auth_event_group (tenant_id,event_id,group_key,method,assigned_by)
    VALUES (p_tenant,v_event,p_group,p_method,'ingest');

    UPDATE card_hold_groups
       SET total_minor  = total_minor + v_delta,
           -- only increase-side messages move the authorized subtotal
           authorized_minor = authorized_minor
               + CASE WHEN p_kind IN ('authorization','incremental','advice')
                      THEN GREATEST(v_delta, 0) ELSE 0 END,
           low_water_minor = LEAST(low_water_minor, total_minor + v_delta),
           -- A new authorization or increment on an EXPIRED group means our
           -- release was premature -- the hold is live again. expired_at was a
           -- one-way latch that nothing ever cleared, so every event after an
           -- expiry was silently voided: 300.00 genuinely held, reported as 0.00,
           -- with zero drift. A late CLEARING must NOT resurrect it, so only the
           -- increase side un-expires.
           -- The un-expire list and the increase-side list must be the SAME list.
           -- `advice` was in v_increases, set the convention and moved
           -- authorized_minor -- but was missing here, so an advice after expiry
           -- added 350.00 of exposure that held_for_company reported as 0, while
           -- record_auth_event returned 35000 to its own caller. The two numbers an
           -- adapter might use disagreed by the entire exposure.
           -- A cumulative total restating "300.00 is still authorized" yields a
           -- delta of ZERO when it repeats the current subtotal -- and the file
           -- calls that a routine re-delivery. Keyed on the delta, an increase-side
           -- message explicitly asserting the hold is live left the group released:
           -- hotel guest extends, our timer already fired, 300.00 handed back.
           -- The restatement is the signal; the delta is not.
           expired_at = CASE WHEN p_kind IN ('authorization','incremental','advice',
                                             'expiry_reversal')
                                  AND (v_delta > 0 OR p_is_total)
                             THEN NULL ELSE expired_at END,
           expired_at_seq = CASE WHEN p_kind IN ('authorization','incremental','advice',
                                                 'expiry_reversal')
                                      AND (v_delta > 0 OR p_is_total)
                                 THEN NULL ELSE expired_at_seq END,
           expired_authorized = CASE WHEN p_kind IN ('authorization','incremental','advice',
                                                     'expiry_reversal')
                                          AND v_delta > 0
                                     THEN NULL ELSE expired_authorized END,
           -- v_increases, not a second copy of the predicate. Written out
           -- separately, this line still let a $0.00 advice fix the convention
           -- after the guard above had been taught not to -- the two must be the
           -- same test or the guard is decorative.
           total_convention = COALESCE(total_convention,
               CASE WHEN v_increases
                    THEN CASE WHEN p_is_total THEN 'total' ELSE 'delta' END END),
           open_events  = open_events + 1,
           last_event_seq = last_event_seq + 1,
           -- Over-capture becomes a RECORDED state, not a value the clamp swallows.
           -- It must NOT latch: the SUM is order-tolerant, so a group whose events
           -- arrive out of order can dip negative in passing. A latching flag turns
           -- every such delivery into a spurious over-capture alarm. The flag
           -- describes the CURRENT total, and a transient dip therefore self-heals.
           overcaptured_at = CASE WHEN total_minor + v_delta < 0
                                  THEN COALESCE(overcaptured_at, now()) END,
           updated_at   = now()
     WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group
    RETURNING total_minor INTO v_current;
    RETURN v_current;
END $$;

-- Expiry is a flag, never a computed delta (see card_hold_groups.expired_at).
-- It is NOT terminal: a later authorization or increment on the same group clears
-- it, because that means the release was premature.
CREATE FUNCTION expire_hold_group(p_tenant text, p_company text, p_group text)
RETURNS void LANGUAGE sql AS $$
    UPDATE card_hold_groups
       SET expired_at = now(), expired_at_seq = last_event_seq,
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
           count(*)
      INTO v_total, v_auth, v_n
      FROM card_auth_event_group m
      JOIN card_auth_events e ON e.tenant_id=m.tenant_id AND e.id=m.event_id
     WHERE m.tenant_id=p_tenant AND m.group_key=p_group AND m.superseded_at IS NULL
       AND e.company_id = p_company;

    UPDATE card_hold_groups
       SET total_minor = v_total, authorized_minor = v_auth, open_events = v_n,
           low_water_minor = LEAST(low_water_minor, v_total), updated_at = now(),
           overcaptured_at = CASE WHEN v_total < 0
                                  THEN COALESCE(overcaptured_at, now()) END
     WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group;
    RETURN v_total;
END $$;

-- Re-grouping: the corrective operation the spec's unmatched queue requires.
-- Supersedes rather than updates, so the trail survives.
CREATE FUNCTION regroup_auth_event(
    p_tenant text, p_event uuid, p_new_group text, p_by text, p_method text DEFAULT 'manual')
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_old text; v_company text; v_ccy char(3); v_dest card_hold_groups; k text;
BEGIN
    SELECT e.company_id, e.currency INTO v_company, v_ccy
      FROM card_auth_events e WHERE e.tenant_id=p_tenant AND e.id=p_event;
    IF v_company IS NULL THEN
        RAISE EXCEPTION 'no such auth event %', p_event USING ERRCODE='data_exception';
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
RETURNS bigint LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(held_minor),0)::bigint FROM card_hold_groups
     WHERE tenant_id = p_tenant AND company_id = p_company
       AND currency = p_currency AND held_minor > 0;
$$;

-- The alarm: the materialised total must always equal the sum of its events.
--
-- FULL OUTER, not LEFT. Starting from card_hold_groups made the alarm blind to
-- the one failure that actually occurred: live membership rows pointing at a
-- group that was never materialised. `stored IS NULL` is that case, and it is
-- reported rather than skipped.
CREATE VIEW card_hold_drift AS
WITH live AS (
    SELECT m.tenant_id, e.company_id, m.group_key,
           SUM(e.amount_delta) AS recomputed
      FROM card_auth_event_group m
      JOIN card_auth_events e ON e.tenant_id = m.tenant_id AND e.id = m.event_id
     WHERE m.superseded_at IS NULL
     GROUP BY m.tenant_id, e.company_id, m.group_key
)
SELECT COALESCE(g.tenant_id,  l.tenant_id)  AS tenant_id,
       COALESCE(g.company_id, l.company_id) AS company_id,
       COALESCE(g.group_key,  l.group_key)  AS group_key,
       g.total_minor          AS stored,      -- NULL = no materialised group
       COALESCE(l.recomputed, 0) AS recomputed
FROM card_hold_groups g
FULL OUTER JOIN live l
  ON  l.tenant_id  = g.tenant_id
  AND l.company_id = g.company_id
  AND l.group_key  = g.group_key
WHERE g.total_minor IS DISTINCT FROM COALESCE(l.recomputed, 0)
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
   -- Exposure added to a group AFTER it was expired. held_minor is GENERATED to 0
   -- once expired_at is set, so anything attached later is invisible to
   -- held_for_company while total_minor and the log still agree -- the two columns
   -- the alarm compares. Keyed on the monotonic counter, not on now().
   OR (g.expired_at IS NOT NULL
       AND (g.authorized_minor > COALESCE(g.expired_authorized, g.authorized_minor)
         OR g.total_minor      > COALESCE(g.expired_total,      g.total_minor)));

COMMIT;
