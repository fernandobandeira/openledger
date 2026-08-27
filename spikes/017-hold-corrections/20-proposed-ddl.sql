-- The proposed DDL, as it would be applied to parked/card/schema.sql.
-- Loaded here into schema `fixed`, beside the unmodified parked schema in `public`,
-- so both can be driven by the same scenarios in the same database.
SET search_path = fixed, public;

DROP VIEW card_hold_drift;
DROP VIEW card_auth_unmatched;

-- HUNK 1 -- delete the expiry_reversal kind. No processor sends an un-expiry.
--           (Marqeta's authorization.reversal.issuerexpiration is a RELEASE;
--            Galileo's BEXR auth_exp_reversal is the reversal record expiring.)
ALTER TABLE card_auth_events DROP CONSTRAINT ck_auth_events__sign;
-- the enum value itself goes; this file is parked, so a rewrite is free
ALTER TYPE auth_event_kind RENAME TO auth_event_kind_old;
CREATE TYPE auth_event_kind AS ENUM
    ('authorization','incremental','advice','reversal','clearing','expiry');
ALTER TABLE card_auth_events ALTER COLUMN kind TYPE auth_event_kind USING kind::text::auth_event_kind;
DROP TYPE auth_event_kind_old;
ALTER TABLE card_auth_events ADD CONSTRAINT ck_auth_events__sign CHECK (
        kind = 'advice' OR
        (kind IN ('authorization','incremental') AND amount_delta >= 0) OR
        (kind IN ('reversal','clearing')  AND amount_delta <= 0));

-- HUNK 2 -- the group row.
ALTER TABLE card_hold_groups
    DROP COLUMN open_events,                       -- dead: read by no view, index or constraint
    DROP COLUMN held_minor,
    -- How far below zero this group's BLOODLESS decreases drove it. Never absorbed
    -- by a later increase, so the residue cannot hide money (ADR-0002, findings 5+6).
    ADD  COLUMN unexplained_minor bigint NOT NULL DEFAULT 0
         CONSTRAINT ck_hold_groups__unexplained_sign CHECK (unexplained_minor <= 0),
    ADD  COLUMN quarantined_at   timestamptz,
    ADD  COLUMN quarantine_reason text
         CONSTRAINT ck_hold_groups__quarantine_reason
         CHECK (quarantine_reason IN ('convention_mix','unorderable_total','unexplained_residue')),
    ADD  COLUMN quarantine_hold_minor bigint,
    -- the three move together, like the expiry snapshots
    ADD  CONSTRAINT ck_hold_groups__quarantine CHECK (
        (quarantined_at IS NULL     AND quarantine_reason IS NULL)
     OR (quarantined_at IS NOT NULL AND quarantine_reason IS NOT NULL)),
    ADD  CONSTRAINT ck_hold_groups__quarantine_hold CHECK (
        quarantine_hold_minor IS NULL OR quarantine_hold_minor >= 0);

ALTER TABLE card_hold_groups ADD COLUMN held_minor bigint GENERATED ALWAYS AS (
    GREATEST(
        CASE WHEN expired_at IS NOT NULL AND quarantined_at IS NULL AND unexplained_minor = 0
             THEN 0
             -- the residue is added back, not netted away
             ELSE total_minor - unexplained_minor END,
        COALESCE(quarantine_hold_minor, 0),
        0)) STORED;

-- HUNK 3 -- make the grouping inference auditable.
ALTER TABLE card_auth_event_group
    -- the base a cumulative total was converted against, so `amount_delta =
    -- raw_amount - base_minor` is a checkable identity rather than a lost step
    ADD COLUMN base_minor bigint,
    -- the network value the matcher matched on: a Visa Transaction Identifier, a
    -- (network, ref, date) triple on Mastercard, or NULL for fuzzy/manual
    ADD COLUMN matched_on text;

-- HUNK 4 -- the indexes the new predicates need.
CREATE INDEX ix_hold_groups__quarantined ON card_hold_groups (tenant_id, company_id)
    WHERE quarantined_at IS NOT NULL;

-- HUNK 5 -- the views.
CREATE VIEW card_auth_unmatched AS
SELECT e.* FROM card_auth_events e
WHERE NOT EXISTS (SELECT 1 FROM card_auth_event_group g
                  WHERE g.tenant_id = e.tenant_id AND g.event_id = e.id
                    AND g.superseded_at IS NULL);

-- THE NOTICER. ADR-0001 says of the mis-grouped cumulative total: "What is missing
-- is anything that NOTICES." Arithmetic cannot notice it -- an equal-amount second
-- authorization is the same three columns as a restatement to an unchanged total --
-- so this view notices the SHAPE and the PROVENANCE instead.
CREATE VIEW card_auth_review AS
-- 1. Two live `authorization` events in one group. A restatement arrives as
--    `incremental` or `advice` on every processor spike 002 read; never as a
--    second `authorization`. So this is a mis-grouping, with no false positive
--    that survives uq_auth_events__msg.
SELECT m.tenant_id, e.company_id, m.group_key, 'two_authorizations'::text AS reason,
       count(*) FILTER (WHERE e.kind = 'authorization') AS n
  FROM card_auth_event_group m
  JOIN card_auth_events e ON e.tenant_id = m.tenant_id AND e.id = m.event_id
 WHERE m.superseded_at IS NULL
 GROUP BY m.tenant_id, e.company_id, m.group_key
HAVING count(*) FILTER (WHERE e.kind = 'authorization') > 1
UNION ALL
-- 2. A fuzzy match attached an increase-side message to a group that already had
--    one. That is the rule D1 forbids; this is the check that the matcher kept it.
SELECT m.tenant_id, e.company_id, m.group_key, 'fuzzy_increase_attached', count(*)
  FROM card_auth_event_group m
  JOIN card_auth_events e ON e.tenant_id = m.tenant_id AND e.id = m.event_id
 WHERE m.superseded_at IS NULL AND m.method = 'fuzzy'
   AND (e.kind IN ('authorization','incremental') OR (e.kind='advice' AND e.amount_delta > 0))
 GROUP BY m.tenant_id, e.company_id, m.group_key
HAVING count(*) > 1
UNION ALL
-- 3. ...and the cost of the rule, made visible rather than silent: an increase-side
--    message the matcher could only place fuzzily OPENED its own group. If it truly
--    belonged to an existing one we now over-reserve, so a human merges it back.
--    This is the "explicit unmatched queue -- never a silent guess" the spec asks
--    for, applied to the increase side.
SELECT m.tenant_id, e.company_id, m.group_key, 'fuzzy_increase_split', count(*)
  FROM card_auth_event_group m
  JOIN card_auth_events e ON e.tenant_id = m.tenant_id AND e.id = m.event_id
 WHERE m.superseded_at IS NULL AND m.method = 'fuzzy'
   AND (e.kind IN ('authorization','incremental') OR (e.kind='advice' AND e.amount_delta > 0))
 GROUP BY m.tenant_id, e.company_id, m.group_key
HAVING count(*) = 1
   AND count(*) FILTER (WHERE e.kind <> 'authorization') = 1;

-- Over-capture finally gets its consumer. ADR-0001 says overcaptured_at and
-- low_water_minor "make it an alarmable state"; nothing read either column.
CREATE VIEW card_hold_overcapture AS
SELECT g.tenant_id, g.company_id, g.group_key, g.currency,
       g.low_water_minor, g.overcaptured_at, g.total_minor, g.held_minor
  FROM card_hold_groups g
 WHERE g.low_water_minor < 0;

CREATE VIEW card_hold_drift AS
WITH live AS (
    SELECT m.tenant_id, e.company_id, m.group_key,
           SUM(e.amount_delta) AS recomputed,
           SUM(GREATEST(e.amount_delta,0)) FILTER (
               WHERE e.kind IN ('authorization','incremental')
                  OR (e.kind = 'advice' AND e.amount_delta > 0)) AS recomputed_auth,
           COALESCE(-SUM(e.amount_delta) FILTER (
               WHERE e.amount_delta < 0 AND e.kind <> 'clearing'), 0) AS bloodless,
           count(*) FILTER (WHERE e.raw_is_total
               AND (e.kind IN ('authorization','incremental')
                 OR (e.kind='advice' AND e.amount_delta > 0)))          AS totals_events,
           bool_or(e.raw_is_total) FILTER (
               WHERE e.kind IN ('authorization','incremental')
                  OR (e.kind = 'advice' AND e.amount_delta > 0)) AS any_total,
           bool_or(NOT e.raw_is_total) FILTER (
               WHERE e.kind IN ('authorization','incremental')
                  OR (e.kind = 'advice' AND e.amount_delta > 0)) AS any_delta,
           -- the conversion identity: a totals event's delta must equal its wire
           -- amount less the base it was converted against
           bool_or(e.raw_is_total AND m.base_minor IS NOT NULL
                   AND e.amount_delta <> e.raw_amount - m.base_minor) AS conversion_broken,
           count(*) FILTER (WHERE e.kind = 'authorization') > 1 AS two_authorizations
      FROM card_auth_event_group m
      JOIN card_auth_events e ON e.tenant_id = m.tenant_id AND e.id = m.event_id
     WHERE m.superseded_at IS NULL
     GROUP BY m.tenant_id, e.company_id, m.group_key
)
SELECT COALESCE(g.tenant_id,  l.tenant_id)  AS tenant_id,
       COALESCE(g.company_id, l.company_id) AS company_id,
       COALESCE(g.group_key,  l.group_key)  AS group_key,
       g.total_minor AS stored, g.authorized_minor AS stored_authorized,
       COALESCE(l.recomputed_auth, 0) AS recomputed_authorized,
       COALESCE(l.recomputed, 0) AS recomputed,
       g.unexplained_minor, g.quarantined_at, g.quarantine_reason
FROM card_hold_groups g
FULL OUTER JOIN live l ON l.tenant_id=g.tenant_id AND l.company_id=g.company_id AND l.group_key=g.group_key
   -- 1. the materialised total disagrees with its log
WHERE g.total_minor IS DISTINCT FROM COALESCE(l.recomputed, 0)
   -- 2. ...or the authorized subtotal does
   OR g.authorized_minor IS DISTINCT FROM COALESCE(l.recomputed_auth, 0)
   -- 3. ...or the group is a totals group holding BOTH a bloodless decrease and a
   --    restatement, which is the state no arrival order can resolve (ADR-0002 D3).
   OR (g.total_convention = 'total' AND l.bloodless > 0 AND l.totals_events > 1)
   -- 4. ...or the group's declared currency disagrees with any of its live events
   OR EXISTS (SELECT 1 FROM card_auth_event_group m
              JOIN card_auth_events e ON e.tenant_id=m.tenant_id AND e.id=m.event_id
              WHERE m.tenant_id=g.tenant_id AND m.group_key=g.group_key
                AND m.superseded_at IS NULL AND e.company_id=g.company_id
                AND e.currency <> g.currency)
   -- 5. ...or exposure was added after a release
   OR (g.expired_at IS NOT NULL
       AND (g.authorized_minor > COALESCE(g.expired_authorized, g.authorized_minor)
         OR g.total_minor      > COALESCE(g.expired_total,      g.total_minor)))
   -- 6. ...or the group carries a residue no increase could absorb. REPLACES the
   --    two self-healing disjuncts (`bloodless > increases` and `total < 0 AND
   --    bloodless > 0`): unexplained_minor is monotone non-increasing in the
   --    writer, so this cannot go false the way those did.
   OR g.unexplained_minor < 0
   -- 7. ...or the group is quarantined
   OR g.quarantined_at IS NOT NULL
   -- 8. ...or its log mixes conventions
   OR (l.any_total AND l.any_delta)
   -- 9. ...or the stored convention disagrees with its own log
   OR g.total_convention IS DISTINCT FROM
        (CASE WHEN l.any_total AND l.any_delta THEN g.total_convention
              WHEN l.any_total THEN 'total' WHEN l.any_delta THEN 'delta' END)
   -- 10. ...or a stored delta does not reconstruct from its wire amount and base
   OR l.conversion_broken
   -- 11. ...or the group holds two authorizations, which is a mis-grouping. THE
   --     NOTICER ADR-0001 says is missing: it does not look at the amounts, because
   --     the amounts are exactly what a mis-grouped equal restatement makes agree.
   OR l.two_authorizations;

GRANT SELECT, INSERT ON card_auth_events, card_auth_event_group TO openledger_app;
GRANT SELECT, INSERT, UPDATE ON card_auth_event_group TO openledger_app;
GRANT SELECT, INSERT, UPDATE ON card_hold_groups TO openledger_app;
REVOKE UPDATE, DELETE, TRUNCATE ON card_auth_events FROM openledger_app;
