-- FINDING 4. A refused convention mix leaves an ORDER-DEPENDENT number in service.
\set QUIET on
SET search_path = public; SELECT reset_all();
\set QUIET off
-- {authorization 100.00 as a DELTA, incremental 120.00 as a cumulative TOTAL}
\echo '--- order 1: the delta first ---'
SELECT ingest_current('t1','c1','card-1','M1','m1','authorization',10000,false) AS delta_100;
SELECT ingest_current('t1','c1','card-1','M1','m2','incremental', 12000,true)  AS total_120;
\echo '--- order 2: the total first ---'
SELECT ingest_current('t1','c1','card-2','M2','n1','incremental', 12000,true)  AS total_120;
SELECT ingest_current('t1','c1','card-2','M2','n2','authorization',10000,false) AS delta_100;

SELECT group_key, held_minor AS reported_held, total_convention,
       (SELECT count(*) FROM card_auth_event_group m JOIN card_auth_events e
          ON e.tenant_id=m.tenant_id AND e.id=m.event_id
        WHERE m.group_key=g.group_key AND m.superseded_at IS NULL) AS events_in_the_log
  FROM card_hold_groups g ORDER BY group_key;
\echo '--- the refused message is a processor fact we threw away; drift sees nothing ---'
SELECT (SELECT count(*) FROM card_hold_drift) AS card_hold_drift_rows;
\echo '--- the largest reading the log admits (every increase read as a delta) ---'
SELECT m.group_key, SUM(GREATEST(e.raw_amount,0)) FILTER (
         WHERE e.kind IN ('authorization','incremental')) AS pessimistic_hold
  FROM card_auth_event_group m JOIN card_auth_events e
    ON e.tenant_id=m.tenant_id AND e.id=m.event_id
 WHERE m.superseded_at IS NULL GROUP BY m.group_key ORDER BY 1;
