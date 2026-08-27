-- FINDING 7. An emptied group pins its currency forever.
\set QUIET on
SET search_path = public; SELECT reset_all();
\set QUIET off
SELECT ingest_current('t1','c1','card-1','P1','p1','authorization',10000,false,'USD') AS usd_auth;
\echo '--- the one event is re-grouped out (the routine corrective operation) ---'
UPDATE card_auth_event_group SET superseded_at=now() WHERE group_key='P1';
UPDATE card_hold_groups SET total_minor=0, authorized_minor=0, total_convention=NULL, last_event_seq=last_event_seq+1
 WHERE group_key='P1';
SELECT group_key, currency, total_minor, held_minor,
       (SELECT count(*) FROM card_auth_event_group m WHERE m.group_key=g.group_key AND m.superseded_at IS NULL) AS live_members,
       expired_at, low_water_minor, overcaptured_at
  FROM card_hold_groups g;
\echo '--- a later message for that key in another currency is refused and NEVER STORED ---'
SELECT ingest_current('t1','c1','card-1','P1','p2','authorization',5000,false,'EUR') AS eur_auth;
SELECT (SELECT count(*) FROM card_auth_events WHERE processor_msg_id='p2') AS rows_stored_for_p2,
       (SELECT count(*) FROM card_hold_drift) AS drift_rows;
