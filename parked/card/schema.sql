-- PARKED -- the card reference product's schema. NOT APPLIED BY ANY MIGRATION.
--
-- This is the authorization / hold / clearing half of what used to be
-- `schema/schema.sql`, lifted out when the core ledger became
-- `migrations/00001_baseline.sql`. Nothing loads it today. See site/content/card/parked.md for
-- why it is here and what has to be true before it comes back.
--
-- NOT QUITE VERBATIM, and the difference is worth naming: 24 of the 25 statements
-- below are byte-for-byte the originals, the 25th is the DO block added below to
-- fail early when the core objects are absent, and one REVOKE was dropped in the
-- lift and later restored with the comment that records how. Checked
-- statement-by-statement against `git show 525ada2:schema/schema.sql`; every one of
-- the original file's 79 statements appears in the baseline or in this file.
--
-- IT DOES NOT LOAD ON ITS OWN. Four things it does not own: the `refuse_mutation()`
-- and `refuse_truncate()` trigger functions and the `openledger_app` role, all three
-- from the core migration -- plus `uuidv7()`, which is PostgreSQL 18 and makes 18 a
-- floor here as it is there. Nothing else crosses the boundary -- not one foreign
-- key, in either direction (ADR-0008, read from `pg_constraint`). The DO block below
-- checks the first three; the fourth fails on its own with a clear message.
--
-- WHEN IT RETURNS IT DOES NOT RETURN LIKE THIS. ADR-0008 puts these objects in
-- their own `card` PostgreSQL schema, inside the same migration set and the same
-- lock, so that `DROP SCHEMA card CASCADE` removes the module in one statement.
-- That rewrite is the work; this file is the content it starts from.


-- ...so fail at the TOP if they are absent, rather than two thirds of the way down.
-- This file inherits the core's deliberate no-BEGIN;/COMMIT; design without
-- inheriting the runner that wraps it, so a bare `psql -f` against a database with
-- no core stranded four tables, six indexes and an enum -- and the retry then died
-- on `type "auth_event_kind" already exists`, which is exactly the misleading
-- second error the core file's header says not to reintroduce.
-- PASTE IT WITH `psql --single-transaction`, verified to leave the database clean.
DO $$ BEGIN
    IF to_regproc('refuse_mutation') IS NULL OR to_regproc('refuse_truncate') IS NULL
       OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'openledger_app') THEN
        RAISE EXCEPTION 'apply migrations/00001_baseline.sql first: this file needs '
                        'refuse_mutation(), refuse_truncate() and the openledger_app role';
    END IF;
END $$;


-- ----------------------------------------------------------------------
-- the card reference product -- authorizations, holds, clearing

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
    -- ISO 4217 is uppercase. `ck_entries__currency_iso` and `ck_accounts__currency_iso`
    -- enforce that on the journal; the hold log originally enforced it nowhere, so
    -- 'usd' created a SECOND hold group -- the hold total for 'USD' reported 1000
    -- while 500 more was live under 'usd'. The same failure as on the journal, in
    -- the number the authorization decision is made on. (Two earlier versions of
    -- this comment cited ADR numbers that never carried the claim; the constraints
    -- are the durable reference.)
    CONSTRAINT ck_auth_events__currency_iso CHECK (currency ~ '^[A-Z]{3}$'),
    -- sign is a property of the kind. 'advice' is exempt because it is bidirectional
    -- on some processors. 'expiry_reversal' is NOT exempt -- it is pinned to ZERO, for
    -- the reason given below the constraint.
    -- A $0.00 authorization is a real message -- account verification / AVS /
    -- card-on-file -- and so is a $0.00 capture. Both were refused outright, with
    -- an opaque constraint error.
    -- A totals event MUST keep its wire amount. The only recovery from a message
    -- mis-grouped into a totals group is to split it to a new, empty group and
    -- recompute `delta = raw_amount - 0` (ADR-0001, Known #1). That recovery is
    -- unavailable if raw_amount is null, and nothing else in the schema would
    -- notice, so it is a constraint rather than a convention.
    CONSTRAINT ck_auth_events__totals_keep_wire
        CHECK (NOT raw_is_total OR raw_amount IS NOT NULL),
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
        -- (removing one is a rewrite) and no row may carry it. The pre-ADR-0004 writer
        -- function refused it too, but that gated only the function -- an operator backfill
        -- or a second adapter produced the double release the header argues
        -- against, five lines above the constraint that used to permit it.
        (kind IN ('reversal','clearing')  AND amount_delta <= 0))
        -- This is a WHITELIST over kinds, not a blacklist, and that is worth more
        -- than it looks: a value added to auth_event_kind later matches no arm, so
        -- it can carry NO delta at all -- positive, negative or zero. Verified in
        -- spike 007 by adding 'financial_authorization' to the enum; the first
        -- INSERT was refused here. The database is the only layer in the stack that
        -- noticed. Go's generated enum is `type AuthEventKind string`, an open set
        -- that decoded the unknown value silently with err == nil.
);


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
    -- the same lesson as ADR-0006 -- a timestamp is not an ordering key -- and
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


-- Materialised per-group total. Every processor surveyed ships one; against a
-- ~1s real-time-decisioning budget, deriving a hold by summing an unbounded event
-- log is unbounded work. This is the design, not a contingency.
--
-- That is an ARGUMENT, not a measurement. The cost of summing the log has not been
-- benchmarked, and the auth budget everywhere else in this repo is ~1s.
CREATE TABLE card_hold_groups (
    tenant_id   text NOT NULL,
    company_id  text NOT NULL,
    group_key   text NOT NULL,
    -- A group holds ONE currency. Without this, total_minor summed minor units
    -- across denominations and reported 100.00 USD + 50.00 EUR as "held 15000" --
    -- the same vacuity removed from the accounting equation in ADR-0007, but sitting
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
    -- contribute 0, never raise available credit. LITHIC ships the same clamp:
    -- "if there is an over-reversal, Lithic will cap the amounts.hold.amount to $0."
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
    CONSTRAINT pk_hold_groups PRIMARY KEY (tenant_id, company_id, group_key),
    -- Expiry MUST carry its snapshots. The post-expiry alarm compares
    -- authorized_minor and total_minor against the values frozen when the group
    -- was released; with a NULL snapshot the COALESCE below degenerates to
    -- `x > x`, which is never true, and the alarm is silently disarmed rather
    -- than noisy. Verified: authorize 10000, set expired_at alone, then a genuine
    -- incremental 10000 -- true exposure 20000, held_minor 0 (GENERATED to 0 the
    -- moment expired_at is set), drift 0 rows. A missing snapshot fails silent,
    -- which is the failure this project ranks worst, so the three columns move
    -- together or not at all.
    CONSTRAINT ck_hold_groups__expiry_snapshot CHECK (
        (expired_at IS NULL     AND expired_authorized IS NULL AND expired_total IS NULL)
     OR (expired_at IS NOT NULL AND expired_authorized IS NOT NULL AND expired_total IS NOT NULL))
);


-- HTTP-layer dedup. A separate concern from ledger identity, with no ledger effect.
CREATE TABLE webhook_deliveries (
    tenant_id   text NOT NULL,
    delivery_id text NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_webhook_deliveries PRIMARY KEY (tenant_id, delivery_id)
);


CREATE UNIQUE INDEX uq_auth_events__msg
    ON card_auth_events (tenant_id, processor_msg_id);


-- exactly one live assignment per event
CREATE UNIQUE INDEX uq_event_group__current
    ON card_auth_event_group (tenant_id, event_id) WHERE superseded_at IS NULL;

CREATE INDEX ix_event_group__group
    ON card_auth_event_group (tenant_id, group_key) WHERE superseded_at IS NULL;

-- the audit trail for one event, in assignment order
CREATE INDEX ix_event_group__event ON card_auth_event_group (tenant_id, event_id, id);


-- Serves the AUTHORIZATION read -- "sum the live holds for this company" -- which
-- is the one lookup inside the ~1s deadline (ADR-0001). It does NOT serve the
-- expiry sweep, and an earlier comment claiming it did was wrong: the partial
-- predicate `held_minor > 0` matched 100.0% of 20,733 groups in a populated
-- database, so it has no selectivity to offer a scan that has no tenant or
-- company to equal against. The planner drove from the event log and applied
-- held_minor > 0 as a filter, same plan with enable_seqscan = off.
CREATE INDEX ix_hold_groups__held
    ON card_hold_groups (tenant_id, company_id) WHERE held_minor > 0;

-- What the sweep actually needs. The selective column is the deadline, not the
-- held amount: 20 of 24,351 events were past due and the plan was a Seq Scan
-- removing 24,331 rows by filter, because hold_expires_at carried no index at
-- all. Partial, because a NULL deadline is the overwhelming majority and can
-- never be due.
CREATE INDEX ix_auth_events__hold_expiry
    ON card_auth_events (tenant_id, hold_expires_at) WHERE hold_expires_at IS NOT NULL;

CREATE TRIGGER ck_auth_events__append_only BEFORE UPDATE OR DELETE ON card_auth_events
    FOR EACH ROW EXECUTE FUNCTION refuse_mutation();
ALTER TABLE card_auth_events ENABLE ALWAYS TRIGGER ck_auth_events__append_only;
CREATE TRIGGER ck_auth_events__no_truncate BEFORE TRUNCATE ON card_auth_events
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE card_auth_events ENABLE ALWAYS TRIGGER ck_auth_events__no_truncate;
-- ----------------------------------------------------------------------
-- THE CARD ALARMS
--
-- RESTORED. These two are VIEWS -- declarative, no PL/pgSQL -- and ADR-0004's own
-- rule keeps views; it kept the three report views. They were lost because the
-- script that extracted this file from the old migrations selected report views by
-- name and never looked for these. Nobody noticed until an adversarial reviewer
-- pointed out that ADR-0001 names `card_hold_drift` EIGHT TIMES as the alarm that
-- catches every failure it records -- including the three it declines to fix on the
-- grounds that the alarm sees them -- while the schema had no such object.
--
-- Every sentence of the form "the alarm catches this" was false for as long as they
-- were absent. That is the most expensive kind of deletion: not a lost guard, a lost
-- guard that several documents still promise.
--
-- `card_auth_unmatched` is the review queue: an event with no live assignment.
-- `card_hold_drift` compares the materialised group against a re-aggregation of its
-- live event log, and reports the ways they can disagree.
CREATE VIEW card_auth_unmatched AS
SELECT e.* FROM card_auth_events e
WHERE NOT EXISTS (SELECT 1 FROM card_auth_event_group g
                  WHERE g.tenant_id = e.tenant_id AND g.event_id = e.id
                    AND g.superseded_at IS NULL);

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
           -- NO `amount_delta <> 0` FILTER HERE, and that is the whole point.
           -- A cumulative-total message mis-grouped into a DELTA group converts to
           -- delta = raw_amount - total_so_far, which is exactly 0 when the wire
           -- total equals what the group already holds. Filtering on a non-zero
           -- delta then removes the only raw_is_total row in the group, the mix
           -- disappears, and 100.00 of live exposure reports as held 0. Verified:
           -- two authorizations, wire 10000 each, the second flagged raw_is_total,
           -- stored deltas 10000 and 0 -- held 10000 against 20000 truly live,
           -- drift 0 rows WITH the filter and 1 row without it. A $0.00
           -- authorization is a real message (account verification / AVS), so it
           -- also has to survive this predicate: without the filter its convention
           -- is recorded rather than left NULL, which is what stopped the alarm
           -- firing forever on a legitimate zero-amount auth.
           bool_or(e.raw_is_total) FILTER (
               WHERE e.kind IN ('authorization','incremental')
                  OR (e.kind = 'advice' AND e.amount_delta > 0)) AS any_total,
           bool_or(NOT e.raw_is_total) FILTER (
               WHERE e.kind IN ('authorization','incremental')
                  OR (e.kind = 'advice' AND e.amount_delta > 0)) AS any_delta,
           -- Decreases that moved NO MONEY. A clearing posts to the ledger, so a
           -- group whose total went negative from clearings is not under-reserving
           -- -- the cleared amount is a receivable in the journal, and exposure is
           -- posted + held. ADR-0001 declines the over-capture report on exactly
           -- that argument, and the argument covers `clearing` AND NOTHING ELSE.
           -- `reversal` and negative `advice` post nothing. Two reversals against
           -- one authorization left total_minor at -10000 with zero clearings in
           -- the log, and the next genuine incremental was absorbed by the
           -- residue: 100.00 live, 0.00 held, 0.00 posted, drift silent. The
           -- non-latching overcaptured_at was erased by the very message that hid
           -- the money.
           COALESCE(-SUM(e.amount_delta) FILTER (
               WHERE e.amount_delta < 0 AND e.kind <> 'clearing'), 0) AS bloodless_decreases,
           COALESCE(SUM(GREATEST(e.amount_delta,0)) FILTER (
               WHERE e.kind IN ('authorization','incremental','advice')), 0) AS increases,
           COALESCE(-SUM(e.amount_delta) FILTER (WHERE e.kind = 'clearing'), 0) AS cleared
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
   -- GENERATED to 0 once expired_at is set, so exposure attached later is invisible
   -- to any sum over held_minor -- which is the number the authorization decision is
   -- made on -- while total_minor and the log still agree, and those two are exactly
   -- what the alarm compared, so it reported nothing. The clamp is the thing hiding
   -- the number, so the alarm has to look past it. Keyed on the monotonic counter,
   -- not on now().
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
   -- granted so the writer can maintain it -- and one statement sets both
   -- low_water_minor and overcaptured_at back to a clean state with drift silent,
   -- because drift reads neither column: it cannot be erased by the WRITER, which is
   -- not the same as cannot be erased.
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
   -- the order tolerance the file exists to provide. The counter-example was a
   -- permutation test, 4,3,2,1, in a `tests/` directory ADR-0004 deleted along with
   -- the PL/pgSQL -- SO IT CANNOT BE RE-RUN, and by this file's own rule that makes
   -- it an argument rather than evidence. The reasoning stands on its own: a
   -- decrease-first group legitimately dips below its own clearings, so a latch on
   -- the low-water mark fires on correct behaviour.
   --
   -- The reason no predicate works is that THE LOG CANNOT DECIDE THE QUESTION. A
   -- reversal that arrives before its authorization and a reversal that should
   -- never have been sent are the same three columns. Deciding it needs the
   -- processor's own reversal-to-authorization linkage, which this design
   -- deliberately does not model -- ADR-0001 argues that grouping is a revisable
   -- inference precisely because that linkage is unreliable. So the alarm reports
   -- the precursor state, `low_water_minor` keeps the durable evidence that the
   -- group was ever there, and the ambiguity is recorded in ADR-0001 rather than
   -- papered over with a guard that would fire on honest traffic.
   --
   -- AND A CLEARING BLINDED IT COMPLETELY. `total_minor` is
   -- `increases - cleared - bloodless`, so a group can sit BELOW ZERO from a
   -- bloodless reversal while `bloodless <= increases` -- and then the predicate
   -- above never fires, not in the precursor state and not after. Measured:
   -- authorization 100.00, clearing 100.00 (which POSTS), spurious reversal
   -- 100.00, then a genuine incremental 100.00. True exposure 200.00 (100 posted +
   -- 100 un-cleared), reported 100.00, and drift silent from the incremental onward -- the second disjunct below catches the precursor state and then self-heals. Scaled three
   -- times over: 300.00 under-reserved, and the hidden residue is bounded only by
   -- the group's cleared amount.
   --
   -- That falsifies the precise restatement ADR-0001 wrote to close the declined
   -- over-capture report -- "an over-capture never makes the reported hold smaller
   -- than the un-cleared exposure of that group" -- in a state the system itself
   -- flags as an over-capture.
   --
   -- The second disjunct is strictly stronger than the first (bloodless >
   -- increases implies total < 0 and bloodless > 0), so it loses nothing, and the
   -- genuine $1-authorization-clearing-at-$95 over-capture still does not fire,
   -- because it has no bloodless decrease at all.
   OR l.bloodless_decreases > l.increases
   OR (g.total_minor < 0 AND l.bloodless_decreases > 0)
   OR (l.any_total AND l.any_delta)
   OR g.total_convention IS DISTINCT FROM
        (CASE WHEN l.any_total AND l.any_delta THEN g.total_convention
              WHEN l.any_total THEN 'total'
              WHEN l.any_delta THEN 'delta' END);
-- The card tables: the hold flow appends events and rewrites its own materialised
-- group rows.
--
-- NOTE, AND IT IS A REAL GAP: ADR-0001's fix for the attach/regroup deadlock is
-- "take the event row lock first, explicitly" -- and `SELECT ... FOR UPDATE` on
-- card_auth_events requires UPDATE privilege, which this role is NOT granted and is
-- explicitly revoked below. The application role cannot currently execute the ADR's
-- own remedy. Deciding between
-- granting UPDATE (and leaning on the append-only trigger to keep it a lock rather
-- than mutability) and finding a lock that does not need it is open work, recorded
-- in ADR-0001's *What it costs*, beside the re-grouping lock order it makes unavailable.
GRANT SELECT, INSERT ON card_auth_events, card_auth_event_group TO openledger_app;
GRANT SELECT, INSERT, UPDATE ON card_auth_event_group TO openledger_app;
GRANT SELECT, INSERT, UPDATE ON card_hold_groups TO openledger_app;
GRANT SELECT, INSERT ON webhook_deliveries TO openledger_app;

-- ...and belt and braces, matching the core's REVOKE block. On a fresh load this is
-- a no-op -- the GRANT above only grants SELECT and INSERT, so there is nothing to
-- take away -- and that is not why it is here. It is the line that survives a later
-- `GRANT ALL ON ALL TABLES` in review. THIS LINE WAS DROPPED when the card schema was
-- split out of the core file, and it was the only executable statement in the whole
-- 1,294-line original that landed in neither half. It went unnoticed because a
-- `pg_dump -s` of the two files concatenated is byte-identical to the monolith's
-- either way: a privilege state that is a no-op at load time does not appear in a
-- structural diff. Restored, and recorded here because the class of mistake is the
-- point -- ADR-0004 specifies the mechanism as `REVOKE` AND a trigger, and for one
-- commit this log had one of the two.
REVOKE UPDATE, DELETE, TRUNCATE ON card_auth_events        FROM openledger_app;
