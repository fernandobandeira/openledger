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
    -- The database transaction that created this row. Entries may only be added
    -- by that same transaction (ck_entries__sealed below).
    --
    -- Without this, append-only protected the ENTRY and not the JOURNAL: the app
    -- role, holding nothing but its ordinary INSERT grant, could add a balanced,
    -- correctly-dated, correctly-sequenced pair of legs to a transaction committed
    -- and reported months earlier. February revenue went from 500.00 to 1,166.00
    -- with the drift view, the accounting equation and the balance sheet all
    -- green, because every constraint in this file was satisfied.
    xact_id         bigint NOT NULL DEFAULT pg_current_xact_id()::text::bigint,

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
    -- currency is IN the foreign key, as it is for entries. Without it the cache
    -- -- the copy the hot path reads, and the only one the app role may write --
    -- accepted a second row for the same account under 'usd' or 'JPY', splitting
    -- one account's balance across two rows.
    CONSTRAINT fk_balances__account FOREIGN KEY (tenant_id, account_id, currency)
        REFERENCES ledger_accounts (tenant_id, id, currency),
    CONSTRAINT ck_balances__non_negative CHECK (input >= 0 AND output >= 0),
    CONSTRAINT ck_balances__currency_iso CHECK (currency ~ '^[A-Z]{3}$')
);

-- ------------------------------------------------------------ the invariant
-- Balanced per currency, enforced by the DATABASE, deferred to COMMIT so a
-- transaction can be built up entry by entry.

-- recorded_at is the INSERTION axis. It is now assigned, never accepted.
--
-- effective_at was made honest by putting it inside a composite key. recorded_at
-- -- the other half of the bitemporal claim, the axis every "reproducible as of
-- any date, forever" statement rests on -- had a DEFAULT and nothing else. It was
-- client-supplied, unconstrained, and not even consistent between the two legs of
-- one transaction. Three consequences, all reproduced:
--
--   * an already-issued recorded-axis report could be rewritten months later by
--     inserting a new transaction that CLAIMS to predate it -- no seal broken, no
--     UPDATE, no DELETE, and zero drift
--   * one transaction's legs could carry different recorded_at, so a recorded-axis
--     report of a perfectly balanced journal came back UNBALANCED
--   * and made silent: two honest sales, each with one leg slipped forward, gave a
--     GREEN recorded-axis report that was 50% wrong
--
-- now() is transaction-start time, so all legs of a transaction now share one
-- value by construction, and no caller can choose it. What this does NOT fix is
-- monotonicity with COMMIT order -- see ADR-0005, still proposed. Until that
-- lands, balance_after cannot answer a recorded-axis as-of question either; the
-- aggregate can.
CREATE FUNCTION assign_recorded_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.recorded_at := now();
    RETURN NEW;
END $$;

CREATE TRIGGER ck_entries__recorded_at BEFORE INSERT ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION assign_recorded_at();
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ck_entries__recorded_at;
CREATE TRIGGER ck_txn__recorded_at BEFORE INSERT ON ledger_transactions
    FOR EACH ROW EXECUTE FUNCTION assign_recorded_at();
ALTER TABLE ledger_transactions ENABLE ALWAYS TRIGGER ck_txn__recorded_at;
CREATE TRIGGER ck_events__recorded_at BEFORE INSERT ON ledger_events
    FOR EACH ROW EXECUTE FUNCTION assign_recorded_at();
ALTER TABLE ledger_events ENABLE ALWAYS TRIGGER ck_events__recorded_at;

-- ---- the transaction record itself is immutable -----------------------------
-- Two escapes closed at once. The "fewer than two entries" DELETE guard gated on
-- the parent still existing, so deleting the legs AND the transaction row in one
-- statement erased 50,000 of revenue with every check green. And xact_id -- the
-- seal's whole basis -- was an ordinary mutable column: one UPDATE re-opened a
-- committed, already-reported transaction and appended to it.
CREATE FUNCTION assert_transaction_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'transaction % is history and cannot be deleted; reverse it instead',
            OLD.id USING ERRCODE = '23514';
    END IF;
    -- metadata and external_ref are annotation; everything else is the record
    IF ROW(NEW.tenant_id, NEW.id, NEW.event_id, NEW.kind, NEW.status, NEW.effective_at,
           NEW.recorded_at, NEW.resolves_id, NEW.reverses_id, NEW.xact_id)
       IS DISTINCT FROM
       ROW(OLD.tenant_id, OLD.id, OLD.event_id, OLD.kind, OLD.status, OLD.effective_at,
           OLD.recorded_at, OLD.resolves_id, OLD.reverses_id, OLD.xact_id) THEN
        RAISE EXCEPTION
            'transaction % is immutable; only metadata and external_ref may change',
            OLD.id USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER ck_txn__immutable BEFORE UPDATE OR DELETE ON ledger_transactions
    FOR EACH ROW EXECUTE FUNCTION assert_transaction_immutable();
ALTER TABLE ledger_transactions ENABLE ALWAYS TRIGGER ck_txn__immutable;

-- A transaction's entry set is closed when its creating transaction commits.
CREATE FUNCTION assert_entry_seals() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_xact bigint;
BEGIN
    SELECT xact_id INTO v_xact FROM ledger_transactions
     WHERE tenant_id = NEW.tenant_id AND id = NEW.transaction_id;
    -- If there is no such transaction, say nothing: fk_entries__txn is the right
    -- error for that, and it is the one that names the cross-tenant guard.
    IF v_xact IS NOT NULL
       AND v_xact IS DISTINCT FROM pg_current_xact_id()::text::bigint THEN
        RAISE EXCEPTION
            'transaction % is already committed; its entries are sealed. Correct it '
            'with a reversing transaction, not by appending legs', NEW.transaction_id
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;

-- account_seq is ASSIGNED from the journal, never accepted and never validated
-- against the cache.
--
-- The previous version compared the incoming sequence against
-- ledger_account_balances.last_seq -- a column the app role is granted UPDATE on.
-- So the counter was not issued, it was ASKED: rewind last_seq into a reserved
-- gap in one transaction, back-fill the gap in another, put the counter back, and
-- gross turnover on a closed period went from 1,400.00 to 1,551,400.00 with every
-- running balance correct, the cache in perfect agreement, and zero drift rows.
-- The alarm detects disagreement, never fabrication, so it could not see it.
--
-- Deriving it from the journal under the row lock the balance upsert already holds
-- closes the gap-creation, the gap-filling and the brand-new-account case at once
-- (the old trigger was a no-op when no cache row existed yet, so ANY sequence was
-- accepted, including bigint max, which permanently bricked the account).
CREATE FUNCTION assign_entry_seq() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    SELECT COALESCE(MAX(account_seq), 0) + 1 INTO NEW.account_seq
      FROM ledger_entries
     WHERE tenant_id = NEW.tenant_id AND account_id = NEW.account_id
       AND currency = NEW.currency;
    RETURN NEW;
END $$;

CREATE TRIGGER ck_entries__seq BEFORE INSERT ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION assign_entry_seq();
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ck_entries__seq;

-- Entries are immutable. ck_txn__immutable protects the transaction row; the table
-- with the STRONGER stated guarantee had only a REVOKE, and this file says in
-- terms that "REVOKE is a grant, not a constraint, and migrations run as a
-- privileged role". As the owner, one UPDATE rewrote recorded_at across ten
-- entries and moved an already-issued as-of report; one more made a balanced
-- journal report UNBALANCED by moving only the credit legs.
CREATE FUNCTION assert_entry_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION
        'ledger entries are immutable: % on entry % refused. Correct the books with '
        'a reversing transaction', TG_OP, OLD.id
        USING ERRCODE = '23514';
END $$;

CREATE TRIGGER ck_entries__immutable BEFORE UPDATE OR DELETE ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION assert_entry_immutable();
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ck_entries__immutable;

CREATE TRIGGER ck_entries__sealed
    BEFORE INSERT ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION assert_entry_seals();
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ck_entries__sealed;

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

    -- Deleting EVERY leg leaves a zero-row GROUP BY, so the check above finds
    -- nothing and passes -- the same "vacuously balanced" reasoning that justified
    -- ck_txn__has_entries on INSERT, in the delete direction. Verified: a committed
    -- 2-leg transaction was reduced to zero entries, the posted row survived, and
    -- with its cached balances also removed the drift view returned nothing, the
    -- balance sheet balanced, and the accounting equation returned no rows at all.
    IF TG_OP = 'DELETE'
       AND EXISTS (SELECT 1 FROM ledger_transactions
                    WHERE tenant_id = v_tenant AND id = v_txn)
       AND (SELECT count(*) FROM ledger_entries
             WHERE tenant_id = v_tenant AND transaction_id = v_txn) < 2 THEN
        RAISE EXCEPTION
            'transaction % would be left with fewer than two entries', v_txn
            USING ERRCODE = '23514';
    END IF;

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

-- ...and the FOREIGN KEYS, which were not. `ENABLE ALWAYS` was applied to the two
-- hand-written constraint triggers and to nothing else, so under
-- session_replication_role='replica' all three composite FKs were skipped:
-- verified, a transaction spanning two tenants, with both legs carrying a currency
-- their account does not hold, dated 27 years before their own transaction --
-- every guard the composite keys exist to provide, on the replication apply path.
-- Referential integrity is implemented as system triggers, so it takes the same
-- treatment.
-- EVERY table that participates in a foreign key, not a hand-written list.
--
-- The list version covered ledger_entries, ledger_transactions and
-- ledger_account_balances -- and missed the REFERENCED side, which lives on
-- ledger_accounts and ledger_events. Under replica, deleting two rows from
-- ledger_accounts removed a whole balanced sub-book: every report INNER JOINs
-- ledger_accounts, so revenue went to zero, the equation and the balance sheet
-- both stayed BALANCED, and eight orphaned entries worth 310,280,000 minor units
-- stayed in the journal with the drift view silent.
--
-- 0002 re-runs this same block, because its foreign keys do not exist yet here.
CREATE PROCEDURE enforce_triggers_on_replicas() LANGUAGE plpgsql AS $$
DECLARE t record;
BEGIN
    FOR t IN
        SELECT c.relname AS tbl, tg.tgname
          FROM pg_trigger tg
          JOIN pg_class c ON c.oid = tg.tgrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND tg.tgisinternal AND tg.tgenabled = 'O'
    LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I', t.tbl, t.tgname);
    END LOOP;
END $$;

CALL enforce_triggers_on_replicas();

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
-- These REVOKEs are defensive, and their limits are worth stating plainly, because
-- an earlier comment here overstated them. A REVOKE is a point-in-time change to a
-- privilege, NOT a standing prohibition: a later `GRANT ALL` re-grants everything,
-- including TRUNCATE, and verified -- `SET ROLE openledger_app; TRUNCATE
-- ledger_entries;` then empties the journal. Nothing in SQL can stop that.
--
-- So the property comes from the NARROW GRANT above and from never widening it.
-- These lines make the intent explicit and make an accidental widening obvious in
-- review; they are not a backstop against a deliberate one.
-- TRUNCATE is included deliberately. It is not covered by DELETE, it fires no row
-- trigger, and it was verified reachable: after a careless `GRANT ALL`, the shipped
-- REVOKEs left TRUNCATE in place and `SET ROLE openledger_app; TRUNCATE
-- ledger_entries;` succeeded. That is the whole journal, silently, past every
-- constraint in this file.
-- A child table under INHERITS (ledger_entries) inherits the CHECK constraints and
-- NOTHING else -- no triggers, no foreign keys, no unique indexes -- while its rows
-- remain visible through the parent to every view. Verified: two legs appended to a
-- long-committed transaction through such a child, with the seal, the append-only
-- grant and the drift alarm all intact and silent. The invariants here are
-- per-table, not per-hierarchy, and SQL cannot make them otherwise; the least this
-- file can do is not hand out the privilege that reaches it.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

REVOKE UPDATE, DELETE, TRUNCATE ON ledger_entries      FROM openledger_app;
REVOKE UPDATE, DELETE, TRUNCATE ON ledger_transactions FROM openledger_app;
REVOKE        DELETE, TRUNCATE ON ledger_events        FROM openledger_app;
REVOKE        DELETE, TRUNCATE ON ledger_account_balances FROM openledger_app;

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
           tenant_id, account_id, currency, recomputed AS journal_total,
           account_seq AS journal_last_seq
      FROM j ORDER BY tenant_id, account_id, currency, account_seq DESC
), gross AS (
    SELECT e.tenant_id, e.account_id, e.currency,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'),0)  AS journal_debits,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'),0) AS journal_credits
      FROM ledger_entries e GROUP BY e.tenant_id, e.account_id, e.currency
)
SELECT COALESCE(l.tenant_id,  b.tenant_id)  AS tenant_id,
       COALESCE(l.account_id, b.account_id) AS account_id,
       COALESCE(l.currency,   b.currency)   AS currency,
       fb.account_seq  AS first_bad_seq,   -- NULL = the running balances agree
       fb.stored,
       fb.recomputed,
       l.journal_total, l.journal_last_seq, gr.journal_debits, gr.journal_credits,
       (b.input - b.output) AS cached,     -- ledger_account_balances
       CASE WHEN fb.account_seq IS NOT NULL THEN 'running balance diverges at seq '
                                                 || fb.account_seq
            WHEN b.account_id IS NULL       THEN 'no cached balance row'
            WHEN l.account_id IS NULL       THEN 'cached balance with no entries'
            WHEN b.last_seq IS DISTINCT FROM l.journal_last_seq
                                            THEN 'cached last_seq disagrees with the journal'
            WHEN b.input IS DISTINCT FROM gr.journal_debits
              OR b.output IS DISTINCT FROM gr.journal_credits
                                            THEN 'cached gross turnover disagrees with the journal'
            ELSE 'cached balance disagrees with the journal'
       END AS problem
FROM latest l
LEFT JOIN gross gr ON gr.tenant_id=l.tenant_id AND gr.account_id=l.account_id
                  AND gr.currency=l.currency
FULL OUTER JOIN ledger_account_balances b
  ON b.tenant_id = l.tenant_id AND b.account_id = l.account_id AND b.currency = l.currency
LEFT JOIN first_bad fb
  ON fb.tenant_id = COALESCE(l.tenant_id, b.tenant_id)
 AND fb.account_id = COALESCE(l.account_id, b.account_id)
 AND fb.currency   = COALESCE(l.currency, b.currency)
WHERE fb.account_seq IS NOT NULL
   OR (b.input - b.output) IS DISTINCT FROM l.journal_total
   -- input and output are checked INDIVIDUALLY, not just their difference. The
   -- reason they are stored separately is that gross turnover is then free -- and
   -- gross turnover was the one thing nothing validated: adding 9,999,999.99 to
   -- both sides left the difference intact and the alarm silent.
   OR b.input  IS DISTINCT FROM gr.journal_debits
   OR b.output IS DISTINCT FROM gr.journal_credits
   -- last_seq drives the next account_seq. Poisoned downward it is a permanent
   -- per-account denial of service (every later posting hits uq_entries__account_seq);
   -- poisoned upward it silently corrupts balance_after. It was outside the alarm.
   OR b.last_seq IS DISTINCT FROM l.journal_last_seq;

COMMIT;
