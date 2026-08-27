-- Every finding, re-run against the corrected schema. Same scenarios as 01..07.
SET search_path = fixed, public;
\pset footer off

\echo '################ D1 -- the mis-grouped cumulative total (finding 1)'
\set QUIET on
SELECT reset_all(); \set QUIET off
SELECT ingest_fixed('t1','c1','card-1','G1','msg-1','authorization',10000,true) AS msg1;
SELECT ingest_fixed('t1','c1','card-1','G1','msg-2','authorization',10000,true,'USD',NULL,'fuzzy') AS msg2;
SELECT 20000 AS true_exposure_from_the_scenario, sum(held_minor) AS reported_held FROM card_hold_groups;
SELECT group_key, total_convention, authorized_minor, held_minor FROM card_hold_groups ORDER BY 1;
\echo '  -- and the noticer sees the SHAPE even if the matcher ignores the rule:'
\set QUIET on
SELECT reset_all(); \set QUIET off
SELECT ingest_fixed('t1','c1','card-1','G1','msg-1','authorization',10000,true,'USD',NULL,'lifecycle_id') AS msg1;
SELECT ingest_fixed('t1','c1','card-1','G1','msg-2','authorization',10000,true,'USD',NULL,'lifecycle_id') AS msg2_forced_in;
SELECT group_key, reason, n FROM card_auth_review ORDER BY 2;
SELECT count(*) AS card_hold_drift_rows FROM card_hold_drift;

\echo '################ D2 -- the expiry race (finding 2)'
\set QUIET on
SELECT reset_all(); \set QUIET off
\echo '  -- expiry_reversal no longer exists as a kind:'
SELECT 'expiry_reversal'::auth_event_kind;
\echo '  -- the incremental race, BOTH orders:'
SELECT ingest_fixed('t1','c1','card-1','G-C','c1','authorization',10000,false,'USD', now()-interval '1 day') AS c1;
SELECT sweep_fixed('G-C') AS sweep_before_the_incremental;
SELECT ingest_fixed('t1','c1','card-1','G-C','c2','incremental',5000,false,'USD', now()+interval '7 days') AS c2;
SELECT sweep_fixed('G-C') AS sweep_again;
SELECT ingest_fixed('t1','c1','card-1','G-D','d1','authorization',10000,false,'USD', now()-interval '1 day') AS d1;
SELECT ingest_fixed('t1','c1','card-1','G-D','d2','incremental',5000,false,'USD', now()+interval '7 days') AS d2;
SELECT sweep_fixed('G-D') AS sweep_after_both;
SELECT group_key, 15000 AS live_exposure_from_the_scenario, held_minor AS reported_held FROM card_hold_groups ORDER BY 1;
\echo '  -- and a group that really IS past its latest deadline still expires:'
SELECT ingest_fixed('t1','c1','card-1','G-E','e1','authorization',10000,false,'USD', now()-interval '1 day') AS e1;
SELECT sweep_fixed('G-E') AS swept;
SELECT group_key, held_minor FROM card_hold_groups WHERE group_key='G-E';

\echo '################ D3 -- the decreasing cumulative restatement (finding 3)'
\set QUIET on
SELECT reset_all(); \set QUIET off
SELECT ingest_fixed('t1','c1','card-1','H1','h1','authorization',10000,true) AS auth_100;
SELECT ingest_fixed('t1','c1','card-1','H1','h2','reversal',    4000,false) AS reversal_40;
SELECT ingest_fixed('t1','c1','card-1','H1','h3','incremental', 9000,true)  AS restate_to_90;
SELECT 9000 AS true_exposure_from_the_scenario, held_minor AS reported_held,
       authorized_minor AS high_water, quarantine_reason, quarantine_hold_minor
  FROM card_hold_groups;
\echo '  -- ...and an ORDINARY out-of-order totals pair, with no reversal, is not ambiguous:'
\set QUIET on
SELECT reset_all(); \set QUIET off
SELECT ingest_fixed('t1','c1','card-1','H2','i1','authorization',15000,true) AS total_150;
SELECT ingest_fixed('t1','c1','card-1','H2','i2','incremental', 10000,true) AS stale_total_100;
SELECT held_minor AS reported_held FROM card_hold_groups;

\echo '################ D4 -- the convention mix quarantines the GROUP (finding 4)'
\set QUIET on
SELECT reset_all(); \set QUIET off
SELECT ingest_fixed('t1','c1','card-1','M1','m1','authorization',10000,false) AS order1_delta_100;
SELECT ingest_fixed('t1','c1','card-1','M1','m2','incremental', 12000,true)  AS order1_total_120;
SELECT ingest_fixed('t1','c1','card-2','M2','n1','incremental', 12000,true)  AS order2_total_120;
SELECT ingest_fixed('t1','c1','card-2','M2','n2','authorization',10000,false) AS order2_delta_100;
SELECT group_key, held_minor AS reported_held, quarantine_reason, quarantine_hold_minor,
       (SELECT count(*) FROM card_auth_event_group m WHERE m.group_key=g.group_key AND m.superseded_at IS NULL) AS events_stored
  FROM card_hold_groups g ORDER BY 1;
SELECT count(*) AS card_hold_drift_rows FROM card_hold_drift;

\echo '################ D5/D6 -- the residue no increase may absorb (findings 5 and 6)'
\set QUIET on
SELECT reset_all(); \set QUIET off
\echo '  -- finding 5: two reversals, then an ordinary incremental'
SELECT ingest_fixed('t1','c1','card-1','R1','r1','authorization',10000,false) AS auth_100;
SELECT ingest_fixed('t1','c1','card-1','R1','r2','reversal',     10000,false) AS reversal_100;
SELECT ingest_fixed('t1','c1','card-1','R1','r3','reversal',     10000,false) AS reversal_100_again;
SELECT ingest_fixed('t1','c1','card-1','R1','r4','incremental',  10000,false) AS incremental_100;
SELECT 10000 AS live_exposure_from_the_scenario, total_minor, unexplained_minor,
       held_minor AS reported_held, quarantine_reason,
       (SELECT count(*) FROM card_hold_drift) AS drift_rows FROM card_hold_groups;
\echo '  -- finding 6: the clearing case'
\set QUIET on
SELECT reset_all(); \set QUIET off
SELECT ingest_fixed('t1','c1','card-1','R2','s1','authorization',10000,false) AS auth_100;
SELECT ingest_fixed('t1','c1','card-1','R2','s2','clearing',     10000,false) AS clearing_100_POSTS;
SELECT ingest_fixed('t1','c1','card-1','R2','s3','reversal',     10000,false) AS spurious_reversal;
SELECT ingest_fixed('t1','c1','card-1','R2','s4','incremental',  10000,false) AS genuine_incremental;
SELECT 10000 AS un_cleared_live_exposure, total_minor, unexplained_minor,
       held_minor AS reported_held, quarantine_reason,
       (SELECT count(*) FROM card_hold_drift) AS drift_rows FROM card_hold_groups;
\echo '  -- NO REGRESSION: a genuine over-capture ($1 auth clearing at $95) still clamps SILENTLY'
\set QUIET on
SELECT reset_all(); \set QUIET off
SELECT ingest_fixed('t1','c1','card-1','R3','t1','authorization',100,false)  AS auth_1;
SELECT ingest_fixed('t1','c1','card-1','R3','t2','clearing',     9500,false) AS clearing_95;
SELECT total_minor, unexplained_minor, held_minor, low_water_minor, quarantine_reason,
       (SELECT count(*) FROM card_hold_drift) AS drift_rows,
       (SELECT count(*) FROM card_hold_overcapture) AS overcapture_rows FROM card_hold_groups;
\echo '  -- NO REGRESSION: an out-of-order CLEARING before its authorization (spike 001 case G)'
\set QUIET on
SELECT reset_all(); \set QUIET off
SELECT ingest_fixed('t1','c1','card-1','R4','u1','clearing',     30000,false) AS clearing_300_first;
SELECT ingest_fixed('t1','c1','card-1','R4','u2','authorization',50000,false) AS auth_500_after;
SELECT 20000 AS spike001_case_G_expected, held_minor AS reported_held, unexplained_minor,
       quarantine_reason FROM card_hold_groups;
\echo '  -- THE COST: an out-of-order REVERSAL before its authorization over-reserves, visibly'
\set QUIET on
SELECT reset_all(); \set QUIET off
SELECT ingest_fixed('t1','c1','card-1','R5','v1','reversal',     10000,false) AS reversal_first;
SELECT ingest_fixed('t1','c1','card-1','R5','v2','authorization',10000,false) AS auth_after;
SELECT 0 AS true_exposure_from_the_scenario, held_minor AS OVER_reserved,
       unexplained_minor, quarantine_reason FROM card_hold_groups;

\echo '################ D7 -- the emptied group is re-denominable (finding 7)'
\set QUIET on
SELECT reset_all(); \set QUIET off
SELECT ingest_fixed('t1','c1','card-1','P1','p1','authorization',10000,false,'USD') AS usd_auth;
UPDATE card_auth_event_group SET superseded_at=now() WHERE group_key='P1';
UPDATE card_hold_groups SET total_minor=0, authorized_minor=0, total_convention=NULL WHERE group_key='P1';
SELECT ingest_fixed('t1','c1','card-1','P1','p2','authorization',5000,false,'EUR') AS eur_auth;
SELECT group_key, currency, held_minor,
       (SELECT count(*) FROM card_auth_events WHERE processor_msg_id='p2') AS p2_stored FROM card_hold_groups;
\echo '  -- ...but a group carrying state that is NOT a materialisation is still pinned:'
\set QUIET on
SELECT reset_all(); \set QUIET off
SELECT ingest_fixed('t1','c1','card-1','P2','q1','authorization',10000,false,'USD') AS usd_auth;
SELECT ingest_fixed('t1','c1','card-1','P2','q2','reversal',      20000,false,'USD') AS over_reversal;
UPDATE card_auth_event_group SET superseded_at=now() WHERE group_key='P2';
SELECT ingest_fixed('t1','c1','card-1','P2','q3','authorization',5000,false,'EUR') AS eur_auth;
