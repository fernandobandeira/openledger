-- Schema snapshot assertion. Run after migrations in CI.
--
-- WHY: dropping a column silently drops its indexes and constraints. Formance lost
-- their running-balance index this way (migration 37 dropped `accounts_seq`, taking
-- two indexes with it) and nobody noticed for sixteen migrations -- their
-- point-in-time balance read has been a scan-and-sort ever since. Four separate
-- regressions traced to that one mechanism.
--
-- This turns that class of accident into a failed build.
SELECT string_agg(name, E'\n' ORDER BY name) AS actual FROM (
  SELECT 'index:  '||schemaname||'.'||indexname AS name FROM pg_indexes WHERE schemaname='public'
  UNION ALL
  SELECT 'constr: '||conrelid::regclass::text||'.'||conname FROM pg_constraint
   WHERE connamespace='public'::regnamespace AND contype IN ('c','u','p','f')
  UNION ALL
  SELECT 'trigger:'||tgrelid::regclass::text||'.'||tgname FROM pg_trigger WHERE NOT tgisinternal
  UNION ALL
  -- a NOT VALID constraint constrains new rows only. Formance has four and validated none.
  SELECT 'NOTVALID:'||conrelid::regclass::text||'.'||conname FROM pg_constraint
   WHERE connamespace='public'::regnamespace AND NOT convalidated
) x;
