-- SPIKE ONLY. The ingest path under ADR-0002's rules, so the same scenarios can be
-- driven against the corrected schema. Never product code (ADR-0004).
SET search_path = fixed, public;

CREATE OR REPLACE FUNCTION fixed.ingest_fixed(
        p_tenant text, p_company text, p_card text, p_group text,
        p_msg text, p_kind auth_event_kind, p_wire bigint, p_is_total boolean,
        p_currency char(3) DEFAULT 'USD', p_expires timestamptz DEFAULT NULL,
        p_method text DEFAULT 'lifecycle_id')
RETURNS text LANGUAGE plpgsql SET search_path = fixed, public AS $$
DECLARE
    _i int;
    g card_hold_groups%ROWTYPE; v_delta bigint; v_increase boolean; v_id uuid;
    v_base bigint; v_new_total bigint; v_resid bigint := 0; v_group text := p_group;
    v_mix boolean := false; v_unorder boolean := false; v_live int; v_inc_members int; v_pess bigint; v_note text := '';
BEGIN
  FOR _i IN 1..2 LOOP
    INSERT INTO card_hold_groups (tenant_id, company_id, group_key, currency)
    VALUES (p_tenant, p_company, v_group, p_currency) ON CONFLICT DO NOTHING;
    SELECT * INTO g FROM card_hold_groups
     WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=v_group FOR UPDATE;

    SELECT count(*) INTO v_live FROM card_auth_event_group m
     WHERE m.tenant_id=p_tenant AND m.group_key=v_group AND m.superseded_at IS NULL;

    -- ADR-0002 D7: an EMPTIED group carrying no state that is not a materialisation
    -- is a pure materialisation and may be rewritten, currency included.
    IF g.currency <> p_currency THEN
        IF v_live = 0 AND g.expired_at IS NULL AND g.quarantined_at IS NULL
           AND g.low_water_minor = 0 AND g.unexplained_minor = 0 AND g.overcaptured_at IS NULL THEN
            UPDATE card_hold_groups SET currency=p_currency, total_convention=NULL
             WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=v_group;
            g.currency := p_currency; g.total_convention := NULL;
            v_note := ' [emptied group re-denominated]';
        ELSE
            RETURN 'REFUSED: group currency '||g.currency||' <> '||p_currency;
        END IF;
    END IF;

    v_increase := p_kind IN ('authorization','incremental') OR (p_kind='advice' AND p_wire > 0);

    -- ADR-0002 D1: a FUZZY match may not attach an increase-side message to a group
    -- that already has one. It opens a new group, where a total converts exactly.
    IF v_increase AND p_method='fuzzy' THEN
        SELECT count(*) INTO v_inc_members FROM card_auth_event_group m
          JOIN card_auth_events e ON e.tenant_id=m.tenant_id AND e.id=m.event_id
         WHERE m.tenant_id=p_tenant AND m.group_key=v_group AND m.superseded_at IS NULL
           AND (e.kind IN ('authorization','incremental') OR (e.kind='advice' AND e.amount_delta>0));
        IF v_inc_members > 0 AND v_group = p_group THEN
            v_group := p_group||'#'||p_msg;      -- the matcher mints a surrogate
            v_note := ' [fuzzy increase split to a new group]';
            CONTINUE;
        END IF;
    END IF;
    EXIT;
  END LOOP;

    IF v_increase THEN
        IF p_is_total THEN
            IF g.total_convention = 'delta' THEN v_mix := true; v_delta := 0;
            ELSE
                -- ADR-0002 D3: the base is the authorized subtotal NET of bloodless
                -- decreases, not the increase-only high-water mark.
                v_base  := g.authorized_minor;   -- the gross high-water mark
                v_delta := p_wire - v_base;
                -- D3: we never REFUSE a processor message. A total at or below the
                -- high-water mark is the ordinary out-of-order resolution -- the
                -- maximum total seen wins -- so it is STORED at delta zero rather
                -- than thrown away. It quarantines nothing on its own; the
                -- declarative check below decides whether the group is ambiguous.
                IF v_delta < 0 THEN v_delta := 0; END IF;
            END IF;
        ELSE
            IF g.total_convention = 'total' THEN v_mix := true; v_delta := 0;
            ELSE v_delta := p_wire; END IF;
        END IF;
    ELSE
        v_delta := -abs(p_wire);
    END IF;

    BEGIN
        INSERT INTO card_auth_events (tenant_id, processor_msg_id, company_id, card_id, kind,
              amount_delta, currency, raw_amount, raw_is_total, occurred_at, hold_expires_at)
        VALUES (p_tenant, p_msg, p_company, p_card, p_kind, v_delta, p_currency,
                p_wire, COALESCE(p_is_total,false), now(), p_expires) RETURNING id INTO v_id;
    EXCEPTION WHEN check_violation THEN
        RETURN 'REFUSED: ck_auth_events__sign (delta '||v_delta||' for kind '||p_kind||')';
    END;
    INSERT INTO card_auth_event_group (tenant_id, event_id, group_key, method, assigned_by, base_minor)
    VALUES (p_tenant, v_id, v_group, p_method, 'spike017', CASE WHEN p_is_total THEN v_base END);

    v_new_total := g.total_minor + v_delta;
    -- ADR-0002 D5/D6: a BLOODLESS decrease that drives the group below zero leaves a
    -- residue no later increase may absorb. A CLEARING does not: it posted.
    IF NOT v_increase AND p_kind <> 'clearing' AND v_new_total < 0 THEN
        v_resid := v_new_total - LEAST(g.total_minor, 0);
    END IF;

    UPDATE card_hold_groups SET
        total_minor       = v_new_total,
        authorized_minor  = authorized_minor + CASE WHEN v_increase THEN GREATEST(v_delta,0) ELSE 0 END,
        unexplained_minor = unexplained_minor + v_resid,
        total_convention  = CASE WHEN v_mix THEN total_convention
                                 WHEN v_increase AND p_is_total THEN 'total'
                                 WHEN v_increase THEN 'delta' ELSE total_convention END,
        last_event_seq    = last_event_seq + 1,
        low_water_minor   = LEAST(low_water_minor, v_new_total),
        overcaptured_at   = COALESCE(overcaptured_at, CASE WHEN v_new_total < 0 THEN now() END),
        quarantined_at    = COALESCE(quarantined_at,
                              CASE WHEN v_mix OR v_resid < 0 THEN now() END),
        quarantine_reason = COALESCE(quarantine_reason,
                              CASE WHEN v_mix THEN 'convention_mix'
                                   WHEN v_resid < 0 THEN 'unexplained_residue' END),
        expired_at         = CASE WHEN v_increase THEN NULL ELSE expired_at END,
        expired_authorized = CASE WHEN v_increase THEN NULL ELSE expired_authorized END,
        expired_total      = CASE WHEN v_increase THEN NULL ELSE expired_total END,
        updated_at = now()
     WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=v_group;

    -- D3, the declarative half. A TOTALS group holding both a bloodless decrease
    -- and a restatement is unresolvable in EVERY arrival order: a cumulative total
    -- already nets the reversal, and nothing on the wire says whether this total is
    -- before or after it. Detected from the live log, so it fires in every order.
    UPDATE card_hold_groups hg SET quarantined_at = COALESCE(hg.quarantined_at, now()),
           quarantine_reason = COALESCE(hg.quarantine_reason, 'unorderable_total')
     WHERE hg.tenant_id=p_tenant AND hg.company_id=p_company AND hg.group_key=v_group
       AND hg.total_convention = 'total'
       AND (SELECT count(*) FILTER (WHERE e.raw_is_total AND e.kind IN ('authorization','incremental')) > 1
                 AND COALESCE(-SUM(e.amount_delta) FILTER (WHERE e.amount_delta<0 AND e.kind<>'clearing'),0) > 0
              FROM card_auth_event_group m JOIN card_auth_events e
                ON e.tenant_id=m.tenant_id AND e.id=m.event_id
             WHERE m.tenant_id=hg.tenant_id AND m.group_key=hg.group_key AND m.superseded_at IS NULL);

    -- The quarantine hold: the LARGEST reading the log admits, so a group we cannot
    -- compute OVER-reserves rather than under-reserves. Recomputed on every event.
    SELECT CASE
             WHEN g2.quarantine_reason = 'convention_mix' THEN
               -- every increase read as a delta (ADR-0001's own 220.00 reading)
               COALESCE(SUM(GREATEST(e.raw_amount,0)) FILTER (WHERE e.kind IN ('authorization','incremental')),0)
             - COALESCE(-SUM(e.amount_delta) FILTER (WHERE e.amount_delta < 0),0)
             WHEN g2.quarantine_reason = 'unorderable_total' THEN
               -- the largest cumulative total ever restated, with no decrease netted
               COALESCE(MAX(e.raw_amount) FILTER (WHERE e.kind IN ('authorization','incremental')),0)
             ELSE NULL END
      INTO v_pess
      FROM card_hold_groups g2
      LEFT JOIN card_auth_event_group m ON m.tenant_id=g2.tenant_id AND m.group_key=g2.group_key AND m.superseded_at IS NULL
      LEFT JOIN card_auth_events e ON e.tenant_id=m.tenant_id AND e.id=m.event_id
     WHERE g2.tenant_id=p_tenant AND g2.company_id=p_company AND g2.group_key=v_group
       AND g2.quarantined_at IS NOT NULL
     GROUP BY g2.quarantine_reason;
    IF v_pess IS NOT NULL THEN
        UPDATE card_hold_groups SET quarantine_hold_minor = GREATEST(v_pess,0)
         WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=v_group;
    END IF;
    RETURN 'ok group='||v_group||' delta='||v_delta
           ||CASE WHEN v_resid<0 THEN ' residue='||v_resid ELSE '' END
           ||CASE WHEN v_mix THEN ' QUARANTINED(convention_mix)' ELSE '' END
           ||CASE WHEN (SELECT quarantine_reason FROM card_hold_groups
                         WHERE tenant_id=p_tenant AND company_id=p_company AND group_key=v_group)
                       = 'unorderable_total' THEN ' QUARANTINED(unorderable_total)' ELSE '' END || v_note;
END $$;

-- ADR-0002 D2: the sweep keys on the group's LATEST live deadline, never on the
-- existence of any past-due event.
CREATE OR REPLACE FUNCTION fixed.sweep_fixed(p_group text DEFAULT NULL) RETURNS int LANGUAGE sql AS $$
    WITH d AS (
        UPDATE card_hold_groups g SET expired_at=now(),
               expired_authorized=g.authorized_minor, expired_total=g.total_minor
         WHERE g.expired_at IS NULL AND g.held_minor > 0 AND g.quarantined_at IS NULL
           AND (p_group IS NULL OR g.group_key = p_group)
           AND (SELECT max(e.hold_expires_at) FROM card_auth_event_group m
                  JOIN card_auth_events e ON e.tenant_id=m.tenant_id AND e.id=m.event_id
                 WHERE m.tenant_id=g.tenant_id AND m.group_key=g.group_key
                   AND m.superseded_at IS NULL) < now()
        RETURNING 1) SELECT count(*)::int FROM d;
$$;

CREATE OR REPLACE FUNCTION fixed.reset_all() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    ALTER TABLE fixed.card_auth_events DISABLE TRIGGER ck_auth_events__append_only;
    DELETE FROM fixed.card_auth_event_group; DELETE FROM fixed.card_auth_events;
    DELETE FROM fixed.card_hold_groups;
    ALTER TABLE fixed.card_auth_events ENABLE ALWAYS TRIGGER ck_auth_events__append_only;
END $$;
