CREATE OR REPLACE VIEW spike_grid AS
SELECT tn.t AS tenant, cu.name AS cursor_name, cu.cur, ao.asof, ao.label
FROM (VALUES ('bk'), ('nc')) tn(t)
CROSS JOIN (SELECT name, cur FROM spike_cursors) cu
CROSS JOIN (VALUES
    ('2026-01-01 00:00+00'::timestamptz, 'before everything'),
    ('2026-01-15 00:00+00', 'mid 2026-01'),
    ('2026-02-01 00:00+00', 'ON the 2026-01 close boundary'),
    ('2026-02-15 00:00+00', 'mid 2026-02'),
    ('2026-03-01 00:00+00', 'ON the 2026-02 close boundary'),
    ('2026-03-15 00:00+00', 'mid 2026-03'),
    ('2026-04-01 00:00+00', 'ON the 2026-03 close boundary'),
    ('2026-04-15 00:00+00', 'mid 2026-04, no close'),
    ('2026-05-01 00:00+00', 'past every entry'),
    ('infinity',            'infinity -- what the sweep uses')
) ao(asof, label);
