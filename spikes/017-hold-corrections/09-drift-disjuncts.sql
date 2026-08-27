-- FINDING 9 (round 15). "This ADR lists five drift disjuncts; the view has eight."
-- Count them from the catalogue, then fire the two the prose omits.
SET search_path = public;
-- (the disjuncts are counted from the source file by 09-count-disjuncts.sh --
--  pg_get_viewdef re-flattens them onto one line.)

\echo '=== positive control: the CURRENCY disjunct (prose omits it) ==='
\set QUIET on
SELECT reset_all();
\set QUIET off
SELECT ingest_current('t1','c1','card-1','D1','d1','authorization',10000,false,'USD') AS usd;
-- force the state re-grouping used to be able to create: a second currency inside one group
INSERT INTO card_auth_events (tenant_id, processor_msg_id, company_id, card_id, kind, amount_delta, currency, raw_amount, occurred_at)
VALUES ('t1','d2','c1','card-1','authorization',0,'EUR',0, now());
INSERT INTO card_auth_event_group (tenant_id, event_id, group_key, method, assigned_by)
SELECT 't1', id, 'D1', 'manual', 'spike017' FROM card_auth_events WHERE processor_msg_id='d2';
SELECT d.group_key, g.currency AS group_currency, d.stored, d.recomputed
  FROM card_hold_drift d JOIN card_hold_groups g USING (tenant_id, company_id, group_key);

\echo '=== positive control: the STORED-CONVENTION-DISAGREES disjunct (prose omits it) ==='
\set QUIET on
SELECT reset_all();
\set QUIET off
SELECT ingest_current('t1','c1','card-1','D2','e1','authorization',10000,false,'USD') AS delta_group;
UPDATE card_hold_groups SET total_convention='total' WHERE group_key='D2';
SELECT group_key, stored, recomputed FROM card_hold_drift;

\echo '=== open_events: read by nothing. Every reference to it in the whole tree: ==='
SELECT count(*) AS references_in_any_view_or_index FROM pg_attribute a
 JOIN pg_class c ON c.oid=a.attrelid
 WHERE c.relname='card_hold_groups' AND a.attname='open_events'
   AND EXISTS (SELECT 1 FROM pg_depend d WHERE d.refobjid=c.oid AND d.refobjsubid=a.attnum
                 AND d.deptype='n' AND d.classid='pg_rewrite'::regclass);
