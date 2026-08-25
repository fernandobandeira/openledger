-- 0003 — authorization holds as an append-only event log.
--
-- v5. Supersedes spikes/006-append-only-holds/holds.sql, whose mixed delta/absolute
-- view was broken in four ways by adversarial review — one of them silently
-- UNDER-reserving credit, which is the worst failure available here.
--
-- THE ROOT CAUSE was mixing two conventions in the derivation. Six of eleven
-- processors report an incremental authorization as a cumulative TOTAL rather than
-- a delta. v2 stored both and resolved absolutes by `occurred_at` — but processors
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
        (kind IN ('reversal','clearing','expiry')  AND amount_delta <= 0))
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
-- 1500ms real-time-decisioning budget, deriving it on read was measured at 1131ms
-- on two years of history. This is the design, not a contingency.
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
        v_event uuid; v_ccy char(3); v_expired timestamptz;
        v_conv text; v_incoming text; v_increases boolean;
BEGIN
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

        -- DEDUP BEFORE VALIDATING. A processor retrying the same message id must be
        -- a no-op, and the guards below would otherwise reject it: a re-sent
        -- cumulative total is, by construction, lower than the total the group has
        -- already reached, so it looks exactly like an out-of-order message.
        PERFORM 1 FROM card_auth_events
         WHERE tenant_id = p_tenant AND processor_msg_id = p_msg_id;
        IF FOUND THEN
            RETURN COALESCE(v_current, 0);
        END IF;

        -- one convention per group, fixed by the first increase-side message
        v_increases := p_kind IN ('authorization','incremental','advice');
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
           expired_at = CASE WHEN p_kind IN ('authorization','incremental','expiry_reversal')
                                  AND v_delta > 0
                             THEN NULL ELSE expired_at END,
           total_convention = COALESCE(total_convention,
               CASE WHEN p_kind IN ('authorization','incremental','advice')
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
    UPDATE card_hold_groups SET expired_at = now(), updated_at = now()
     WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group
       AND expired_at IS NULL;
$$;

-- Rebuild a group's materialised total from its log. Must be a shipped, exercised
-- operation, not a theoretical one -- if it is never run, it does not work.
CREATE FUNCTION recompute_hold_group(p_tenant text, p_company text, p_group text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_total bigint; v_auth bigint; v_n int;
BEGIN
    -- Lock FIRST. This function took no lock at all: it read the sum under a READ
    -- COMMITTED snapshot and then blind-wrote it, so a concurrent record_auth_event
    -- that committed in between was erased -- a committed 200.00 incremental
    -- vanished, and the caller had already made an authorization decision on it.
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
DECLARE v_old text; v_company text; v_ccy char(3); v_dest record;
BEGIN
    SELECT e.company_id, e.currency INTO v_company, v_ccy
      FROM card_auth_events e WHERE e.tenant_id=p_tenant AND e.id=p_event;
    IF v_company IS NULL THEN
        RAISE EXCEPTION 'no such auth event %', p_event USING ERRCODE='data_exception';
    END IF;

    -- The destination must be able to accept this event. record_auth_event refuses
    -- a cross-currency join; this function -- the ROUTINE corrective operation --
    -- did not, so moving a USD event into a EUR group produced a total that added
    -- USD minor units to EUR minor units and raised USD available credit by 500.00.
    -- Same vacuity 0002 removed from the accounting equation, through the back door.
    SELECT * INTO v_dest FROM card_hold_groups
     WHERE tenant_id=p_tenant AND company_id=v_company AND group_key=p_new_group
     FOR UPDATE;

    IF FOUND AND v_dest.currency <> v_ccy THEN
        RAISE EXCEPTION
          'cannot move a % event into group %, which holds %; a hold total is only '
          'meaningful in one currency', v_ccy, p_new_group, v_dest.currency
          USING ERRCODE='data_exception';
    END IF;

    -- ...and an EXPIRED group is a released hold. Attaching a live authorization to
    -- one hid 900.00 from held_for_company, from the drift alarm, AND from the
    -- unmatched queue -- the operator's own corrective action made it invisible.
    IF FOUND AND v_dest.expired_at IS NOT NULL THEN
        RAISE EXCEPTION
          'cannot move an event into group %, which expired at %; re-open it or '
          'choose another group', p_new_group, v_dest.expired_at
          USING ERRCODE='data_exception';
    END IF;

    SELECT group_key INTO v_old FROM card_auth_event_group
     WHERE tenant_id=p_tenant AND event_id=p_event AND superseded_at IS NULL;

    UPDATE card_auth_event_group SET superseded_at = now()
     WHERE tenant_id=p_tenant AND event_id=p_event AND superseded_at IS NULL;
    INSERT INTO card_auth_event_group (tenant_id,event_id,group_key,method,assigned_by)
    VALUES (p_tenant,p_event,p_new_group,p_method,p_by);

    -- Materialise the destination if it does not exist yet. Splitting a mis-grouped
    -- event into its OWN group is the routine case, and without this the membership
    -- row existed while the group did not: held_for_company reported 50.00 where
    -- 80.00 was genuinely held. Under-reserving credit is the worst failure
    -- available here, and card_hold_drift could not see it either.
    INSERT INTO card_hold_groups (tenant_id, company_id, group_key, currency)
    VALUES (p_tenant, v_company, p_new_group, v_ccy)
    ON CONFLICT DO NOTHING;

    -- Recompute BOTH affected groups from their events, company-scoped.
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
          AND e.currency <> g.currency);

COMMIT;
