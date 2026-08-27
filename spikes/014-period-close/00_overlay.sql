-- Spike 014 -- the PROPOSED DDL of ADR-0011, applied on top of migrations/00001_baseline.sql.
--
-- THIS IS EVIDENCE, NOT A MIGRATION. Nothing here is applied by `openledger migrate`.
-- The ADR carries the same statements as the proposed baseline edit; this file is how
-- they were proven. Load order: 00001_baseline.sql, schema/chart.sql, then this file.
--
-- Four things:
--   1. a commit-ordered cursor column on the journal            (xid8, ADR-0011 s1)
--   2. ledger_periods        -- resolved period boundaries      (ADR-0011 s5)
--   3. ledger_period_closes  -- one close per tenant/period/ccy (ADR-0011 s2)
--   4. ledger_period_balances -- the effective-axis checkpoint   (ADR-0011 s3)
-- and the three statements re-expressed as parameterised functions (ADR-0011 s4).
--
-- NO TRIGGERS. Every guard below is a key, a CHECK or an exclusion constraint.

-- ----------------------------------------------------------------- 1. the cursor

-- ledger_transactions.xact_id is already here, as
--     bigint NOT NULL DEFAULT pg_current_xact_id()::text::bigint
-- The cast through text is a workaround for xid8 having no bigint cast; it is also
-- lossy in the sense that it discards the type that carries the ordering. Retype it.
ALTER TABLE ledger_transactions
    ALTER COLUMN xact_id DROP DEFAULT,
    ALTER COLUMN xact_id TYPE xid8 USING (xact_id::text::xid8),
    ALTER COLUMN xact_id SET DEFAULT pg_current_xact_id();

-- THE COLUMN THE DESIGN ADDS. An entry's own commit-ordering key.
--
-- Not denormalised from ledger_transactions and deliberately NOT under a composite
-- foreign key like effective_at and currency are, because the two values are allowed
-- to differ and the difference is the point: a leg appended to an already-committed
-- transaction gets a HIGHER xact_id than that transaction, so a report pinned before
-- the append cannot see it. Under an FK to the transaction's value it would inherit
-- the old id and rewrite the issued report. Proven in 05_reproducible_report.sql.
ALTER TABLE ledger_entries
    ADD COLUMN xact_id xid8 NOT NULL DEFAULT pg_current_xact_id();

-- ...and on the event log, which is where an operation that writes no transaction
-- (ADR-0005) has to record its position.
ALTER TABLE ledger_events
    ADD COLUMN xact_id xid8 NOT NULL DEFAULT pg_current_xact_id();

-- The as-of index carries the cursor so the effective-axis aggregate stays a
-- single-table scan under a pinned report. ix_entries__effective is replaced, not
-- supplemented: (tenant_id, account_id, effective_at) is a prefix of this.
DROP INDEX ix_entries__effective;
CREATE INDEX ix_entries__effective
    ON ledger_entries (tenant_id, account_id, effective_at, xact_id);

-- ...and the RECORDED-axis index becomes the COMMIT-axis index. ix_entries__asof_recorded
-- was (tenant_id, account_id, recorded_at DESC, account_seq DESC), an index on a column
-- ADR-0006 proved cannot order commits -- so it served a question that cannot be answered
-- correctly. Same three columns' worth of space, two jobs:
--   * "what did this account read as, as recorded at cursor C" -- now reproducible
--   * the checkpoint's BACKDATED-ARRIVALS term: entries effective before a closed
--     period's end whose xact_id is at or above that close's cursor. Without this index
--     that term scans the whole pre-close prefix and the checkpoint buys nothing.
--     Measured in 05_checkpoint_cost.sql.
DROP INDEX ix_entries__asof_recorded;
CREATE INDEX ix_entries__asof_commit
    ON ledger_entries (tenant_id, account_id, xact_id);

-- ----------------------------------------------------------------- 2. periods

-- for ex_periods__no_overlap, below. Trusted on PostgreSQL 13+.
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE ledger_periods (
    tenant_id  text NOT NULL,
    code       text NOT NULL,              -- '2026-02', 'FY2026Q1' -- a label, not a key of time
    -- HALF-OPEN, AND RESOLVED. starts_at/ends_at are absolute instants, resolved ONCE
    -- from (local date, tz) at the moment the period is created. They are what a
    -- report filters on and what makes an issued statement reproducible: IANA rules
    -- are legislation and change, so a stored (local date, zone) pair is not a stable
    -- instant. Evidence: 06_timezone.sql.
    starts_at  timestamptz NOT NULL,
    ends_at    timestamptz NOT NULL,
    -- PROVENANCE, not the boundary. Whose business date this period is. Recorded so a
    -- reader can say "February in America/New_York"; never re-resolved.
    tz         text NOT NULL,
    CONSTRAINT pk_periods PRIMARY KEY (tenant_id, code),
    CONSTRAINT ck_periods__non_empty CHECK (ends_at > starts_at),
    -- The zone name IS constrainable, declaratively. timezone(text, timestamptz) is
    -- marked IMMUTABLE -- verified, pg_proc.provolatile = 'i' -- so a CHECK may call it,
    -- and an unrecognised zone RAISES rather than returning NULL, which is what makes
    -- this bite: 'Middle/Earth' is refused with `time zone "Middle/Earth" not
    -- recognized`. WHAT IT DOES NOT DO: re-validate when tzdata changes under the
    -- server. PostgreSQL believes this function is immutable and the IANA database is
    -- legislation, which is the whole reason starts_at/ends_at are stored resolved.
    CONSTRAINT ck_periods__tz_known
        CHECK ((timestamp '2000-01-01 00:00' AT TIME ZONE tz) IS NOT NULL),
    -- the target of fk_closes__period, so a close cannot name a period's code without
    -- also naming the instants that period resolved to
    CONSTRAINT uq_periods__bounds UNIQUE (tenant_id, code, starts_at, ends_at),
    -- A tenant's periods may not overlap. Declarative; no trigger, no application
    -- check. COSTS ONE EXTENSION: btree_gist, for the `tenant_id WITH =` operand.
    -- It is a TRUSTED extension on PostgreSQL 13+, so a database owner installs it
    -- without superuser -- verified on 18.6, pg_available_extension_versions.trusted
    -- = t. That is the only dependency this ADR adds outside core.
    CONSTRAINT ex_periods__no_overlap EXCLUDE USING gist (
        tenant_id WITH =, tstzrange(starts_at, ends_at, '[)') WITH &&)
);

-- ----------------------------------------------------------------- 3. the close

-- One close per tenant per period per currency, and the close IS an ordinary
-- transaction: this table records which one. That is what lets income_statement
-- exclude closing entries declaratively instead of matching on a text `kind`.
CREATE TABLE ledger_period_closes (
    tenant_id      text NOT NULL,
    period_code    text NOT NULL,
    currency       char(3) NOT NULL,
    starts_at      timestamptz NOT NULL,   -- carried from the period, under the FK below
    ends_at        timestamptz NOT NULL,
    -- The closing transaction, posted through the ordinary write primitive (ADR-0005).
    -- Nothing here writes it; this row only names it.
    transaction_id uuid NOT NULL,
    -- THE CURSOR THE CHECKPOINT WAS COMPUTED AT. Everything below it had committed;
    -- nothing below it can ever appear. A later arrival backdated into this period is
    -- accepted (append-only) and lands ABOVE this value, so it is a tail term rather
    -- than an invalidation. This is the whole reason the checkpoint is safe.
    computed_at_xid xid8 NOT NULL,
    closed_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_closes PRIMARY KEY (tenant_id, period_code, currency),
    CONSTRAINT ck_closes__currency_iso CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT fk_closes__period FOREIGN KEY (tenant_id, period_code, starts_at, ends_at)
        REFERENCES ledger_periods (tenant_id, code, starts_at, ends_at),
    CONSTRAINT fk_closes__txn FOREIGN KEY (tenant_id, transaction_id)
        REFERENCES ledger_transactions (tenant_id, id),
    -- one transaction closes one thing
    CONSTRAINT uq_closes__txn UNIQUE (tenant_id, transaction_id)
);

-- ----------------------------------------------------------------- 4. the checkpoint

-- The effective-axis checkpoint. DERIVED AND REBUILDABLE -- every row is exactly
-- recomputable from ledger_entries at (effective_at < ends_at, xact_id < computed_at_xid),
-- which is what separates it from the balance_after column spike 009 deleted: bounded
-- (one row per account per period, not per entry), on the axis people actually query,
-- off the write path, and reconcilable.
--
-- PRE-CLOSE balances. The closing transaction's own entries carry an xact_id at or
-- above computed_at_xid, so they are part of the tail like any other entry and the
-- as-of arithmetic needs no special case for them.
CREATE TABLE ledger_period_balances (
    tenant_id      text NOT NULL,
    period_code    text NOT NULL,
    currency       char(3) NOT NULL,
    account_id     uuid NOT NULL,
    -- same shape as ledger_account_balances: unsigned, sign carried by direction
    input          bigint NOT NULL,
    output         bigint NOT NULL,
    CONSTRAINT pk_period_balances PRIMARY KEY (tenant_id, period_code, currency, account_id),
    CONSTRAINT ck_period_balances__non_negative CHECK (input >= 0 AND output >= 0),
    -- a checkpoint row cannot exist without the close that computed it...
    CONSTRAINT fk_period_balances__close FOREIGN KEY (tenant_id, period_code, currency)
        REFERENCES ledger_period_closes (tenant_id, period_code, currency),
    -- ...and carries currency into the account key, as entries and balances do
    CONSTRAINT fk_period_balances__account FOREIGN KEY (tenant_id, account_id, currency)
        REFERENCES ledger_accounts (tenant_id, id, currency)
);

-- ----------------------------------------------------------------- grants
GRANT SELECT ON ledger_periods, ledger_period_closes, ledger_period_balances TO openledger_app;
GRANT INSERT ON ledger_periods, ledger_period_closes, ledger_period_balances TO openledger_app;
