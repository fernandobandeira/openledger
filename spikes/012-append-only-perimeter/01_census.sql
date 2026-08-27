-- 01 -- what the shipped schema's trigger population actually is.
-- tgenabled: O = origin (default, SKIPPED when session_replication_role='replica'),
--            D = disabled, R = replica-only, A = always.
\echo '--- internal (foreign-key) triggers, by enablement ---'
SELECT tgisinternal, tgenabled, count(*)
FROM pg_trigger WHERE NOT tgisinternal OR tgisinternal
GROUP BY 1,2 ORDER BY 1,2;

\echo '--- the nine foreign keys and their four internal triggers each ---'
SELECT c.conname, count(t.oid) AS internal_triggers,
       string_agg(DISTINCT t.tgenabled::text, ',') AS enabled
FROM pg_constraint c
JOIN pg_trigger t ON t.tgconstraint = c.oid
WHERE c.contype = 'f'
GROUP BY c.conname ORDER BY c.conname;

\echo '--- the six declared triggers ---'
SELECT c.relname, t.tgname, t.tgenabled
FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
WHERE NOT t.tgisinternal ORDER BY 1,2;

\echo '--- event triggers ---'
SELECT count(*) AS event_triggers FROM pg_event_trigger;

\echo '--- do the views read ONLY? ---'
SELECT c.relname,
       pg_get_viewdef(c.oid) ~ 'FROM ONLY' AS reads_only
FROM pg_class c WHERE c.relkind='v' AND c.relnamespace='public'::regnamespace ORDER BY 1;
