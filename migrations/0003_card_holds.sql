-- 0003 — authorization holds as an append-only event log.
--
-- v3. Supersedes spikes/006-append-only-holds/holds.sql, whose mixed delta/absolute
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
    CONSTRAINT ck_auth_events__sign CHECK (
        kind IN ('advice','expiry_reversal') OR
        (kind IN ('authorization','incremental') AND amount_delta > 0) OR
        (kind IN ('reversal','clearing','expiry')  AND amount_delta < 0))
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
    event_id     uuid NOT NULL,
    group_key    text NOT NULL,
    method       text NOT NULL CHECK (method IN ('lifecycle_id','rrn','fuzzy','manual')),
    assigned_at  timestamptz NOT NULL DEFAULT now(),
    assigned_by  text NOT NULL,
    superseded_at timestamptz,           -- NULL = the current assignment
    CONSTRAINT pk_event_group PRIMARY KEY (tenant_id, event_id, assigned_at),
    CONSTRAINT fk_event_group__event FOREIGN KEY (tenant_id, event_id)
        REFERENCES card_auth_events (tenant_id, id)
);

-- exactly one live assignment per event
CREATE UNIQUE INDEX uq_event_group__current
    ON card_auth_event_group (tenant_id, event_id) WHERE superseded_at IS NULL;
CREATE INDEX ix_event_group__group
    ON card_auth_event_group (tenant_id, group_key) WHERE superseded_at IS NULL;

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
    total_minor bigint NOT NULL DEFAULT 0,
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
DECLARE v_delta bigint; v_current bigint; v_event uuid;
BEGIN
    IF p_group IS NOT NULL THEN
        -- Serialise the group. Converting a cumulative total into a delta requires
        -- reading the current total, so it must not race. This is where the
        -- order-dependence lives: at ingest, under a lock, rather than in the
        -- derivation where it could not be controlled.
        INSERT INTO card_hold_groups (tenant_id,company_id,group_key)
        VALUES (p_tenant,p_company,p_group) ON CONFLICT DO NOTHING;
        SELECT total_minor INTO v_current FROM card_hold_groups
         WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group FOR UPDATE;
    END IF;

    -- An absolute total that implies a NEGATIVE delta on an increase-only kind means
    -- it arrived out of order relative to totals already applied. This is not
    -- resolvable from the message alone -- a cumulative total carries no sequence --
    -- so refuse it explicitly rather than guess. v2 guessed, using occurred_at with
    -- an insertion-order tiebreak, and silently UNDER-reserved credit.
    IF p_is_total AND p_group IS NOT NULL
       AND p_kind IN ('authorization','incremental')
       AND p_amount < v_current THEN
        RAISE EXCEPTION
          'out-of-order cumulative total for group %: received % but group is already at %; '
          'route to the review queue rather than applying it',
          p_group, p_amount, v_current
          USING ERRCODE = 'data_exception';
    END IF;

    v_delta := CASE
        WHEN p_is_total AND p_group IS NOT NULL THEN p_amount - v_current
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
           open_events  = open_events + 1,
           last_event_seq = last_event_seq + 1,
           -- over-capture becomes a RECORDED state, not a value the clamp swallows
           overcaptured_at = CASE WHEN total_minor + v_delta < 0 AND overcaptured_at IS NULL
                                  THEN now() ELSE overcaptured_at END,
           updated_at   = now()
     WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group
    RETURNING total_minor INTO v_current;
    RETURN v_current;
END $$;

-- Expiry is a flag, never a computed delta (see card_hold_groups.expired_at).
CREATE FUNCTION expire_hold_group(p_tenant text, p_company text, p_group text)
RETURNS void LANGUAGE sql AS $$
    UPDATE card_hold_groups SET expired_at = now(), updated_at = now()
     WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group
       AND expired_at IS NULL;
$$;

-- Rebuild a group's materialised total from its log. Must be a shipped, exercised
-- operation, not a theoretical one -- if it is never run, it does not work.
CREATE FUNCTION recompute_hold_group(p_tenant text, p_group text) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE v_total bigint; v_n int;
BEGIN
    SELECT COALESCE(SUM(e.amount_delta),0), count(*) INTO v_total, v_n
      FROM card_auth_event_group m
      JOIN card_auth_events e ON e.tenant_id=m.tenant_id AND e.id=m.event_id
     WHERE m.tenant_id=p_tenant AND m.group_key=p_group AND m.superseded_at IS NULL;

    UPDATE card_hold_groups
       SET total_minor = v_total, open_events = v_n, updated_at = now(),
           overcaptured_at = CASE WHEN v_total < 0 AND overcaptured_at IS NULL
                                  THEN now() ELSE overcaptured_at END
     WHERE tenant_id=p_tenant AND group_key=p_group;
    RETURN v_total;
END $$;

-- Re-grouping: the corrective operation the spec's unmatched queue requires.
-- Supersedes rather than updates, so the trail survives.
CREATE FUNCTION regroup_auth_event(
    p_tenant text, p_event uuid, p_new_group text, p_by text, p_method text DEFAULT 'manual')
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_old text;
BEGIN
    SELECT group_key INTO v_old FROM card_auth_event_group
     WHERE tenant_id=p_tenant AND event_id=p_event AND superseded_at IS NULL;

    UPDATE card_auth_event_group SET superseded_at = now()
     WHERE tenant_id=p_tenant AND event_id=p_event AND superseded_at IS NULL;
    INSERT INTO card_auth_event_group (tenant_id,event_id,group_key,method,assigned_by)
    VALUES (p_tenant,p_event,p_new_group,p_method,p_by);

    -- Recompute BOTH affected groups from their events. Without this the
    -- materialised total silently disagrees with the log -- caught by
    -- card_hold_drift the first time it was tried.
    PERFORM recompute_hold_group(p_tenant, g) FROM (SELECT unnest(ARRAY[v_old, p_new_group]) g) x
     WHERE g IS NOT NULL;
END $$;

-- held is now an indexed sum over GROUPS, not over events.
CREATE FUNCTION held_for_company(p_tenant text, p_company text) RETURNS bigint
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(held_minor),0)::bigint FROM card_hold_groups
     WHERE tenant_id = p_tenant AND company_id = p_company AND held_minor > 0;
$$;

-- The alarm: the materialised total must always equal the sum of its events.
CREATE VIEW card_hold_drift AS
SELECT g.tenant_id, g.company_id, g.group_key, g.total_minor AS stored,
       COALESCE(SUM(e.amount_delta),0) AS recomputed
FROM card_hold_groups g
LEFT JOIN card_auth_event_group m ON m.tenant_id=g.tenant_id
     AND m.group_key=g.group_key AND m.superseded_at IS NULL
LEFT JOIN card_auth_events e ON e.tenant_id=m.tenant_id AND e.id=m.event_id
GROUP BY g.tenant_id, g.company_id, g.group_key, g.total_minor
HAVING g.total_minor <> COALESCE(SUM(e.amount_delta),0);

COMMIT;
