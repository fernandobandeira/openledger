-- 0001 — the ledger core.
--
-- Written by hand, not promoted from the spikes: those hold three competing posting
-- engines (two of them designs we rejected), two competing hold models, and
-- benchmark scaffolding with hardcoded amounts. They were how we learned; they are
-- not a source tree.
--
-- Scope is the CORE only: accounts, transactions, entries, balances, events. The
-- chart of accounts, holds, striping and the completeness layer are later
-- milestones — shipping them now guarantees rewriting them.
--
-- NAMING: ix_<table>__<cols> / uq_<table>__<cols> / ck_<table>__<rule> (ADR-0006).

BEGIN;

CREATE TYPE ledger_category       AS ENUM ('asset','liability','equity','revenue','expense');
CREATE TYPE ledger_normal_balance AS ENUM ('debit','credit');
CREATE TYPE ledger_direction      AS ENUM ('debit','credit');
CREATE TYPE ledger_txn_status     AS ENUM ('pending','posted');
CREATE TYPE account_owner_type    AS ENUM ('company','platform','bank_account','house');

-- ---------------------------------------------------------------- accounts

CREATE TABLE ledger_accounts (
    tenant_id      text NOT NULL,
    id             uuid NOT NULL DEFAULT uuidv7(),
    owner_type     account_owner_type    NOT NULL,
    owner_id       text,                      -- NULL only when owner_type = 'house'
    purpose        text                  NOT NULL,
    category       ledger_category       NOT NULL,
    -- NOT derivable from category: allowance_for_credit_losses is an asset with a
    -- CREDIT normal balance.
    normal_balance ledger_normal_balance NOT NULL,
    currency       char(3)               NOT NULL,
    metadata       jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at     timestamptz NOT NULL DEFAULT now(),

    -- composite key: tenant leads every key in the schema (ADR-0007). Free now,
    -- expensive later -- it is the prerequisite for both partitioning and sharding.
    CONSTRAINT pk_accounts PRIMARY KEY (tenant_id, id),
    CONSTRAINT ck_accounts__house_has_no_owner
        CHECK ((owner_type = 'house') = (owner_id IS NULL)),
    CONSTRAINT ck_accounts__currency_iso CHECK (currency ~ '^[A-Z]{3}$')
);

-- Disjoint sets. A plain UNIQUE would not constrain house rows at all, since
-- owner_id is NULL there and NULL <> NULL.
-- Lets entries reference (account, currency) as a unit, so an entry cannot carry a
-- currency its account does not hold. Verified: without this, USD entries sit
-- happily in EUR accounts and the declared currency is decorative.
CREATE UNIQUE INDEX uq_accounts__id_currency
    ON ledger_accounts (tenant_id, id, currency);

CREATE UNIQUE INDEX uq_accounts__owned
    ON ledger_accounts (tenant_id, owner_type, owner_id, purpose, currency)
    WHERE owner_type <> 'house';
-- House accounts are PER TENANT, not per deployment (ADR-0007): a deployment-global
-- house account makes every tenant contend on one row and blocks tenant-locality.
CREATE UNIQUE INDEX uq_accounts__house
    ON ledger_accounts (tenant_id, purpose, currency)
    WHERE owner_type = 'house';

-- ------------------------------------------------------------ events (ADR-0004)
-- The idempotency spine. Most of the lifecycle writes NO ledger transaction --
-- authorizations, declines, hold expiry, reversals, limit changes -- so idempotency
-- cannot live on ledger_transactions.

CREATE TABLE ledger_events (
    tenant_id        text NOT NULL,
    id               uuid NOT NULL DEFAULT uuidv7(),
    kind             text NOT NULL,
    source           text NOT NULL,          -- processor | treasury | customer | internal
    idempotency_key  text NOT NULL,
    -- sha256 of the canonical request body. Same key + same hash -> replay the
    -- stored result. Same key + DIFFERENT hash -> reject: silently replaying the
    -- wrong result is worse than failing.
    idempotency_hash bytea NOT NULL,
    payload          jsonb NOT NULL,
    effective_at     timestamptz NOT NULL,
    recorded_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_events PRIMARY KEY (tenant_id, id)
);

-- NULLS NOT DISTINCT is INERT here and kept only for uniformity: both columns are
-- NOT NULL, so there are no NULLs to make distinct. It was load-bearing when
-- house-scoped rows carried tenant_id NULL; they no longer can. Where the clause
-- still earns its keep is uq_accounts__owned, whose owner_id IS nullable.
-- (Found by mutation testing: removing it changed nothing.)
CREATE UNIQUE INDEX uq_events__idempotency
    ON ledger_events (tenant_id, idempotency_key) NULLS NOT DISTINCT;

-- ------------------------------------------------------------ transactions

CREATE TABLE ledger_transactions (
    tenant_id       text NOT NULL,
    id              uuid NOT NULL DEFAULT uuidv7(),
    event_id        uuid,                    -- the event that caused this
    kind            text NOT NULL,
    status          ledger_txn_status NOT NULL,   -- NEVER MUTATES
    -- from the SOURCE's clock, never now(): a clearing's is the network business
    -- date, not our webhook's arrival.
    effective_at    timestamptz NOT NULL,
    recorded_at     timestamptz NOT NULL DEFAULT now(),
    resolves_id     uuid,                    -- pending -> posted is a NEW row
    reverses_id     uuid,
    external_ref    jsonb NOT NULL DEFAULT '{}'::jsonb,
    metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,

    CONSTRAINT pk_txn PRIMARY KEY (tenant_id, id),
    -- the target of fk_entries__txn_effective, below
    CONSTRAINT uq_txn__id_effective UNIQUE (tenant_id, id, effective_at),
    CONSTRAINT fk_txn__event    FOREIGN KEY (tenant_id, event_id)
        REFERENCES ledger_events (tenant_id, id),
    CONSTRAINT fk_txn__resolves FOREIGN KEY (tenant_id, resolves_id)
        REFERENCES ledger_transactions (tenant_id, id),
    CONSTRAINT fk_txn__reverses FOREIGN KEY (tenant_id, reverses_id)
        REFERENCES ledger_transactions (tenant_id, id),
    -- A transaction cannot reverse or resolve ITSELF, and cannot be both a
    -- resolution and a reversal. All three committed before these existed.
    CONSTRAINT ck_txn__no_self_reference
        CHECK (id <> COALESCE(reverses_id, resolves_id, '00000000-0000-0000-0000-000000000000'::uuid)
               AND id IS DISTINCT FROM reverses_id AND id IS DISTINCT FROM resolves_id),
    CONSTRAINT ck_txn__not_both
        CHECK (NOT (reverses_id IS NOT NULL AND resolves_id IS NOT NULL))
);

-- A transaction may be reversed once, and resolved once. We refuse to mutate, so
-- we cannot use the UPDATE ... WHERE reverted_at IS NULL guard.
CREATE UNIQUE INDEX uq_txn__one_reversal
    ON ledger_transactions (tenant_id, reverses_id) WHERE reverses_id IS NOT NULL;
CREATE UNIQUE INDEX uq_txn__one_resolution
    ON ledger_transactions (tenant_id, resolves_id) WHERE resolves_id IS NOT NULL;

-- ------------------------------------------------------------ entries

CREATE TABLE ledger_entries (
    -- tenant_id is what makes "no transaction spans two tenants" EXPRESSIBLE.
    -- Without it, M1's own acceptance criterion could not be stated.
    tenant_id      text NOT NULL,
    id             uuid NOT NULL DEFAULT uuidv7(),
    transaction_id uuid NOT NULL,
    account_id     uuid NOT NULL,
    direction      ledger_direction NOT NULL,   -- direction carries the sign,
    amount_minor   bigint NOT NULL,             -- never the amount
    currency       char(3) NOT NULL,
    account_seq    bigint NOT NULL,             -- monotonic per account
    -- Running balance on the RECORDED axis only. It cannot answer a business-date
    -- question once anything is backdated (ADR-0003).
    --
    -- SIGN CONVENTION: debit-positive. balance_after is SUM(debits) - SUM(credits)
    -- for this account, so a credit-normal account carries a negative running
    -- balance. This was undefined until the drift view forced the question -- the
    -- golden trace stored it natural-positive, which disagrees. Presentation flips
    -- the sign using the account's normal_balance; storage does not.
    balance_after  bigint NOT NULL,
    recorded_at    timestamptz NOT NULL DEFAULT now(),
    -- denormalised from the transaction so the effective-axis aggregate is a
    -- single-table index scan.
    effective_at   timestamptz NOT NULL,

    CONSTRAINT pk_entries PRIMARY KEY (tenant_id, id),
    CONSTRAINT ck_entries__amount_positive CHECK (amount_minor > 0),
    -- account_seq orders history: it is the key ledger_balance_drift walks and the
    -- key every as-of reconstruction depends on. Nothing enforced even POSITIVITY
    -- -- a seq of -9999 inserted later silently reordered an account's past.
    -- Gaplessness itself is still only asserted by the suite, not enforced here.
    CONSTRAINT ck_entries__seq_positive CHECK (account_seq > 0),
    -- ISO 4217 is uppercase. Without this 'usd' and 'USD' are different
    -- currencies: each "balances" on its own, a customer's USD balance reads
    -- 100.00 when it is 300.00, and uq_accounts__owned is defeated because the
    -- same owner can then hold two operating_cash accounts.
    CONSTRAINT ck_entries__currency_iso CHECK (currency ~ '^[A-Z]{3}$'),
    -- THE cross-tenant guard. A composite FK makes a transaction spanning two
    -- tenants structurally impossible rather than merely discouraged.
    CONSTRAINT fk_entries__txn FOREIGN KEY (tenant_id, transaction_id)
        REFERENCES ledger_transactions (tenant_id, id),
    -- currency is part of the key: an entry inherits its account's currency and
    -- cannot contradict it.
    CONSTRAINT fk_entries__account FOREIGN KEY (tenant_id, account_id, currency)
        REFERENCES ledger_accounts (tenant_id, id, currency),
    -- effective_at is denormalised from the transaction, and nothing held it
    -- honest: a transaction dated 2026-06-15 accepted 1,000 entries dated
    -- 1999-01-01. This column is the entire basis of ADR-0003 and every
    -- business-date report. Same trick as the currency FK above -- make the
    -- denormalised copy part of a composite key so it CANNOT disagree.
    CONSTRAINT fk_entries__txn_effective FOREIGN KEY (tenant_id, transaction_id, effective_at)
        REFERENCES ledger_transactions (tenant_id, id, effective_at),
    CONSTRAINT uq_entries__account_seq UNIQUE (tenant_id, account_id, account_seq)
);

CREATE INDEX ix_entries__balance_lookup
    ON ledger_entries (tenant_id, account_id, account_seq DESC) INCLUDE (balance_after);
CREATE INDEX ix_entries__asof_recorded
    ON ledger_entries (tenant_id, account_id, recorded_at DESC, account_seq DESC);
CREATE INDEX ix_entries__effective
    ON ledger_entries (tenant_id, account_id, effective_at);
CREATE INDEX ix_entries__txn ON ledger_entries (tenant_id, transaction_id);

-- ------------------------------------------------------------ balances
-- The write-side serialization point AND the O(1) current-balance read. One atomic
-- upsert returns the new balance and the next sequence number together, so the row
-- lock IS the serialization -- no SELECT max(), no advisory lock, no retry loop.
--
-- input/output kept separate rather than one signed balance: the upsert stays
-- commutative, gross turnover is free, and no row needs to know the sign convention.

CREATE TABLE ledger_account_balances (
    tenant_id  text    NOT NULL,
    account_id uuid    NOT NULL,
    currency   char(3) NOT NULL,
    input      bigint  NOT NULL DEFAULT 0,
    output     bigint  NOT NULL DEFAULT 0,
    last_seq   bigint  NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_balances PRIMARY KEY (tenant_id, account_id, currency),
    CONSTRAINT fk_balances__account FOREIGN KEY (tenant_id, account_id)
        REFERENCES ledger_accounts (tenant_id, id),
    CONSTRAINT ck_balances__non_negative CHECK (input >= 0 AND output >= 0)
);

-- ------------------------------------------------------------ the invariant
-- Balanced per currency, enforced by the DATABASE, deferred to COMMIT so a
-- transaction can be built up entry by entry.

CREATE FUNCTION assert_transaction_balances() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE offending record; v_tenant text; v_txn uuid;
BEGIN
    -- OLD on DELETE, NEW otherwise. The trigger used to fire on INSERT only, which
    -- left a hole big enough to drive through: deleting one leg of a committed
    -- transaction left 900 debits against 0 credits and nothing complained. REVOKE
    -- is a grant, not a constraint, and migrations run as a privileged role.
    v_tenant := COALESCE(NEW.tenant_id, OLD.tenant_id);
    v_txn    := COALESCE(NEW.transaction_id, OLD.transaction_id);

    SELECT e.currency,
           SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit')  AS dr,
           SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit') AS cr
      INTO offending
      FROM ledger_entries e
     WHERE e.tenant_id = v_tenant AND e.transaction_id = v_txn
     GROUP BY e.currency
    HAVING COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'), 0)
        <> COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'), 0)
     LIMIT 1;

    IF FOUND THEN
        -- COALESCE because a one-legged transaction reports the missing side as
        -- NULL, which reads as though the value were unknown rather than zero.
        -- ERRCODE 23514 (check_violation), not the plpgsql default P0001: a caller
        -- must be able to tell an integrity violation from any other raised error.
        RAISE EXCEPTION 'transaction % does not balance in %: debits=% credits=%',
            v_txn, offending.currency,
            COALESCE(offending.dr, 0), COALESCE(offending.cr, 0)
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER ck_entries__balances
    AFTER INSERT OR UPDATE OR DELETE ON ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION assert_transaction_balances();

-- ENABLE ALWAYS, not the default ENABLE ORIGIN. `SET session_replication_role =
-- 'replica'` is the logical-replication apply path and what `pg_restore
-- --disable-triggers` uses -- and under it an unbalanced transaction COMMITTED
-- (verified: 500 debits, 0 credits). A subscriber must enforce the same invariant
-- as its publisher, or replication is a laundering channel for corrupt rows.
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ck_entries__balances;

-- A transaction with NO entries is vacuously balanced, so the row trigger above
-- never fires for it. Verified: a `posted` clearing with zero entries committed,
-- consuming an idempotency key. Oracle GL refuses the same thing -- "journal
-- entries must have at least two journal entry lines."
CREATE FUNCTION assert_transaction_has_entries() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    SELECT count(*) INTO n FROM ledger_entries
     WHERE tenant_id = NEW.tenant_id AND transaction_id = NEW.id;
    IF n < 2 THEN
        RAISE EXCEPTION 'transaction % has % entr%; a transaction needs at least two',
            NEW.id, n, CASE WHEN n = 1 THEN 'y' ELSE 'ies' END
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER ck_txn__has_entries
    AFTER INSERT ON ledger_transactions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION assert_transaction_has_entries();
ALTER TABLE ledger_transactions ENABLE ALWAYS TRIGGER ck_txn__has_entries;

-- ------------------------------------------------------------ append-only
-- ADR-0001 says entries are "never updated or deleted, enforced by revoking the
-- grants, not by convention." Until now that was a description, not an
-- enforcement: a plain UPDATE mutated four committed entries in testing.

-- Roles are CLUSTER-global, not per-database, so a bare CREATE ROLE makes this
-- migration fail on the second database it is applied to. Found by applying it
-- twice.
DO $$ BEGIN
    CREATE ROLE openledger_app NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
GRANT USAGE ON SCHEMA public TO openledger_app;
GRANT SELECT, INSERT ON ledger_accounts, ledger_events, ledger_transactions,
                        ledger_entries TO openledger_app;
GRANT SELECT, INSERT, UPDATE ON ledger_account_balances TO openledger_app;
-- The ledger is append-only. The balances table is a derived cache and may be
-- updated; the journal may not.
--
-- These REVOKEs are defensive, not the mechanism: the GRANT above never granted
-- UPDATE or DELETE in the first place, so removing them changes nothing today
-- (verified by mutation). They exist so that a later careless GRANT ALL does not
-- silently make the journal mutable. The property is real -- granting UPDATE and
-- then dropping these lines IS caught by the test suite -- but it comes from the
-- narrow GRANT, not from these lines.
REVOKE UPDATE, DELETE ON ledger_entries      FROM openledger_app;
REVOKE UPDATE, DELETE ON ledger_transactions FROM openledger_app;
REVOKE        DELETE ON ledger_events        FROM openledger_app;
REVOKE        DELETE ON ledger_account_balances FROM openledger_app;

-- ------------------------------------------------------------ the corruption alarm
-- ADR-0003 leans on balance_after and a recomputation always agreeing, calling it a
-- free corruption alarm. It was described and never implemented. Here it is.
-- Compares against the debit-positive convention declared on balance_after above.
-- The corruption alarm, over all THREE copies of every balance.
--
-- Two defects found by mutation testing, both of which made this look like a
-- working alarm while it watched almost nothing:
--
--   * It compared only the LAST balance_after per account, via last_value() over
--     an unbounded frame. Corrupting any INTERMEDIATE running balance was
--     invisible -- and ADR-0003 justifies balance_after precisely as the
--     as-of/point-in-time read, i.e. the rows this did not check. Now per row.
--   * It ignored ledger_account_balances entirely -- the copy the hot path
--     trusts, and the only one the app role may UPDATE. Verified: input-output
--     set to 999999 by hand, alarm silent.
--
-- It also returned one row PER ENTRY (1,000 entries, 1,000 identical rows), so
-- the "free" alarm materialised the whole table.
CREATE VIEW ledger_balance_drift AS
WITH j AS (
    SELECT e.tenant_id, e.account_id, e.currency, e.account_seq,
           e.balance_after AS stored,
           SUM(CASE WHEN e.direction = 'debit' THEN e.amount_minor ELSE -e.amount_minor END)
               OVER (PARTITION BY e.tenant_id, e.account_id, e.currency
                     ORDER BY e.account_seq ROWS UNBOUNDED PRECEDING) AS recomputed
    FROM ledger_entries e
), first_bad AS (
    SELECT DISTINCT ON (tenant_id, account_id, currency)
           tenant_id, account_id, currency, account_seq, stored, recomputed
      FROM j WHERE stored <> recomputed
     ORDER BY tenant_id, account_id, currency, account_seq
), latest AS (
    SELECT DISTINCT ON (tenant_id, account_id, currency)
           tenant_id, account_id, currency, recomputed AS journal_total
      FROM j ORDER BY tenant_id, account_id, currency, account_seq DESC
)
SELECT COALESCE(l.tenant_id,  b.tenant_id)  AS tenant_id,
       COALESCE(l.account_id, b.account_id) AS account_id,
       COALESCE(l.currency,   b.currency)   AS currency,
       fb.account_seq  AS first_bad_seq,   -- NULL = the running balances agree
       fb.stored,
       fb.recomputed,
       l.journal_total,
       (b.input - b.output) AS cached,     -- ledger_account_balances
       CASE WHEN fb.account_seq IS NOT NULL THEN 'running balance diverges at seq '
                                                 || fb.account_seq
            WHEN b.account_id IS NULL       THEN 'no cached balance row'
            WHEN l.account_id IS NULL       THEN 'cached balance with no entries'
            ELSE 'cached balance disagrees with the journal'
       END AS problem
FROM latest l
FULL OUTER JOIN ledger_account_balances b
  ON b.tenant_id = l.tenant_id AND b.account_id = l.account_id AND b.currency = l.currency
LEFT JOIN first_bad fb
  ON fb.tenant_id = COALESCE(l.tenant_id, b.tenant_id)
 AND fb.account_id = COALESCE(l.account_id, b.account_id)
 AND fb.currency   = COALESCE(l.currency, b.currency)
WHERE fb.account_seq IS NOT NULL
   OR (b.input - b.output) IS DISTINCT FROM l.journal_total;

COMMIT;
