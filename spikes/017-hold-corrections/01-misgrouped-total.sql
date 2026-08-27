-- FINDING 1. A mis-grouped cumulative total absorbs money silently.
-- ADR-0001 "Known, and not fixed", first entry.
\set QUIET on
SET search_path = public;
SELECT reset_all();
\set QUIET off

-- msg-1 opens a totals group at 100.00. msg-2 is a SECOND, genuinely different
-- authorization for the same amount, fuzzy-matched into it.
SELECT ingest_current('t1','c1','card-1','G1','msg-1','authorization',10000,true)  AS msg1;
SELECT ingest_current('t1','c1','card-1','G1','msg-2','authorization',10000,true)  AS msg2;

\echo '--- the log ---'
SELECT e.processor_msg_id, e.kind, e.raw_amount AS wire, e.raw_is_total, e.amount_delta AS stored_delta
  FROM card_auth_events e ORDER BY e.processor_msg_id;

\echo '--- what is reported vs what is live ---'
SELECT 20000 AS true_live_exposure_from_the_scenario,   -- two 100.00 authorizations
       g.held_minor AS reported_held, g.authorized_minor, g.total_minor, g.total_convention
  FROM card_hold_groups g;

\echo '--- every watcher ---'
SELECT (SELECT count(*) FROM card_hold_drift)      AS card_hold_drift_rows,
       (SELECT count(*) FROM card_auth_unmatched)  AS card_auth_unmatched_rows;

\echo '--- and the SAFE case errors while the dangerous one is silent ---'
SELECT ingest_current('t1','c1','card-1','G1','msg-3','authorization',5000,true) AS smaller_second_auth;

\echo '--- the noticer this spike proposes: two live authorization-kind events in one group ---'
SELECT m.group_key, count(*) AS live_authorization_events
  FROM card_auth_event_group m
  JOIN card_auth_events e ON e.tenant_id=m.tenant_id AND e.id=m.event_id
 WHERE m.superseded_at IS NULL AND e.kind='authorization'
 GROUP BY m.group_key HAVING count(*) > 1;
