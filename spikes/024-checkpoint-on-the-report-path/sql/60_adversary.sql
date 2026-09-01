-- Spike 024 -- B and C of the adversarial cells. Both rolled back.
\set ON_ERROR_STOP on

\echo '=== B. computed_at_xid is bounded FROM BELOW ONLY ==='
\echo '    Forge the 2026-03/USD close cursor to 2^62 and ask every check.'
BEGIN;
-- ledger_period_closes carries the append-only trigger, so the forgery has to be
-- a DELETE+INSERT... which the trigger also refuses. Disable it for the cell, the
-- way the snapshot test's own red proofs do: this is the OWNER accident class
-- ADR-0009 admits is out of model, and the point is what the CHECKS say, not
-- whether a trigger stopped it.
ALTER TABLE ledger_period_closes DISABLE TRIGGER ck_closes__append_only;
UPDATE ledger_period_closes SET computed_at_xid = '4611686018427387904'::xid8
WHERE tenant_id='bk' AND period_code='2026-03' AND currency='USD';
ALTER TABLE ledger_period_closes ENABLE ALWAYS TRIGGER ck_closes__append_only;

SELECT (SELECT count(*) FROM recon_close_breaks)  AS shipped_close_typing_breaks,
       (SELECT count(*) FROM close_disclosures
         WHERE tenant_id='bk' AND period_code='2026-03') AS disclosures_for_that_period,
       (SELECT count(*) FROM recon_checkpoint_breaks)    AS checkpoint_drift_breaks,
       (SELECT COALESCE(string_agg(DISTINCT reason, ',' ORDER BY reason), '-')
          FROM recon_checkpoint_breaks)                  AS checkpoint_reasons,
       (SELECT count(*) FROM recon_close_order)          AS proposed_close_order_breaks,
       (SELECT COALESCE(string_agg(DISTINCT reason, ',' ORDER BY reason), '-')
          FROM recon_close_order)                        AS proposed_reasons;
ROLLBACK;

\echo
\echo '=== ...and the same cell with the cursor forged DOWNWARD to 1 ==='
BEGIN;
ALTER TABLE ledger_period_closes DISABLE TRIGGER ck_closes__append_only;
UPDATE ledger_period_closes SET computed_at_xid = '1'::xid8
WHERE tenant_id='bk' AND period_code='2026-03' AND currency='USD';
ALTER TABLE ledger_period_closes ENABLE ALWAYS TRIGGER ck_closes__append_only;
SELECT (SELECT count(*) FROM recon_close_breaks)  AS shipped_close_typing_breaks,
       (SELECT count(*) FROM recon_checkpoint_breaks) AS checkpoint_drift_breaks,
       (SELECT count(*) FROM recon_close_order)       AS proposed_close_order_breaks,
       (SELECT COALESCE(string_agg(DISTINCT reason, ',' ORDER BY reason), '-')
          FROM recon_close_order)                     AS proposed_reasons;
ROLLBACK;

\echo
\echo '=== C. the grant surface: computed_at_xid vs ledger_entries.xact_id ==='
SELECT c.relname, a.attname,
       has_column_privilege('openledger_app', c.oid, a.attname, 'INSERT') AS app_can_insert
FROM pg_class c
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
WHERE c.relname IN ('ledger_period_closes','ledger_entries')
  AND a.attname IN ('computed_at_xid','xact_id','amount_minor','transaction_id')
ORDER BY c.relname, a.attname;

\echo '    ...and the grant that makes it so, verbatim from the catalog:'
SELECT c.relname || ': ' || COALESCE(r.rolname,'PUBLIC') || ' ' || x.privilege_type AS grant_line
FROM pg_class c
CROSS JOIN LATERAL aclexplode(c.relacl) x
LEFT JOIN pg_roles r ON r.oid = x.grantee
WHERE c.relname = 'ledger_period_closes' AND COALESCE(r.rolname,'') = 'openledger_app'
ORDER BY 1;

\echo '    column-level INSERT grants on ledger_entries, for contrast (attacl is set there):'
SELECT c.relname || '.' || a.attname || ': ' || COALESCE(r.rolname,'PUBLIC')
       || ' ' || x.privilege_type AS grant_line
FROM pg_class c
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
CROSS JOIN LATERAL aclexplode(a.attacl) x
LEFT JOIN pg_roles r ON r.oid = x.grantee
WHERE c.relname = 'ledger_entries'
ORDER BY 1;
