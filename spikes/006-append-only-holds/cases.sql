\set ON_ERROR_STOP 0
-- Every edge case from the reference spec's table, against ONE formula.

-- A. normal: auth 500, partial clear 300, final clear 200
INSERT INTO card_auth_events (tenant_id,event_id,group_key,company_id,card_id,kind,amount_delta,expires_at) VALUES
 ('t1','ev_a1','grp_A','acme','card_1','authorization', 50000, now()+interval '7 days'),
 ('t1','ev_a2','grp_A','acme','card_1','clearing',     -30000, NULL),
 ('t1','ev_a3','grp_A','acme','card_1','clearing',     -20000, NULL);

-- B. INCREMENTAL: hotel authorizes 200, tops up 150 twice, clears 400
INSERT INTO card_auth_events (tenant_id,event_id,group_key,company_id,card_id,kind,amount_delta,expires_at) VALUES
 ('t1','ev_b1','grp_B','acme','card_2','authorization', 20000, now()+interval '30 days'),
 ('t1','ev_b2','grp_B','acme','card_2','incremental',   15000, NULL),
 ('t1','ev_b3','grp_B','acme','card_2','incremental',   15000, NULL),
 ('t1','ev_b4','grp_B','acme','card_2','clearing',     -40000, NULL);

-- C. OVER-CAPTURE: $1 fuel auth, $95 clearing
INSERT INTO card_auth_events (tenant_id,event_id,group_key,company_id,card_id,kind,amount_delta,expires_at) VALUES
 ('t1','ev_c1','grp_C','acme','card_3','authorization',   100, now()+interval '7 days'),
 ('t1','ev_c2','grp_C','acme','card_3','clearing',      -9500, NULL);

-- D. REVERSAL: merchant voided the sale
INSERT INTO card_auth_events (tenant_id,event_id,group_key,company_id,card_id,kind,amount_delta,expires_at) VALUES
 ('t1','ev_d1','grp_D','acme','card_4','authorization', 75000, now()+interval '7 days'),
 ('t1','ev_d2','grp_D','acme','card_4','reversal',     -75000, NULL);

-- E. EXPIRY: clearing never arrived
INSERT INTO card_auth_events (tenant_id,event_id,group_key,company_id,card_id,kind,amount_delta,expires_at) VALUES
 ('t1','ev_e1','grp_E','acme','card_5','authorization', 12000, now()-interval '1 day'),
 ('t1','ev_e2','grp_E','acme','card_5','expiry',       -12000, NULL);

-- F. STILL OPEN: authorized, nothing cleared yet
INSERT INTO card_auth_events (tenant_id,event_id,group_key,company_id,card_id,kind,amount_delta,expires_at) VALUES
 ('t1','ev_f1','grp_F','acme','card_6','authorization', 33000, now()+interval '7 days');

\echo ''
\echo '=== derived holds — one formula, every case ==='
SELECT group_key,
       to_char(group_total/100.0,'FM99,990.00')  AS group_total,
       to_char(still_held/100.0,'FM99,990.00')   AS still_held,
       events
FROM card_holds_derived ORDER BY group_key;

\echo ''
\echo '=== total held for the company ==='
SELECT to_char(held_for_company('acme')/100.0,'FM99,990.00') AS held;

\echo ''
\echo '=== IDEMPOTENCY: redeliver ev_b2 (the first hotel top-up) ==='
INSERT INTO card_auth_events (tenant_id,event_id,group_key,company_id,card_id,kind,amount_delta)
VALUES ('t1','ev_b2','grp_B','acme','card_2','incremental', 15000);

\echo ''
\echo '=== SIGN GUARD: a clearing with a positive delta ==='
INSERT INTO card_auth_events (tenant_id,event_id,group_key,company_id,card_id,kind,amount_delta)
VALUES ('t1','ev_x','grp_X','acme','card_9','clearing', 500);
