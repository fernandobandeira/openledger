-- Spike 024 -- the candidate partitioning DDL, applied BY HAND in a scratch
-- database. PROPOSAL.sql carries the commented, migration-ready form.
--
-- There is no in-place ALTER, so the shape is: create the partitioned table
-- beside the old one, move the rows, drop the old one, rename. Everything that
-- DEPENDS on the table has to be dropped and recreated with it -- which here is
-- two views and their grants, because recon_checkpoint_breaks reads the table and
-- `reconciliation` reads that view.
\set ON_ERROR_STOP on
BEGIN;

-- 1. the readers, dropped in dependency order and recreated verbatim at the end
DROP VIEW reconciliation;
DROP VIEW recon_checkpoint_breaks;

-- 2. the rows, parked in an UNLOGGED staging table so the old table can be
-- DROPPED FIRST. That ordering is not cosmetic: constraint and index names are
-- schema-scoped, so building the partitioned table while the old one still exists
-- forces suffixed names -- and RENAME CONSTRAINT on a partitioned parent renames
-- the parent's copy only, leaving every PARTITION carrying `fk_..._new` and every
-- server-generated NOT NULL row carrying `ledger_period_balances_new_*` forever.
-- Measured: 55 constraint rows, 20 of them misnamed. Dropping first costs one
-- extra copy of a table that is derived anyway and keeps the baseline's naming.
CREATE UNLOGGED TABLE lpb_stage AS SELECT * FROM ledger_period_balances;
DROP TABLE ledger_period_balances;

-- 3. the new table. PARTITION BY LIST (period_code): legal because period_code is
-- a column of pk_period_balances, which the tenant-leading key convention put
-- there for the period's sake and not for this. The primary key is UNCHANGED and
-- still tenant-leading; a partition key must be a SUBSET of every unique
-- constraint, not a prefix of it.
CREATE TABLE ledger_period_balances (
    tenant_id      text NOT NULL,
    period_code    text NOT NULL,
    currency       char(3) NOT NULL,
    account_id     uuid NOT NULL,
    input          bigint NOT NULL,
    output         bigint NOT NULL,
    CONSTRAINT pk_period_balances PRIMARY KEY (tenant_id, period_code, currency, account_id),
    CONSTRAINT ck_period_balances__tenant_non_empty CHECK (btrim(tenant_id) <> ''),
    CONSTRAINT ck_period_balances__non_negative CHECK (input >= 0 AND output >= 0),
    CONSTRAINT fk_period_balances__close FOREIGN KEY (tenant_id, period_code, currency)
        REFERENCES ledger_period_closes (tenant_id, period_code, currency),
    CONSTRAINT fk_period_balances__account FOREIGN KEY (tenant_id, account_id, currency)
        REFERENCES ledger_accounts (tenant_id, id, currency)
) PARTITION BY LIST (period_code);

-- 4. one partition per period code that exists, plus a DEFAULT. The DEFAULT is
-- not decoration: the close is an ordinary posting by the APP role, which holds
-- no DDL privilege, so a period whose partition was never provisioned would make
-- the close FAIL rather than merely lose the benefit.
CREATE TABLE ledger_period_balances_p2026_01
    PARTITION OF ledger_period_balances FOR VALUES IN ('2026-01');
CREATE TABLE ledger_period_balances_p2026_02
    PARTITION OF ledger_period_balances FOR VALUES IN ('2026-02');
CREATE TABLE ledger_period_balances_pfy2026q1
    PARTITION OF ledger_period_balances FOR VALUES IN ('FY2026Q1');
CREATE TABLE ledger_period_balances_pdefault
    PARTITION OF ledger_period_balances DEFAULT;

-- 5. move the rows back. The alternative available ONLY because of what this
-- table is -- derived and exactly recomputable at each close's own
-- computed_at_xid -- is to rebuild it from ledger_entries instead of copying it.
-- Copying preserves history byte for byte and is what a migration should do; the
-- recompute is the fallback that proves the table is derived.
INSERT INTO ledger_period_balances SELECT * FROM lpb_stage;
DROP TABLE lpb_stage;

-- 6. row-level security, on the PARENT. Policies on a partitioned parent apply to
-- everything reached THROUGH the parent; a partition addressed directly carries
-- only its own policies, and has none -- which is why the grants below are not
-- extended to the partitions.
ALTER TABLE ledger_period_balances ENABLE ROW LEVEL SECURITY;
CREATE POLICY rls_period_balances__tenant ON ledger_period_balances
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));
CREATE POLICY rls_period_balances__writer ON ledger_period_balances
    FOR ALL TO openledger_app USING (true) WITH CHECK (true);
CREATE POLICY rls_period_balances__recon ON ledger_period_balances
    FOR SELECT TO openledger_recon USING (true);

-- 7. the grants, and the belt-and-braces REVOKE, exactly as the baseline has them
GRANT SELECT, INSERT ON ledger_period_balances TO openledger_app;
GRANT SELECT ON ledger_period_balances TO openledger_read;
GRANT SELECT ON ledger_period_balances TO openledger_recon;
REVOKE UPDATE, DELETE, TRUNCATE ON ledger_period_balances FROM openledger_app;

COMMENT ON TABLE ledger_period_balances IS
  'The effective-axis checkpoint: one row per account per closed period per currency, partitioned BY LIST (period_code). Derived and exactly recomputable from ledger_entries at the close''s computed_at_xid (ADR-0011).';

-- 8. the readers, recreated. Bodies verbatim from the baseline -- this migration
-- changes where the rows live, not what the check compares.
CREATE VIEW recon_checkpoint_breaks AS
WITH recomputed AS (
    SELECT c.tenant_id, c.period_code, c.currency, e.account_id,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'), 0)  AS input,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'), 0) AS output
    FROM ledger_period_closes c
    JOIN ledger_entries e
      ON e.tenant_id = c.tenant_id AND e.currency = c.currency
     AND e.effective_at < c.ends_at AND e.xact_id < c.computed_at_xid
    JOIN ledger_transactions x
      ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id AND x.status = 'posted'
    GROUP BY c.tenant_id, c.period_code, c.currency, e.account_id
)
SELECT COALESCE(s.tenant_id,  r.tenant_id)  AS tenant_id,
       COALESCE(s.period_code, r.period_code) AS period_code,
       COALESCE(s.currency,   r.currency)   AS currency,
       COALESCE(s.account_id, r.account_id) AS account_id,
       COALESCE(s.input, 0)  AS stored_input,
       COALESCE(s.output, 0) AS stored_output,
       COALESCE(r.input, 0)  AS recomputed_input,
       COALESCE(r.output, 0) AS recomputed_output,
       CASE WHEN s.account_id IS NULL THEN 'missing_row'
            WHEN r.account_id IS NULL THEN 'spurious_row'
            ELSE 'value_drift' END AS reason
FROM ledger_period_balances s
FULL JOIN recomputed r
  ON r.tenant_id = s.tenant_id AND r.period_code = s.period_code
 AND r.currency = s.currency AND r.account_id = s.account_id
WHERE COALESCE(s.input, 0)  <> COALESCE(r.input, 0)
   OR COALESCE(s.output, 0) <> COALESCE(r.output, 0);

CREATE VIEW reconciliation AS
SELECT 'balance_cache'      AS check_name, COUNT(*) AS breaks FROM recon_balance_breaks
UNION ALL SELECT 'orphan_entries',           COUNT(*) FROM recon_entry_breaks
UNION ALL SELECT 'unbalanced_transactions',  COUNT(*) FROM recon_transaction_breaks
UNION ALL SELECT 'cross_scope_mirror',       COUNT(*) FROM recon_scope_breaks
UNION ALL SELECT 'journal_to_reports',       COUNT(*) FROM recon_journal_to_reports
                                   WHERE unexplained_debits <> 0 OR unexplained_credits <> 0
UNION ALL SELECT 'checkpoint_drift',         COUNT(*) FROM recon_checkpoint_breaks
UNION ALL SELECT 'close_typing',             COUNT(*) FROM recon_close_breaks
UNION ALL SELECT 'cursor_forgery',           COUNT(*) FROM recon_cursor_breaks
UNION ALL SELECT 'accounting_equation',      COUNT(*) FROM recon_equation_breaks(report_cursor(), 'infinity')
UNION ALL SELECT 'chart_lint',               COUNT(*) FROM chart_lint WHERE severity = 'error';

GRANT SELECT ON recon_checkpoint_breaks, reconciliation TO openledger_recon;

COMMIT;
