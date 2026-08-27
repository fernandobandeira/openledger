-- FINDING 2. held_minor is order-dependent when an expiry_reversal races our own sweep.
-- ADR-0001 "Known, and not fixed", second entry.
--
-- The sweep is global, so each order is run in its own group AND its own pass:
-- sweep_one() expires only the named group, which is what the ADR's table shows.
\set QUIET on
SET search_path = public;
SELECT reset_all();
CREATE OR REPLACE FUNCTION sweep_one(p_group text) RETURNS int LANGUAGE sql AS $$
    WITH d AS (
        UPDATE card_hold_groups g SET expired_at=now(),
               expired_authorized=g.authorized_minor, expired_total=g.total_minor
         WHERE g.group_key=p_group AND g.expired_at IS NULL AND g.held_minor > 0
           AND EXISTS (SELECT 1 FROM card_auth_event_group m
                       JOIN card_auth_events e ON e.tenant_id=m.tenant_id AND e.id=m.event_id
                       WHERE m.tenant_id=g.tenant_id AND m.group_key=g.group_key
                         AND m.superseded_at IS NULL AND e.hold_expires_at < now())
        RETURNING 1) SELECT count(*)::int FROM d;
$$;
\set QUIET off

-- G-A: sweep first, then the expiry_reversal.
SELECT ingest_current('t1','c1','card-1','G-A','a1','authorization',10000,false,'USD', now()-interval '1 day') AS a1;
SELECT sweep_one('G-A') AS ga_sweep;
SELECT ingest_current('t1','c1','card-1','G-A','a2','expiry_reversal',0,false) AS a2;

-- G-B: the expiry_reversal first, then the sweep.
SELECT ingest_current('t1','c1','card-1','G-B','b1','authorization',10000,false,'USD', now()-interval '1 day') AS b1;
SELECT ingest_current('t1','c1','card-1','G-B','b2','expiry_reversal',0,false) AS b2;
SELECT sweep_one('G-B') AS gb_sweep;

\echo '=== ADR-0001 table: same two messages, two arrival orders ==='
SELECT group_key, 10000 AS live_exposure_from_the_scenario, held_minor AS reported_held
  FROM card_hold_groups ORDER BY group_key;
SELECT (SELECT count(*) FROM card_hold_drift) AS card_hold_drift_rows;

\echo '=== ...and the favourable order does not survive the NEXT pass of the same job ==='
SELECT sweep_one('G-A') AS ga_second_pass;
SELECT group_key, held_minor AS reported_held FROM card_hold_groups ORDER BY group_key;

\echo '=== the same race needs no expiry_reversal at all: an ordinary incremental does it ==='
\set QUIET on
SELECT reset_all();
\set QUIET off
SELECT ingest_current('t1','c1','card-1','G-C','c1','authorization',10000,false,'USD', now()-interval '1 day') AS c1;
SELECT sweep_one('G-C') AS gc_sweep;
SELECT ingest_current('t1','c1','card-1','G-C','c2','incremental',5000,false,'USD', now()+interval '7 days') AS c2;
SELECT sweep_one('G-C') AS gc_next_pass;
SELECT group_key, 15000 AS live_exposure_from_the_scenario, held_minor AS reported_held,
       (SELECT max(e.hold_expires_at) FROM card_auth_event_group m
          JOIN card_auth_events e ON e.tenant_id=m.tenant_id AND e.id=m.event_id
         WHERE m.group_key=g.group_key AND m.superseded_at IS NULL) > now() AS latest_deadline_is_in_the_future
  FROM card_hold_groups g;
