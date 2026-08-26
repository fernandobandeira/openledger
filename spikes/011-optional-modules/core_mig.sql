SELECT pg_try_advisory_lock(1001) AS core_got_lock, clock_timestamp() AS t_start;
CREATE INDEX CONCURRENTLY ix_core ON t_core(v);
SELECT 'core' AS who, clock_timestamp() AS t_end;
