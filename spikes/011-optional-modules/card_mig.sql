SELECT pg_try_advisory_lock(2002) AS card_got_lock, clock_timestamp() AS t_start;
CREATE INDEX CONCURRENTLY ix_card ON t_card(v);
SELECT 'card' AS who, clock_timestamp() AS t_end;
