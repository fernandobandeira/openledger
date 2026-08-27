-- FINDINGS 5 and 6. The over-reversal alarm self-heals, and the clamp hides state.
\set QUIET on
SET search_path = public; SELECT reset_all();
\set QUIET off
\echo '=== finding 5: two reversals against one authorization, then an ordinary incremental ==='
SELECT ingest_current('t1','c1','card-1','R1','r1','authorization',10000,false) AS auth_100;
SELECT ingest_current('t1','c1','card-1','R1','r2','reversal',     10000,false) AS reversal_100;
SELECT ingest_current('t1','c1','card-1','R1','r3','reversal',     10000,false) AS reversal_100_again;
\echo '  -- the PRECURSOR state: drift fires, and the money is not yet lost'
SELECT g.total_minor, g.held_minor, g.low_water_minor, g.overcaptured_at IS NOT NULL AS overcaptured,
       (SELECT count(*) FROM card_hold_drift) AS drift_rows FROM card_hold_groups g;
SELECT ingest_current('t1','c1','card-1','R1','r4','incremental',  10000,false) AS incremental_100;
\echo '  -- ...and it self-heals the instant the increase is absorbed'
SELECT 10000 AS live_exposure_from_the_scenario, g.total_minor, g.held_minor AS reported_held,
       g.low_water_minor, g.overcaptured_at IS NOT NULL AS overcaptured,
       (SELECT count(*) FROM card_hold_drift) AS drift_rows FROM card_hold_groups g;

\echo '=== finding 6: a clearing blinds it completely ==='
\set QUIET on
SELECT reset_all();
\set QUIET off
SELECT ingest_current('t1','c1','card-1','R2','s1','authorization',10000,false) AS auth_100;
SELECT ingest_current('t1','c1','card-1','R2','s2','clearing',     10000,false) AS clearing_100_POSTS;
SELECT ingest_current('t1','c1','card-1','R2','s3','reversal',     10000,false) AS spurious_reversal_100;
SELECT g.total_minor, g.held_minor, (SELECT count(*) FROM card_hold_drift) AS drift_rows FROM card_hold_groups g;
SELECT ingest_current('t1','c1','card-1','R2','s4','incremental',  10000,false) AS genuine_incremental_100;
SELECT 10000 AS un_cleared_live_exposure_from_the_scenario, 10000 AS posted_by_the_clearing,
       g.total_minor, g.held_minor AS reported_held, g.low_water_minor,
       g.overcaptured_at IS NOT NULL AS overcaptured,
       (SELECT count(*) FROM card_hold_drift) AS drift_rows FROM card_hold_groups g;
