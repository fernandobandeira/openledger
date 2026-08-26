-- Spike 006 — holds as an append-only event log.
--
-- v2. (An earlier version of this line said "after surveying eleven
-- issuer-processors". NO SUCH SURVEY EXISTS -- it was invented, and is struck. This
-- spike surveys three, below, and they disagree; that disagreement is the finding.) Four changes from v1, each forced
-- by something a vendor documents in their own schema.

BEGIN;

CREATE TYPE auth_event_kind AS ENUM (
    'authorization',    -- the original
    'incremental',      -- hotel/fuel top-up
    'advice',           -- Lithic/Marqeta: amount modified, direction not in the type
    'reversal',         -- merchant voided
    'clearing',         -- merchant captured
    'expiry',           -- the processor expired it
    'expiry_reversal'   -- Galileo BEXR. Expiry is NOT terminal.
);

CREATE TABLE card_auth_events (
    id            uuid PRIMARY KEY DEFAULT uuidv7(),
    tenant_id     text NOT NULL,

    -- (1) IDENTITY IS THE PROCESSOR'S MESSAGE OBJECT, NOT THE WEBHOOK DELIVERY.
    -- Marqeta states the distinction: "each transaction is identified by a unique
    -- transaction token, and each webhook is identified by a unique event token."
    -- Stripe warns that ONE occurrence can emit TWO Event objects -- so a unique
    -- constraint on the delivery id would admit the duplicate. This is Marqeta's
    -- transaction token / Increase's element id / Lithic's events[].token.
    processor_msg_id text NOT NULL,

    -- (2) GROUP MAY BE UNKNOWN AT WRITE TIME.
    -- Increase's card_settlement.card_authorization is nullable -- "if one exists"
    -- -- which is the forced-post case. Resolve from the PROCESSOR's authorization
    -- id, never from ARN/RRN/Banknet: Increase says RRN is "expected to be unique
    -- per acquirer within a window of time"; Lithic says a banknet ref of all
    -- zeroes means "no actual reference number could be found".
    group_key     text,

    company_id    text NOT NULL,
    card_id       text NOT NULL,
    kind          auth_event_kind NOT NULL,

    -- (3) PROCESSORS DISAGREE: SOME SEND AN ABSOLUTE TOTAL, SOME A DELTA.
    -- Stripe rewrites `amount` in place; Galileo "presents the cumulative amount";
    -- Synctera sends total_amount; Unit's amountChanged carries no delta at all.
    -- Increase's card_fuel_confirmation has NO amount field -- only
    -- updated_authorization_amount. Exactly one of these is present.
    amount_delta    bigint,   -- normalised: signed, commutative, order-tolerant
    amount_absolute bigint,   -- the group's new TOTAL. Order-DEPENDENT.

    -- raw payload retained so the normalisation above can be audited
    raw           jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at   timestamptz NOT NULL,   -- processor's clock; orders absolutes
    recorded_at   timestamptz NOT NULL DEFAULT now(),
    expires_at    timestamptz,            -- reconciliation aid, NOT a trigger

    CONSTRAINT ck_auth_events__one_amount CHECK (
        (amount_delta IS NOT NULL) <> (amount_absolute IS NOT NULL)),
    -- sign is a property of the kind -- Marqeta says so in prose:
    -- "authorization.incremental: Increases the amount of prior authorization",
    -- "authorization.advice: Decreases the amount of existing authorization".
    -- 'advice' and 'expiry_reversal' are exempt: advice goes either way, and an
    -- expiry reversal is a POSITIVE delta on a release.
    CONSTRAINT ck_auth_events__sign CHECK (
        amount_delta IS NULL OR
        kind IN ('advice','expiry_reversal') OR
        (kind IN ('authorization','incremental') AND amount_delta > 0) OR
        (kind IN ('reversal','clearing','expiry')  AND amount_delta < 0))
);

CREATE UNIQUE INDEX uq_auth_events__msg ON card_auth_events (tenant_id, processor_msg_id);
CREATE INDEX ix_auth_events__group ON card_auth_events (company_id, group_key)
    WHERE group_key IS NOT NULL;
CREATE INDEX ix_auth_events__ungrouped ON card_auth_events (company_id)
    WHERE group_key IS NULL;

-- HTTP-layer dedup, separate concern, no ledger effect.
CREATE TABLE webhook_deliveries (
    tenant_id   text NOT NULL,
    delivery_id text NOT NULL,   -- the `webhook-id` header / Stripe evt_...
    received_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, delivery_id)
);

-- The derived hold. Deltas sum commutatively; an absolute REPLACES everything
-- before it, so absolutes must be ordered by the processor's clock.
CREATE OR REPLACE VIEW card_holds_derived AS
WITH latest_absolute AS (
    SELECT DISTINCT ON (company_id, group_key)
           company_id, group_key, amount_absolute, occurred_at
    FROM card_auth_events
    WHERE amount_absolute IS NOT NULL AND group_key IS NOT NULL
    ORDER BY company_id, group_key, occurred_at DESC, id DESC
)
SELECT e.company_id, e.group_key,
       COALESCE(la.amount_absolute, 0)
         + COALESCE(SUM(e.amount_delta) FILTER (
             WHERE e.amount_delta IS NOT NULL
               AND (la.occurred_at IS NULL OR e.occurred_at > la.occurred_at)), 0)
         AS group_total,
       GREATEST(
         COALESCE(la.amount_absolute, 0)
         + COALESCE(SUM(e.amount_delta) FILTER (
             WHERE e.amount_delta IS NOT NULL
               AND (la.occurred_at IS NULL OR e.occurred_at > la.occurred_at)), 0), 0)
         AS still_held,
       count(*) AS events,
       bool_or(e.amount_absolute IS NOT NULL) AS order_dependent
FROM card_auth_events e
LEFT JOIN latest_absolute la USING (company_id, group_key)
WHERE e.group_key IS NOT NULL
GROUP BY e.company_id, e.group_key, la.amount_absolute, la.occurred_at;

CREATE OR REPLACE FUNCTION held_for_company(p_company text) RETURNS bigint
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(still_held),0)::bigint
    FROM card_holds_derived WHERE company_id = p_company;
$$;

COMMIT;
