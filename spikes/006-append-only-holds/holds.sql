-- Spike 006 — holds as an append-only event log, mirroring the ledger itself.
--
-- The current design has ONE mutable row per authorization: amount_minor set at
-- auth, cleared_minor UPDATEd as clearings arrive, state UPDATEd on expiry. That
-- contradicts the append-only ethos everywhere else, loses history, and breaks
-- outright on incremental authorizations because auth_id is UNIQUE.
--
-- Here every authorization event is an immutable row with a SIGNED delta, and the
-- held amount is derived.

BEGIN;

CREATE TYPE auth_event_kind AS ENUM (
    'authorization',  -- the original: +amount
    'incremental',    -- hotel/fuel top-up: +amount
    'reversal',       -- merchant voided: -amount
    'clearing',       -- merchant captured: -amount
    'expiry'          -- timer fired, nothing captured: -remaining
);

CREATE TABLE card_auth_events (
    id           uuid PRIMARY KEY DEFAULT uuidv7(),
    tenant_id    text NOT NULL,
    -- IDEMPOTENCY: one row per processor message. A redelivered webhook is
    -- rejected by the database, not by application logic.
    event_id     text NOT NULL,
    -- GROUPING: ties an original authorization to its increments, reversals and
    -- clearings. Which network/processor field this is, is spike 006's open
    -- question -- see README.
    group_key    text NOT NULL,
    company_id   text NOT NULL,
    card_id      text NOT NULL,
    kind         auth_event_kind NOT NULL,
    -- SIGNED. authorization/incremental add; reversal/clearing/expiry subtract.
    amount_delta bigint NOT NULL,
    recorded_at  timestamptz NOT NULL DEFAULT now(),
    -- only meaningful on the original; the group's expiry timer target
    expires_at   timestamptz,

    CONSTRAINT ck_auth_events__sign CHECK (
        (kind IN ('authorization','incremental') AND amount_delta > 0) OR
        (kind IN ('reversal','clearing','expiry') AND amount_delta < 0)
    )
);

-- the whole idempotency story, as a constraint
CREATE UNIQUE INDEX uq_auth_events__event ON card_auth_events (tenant_id, event_id);
CREATE INDEX ix_auth_events__group ON card_auth_events (company_id, group_key);

-- THE derived state. One formula for every case in the spec's edge-case table.
--
--   group_total = SUM(amount_delta)          -- what this auth still reserves
--   held        = SUM(GREATEST(total, 0))    -- clamped, then summed
--
-- GREATEST is what makes over-capture safe: a $1 fuel auth cleared at $95 gives
-- -94, which must contribute 0 rather than silently RAISING available credit.
CREATE OR REPLACE VIEW card_holds_derived AS
SELECT company_id, card_id, group_key,
       SUM(amount_delta)                    AS group_total,
       GREATEST(SUM(amount_delta), 0)       AS still_held,
       MIN(recorded_at)                     AS opened_at,
       MAX(expires_at)                      AS expires_at,
       count(*)                             AS events
FROM card_auth_events
GROUP BY company_id, card_id, group_key;

CREATE OR REPLACE FUNCTION held_for_company(p_company text) RETURNS bigint
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(still_held), 0)::bigint
    FROM card_holds_derived WHERE company_id = p_company;
$$;

COMMIT;
