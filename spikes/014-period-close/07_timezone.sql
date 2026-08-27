-- 07 -- A period boundary is a business-date boundary in SOMEONE's zone. Which one, and
-- what is actually stored?
--
-- `grep -rn "AT TIME ZONE"` over the whole repository returns zero hits, and ADR-0006,
-- which owns time, scopes itself away from the question. Three findings, each one an
-- argument for storing the RESOLVED INSTANT and keeping the zone as provenance.

\pset border 2
SET TimeZone = 'UTC';

\echo '== 1. A local midnight is not always a real instant. =='
-- Brazil's DST transitions took effect at 00:00 local, so on the spring-forward night
-- local midnight did not happen. PostgreSQL resolves it silently and the boundary lands
-- an hour late -- no error, no warning, a period an hour short.
SELECT v AS boundary_asked_for,
       (v AT TIME ZONE 'America/Sao_Paulo') AS resolved_instant,
       (v AT TIME ZONE 'UTC') - (v AT TIME ZONE 'America/Sao_Paulo') AS offset_from_utc,
       ((v AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo') AS renders_back_as
FROM (VALUES (timestamp '2018-11-04 00:00'),
             (timestamp '2019-02-16 00:00'),
             (timestamp '2020-02-16 00:00')) t(v);

\echo '== 2. The same local date resolves to a different instant after a tzdata update. =='
-- Rows 2 and 3 above are the same wall-clock boundary in the same zone, an ordinary
-- mid-February midnight, resolving one hour apart -- because Brazil abolished DST by
-- decree between them. A stored (local date, zone) pair is therefore NOT a stable
-- instant: it is a promise to re-run a lookup against whatever tzdata is installed on
-- the day someone re-runs the report.
-- Rows 2 and 3 of the table above are the same wall-clock boundary, in the same zone,
-- an ordinary mid-February midnight -- resolving ONE HOUR APART, because Brazil abolished
-- DST by decree between them (Decree 9,772/2019). Nothing about the ledger changed.
SELECT (SELECT count(*) FROM pg_timezone_names) AS zones_this_server_knows,
       (SELECT count(*) FROM pg_timezone_abbrevs) AS abbrevs_this_server_knows;

\echo '== 3. Whose zone it is moves money between statements. =='
-- One posting, effective 2026-03-01 02:00 UTC. In New York that is the evening of
-- 28 February.
SELECT sp_post('t1','fee','2026-03-01 02:00+00','operating_cash','fee_revenue', 42000) IS NOT NULL AS posted;
SELECT sp_wait_for_cursor();
SELECT z AS period_resolved_in,
       (timestamp '2026-02-01 00:00' AT TIME ZONE z) AS feb_starts_at,
       (timestamp '2026-03-01 00:00' AT TIME ZONE z) AS feb_ends_at,
       to_char((SELECT SUM(i.amount_minor) FILTER (WHERE i.side='credit')
                FROM income_statement_for('t1', timestamp '2026-02-01 00:00' AT TIME ZONE z,
                                                timestamp '2026-03-01 00:00' AT TIME ZONE z,
                                                report_cursor()) i)/100.0,'FM999,990.00') AS february_revenue
FROM (VALUES ('UTC'),('America/New_York'),('Asia/Kathmandu'),('Australia/Lord_Howe')) t(z);

\echo '== 4. Half-open, not BETWEEN. =='
-- `effective_at <= end-of-day` has to name a last instant, and every approximation of it
-- drops rows. timestamptz resolves to 1 microsecond.
SELECT sp_post('t1','fee','2026-02-28 23:59:59.999999+00','operating_cash','fee_revenue', 700) IS NOT NULL AS posted_at_the_last_instant;
SELECT 'effective_at <  2026-03-01           (half-open)' AS predicate,
       count(*) AS entries FROM ledger_entries
 WHERE effective_at >= '2026-02-01+00' AND effective_at < '2026-03-01+00'
UNION ALL
SELECT 'effective_at <= 2026-02-28 23:59:59  (to the second)', count(*) FROM ledger_entries
 WHERE effective_at >= '2026-02-01+00' AND effective_at <= '2026-02-28 23:59:59+00'
UNION ALL
SELECT 'effective_at <= 2026-02-28           (to the day)', count(*) FROM ledger_entries
 WHERE effective_at >= '2026-02-01+00' AND effective_at <= '2026-02-28+00';

\echo '== 5. What ledger_periods therefore stores: instants, and the zone as provenance =='
INSERT INTO ledger_periods (tenant_id, code, starts_at, ends_at, tz) VALUES
  ('t1','2026-02', timestamp '2026-02-01 00:00' AT TIME ZONE 'America/New_York',
                   timestamp '2026-03-01 00:00' AT TIME ZONE 'America/New_York', 'America/New_York');
SELECT code, starts_at, ends_at, tz FROM ledger_periods WHERE tenant_id='t1' ORDER BY starts_at;

\echo '== 6. Can a CHECK constrain the zone name? =='
-- timezone(text, timestamptz) is marked IMMUTABLE, so a CHECK may call it -- and an
-- unknown zone RAISES rather than returning NULL, which is what makes the guard bite.
-- That it is marked immutable while tzdata is legislation is itself the argument for
-- storing the resolved instant: PostgreSQL will happily cache a value the world changed.
SELECT p.provolatile AS timezone_text_timestamptz_volatility
FROM pg_proc p JOIN pg_type t ON t.oid = p.proargtypes[1]
WHERE p.proname='timezone' AND t.typname='timestamptz' AND p.pronargs=2;
DO $$ BEGIN
    INSERT INTO ledger_periods (tenant_id, code, starts_at, ends_at, tz)
    VALUES ('t1','bad','2027-01-01+00','2027-02-01+00','Middle/Earth');
    RAISE EXCEPTION 'A NONSENSE ZONE WAS ACCEPTED';
EXCEPTION WHEN invalid_parameter_value OR check_violation THEN
    RAISE NOTICE 'refused a nonsense zone: %', SQLERRM;
END $$;
