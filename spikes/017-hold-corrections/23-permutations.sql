-- ORDER-INDEPENDENCE, measured. All 6 arrival orders of one three-message set:
--   {authorization cumulative-total 100.00, reversal 40.00, incremental cumulative-total 90.00}
-- TRUE live exposure is 90.00 in every order. ADR-0001 measured 60.00 held.
\pset footer off
CREATE OR REPLACE FUNCTION public.perm_current(ord int[]) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE i int; r text;
BEGIN
    PERFORM public.reset_all();
    FOREACH i IN ARRAY ord LOOP
        r := CASE i
          WHEN 1 THEN public.ingest_current('t1','c1','k','X','x1','authorization',10000,true)
          WHEN 2 THEN public.ingest_current('t1','c1','k','X','x2','reversal',       4000,false)
          WHEN 3 THEN public.ingest_current('t1','c1','k','X','x3','incremental',    9000,true) END;
    END LOOP;
    RETURN (SELECT held_minor FROM public.card_hold_groups WHERE group_key='X');
END $$;
CREATE OR REPLACE FUNCTION fixed.perm_fixed(ord int[]) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE i int; r text;
BEGIN
    PERFORM fixed.reset_all();
    FOREACH i IN ARRAY ord LOOP
        r := CASE i
          WHEN 1 THEN fixed.ingest_fixed('t1','c1','k','X','x1','authorization',10000,true)
          WHEN 2 THEN fixed.ingest_fixed('t1','c1','k','X','x2','reversal',       4000,false)
          WHEN 3 THEN fixed.ingest_fixed('t1','c1','k','X','x3','incremental',    9000,true) END;
    END LOOP;
    RETURN (SELECT held_minor FROM fixed.card_hold_groups WHERE group_key='X');
END $$;

WITH p(ord) AS (VALUES (ARRAY[1,2,3]),(ARRAY[1,3,2]),(ARRAY[2,1,3]),
                       (ARRAY[2,3,1]),(ARRAY[3,1,2]),(ARRAY[3,2,1]))
SELECT ord AS arrival_order, 9000 AS true_exposure,
       public.perm_current(ord) AS held_today, fixed.perm_fixed(ord) AS held_after
  FROM p;

WITH p(ord) AS (VALUES (ARRAY[1,2,3]),(ARRAY[1,3,2]),(ARRAY[2,1,3]),
                       (ARRAY[2,3,1]),(ARRAY[3,1,2]),(ARRAY[3,2,1])),
     r AS (SELECT public.perm_current(ord) c, fixed.perm_fixed(ord) f FROM p)
SELECT count(DISTINCT c) AS distinct_holds_today, min(c) AS min_today, max(c) AS max_today,
       count(DISTINCT f) AS distinct_holds_after, min(f) AS min_after, max(f) AS max_after,
       9000 AS true_exposure,
       bool_or(c < 9000) AS today_ever_UNDER_reserves,
       bool_or(f < 9000) AS after_ever_UNDER_reserves FROM r;

-- ...and the escape hatch. Where the processor sends an explicit incremental amount
-- alongside the cumulative total -- Stripe (`pending_request.amount`), Increase
-- (`card_increment.amount`), Galileo ("the incremental amount will be present in the
-- local amount fields"), Unit (`oldAmount`/`newAmount`) -- the adapter reads the delta
-- off the message and never enters the ambiguous path at all.
\echo '=== same three facts, adapter using the processor'"'"'s explicit delta field ==='
CREATE OR REPLACE FUNCTION fixed.perm_delta(ord int[]) RETURNS bigint LANGUAGE plpgsql
SET search_path = fixed, public AS $$
DECLARE i int; r text;
BEGIN
    PERFORM fixed.reset_all();
    FOREACH i IN ARRAY ord LOOP
        r := CASE i
          WHEN 1 THEN fixed.ingest_fixed('t1','c1','k','Y','y1','authorization',10000,false)
          WHEN 2 THEN fixed.ingest_fixed('t1','c1','k','Y','y2','reversal',       4000,false)
          WHEN 3 THEN fixed.ingest_fixed('t1','c1','k','Y','y3','incremental',    3000,false) END;
    END LOOP;
    RETURN (SELECT held_minor FROM fixed.card_hold_groups WHERE group_key='Y');
END $$;
WITH p(ord) AS (VALUES (ARRAY[1,2,3]),(ARRAY[1,3,2]),(ARRAY[2,1,3]),
                       (ARRAY[2,3,1]),(ARRAY[3,1,2]),(ARRAY[3,2,1])),
     r AS (SELECT fixed.perm_delta(ord) f FROM p)
SELECT count(DISTINCT f) AS distinct_holds, min(f) AS min_held, max(f) AS max_held,
       9000 AS true_exposure, bool_or(f < 9000) AS ever_UNDER_reserves FROM r;
