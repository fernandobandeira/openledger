-- 20 -- PROPOSED DDL, part 1 of 3: the chart becomes versioned, and the
-- balance-sheet side splits into `liability` and `equity`.
--
-- Written as ALTERs against migrations/00001_baseline.sql so it is runnable on a
-- freshly migrated database. In the baseline this is one CREATE TABLE each; the
-- ALTER form is here because a spike must run, not because a migration should
-- look like this. Nothing in spikes/ ships (ADR-0007).
--
-- THE SEAM. An account type has two kinds of property, with different lifetimes:
--   * IDENTITY -- category, normal_balance, counterparty_scope, is_perimeter.
--     These may never change under posted history, and fk_accounts__type already
--     refuses two of them. They stay on account_types, unversioned.
--   * PRESENTATION -- which financial-statement line the type rolls up to.
--     IAS 1.41 REQUIRES this to change, and requires comparatives to move with
--     it. It moves to chart_presentation, keyed by chart_version, append-only.
-- fs_line therefore LEAVES account_types entirely. Two copies of one fact is the
-- mistake spike 009 removed from ledger_entries; this does not reintroduce it.

BEGIN;

-- ---------------------------------------------------------------- versions

-- Append-only. A chart version is created, never edited and never deleted: an
-- issued statement names the version it was presented under, and a version whose
-- content can change identifies nothing.
CREATE TABLE chart_versions (
    version    int  CONSTRAINT pk_chart_versions PRIMARY KEY,
    created_at timestamptz NOT NULL DEFAULT now(),
    -- IAS 1.41(a)-(c) requires the NATURE of a reclassification, the AMOUNT of
    -- each item reclassified, and the REASON, to be disclosed. The reason is the
    -- half a schema can hold, so it is NOT NULL and non-empty. The amounts are
    -- derivable: the same period presented under both versions, differenced.
    note       text NOT NULL CONSTRAINT ck_chart_versions__note CHECK (btrim(note) <> ''),
    CONSTRAINT ck_chart_versions__positive CHECK (version > 0)
);

INSERT INTO chart_versions (version, note) VALUES
  (1, 'Initial chart. Re-declares every balance-sheet line onto the split '
      'liability/equity side and declares a contra line for every type whose '
      'split key is the counterparty.');

-- "Current" is DERIVED, not stored. Versions are append-only and monotone, so
-- max() IS the current chart: no row to update, no singleton table, and no way
-- for "current" to disagree with what exists.
--
-- THIS RELATION IS THE INTERFACE TO A PINNED REPORT. Every statement view reads
-- its version from here and from nowhere else, and emits it as a column. A report
-- pinned to a chart version substitutes a one-row relation carrying the chosen
-- version for this one; no other line of any view body changes (50_ias1_41.sql
-- does exactly that). The commit-ordered cursor that pins WHICH ENTRIES a report
-- sees is a separate parameter, on a separate axis, and is not designed here
-- (ADR-0006).
CREATE VIEW chart_version_current AS
    SELECT max(version) AS chart_version FROM chart_versions;

-- ---------------------------------------------------------------- teardown

-- Both statement views read account_types.fs_line, which is about to move.
-- Rebuilt in 30_reports.sql. trial_balance reads only category and
-- normal_balance -- account IDENTITY, never presentation -- and survives
-- untouched, which is why it held the correct gross figures throughout 10.
DROP VIEW balance_sheet;
DROP VIEW income_statement;

ALTER TABLE account_types DROP CONSTRAINT fk_types__fs_line;
-- The seeded chart is re-declared as version 1 in 22_chart_v1.sql. Nothing
-- references fs_lines except the constraint just dropped.
DELETE FROM fs_lines;

-- ---------------------------------------------------------------- fs_lines

-- fs_lines is versioned too: a reclassification routinely ADDS a line, and a
-- caption edit is itself a presentation change -- ADR-0007 spends forty lines on
-- the caption being what a reader groups by. Both are new versions.
ALTER TABLE fs_lines DROP CONSTRAINT uq_fs_lines__code_statement_side;
ALTER TABLE fs_lines DROP CONSTRAINT pk_fs_lines;
DROP INDEX uq_fs_lines__caption;

ALTER TABLE fs_lines ADD COLUMN chart_version int NOT NULL;
ALTER TABLE fs_lines ADD CONSTRAINT pk_fs_lines PRIMARY KEY (chart_version, code);
ALTER TABLE fs_lines ADD CONSTRAINT fk_fs_lines__version
    FOREIGN KEY (chart_version) REFERENCES chart_versions (version);
ALTER TABLE fs_lines ADD CONSTRAINT uq_fs_lines__code_statement_side
    UNIQUE (chart_version, code, statement, side);
-- Uniqueness on what the reader distinguishes -- WITHIN a version. Two versions
-- may of course carry the same caption; that is what makes them comparable.
CREATE UNIQUE INDEX uq_fs_lines__caption
    ON fs_lines (chart_version, lower(btrim(caption, E' \t\n\r\u00a0\u200b\u2007\u202f')));

-- THE SPLIT. The income-statement half of this CHECK already distinguishes
-- revenue from expense. The balance-sheet half did not distinguish liability
-- from equity, so `liability`, `equity` and any contra of either were freely
-- interchangeable across all five liability-and-equity captions -- 1,000.00 of
-- paid-in capital presented under "Accounts payable and accrued", assets equal
-- to liabilities-and-equity, every check green (10_repro_baseline.sql, R2).
ALTER TABLE fs_lines DROP CONSTRAINT ck_fs_lines__side_matches_statement;
ALTER TABLE fs_lines ADD CONSTRAINT ck_fs_lines__side_matches_statement CHECK (
    (statement = 'balance_sheet'    AND side IN ('asset','liability','equity')) OR
    (statement = 'income_statement' AND side IN ('credit','debit')));

-- ------------------------------------------------------- account_types split

-- The key chart_presentation points at. uq_types__identity (code, category,
-- normal_balance) already exists and is what ledger_accounts points at; this is
-- its sibling for the two properties presentation is derived from.
ALTER TABLE account_types ADD CONSTRAINT uq_types__presentable
    UNIQUE (code, category, counterparty_scope);

ALTER TABLE account_types DROP COLUMN fs_side;        -- GENERATED, moves
ALTER TABLE account_types DROP COLUMN fs_statement;   -- GENERATED, moves
ALTER TABLE account_types DROP COLUMN fs_line;

-- ------------------------------------------------------ chart_presentation

CREATE TABLE chart_presentation (
    chart_version      int  NOT NULL,
    type_code          text NOT NULL,
    -- COPIED from account_types and held honest by fk_presentation__type below --
    -- the same trick fk_entries__account uses for currency and
    -- fk_entries__txn_effective for the business date: a copy that is part of a
    -- composite key cannot disagree with its source. They are here because
    -- fs_statement, fs_side and the contra rule are all derived from them, and a
    -- generated column may not read another table.
    category           ledger_category NOT NULL,
    counterparty_scope text NOT NULL,

    fs_line            text NOT NULL,
    -- THE LINE AN OPPOSITE-SIGN POSITION OF THIS TYPE PRESENTS UNDER, and the
    -- column whose absence is why the netting hole was recorded as "the schema
    -- cannot express the fix". An account's statement line was fixed by its type,
    -- so a tenant that OWES the operator on a due_to_tenants position had no line
    -- to move to and was netted against a tenant the operator owes: a payables
    -- line of ZERO against a true 425.00 payable and a true 425.00 receivable.
    -- IAS 32.42 permits offset only between the same two parties.
    --
    -- Required exactly where the split key IS the counterparty, and meaningless
    -- otherwise -- nothing offsets against interchange revenue.
    fs_line_contra     text,

    -- Unchanged from the baseline's generated columns, moved with fs_line.
    fs_statement text GENERATED ALWAYS AS (
        CASE WHEN category IN ('revenue','expense') THEN 'income_statement'
             ELSE 'balance_sheet' END) STORED,
    -- ...with the balance-sheet half now THREE-valued, which is the whole of the
    -- fix for the two-valued side. Every income-statement cell is byte-identical
    -- and every asset cell is byte-identical; only the liability/equity cells
    -- change, and they change from one value to two.
    fs_side text GENERATED ALWAYS AS (
        CASE WHEN category = 'revenue'   THEN 'credit'
             WHEN category = 'expense'   THEN 'debit'
             WHEN category = 'asset'     THEN 'asset'
             WHEN category = 'liability' THEN 'liability'
             ELSE 'equity' END) STORED,
    -- An asset position gone credit is a liability; a liability position gone
    -- debit is an asset. Derived, never supplied, and carried into the foreign
    -- key below, so a contra line on the wrong side is unwritable.
    fs_side_contra text GENERATED ALWAYS AS (
        CASE WHEN fs_line_contra IS NULL THEN NULL
             WHEN category = 'asset'     THEN 'liability'
             WHEN category = 'liability' THEN 'asset' END) STORED,

    CONSTRAINT pk_presentation PRIMARY KEY (chart_version, type_code),
    CONSTRAINT fk_presentation__version FOREIGN KEY (chart_version)
        REFERENCES chart_versions (version),
    CONSTRAINT fk_presentation__type
        FOREIGN KEY (type_code, category, counterparty_scope)
        REFERENCES account_types (code, category, counterparty_scope),
    CONSTRAINT fk_presentation__fs_line
        FOREIGN KEY (chart_version, fs_line, fs_statement, fs_side)
        REFERENCES fs_lines (chart_version, code, statement, side),
    -- The contra line is held to the OPPOSITE side by the same key. A NULL in any
    -- column of a MATCH SIMPLE foreign key satisfies it, so a type with no contra
    -- line is unconstrained here and constrained by the CHECK below instead.
    CONSTRAINT fk_presentation__fs_line_contra
        FOREIGN KEY (chart_version, fs_line_contra, fs_statement, fs_side_contra)
        REFERENCES fs_lines (chart_version, code, statement, side),
    -- A contra line exists exactly where the split key IS the counterparty.
    CONSTRAINT ck_presentation__contra_iff_per_shard
        CHECK ((fs_line_contra IS NOT NULL) = (counterparty_scope = 'per_shard')),
    -- ...AND per_shard IS A BALANCE-SHEET PROPERTY. IAS 32.42 opens "A financial
    -- asset and a financial liability shall be offset": the offsetting rule is
    -- about financial assets and financial liabilities, and there is no such
    -- thing as an opposite-sign position in revenue to present gross. Without
    -- this, fs_side_contra is NULL for a revenue or equity type while the CHECK
    -- above demands a contra line, and the pair is unsatisfiable -- confusing
    -- rather than wrong. Stated directly instead.
    CONSTRAINT ck_presentation__per_shard_is_balance_sheet
        CHECK (counterparty_scope <> 'per_shard' OR category IN ('asset','liability'))
);

-- ------------------------------------------------------------ append-only
--
-- A TRIGGER NEEDS A WRITTEN JUSTIFICATION (ADR-0004). This adds no function --
-- refuse_mutation() and refuse_truncate() already exist and are already
-- justified for the journal. What follows is the justification for pointing them
-- at three more tables.
--
-- INVARIANT: no row of chart_versions, fs_lines or chart_presentation may ever be
-- updated or deleted. A reclassification is a NEW VERSION, never an edit. This is
-- the same claim the journal rests on, applied to the mapping a statement was
-- presented through: an issued balance sheet is reproducible only if the chart it
-- was presented under is still exactly what it was.
--
-- WHY NOTHING DECLARATIVE HOLDS IT: there is no CHECK for "this row may not
-- change" and no key that expresses it. Putting chart_version in the primary key
-- makes a NEW mapping a new row -- which is the half a key CAN do -- but nothing
-- declarative stops an UPDATE of the old one. The only non-trigger option is to
-- withhold the privilege, and the app role already lacks it; the population that
-- reclassifies a chart is the OWNER, running a seed file at a psql prompt, which
-- is exactly the population `REVOKE` does not bind. That is not hypothetical
-- here: schema/chart.sql's re-seed is `ON CONFLICT (code) DO UPDATE`, an
-- in-place rewrite of the presentation of every type in the chart, run by hand.
--
-- WHAT IT DOES NOT PROTECT AGAINST: the same owner, who can disable or drop it in
-- one statement, and DDL, which walks past every trigger in this schema (the
-- decision log carries that as open). It also does not make a NEW version
-- correct -- it makes the OLD one durable. Those are different claims and only
-- the second is enforced.
--
-- WHAT IT COSTS, stated because it is not free: a typo in a caption is no longer
-- fixable in place. It is a new chart version. ADR-0007 argues at length that a
-- caption is what a reader groups by; a book whose captions can be rewritten
-- under an issued statement has the same hole as one whose fs_lines can.
-- ONE LINE OF THE SHIPPED FUNCTION HAS TO CHANGE FIRST, and finding out why is
-- worth recording. refuse_mutation() raises `USING OLD.id`, and none of the three
-- tables below has an `id` column: the trigger fires, PL/pgSQL cannot resolve the
-- field, and the error is `record "old" has no field "id"` with a CONTEXT line
-- naming refuse_mutation(). The write IS refused -- the transaction aborts either
-- way -- but the message names PL/pgSQL instead of append-only, which is the same
-- class of defect as a comment naming a guard that is not there. The fix reaches
-- the id through to_jsonb(), which returns NULL for a missing key rather than
-- raising, and leaves the journal's message byte-identical because every journal
-- table does have an `id`.
CREATE OR REPLACE FUNCTION refuse_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only: % on % refused. Correct it with a new row.',
        TG_TABLE_NAME, TG_OP, COALESCE(to_jsonb(OLD)->>'id', '(row)')
        USING ERRCODE = '23514';
END $$;

CREATE TRIGGER ck_chart_versions__append_only BEFORE UPDATE OR DELETE ON chart_versions
    FOR EACH ROW EXECUTE FUNCTION refuse_mutation();
ALTER TABLE chart_versions ENABLE ALWAYS TRIGGER ck_chart_versions__append_only;
CREATE TRIGGER ck_chart_versions__no_truncate BEFORE TRUNCATE ON chart_versions
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE chart_versions ENABLE ALWAYS TRIGGER ck_chart_versions__no_truncate;

CREATE TRIGGER ck_fs_lines__append_only BEFORE UPDATE OR DELETE ON fs_lines
    FOR EACH ROW EXECUTE FUNCTION refuse_mutation();
ALTER TABLE fs_lines ENABLE ALWAYS TRIGGER ck_fs_lines__append_only;
CREATE TRIGGER ck_fs_lines__no_truncate BEFORE TRUNCATE ON fs_lines
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE fs_lines ENABLE ALWAYS TRIGGER ck_fs_lines__no_truncate;

CREATE TRIGGER ck_presentation__append_only BEFORE UPDATE OR DELETE ON chart_presentation
    FOR EACH ROW EXECUTE FUNCTION refuse_mutation();
ALTER TABLE chart_presentation ENABLE ALWAYS TRIGGER ck_presentation__append_only;
CREATE TRIGGER ck_presentation__no_truncate BEFORE TRUNCATE ON chart_presentation
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE chart_presentation ENABLE ALWAYS TRIGGER ck_presentation__no_truncate;

GRANT SELECT ON chart_versions, chart_presentation, chart_version_current TO openledger_app;

COMMIT;
