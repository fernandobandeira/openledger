-- Spike 017 -- harness. SPIKE ONLY: this is evidence machinery, never product code.
-- ADR-0004 puts the ledger in Rust; nothing here is proposed for the schema.
--
-- The card writer does not exist (ADR-0001's header says so). To reproduce a
-- finding in the ingest path you first have to HAVE an ingest path, so these
-- functions re-implement the rules ADR-0001 and parked/card/schema.sql state, as
-- literally as prose allows. Every rule below cites where it comes from.

SET search_path = public;

-- ---------------------------------------------------------------- current rules
CREATE OR REPLACE FUNCTION ingest_current(
        p_tenant text, p_company text, p_card text, p_group text,
        p_msg text, p_kind auth_event_kind, p_wire bigint, p_is_total boolean,
        p_currency char(3) DEFAULT 'USD', p_expires timestamptz DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    g          card_hold_groups%ROWTYPE;
    v_delta    bigint;
    v_increase boolean;
    v_id       uuid;
BEGIN
    -- the group's lock; the row is created on first sight, currency fixed there
    INSERT INTO card_hold_groups (tenant_id, company_id, group_key, currency)
    VALUES (p_tenant, p_company, p_group, p_currency)
    ON CONFLICT DO NOTHING;
    SELECT * INTO g FROM card_hold_groups
     WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group FOR UPDATE;

    IF g.currency <> p_currency THEN
        RETURN 'REFUSED: group currency '||g.currency||' <> '||p_currency;   -- ADR-0001 "one currency, no default"
    END IF;

    v_increase := p_kind IN ('authorization','incremental')
               OR (p_kind = 'advice' AND p_wire > 0);

    IF v_increase THEN
        IF p_is_total THEN
            IF g.total_convention = 'delta' THEN
                RETURN 'REFUSED: convention mix (total into a delta group)';  -- ADR-0001 "mixing is refused"
            END IF;
            -- the conversion. base = authorized_minor, the increase-only high-water mark.
            v_delta := p_wire - g.authorized_minor;
            UPDATE card_hold_groups SET total_convention='total'
             WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group;
        ELSE
            IF g.total_convention = 'total' THEN
                RETURN 'REFUSED: convention mix (delta into a totals group)';
            END IF;
            v_delta := p_wire;
            UPDATE card_hold_groups SET total_convention='delta'
             WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group;
        END IF;
    ELSIF p_kind = 'expiry_reversal' THEN
        v_delta := 0;                       -- pinned to zero by ck_auth_events__sign
    ELSE
        v_delta := -abs(p_wire);            -- clearing / reversal / negative advice
    END IF;

    BEGIN
        INSERT INTO card_auth_events (tenant_id, processor_msg_id, company_id, card_id, kind,
                                      amount_delta, currency, raw_amount, raw_is_total,
                                      occurred_at, hold_expires_at)
        VALUES (p_tenant, p_msg, p_company, p_card, p_kind, v_delta, p_currency,
                p_wire, COALESCE(p_is_total,false), now(), p_expires)
        RETURNING id INTO v_id;
    EXCEPTION WHEN check_violation THEN
        RETURN 'REFUSED: ck_auth_events__sign (delta '||v_delta||' for kind '||p_kind||')';
    END;

    INSERT INTO card_auth_event_group (tenant_id, event_id, group_key, method, assigned_by)
    VALUES (p_tenant, v_id, p_group, 'fuzzy', 'spike017');

    UPDATE card_hold_groups SET
        total_minor      = total_minor + v_delta,
        authorized_minor = authorized_minor + CASE WHEN v_increase THEN GREATEST(v_delta,0) ELSE 0 END,
        last_event_seq   = last_event_seq + 1,
        low_water_minor  = LEAST(low_water_minor, total_minor + v_delta),
        -- NON-LATCHING, exactly as the schema comment says it is
        overcaptured_at  = CASE WHEN total_minor + v_delta < 0 THEN now() ELSE NULL END,
        -- "An expired group re-opens on any increase-side message"; expiry_reversal
        -- clears the flag (ADR-0001 property 3)
        expired_at         = CASE WHEN v_increase OR p_kind='expiry_reversal' THEN NULL ELSE expired_at END,
        expired_authorized = CASE WHEN v_increase OR p_kind='expiry_reversal' THEN NULL ELSE expired_authorized END,
        expired_total      = CASE WHEN v_increase OR p_kind='expiry_reversal' THEN NULL ELSE expired_total END,
        updated_at         = now()
     WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=p_group;
    RETURN 'ok delta='||v_delta;
END $$;

-- ADR-0001's reconciliation sweep, as written in the ADR: EXISTS(any past-due event).
CREATE OR REPLACE FUNCTION sweep_current() RETURNS int LANGUAGE sql AS $$
    WITH d AS (
        UPDATE card_hold_groups g SET expired_at=now(),
               expired_authorized=g.authorized_minor, expired_total=g.total_minor
         WHERE g.expired_at IS NULL AND g.held_minor > 0
           AND EXISTS (SELECT 1 FROM card_auth_event_group m
                       JOIN card_auth_events e ON e.tenant_id=m.tenant_id AND e.id=m.event_id
                       WHERE m.tenant_id=g.tenant_id AND m.group_key=g.group_key
                         AND m.superseded_at IS NULL AND e.hold_expires_at < now())
        RETURNING 1) SELECT count(*)::int FROM d;
$$;

-- What a re-aggregation from the WIRE values can still see. Deliberately NOT
-- called "true exposure": in finding 1 the log has already lost the money, so no
-- function over the log can report the truth. Every scenario below therefore
-- states its ground truth as a literal, from the scenario definition.
CREATE OR REPLACE FUNCTION log_derivable_exposure(p_tenant text, p_company text, p_group text)
RETURNS bigint LANGUAGE sql AS $$
    SELECT COALESCE(SUM(e.amount_delta), 0)
      FROM card_auth_event_group m
      JOIN card_auth_events e ON e.tenant_id=m.tenant_id AND e.id=m.event_id
     WHERE m.tenant_id=p_tenant AND m.group_key=p_group AND m.superseded_at IS NULL
       AND e.company_id=p_company;
$$;

CREATE OR REPLACE FUNCTION reset_all() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    ALTER TABLE card_auth_events DISABLE TRIGGER ck_auth_events__append_only;
    DELETE FROM card_auth_event_group; DELETE FROM card_auth_events; DELETE FROM card_hold_groups;
    ALTER TABLE card_auth_events ENABLE ALWAYS TRIGGER ck_auth_events__append_only;
END $$;
