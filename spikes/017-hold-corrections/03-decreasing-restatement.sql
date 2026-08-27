-- FINDING 3. A cumulative restatement that DECREASES is refused, and the refusal is sticky.
\set QUIET on
SET search_path = public; SELECT reset_all();
\set QUIET off
-- A totals processor (Lithic / Column / Unit convention). 100.00 authorized,
-- the merchant reverses 40.00, then the processor restates its cumulative
-- authorized subtotal as 90.00 (= 60.00 remaining, topped up by 30.00).
SELECT ingest_current('t1','c1','card-1','H1','h1','authorization',10000,true) AS auth_100;
SELECT ingest_current('t1','c1','card-1','H1','h2','reversal',    4000,false) AS reversal_40;
SELECT ingest_current('t1','c1','card-1','H1','h3','incremental', 9000,true)  AS restate_to_90;

SELECT 9000 AS true_live_exposure_from_the_scenario, g.held_minor AS reported_held,
       g.authorized_minor AS high_water_base, g.total_minor
  FROM card_hold_groups g;
\echo '--- and it is sticky: nothing below the 100.00 high-water mark is ever accepted again ---'
SELECT ingest_current('t1','c1','card-1','H1','h4','incremental', 9500,true) AS restate_to_95;
SELECT ingest_current('t1','c1','card-1','H1','h5','incremental', 9900,true) AS restate_to_99;
SELECT (SELECT count(*) FROM card_hold_drift) AS card_hold_drift_rows,
       (SELECT count(*) FROM card_auth_events) AS events_actually_stored;
