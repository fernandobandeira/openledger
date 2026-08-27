-- 00001 -- the core ledger, declaratively.
--
-- This is migration 00001, applied by `openledger migrate` (ADR-0003). It is one
-- flat file on purpose: the readability of a single declarative schema is worth
-- more than a change history nobody reads, and every later change is a NEW
-- numbered migration beside it. There are no down migrations -- a down migration
-- on a ledger is a lie or data loss (ADR-0003).
--
-- IT CARRIES NO `BEGIN;`/`COMMIT;` OF ITS OWN, DELIBERATELY. The runner wraps each
-- migration in a transaction; an inner `COMMIT;` ends it early, so a failure after
-- that line leaves objects behind and is not recorded as applied, and the retry
-- dies on `relation already exists`. That was a real defect in this file's
-- ancestor. Do not add them back.
--
-- WHAT IT DOES NOT CONTAIN. The card reference product -- authorizations, holds
-- and clearing -- is parked in `parked/card/` and is not applied by any migration
-- today. ADR-0008 decided it returns as its own `card` PostgreSQL schema inside
-- this same migration set; until someone invests in that, a deployment gets the
-- ledger core and nothing else. The two trigger functions below are the only
-- objects that half depended on.
--
-- POSTGRESQL 18 IS A FLOOR, NOT A PREFERENCE: `uuidv7()` is the default on four
-- tables here and does not exist before 18.
--
-- A TRIGGER NEEDS A WRITTEN JUSTIFICATION. The default is none. Two invariants
-- clear that bar and are implemented near the bottom of this file; everything else
-- is a CHECK, a key, a GRANT, or one code path in the writer (ADR-0004). No
-- PL/pgSQL business logic, no orchestration, no derivation-with-backfill, and no
-- logic in views beyond reporting.


CREATE TYPE ledger_category       AS ENUM ('asset','liability','equity','revenue','expense');

CREATE TYPE ledger_normal_balance AS ENUM ('debit','credit');

CREATE TYPE ledger_direction      AS ENUM ('debit','credit');

CREATE TYPE ledger_txn_status     AS ENUM ('pending','posted');

CREATE TYPE account_owner_type    AS ENUM ('company','platform','bank_account','house');

-- ----------------------------------------------------------------------
-- the chart of accounts -- what an account MEANS



-- Every account type maps to exactly one financial-statement line. This is what
-- makes omission structurally impossible: reports enumerate from the chart
-- outward, so there is no parameter in which to pass an incomplete account list.
CREATE TABLE fs_lines (
    code       text CONSTRAINT pk_fs_lines PRIMARY KEY,
    -- The caption is what a reader sees, so two lines carrying the SAME caption
    -- are indistinguishable on the face of the statement -- which is exactly the
    -- harm the restricted-cash split exists to prevent, arrived at from the other
    -- direction. Giving `restricted_cash` the caption 'Cash and cash equivalents'
    -- passed every trigger and every test: the split was real in the chart and
    -- invisible in the report. Nothing in the suite reads a caption, so this is
    -- the constraint rather than a test.
    -- A CAPTION IS DISPLAY TEXT, NOT AN IDENTITY -- and three rounds of trying to
    -- make it one are why that sentence is here rather than a stronger one.
    --
    -- The guard below normalises whitespace and case, which stops the accidents
    -- and the earlier measured defects: 'Current year earnings ' with a trailing
    -- space passed the reservation, and one-argument btrim() let a tab, a newline,
    -- an NBSP or a zero-width space through the version that replaced it -- each
    -- time putting customer suspense under a line pixel-identical to the derived
    -- earnings plug, balanced, with the drift views empty.
    --
    -- IT DOES NOT MAKE A CAPTION SAFE TO KEY ON, and the claim that it compared
    -- "as a reader sees it" was not something a CHECK can do. One codepoint
    -- disproves it: `Undistributed earnings (ѕince inception)` with a Cyrillic
    -- U+0455 for the Latin s passes this CHECK and the unique index, prints
    -- identically, and showed 940.00 of undistributed earnings against a true
    -- 500.00 with every report green. Unicode confusables are unbounded and a
    -- blocklist of them is a losing game.
    --
    -- So the rule is stated rather than enforced: **consumers key on `fs_line`,
    -- the code**, which ck_fs_lines__code_reserved does defend and which
    -- `balance_sheet` emits for exactly this reason. What follows is defence in
    -- depth against typos, not a guarantee about what a human eye can tell apart.
    caption    text NOT NULL CONSTRAINT ck_fs_lines__caption_clean
                   CHECK (caption = btrim(caption, E' \t\n\r\u00a0\u200b\u2007\u202f')
                          AND caption <> ''
                          AND caption !~ '[\u0000-\u001f\u00a0\u200b-\u200f\u2028\u2029\u202f\ufeff]'),
    statement  text NOT NULL CONSTRAINT ck_fs_lines__statement
                   CHECK (statement IN ('balance_sheet','income_statement')),
    -- Which side of the statement this line sits on, declared rather than
    -- inferred. balance_sheet used to derive it from whatever happened to be
    -- posted (`bool_or(category = 'asset')`), so a line with NO activity evaluated
    -- to NULL and landed on the liability/equity side -- inferring the chart from
    -- the data, in the one report whose whole purpose is the opposite.
    -- side must belong to the statement. The CHECK used to admit all four values on
    -- either statement, and a balance-sheet roll-up counts only 'asset' and
    -- 'liability_equity' -- so a balance-sheet line carrying side 'debit' was
    -- counted on NEITHER side and vanished. Verified: 90% of a balance sheet
    -- missing, reporting balanced = true.
    side       text NOT NULL,
    -- `current_year_earnings` is SYNTHESISED by the balance_sheet view for
    -- un-closed earnings. A chart that also declares a real line by that code
    -- produces two rows with the same caption and no way to tell them apart --
    -- one an account subtotal, one a derived plug.
    CONSTRAINT ck_fs_lines__code_reserved
        CHECK (code <> 'current_year_earnings'),
    -- ...AND THE CAPTION, which is the half that actually does the harm the
    -- comment above describes. balance_sheet emits `'current_year_earnings',
    -- 'Current year earnings'` as LITERALS, so the synthesised row sits outside
    -- uq_fs_lines__caption entirely: a chart line under a different code could
    -- take that caption and be accepted. Measured -- 44,000.00 of customer
    -- suspense liability booked to such a line, and a reader grouping by caption
    -- saw 268,000.00 of current year earnings against a true 224,000.00, with
    -- `balanced = t` and the drift views empty.
    CONSTRAINT ck_fs_lines__caption_reserved
        CHECK (lower(btrim(caption, E' \t\n\r\u00a0\u200b\u2007\u202f'))
                 <> 'undistributed earnings (since inception)'),
    CONSTRAINT ck_fs_lines__side_matches_statement CHECK (
        (statement = 'balance_sheet'    AND side IN ('asset','liability_equity')) OR
        (statement = 'income_statement' AND side IN ('credit','debit'))),
    sort_order int  NOT NULL DEFAULT 1000
);


-- ...and uniqueness on what the reader distinguishes, not on bytes.
CREATE UNIQUE INDEX uq_fs_lines__caption
    ON fs_lines (lower(btrim(caption, E' \t\n\r\u00a0\u200b\u2007\u202f')));


-- ...and the key the chart's integrity FK points at. `code` is already the primary
-- key, so this adds no new uniqueness -- it exists so that a composite foreign key
-- can carry `statement` and `side` along with the code, which is what turns "a
-- revenue type may not report under an expense caption" from a trigger into a key.
ALTER TABLE fs_lines ADD CONSTRAINT uq_fs_lines__code_statement_side
    UNIQUE (code, statement, side);

CREATE TABLE account_types (
    code           text CONSTRAINT pk_account_types PRIMARY KEY,
    category       ledger_category       NOT NULL,
    -- NOT derivable from category: a loss allowance is an asset with a CREDIT
    -- normal balance. Storing both is the only correct option.
    normal_balance ledger_normal_balance NOT NULL,
    description    text NOT NULL,
    fs_line        text NOT NULL,
    -- WHICH STATEMENT AND WHICH SIDE A CATEGORY IMPLIES. Derived, never supplied,
    -- so it cannot disagree with the category it comes from -- and then carried
    -- into the foreign key below. This replaces assert_type_matches_fs_line, the
    -- trigger this project called its best guard because it refused a wrong chart
    -- at SEED time: the wrong system could not be built and no test had to notice.
    -- A foreign key does the same and is visible in \\d.
    fs_statement   text GENERATED ALWAYS AS (
        CASE WHEN category IN ('revenue','expense') THEN 'income_statement'
             ELSE 'balance_sheet' END) STORED,
    -- DERIVED FROM CATEGORY ONLY, on both statements. `side` on fs_lines is the
    -- LINE's presentation sign, not the account's lean, and conflating the two made
    -- CONTRA-REVENUE UNBUILDABLE. Refunds and chargebacks are revenue category with
    -- a DEBIT normal balance; while this consulted normal_balance they derived
    -- side='debit', `revenue` is the only credit-side income line in the chart, and
    -- so the foreign key below admitted exactly one home for them -- a COST line.
    -- Measured: 80.00 of refunds against 250.00 gross printed Revenue 250.00
    -- against a true net 170.00, a 47% overstatement, with cost of revenue equally
    -- wrong and NET INCOME CORRECT, so every aggregate stayed green. The chart
    -- author could not avoid it; the key refused the right answer.
    --
    -- The balance-sheet half was already category-only, which is exactly why a
    -- contra-ASSET works: allowance_for_credit_losses is asset/credit and reports
    -- under Accounts receivable. This is the same rule, applied to both halves.
    -- income_statement already nets a debit into a credit line correctly
    -- (`CASE WHEN f.side='credit' THEN -1 ELSE 1 END`), so nothing downstream
    -- changes. The guard still bites in the direction it was built for: an expense
    -- type still cannot report under Revenue, and a revenue type still cannot
    -- report under a cost line.
    --
    -- AND IT CLOSED A SECOND SILENT CASE nobody had found. Under the old rule an
    -- expense type with a CREDIT normal balance -- a vendor rebate, a supplier
    -- allowance -- derived side='credit', and `revenue` was the ONLY line the key
    -- then admitted for it. A 40.00 rebate booked that way printed revenue 290.00
    -- against a true 250.00, cost of revenue 100.00 against 60.00, net income
    -- CORRECT at 190.00, trial balance green. Same signature as the contra-revenue
    -- bug, opposite direction, and it inflated revenue directly. Now refused.
    --
    -- The change is eight cells of the 130-cell cross-product and every
    -- asset/liability/equity cell is identical, so the balance-sheet half is
    -- provably untouched. A property falls out: every income-statement line is now
    -- category-homogeneous, which matters because income_statement groups by
    -- fs_line WITHOUT category and signs by the line's side -- a line hosting both
    -- categories is exactly the state that made that netting meaningless.
    fs_side        text GENERATED ALWAYS AS (
        CASE WHEN category = 'revenue' THEN 'credit'
             WHEN category = 'expense' THEN 'debit'
             WHEN category = 'asset'   THEN 'asset'
             ELSE 'liability_equity' END) STORED,
    CONSTRAINT fk_types__fs_line FOREIGN KEY (fs_line, fs_statement, fs_side)
        REFERENCES fs_lines (code, statement, side),
    -- ...and the key ledger_accounts points at, so an account cannot claim a
    -- category or normal balance its type does not have. Was a trigger.
    CONSTRAINT uq_types__identity UNIQUE (code, category, normal_balance),
    -- mirrors exactly one external balance and must reconcile against it
    is_perimeter   boolean NOT NULL DEFAULT false,
    -- Can a set of these accounts be summed for reporting? Only if all members
    -- face ONE counterparty. IAS 32.42 / ASC 210-20-45-1 permit offsetting only
    -- for amounts due to and from the same party; where the shard key IS the
    -- counterparty, opposite-sign members must be presented gross.
    counterparty_scope text NOT NULL DEFAULT 'none'
        CONSTRAINT ck_types__counterparty_scope
        CHECK (counterparty_scope IN ('none','shared','per_shard'))
);


-- ----------------------------------------------------------------------
-- the journal



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

    -- composite key: tenant leads every key in the schema (ADR-0002). Free now,
    -- expensive later -- it is the prerequisite for both partitioning and sharding.
    CONSTRAINT pk_accounts PRIMARY KEY (tenant_id, id),
    CONSTRAINT ck_accounts__house_has_no_owner
        CHECK ((owner_type = 'house') = (owner_id IS NULL)),
    CONSTRAINT ck_accounts__currency_iso CHECK (currency ~ '^[A-Z]{3}$'),
    -- AN ACCOUNT MAY NOT DISAGREE WITH ITS TYPE. Carrying category and
    -- normal_balance on the account is deliberate -- a report must not have to join
    -- the chart to know the sign of a balance -- but a copy can drift, so the copy
    -- is a foreign key into the row it was copied from. Was a trigger.
    CONSTRAINT fk_accounts__type FOREIGN KEY (purpose, category, normal_balance)
        REFERENCES account_types (code, category, normal_balance)
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

-- House accounts are PER TENANT, not per deployment (ADR-0002): a deployment-global
-- house account makes every tenant contend on one row and blocks tenant-locality.
CREATE UNIQUE INDEX uq_accounts__house
    ON ledger_accounts (tenant_id, purpose, currency)
    WHERE owner_type = 'house';


-- ------------------------------------------------------------ events (ADR-0005)
-- The idempotency spine. Most of the lifecycle writes NO ledger transaction --
-- authorizations, declines, hold expiry, reversals, limit changes -- so idempotency
-- cannot live on ledger_transactions.
--
-- Those five examples are all CARD events, and the card module is parked, so the
-- clearest argument for this table is currently an argument about something not in
-- this file. The general claim is what carries it: every ledger has accepted
-- operations that write no transaction -- an account opened, a limit changed, a
-- posting rejected, a metadata edit -- and this table is the difference between
-- having a retry contract for them and not having one (ADR-0005).

CREATE TABLE ledger_events (
    tenant_id        text NOT NULL,
    id               uuid NOT NULL DEFAULT uuidv7(),
    kind             text NOT NULL,
    source           text NOT NULL,          -- processor | treasury | customer | internal
    idempotency_key  text NOT NULL,
    -- sha256 of the canonical request body. Same key + same hash -> replay the
    -- stored result. Same key + DIFFERENT hash -> reject: silently replaying the
    -- wrong result is worse than failing.
    --
    -- BUT THAT IS A RULE FOR THE WRITER, NOT A GUARANTEE OF THIS TABLE, and this
    -- comment used to read as if it were one. uq_events__idempotency rejects the
    -- second insert only if the caller lets it: `INSERT ... ON CONFLICT DO NOTHING`
    -- swallows a same-key/different-hash replay in silence, which is exactly the
    -- shape a retry loop reaches for. The unique index cannot tell a deliberate
    -- DO NOTHING from a bug. Verified: accepted, no error, no row, no rejection.
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
    -- The database transaction that created this row -- the SEAL. Entries are
    -- meant to be addable only by that same transaction.
    --
    -- WHY IT MATTERS. Without it, append-only protects the ENTRY and not the
    -- JOURNAL: the app role, holding nothing but its ordinary INSERT grant, can add
    -- a balanced, correctly-dated, correctly-sequenced pair of legs to a
    -- transaction committed and reported months earlier. Measured, before the
    -- guard existed: February revenue went from 500.00 to 1,166.00 with every
    -- constraint in this file satisfied and every report green.
    --
    -- AND IT IS NOT ENFORCED TODAY. The guard was a trigger, and ADR-0004 deleted it.
    -- This column is a bare DEFAULT, which the comment above argues is exactly not
    -- enough -- verified: an ordinary INSERT supplying xact_id = 42 is accepted.
    -- The seal belongs to the writer (ADR-0005), which is not built. Two earlier
    -- versions of this comment pointed at `ck_entries__sealed` and
    -- `assign_xact_id()` as if they were below; neither has existed since ADR-0004, and
    -- a comment naming a guard that is not there is worse than no comment.
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
    -- The two IS DISTINCT FROM conjuncts are the whole rule. Do not add a nil-uuid
    -- sentinel to them: it is redundant, and it rejects a transaction whose id
    -- happens to be the nil uuid even when it references nothing.
    CONSTRAINT ck_txn__no_self_reference
        CHECK (id IS DISTINCT FROM reverses_id AND id IS DISTINCT FROM resolves_id),
    CONSTRAINT ck_txn__not_both
        CHECK (NOT (reverses_id IS NOT NULL AND resolves_id IS NOT NULL))
);


-- A transaction may be reversed once, and resolved once. We refuse to mutate, so
-- we cannot use the UPDATE ... WHERE reverted_at IS NULL guard.
-- One event, at most one transaction. Without this the "idempotency spine" does
-- not by itself prevent double-posting: two transactions were produced from one
-- event row. (An event may still cause NONE -- most of the lifecycle does.)
CREATE UNIQUE INDEX uq_txn__one_per_event
    ON ledger_transactions (tenant_id, event_id) WHERE event_id IS NOT NULL;


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
    -- NO RUNNING BALANCE. There was a balance_after column here, holding the
    -- account's balance immediately after this entry, and spike 009 removed it.
    --
    -- A running balance is a point-in-time answer on the RECORDED axis, and the
    -- recorded axis is not the one anybody asks about: every as-of question a
    -- business asks -- "as of June 30" -- is an EFFECTIVE-date question, and
    -- effective dates get backfilled. One backdated entry makes every later
    -- running balance wrong, because each was computed without it -- which is the
    -- failure ADR-0006 measured on this schema: 180 returned against a true 130.
    --
    -- What used to justify the column now lives elsewhere: "the balance now"
    -- is ledger_account_balances, and "the balance as of a date" aggregates
    -- over effective_at on ix_entries__effective (ADR-0006).
    recorded_at    timestamptz NOT NULL DEFAULT now(),
    -- denormalised from the transaction so the effective-axis aggregate is a
    -- single-table index scan.
    effective_at   timestamptz NOT NULL,

    CONSTRAINT pk_entries PRIMARY KEY (tenant_id, id),
    CONSTRAINT ck_entries__amount_positive CHECK (amount_minor > 0),
    -- account_seq orders history: it is the key a drift check walks and the
    -- key every as-of reconstruction depends on.
    --
    -- NOT A SEQUENCE, and the reason is in ADR-0004's alternatives. A Postgres
    -- sequence counts per TABLE, not per account, and nextval() is not rolled
    -- back -- an aborted transaction leaves a permanent hole. Gaplessness is the
    -- property this column exists to provide, so the writer issues it inside the
    -- same statement that advances the balance row, under the lock it already
    -- holds. Nothing enforced even POSITIVITY
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
    -- 1999-01-01. This column is the entire basis of ADR-0006 and every
    -- business-date report. Same trick as the currency FK above -- make the
    -- denormalised copy part of a composite key so it CANNOT disagree.
    CONSTRAINT fk_entries__txn_effective FOREIGN KEY (tenant_id, transaction_id, effective_at)
        REFERENCES ledger_transactions (tenant_id, id, effective_at),
    CONSTRAINT uq_entries__account_seq UNIQUE (tenant_id, account_id, account_seq)
);


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
    -- currency is IN the foreign key, as it is for entries. Without it this row --
    -- the only copy of a balance the app role may write -- accepted a second row
    -- for the same account under 'usd' or 'JPY', splitting one account's balance
    -- across two rows.
    --
    -- THIS ROW IS WHERE THE HOT PATH READS "the balance now". It is the only
    -- copy left: spike 009 dropped the per-entry running balance that used to be
    -- the other answer, so there is no longer a second number to disagree with.
    CONSTRAINT fk_balances__account FOREIGN KEY (tenant_id, account_id, currency)
        REFERENCES ledger_accounts (tenant_id, id, currency),
    CONSTRAINT ck_balances__non_negative CHECK (input >= 0 AND output >= 0),
    CONSTRAINT ck_balances__currency_iso CHECK (currency ~ '^[A-Z]{3}$')
);


-- ----------------------------------------------------------------------
-- indexes -- the hot reads named in ADR-0006 and the reference product



-- There is no ix_entries__balance_lookup. It was
--     (tenant_id, account_id, account_seq DESC) INCLUDE (balance_after)
-- and the INCLUDE was its whole reason to exist: the three key columns are
-- already indexed by uq_entries__account_seq. Dropping the column (spike 009)
-- left a straight duplicate, so the column took an entire index with it.

CREATE INDEX ix_entries__asof_recorded
    ON ledger_entries (tenant_id, account_id, recorded_at DESC, account_seq DESC);

CREATE INDEX ix_entries__effective
    ON ledger_entries (tenant_id, account_id, effective_at);

CREATE INDEX ix_entries__txn ON ledger_entries (tenant_id, transaction_id);

-- ----------------------------------------------------------------------
-- reports -- the claim Formance cannot meet without a mapping layer



-- ------------------------------------------------------------ reporting

CREATE VIEW trial_balance AS
SELECT a.tenant_id, a.id AS account_id, a.owner_id, a.purpose,
       t.category, t.normal_balance, e.currency,
       -- COALESCE, because an account with only credits returned NULL for debits,
       -- and `WHERE debits - credits <> 0` then DROPS the row instead of flagging
       -- it -- the same NULL-swallowing class as the `NULL NOT IN (...)` bug.
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'), 0)  AS debits,
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'), 0) AS credits,
       -- natural balance: positive means more of what this account normally holds
       -- PRESENTATION value: positive means more of what this account normally
       -- holds. Correct for showing ONE account; WRONG to sum across a category,
       -- because a contra account (asset/credit) would then ADD to assets.
       CASE WHEN t.normal_balance = 'debit'
            THEN SUM(CASE WHEN e.direction='debit'  THEN e.amount_minor ELSE -e.amount_minor END)
            ELSE SUM(CASE WHEN e.direction='credit' THEN e.amount_minor ELSE -e.amount_minor END)
       END AS balance_minor,
       -- ARITHMETIC value -- roll up with this one. normal_balance never enters it,
       -- so a contra account carries its own sign instead of being flipped twice.
       SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END)
           AS balance_debit_positive
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                          AND x.status = 'posted'
JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                          AND a.currency  = e.currency
JOIN account_types   t ON t.code = a.purpose
GROUP BY a.tenant_id, a.id, a.owner_id, a.purpose, t.category, t.normal_balance, e.currency;


-- The income statement, enumerated the same way. Its absence was itself a gap:
-- the completeness defence covered only the balance sheet, while revenue
-- understatement -- the thing ADR-0007 is about -- had no chart-outward report.
CREATE VIEW income_statement AS
WITH dp AS (
    SELECT e.tenant_id, e.currency, t.fs_line,
           SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END) AS v
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                              AND x.status = 'posted'
    JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                          AND a.currency  = e.currency
    JOIN account_types   t ON t.code = a.purpose
    GROUP BY e.tenant_id, e.currency, t.fs_line
), scopes AS (SELECT DISTINCT tenant_id, currency FROM ledger_accounts)
SELECT s.tenant_id, s.currency, f.code AS fs_line, f.caption, f.sort_order,
       -- credit-normal lines (revenue) present positive; debit-normal (expense) too
       (CASE WHEN f.side = 'credit' THEN -1 ELSE 1 END
        * COALESCE(SUM(d.v), 0))::bigint AS amount_minor,
       f.side
FROM scopes s
CROSS JOIN fs_lines f
LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency AND d.fs_line = f.code
WHERE f.statement = 'income_statement'
GROUP BY s.tenant_id, s.currency, f.code, f.caption, f.sort_order, f.side
-- ORDERED BY THE CHART. sort_order was written by the seed and read by
-- nothing, so every value in it could be changed with the suite green -- and the
-- assertion that claimed to check the order was reading PHYSICAL ROW ORDER: moving
-- one VALUES row in the seed, changing no sort_order at all, turned it red. A
-- statement whose lines come out in an arbitrary order is not a statement.
ORDER BY tenant_id, currency, sort_order;


-- ------------------------------------------------------------ the balance sheet
--
-- ADR-0007 claimed "reports enumerate from the chart outward, so there is no
-- parameter in which to pass an incomplete account list." That was ASPIRATIONAL:
-- CURRENCY IS PART OF THE ACCOUNT IDENTITY, so every join above re-asserts it.
-- fk_entries__account is (tenant_id, account_id, currency); on the replication
-- apply path that key is skipped, and an entry then existed in a currency its
-- account does not hold. Joining on (tenant_id, id) alone gave TWO failures, and
-- the second is the worse one:
--
--   * The tenant holds NO account in the orphan's currency. trial_balance
--     reported it; balance_sheet and income_statement derive their scopes FROM
--     ledger_accounts, so they could not see it. 50,000.00 EUR of balanced,
--     permanently unremovable entries in one report and neither statement.
--   * The tenant ALREADY holds accounts in that currency -- an ordinary
--     multi-currency book. Then the scopes CTE admits it and ALL THREE REPORTS
--     AGREE ON THE INFLATED NUMBER: revenue 250.06 printed as 50,250.06. There
--     is no divergence to notice. Silent everywhere.
--
-- Currency is functionally dependent on (tenant_id, id) via pk_accounts, so the
-- added predicate is a pure filter and cannot fan out -- verified, all three
-- reports byte-identical on a legitimate 2-tenant 3-currency book. It also makes
-- `dp` a subset of `scopes` structurally rather than by accident. What it does
-- not do is surface the orphan: nothing compares the journal to the reports.
--
-- trial_balance starts FROM ledger_entries and
-- enumerate INWARD, so an account with no entries is simply absent. This view is
-- the claim made true -- it starts FROM fs_lines and left-joins the numbers on, so
-- a statement line with no activity appears as a zero rather than vanishing.
--
-- It also carries the line the chart could not previously produce. Before this,
-- a balance sheet built from fs_lines was out by exactly net income: there is no
-- retained_earnings account and no close, so revenue and expense had nowhere to
-- go. Un-closed books present that residual as CURRENT YEAR EARNINGS inside
-- equity, which is standard interim presentation -- and it is a derived line, not
-- an account, precisely because no closing entry has been made.
CREATE VIEW balance_sheet AS
WITH dp AS (
    SELECT e.tenant_id, e.currency, t.fs_line, t.category,
           SUM(CASE WHEN e.direction='debit' THEN e.amount_minor ELSE -e.amount_minor END) AS v
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                              AND x.status = 'posted'
    JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                          AND a.currency  = e.currency
    JOIN account_types   t ON t.code = a.purpose
    GROUP BY e.tenant_id, e.currency, t.fs_line, t.category
), scopes AS (
    -- Enumerated from the ACCOUNTS, not from the entries. A scope that has been
    -- opened but has not yet posted anything is still a scope, and a report that
    -- cannot name it cannot claim completeness over it.
    --
    -- HONEST LIMIT: this is still enumeration from data, one level further out.
    -- There is no tenant registry and no currency registry, so a scope with no
    -- accounts at all remains invisible. balance_sheet is a plain view and takes no
    -- parameters; the moment a tenant parameter is added to it -- the obvious next
    -- step -- that parameter is exactly the "parameter in which to pass an incomplete
    -- list" ADR-0007 says should not exist. Completeness here is guaranteed WITHIN a
    -- scope, not across them.
    SELECT DISTINCT tenant_id, currency FROM ledger_accounts
), lines AS (
    SELECT s.tenant_id, s.currency, f.code AS fs_line, f.caption, f.sort_order, f.side,
           COALESCE(SUM(CASE WHEN d.category = 'asset' THEN d.v ELSE -d.v END), 0)::bigint
               AS amount_minor
    FROM scopes s
    CROSS JOIN fs_lines f
    LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency
                  AND d.fs_line = f.code
    WHERE f.statement = 'balance_sheet'
    GROUP BY s.tenant_id, s.currency, f.code, f.caption, f.sort_order, f.side
)
SELECT tenant_id, currency, fs_line, caption, sort_order, amount_minor, side FROM lines
UNION ALL
-- "UNDISTRIBUTED", NOT "CURRENT YEAR". This plug sums revenue and expense over
-- ALL POSTED HISTORY, with no date bound -- there is no period close, so there is
-- no year to be current within. Calling it "Current year earnings" made a ledger
-- holding three years of activity present 34,000.00 under that caption against a
-- true current year of 4,000.00: an 8.5x overstatement that grows without bound
-- with the age of the book, with `balanced = t` and the drift views empty.
-- `retained_earnings` sits in the chart at sort_order 800 and stays at zero
-- forever, because nothing routes to it.
--
-- The honest fix is a period close, which is designed and unbuilt (ADR-0007, and
-- "Still open" in the decision log). Until then the caption says what the number
-- is. `income_statement` has the same shape and no parameter at all: it reports
-- every posted entry ever, so it is a since-inception statement too.
SELECT s.tenant_id, s.currency, 'current_year_earnings',
       'Undistributed earnings (since inception)', 9000,
       (-COALESCE(SUM(d.v), 0))::bigint, 'liability_equity'
FROM scopes s
LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency
              AND d.category IN ('revenue','expense')
GROUP BY s.tenant_id, s.currency
-- ORDERED BY THE CHART. sort_order was written by the seed and read by
-- nothing, so every value in it could be changed with the suite green -- and the
-- assertion that claimed to check the order was reading PHYSICAL ROW ORDER: moving
-- one VALUES row in the seed, changing no sort_order at all, turned it red. A
-- statement whose lines come out in an arbitrary order is not a statement.
ORDER BY tenant_id, currency, sort_order;


-- ----------------------------------------------------------------------
-- THE ONLY TRIGGERS IN THIS SCHEMA, AND WHY EACH ONE IS HERE
--
-- The rule: a trigger states (1) the invariant it holds, (2) why nothing
-- declarative can hold it, and (3) what it does NOT protect against. Two clear
-- that bar, as six trigger objects; ADR-0004 records what happened to the other
-- nineteen.
--
-- The evidence for drawing the line here rather than elsewhere is spike 006.
-- Formance -- Go, PostgreSQL, in production, the closest analogue there is -- built
-- a full PL/pgSQL write engine and then demolished it: migration 11
-- `make-stateless` dropped five triggers that dispatched business flow, and
-- migration 37 dropped twenty-seven stored functions. But they still run seven
-- triggers per ledger today, on by default. What they removed was ORCHESTRATION and
-- DERIVATION-WITH-BACKFILL. What they kept is assignment and integrity on insert.
-- Airbnb's demolition is the same shape: their triggers were change-data-capture
-- feeding an ETL pipeline, and their verdict was that "SQL is good for lightweight
-- data transformation. It is not designed to handle complicated business data flow."
-- Neither project removed a constraint.

-- (1) THE JOURNAL IS APPEND-ONLY.
--
-- INVARIANT: no row in ledger_entries, ledger_transactions or ledger_events may
-- ever be updated or deleted. A correction is a new row. This
-- is the claim the whole project rests on -- every other guarantee is downstream of
-- "the history you are reading is the history that happened".
--
-- WHY NOTHING DECLARATIVE HOLDS IT: there is no CHECK for "this row may not change"
-- and no key that expresses it. The only non-trigger option is to withhold the
-- privilege, and `REVOKE` binds the APPLICATION role only. Migrations, repair
-- scripts and a human at a psql prompt all run as the owner, which is precisely the
-- population that has historically done the damage: Airbnb's core payment objects
-- were "mutable by default", and the audit-trail machinery they bolted on to cope
-- is what they later tore out.
--
-- WHAT IT DOES NOT PROTECT AGAINST: an owner who runs `ALTER TABLE ... DISABLE
-- TRIGGER` or drops it, which is one statement. This binds ACCIDENTS, not intent.
-- Nobody in this field holds append-only with a database mechanism -- Monzo does it
-- with a reviewed six-caller network allowlist, Uber with cryptographic signatures
-- over each record. Those are the two published answers and both live outside the
-- database. This is the cheap 80%.
CREATE FUNCTION refuse_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only: % on % refused. Correct it with a new row.',
        TG_TABLE_NAME, TG_OP, OLD.id
        USING ERRCODE = '23514';
END $$;

-- (2) ...AND TRUNCATE IS NOT A DELETE.
--
-- INVARIANT: the same one. TRUNCATE is separated because PostgreSQL separates it:
-- "TRUNCATE will not fire any ON DELETE triggers that might exist for the tables"
-- (sql-truncate). The guard above sees nothing.
--
-- WHY NOTHING DECLARATIVE HOLDS IT: `REVOKE TRUNCATE` has the same owner-shaped
-- hole as above, and there is no other mechanism -- an event trigger would be the
-- natural one object for the job, and PostgreSQL refuses it outright:
-- `ERROR: event triggers are not supported for TRUNCATE TABLE`. Verified. So it is
-- one statement-level trigger per table or nothing.
--
-- WHAT IT DOES NOT PROTECT AGAINST: the same owner. Also note each table must carry
-- its own -- `TRUNCATE a CASCADE` reaching b is refused by B's guard, naming B, so a
-- test that only checks "something was refused" passes with A's guard deleted.
CREATE FUNCTION refuse_truncate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is history and cannot be truncated', TG_TABLE_NAME
        USING ERRCODE = '23514';
END $$;

-- ENABLE ALWAYS on every one, or they are decoration on exactly the paths that need
-- them most. `session_replication_role = 'replica'` is the logical-replication apply
-- path and what `pg_restore --disable-triggers` sets; the PostgreSQL manual states
-- that "in the default configuration, triggers do not fire on replicas", and that
-- "triggers configured as ENABLE ALWAYS will fire regardless of the current
-- replication role". A subscriber that does not enforce its publisher's invariants
-- is a laundering channel for corrupt rows.
CREATE TRIGGER ck_entries__append_only BEFORE UPDATE OR DELETE ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION refuse_mutation();
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ck_entries__append_only;
CREATE TRIGGER ck_entries__no_truncate BEFORE TRUNCATE ON ledger_entries
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE ledger_entries ENABLE ALWAYS TRIGGER ck_entries__no_truncate;

CREATE TRIGGER ck_txn__append_only BEFORE UPDATE OR DELETE ON ledger_transactions
    FOR EACH ROW EXECUTE FUNCTION refuse_mutation();
ALTER TABLE ledger_transactions ENABLE ALWAYS TRIGGER ck_txn__append_only;
CREATE TRIGGER ck_txn__no_truncate BEFORE TRUNCATE ON ledger_transactions
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE ledger_transactions ENABLE ALWAYS TRIGGER ck_txn__no_truncate;

CREATE TRIGGER ck_events__append_only BEFORE UPDATE OR DELETE ON ledger_events
    FOR EACH ROW EXECUTE FUNCTION refuse_mutation();
ALTER TABLE ledger_events ENABLE ALWAYS TRIGGER ck_events__append_only;
CREATE TRIGGER ck_events__no_truncate BEFORE TRUNCATE ON ledger_events
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE ledger_events ENABLE ALWAYS TRIGGER ck_events__no_truncate;

-- WHAT DELIBERATELY HAS NO GUARD, so the absence reads as a decision:
--
--   * ledger_account_balances -- MATERIALISED state, rebuildable from the journal.
--     It is supposed to be updated; that is what it is for.
--   * fs_lines, account_types, ledger_accounts -- the chart and the account register.
--     A chart is edited: a line is renamed, a type is added. They are NOT history,
--     and this is an admission rather than a defence -- reclassifying a line
--     silently restates issued statements, and the decision log carries it as open.
--   * "debits equal credits", "a transaction has at least two entries" -- enforced
--     by CONSTRUCTION. The Rust writer builds both legs in one code path, so an
--     unbalanced transaction is unrepresentable rather than refused. This is what
--     TigerBeetle gets from a single Transfer row carrying both account ids, and
--     what Formance gets from Posting{Source,Destination} -- their Validate() has
--     no balance check at all, because there is nothing to check.
--   * recorded_at, account_seq, xact_id -- ASSIGNED by the writer.
--     There is no parameter for a caller to supply, which is stronger than a
--     DEFAULT (a DEFAULT is overridable, and that was a measured defect here: a
--     client-settable insertion axis let an already-issued report be rewritten by a
--     transaction claiming to predate it). Formance kept its assignment triggers and
--     we did not. The difference is NOT that we assume one writer -- Formance ships
--     zero GRANTs and zero REVOKEs in its entire repository and does not assume that
--     either. It is that their guarantee is a TYPE: a Posting{Source,Destination}
--     cannot express one leg, so any Go caller gets a balanced pair or nothing.
--     Ours has to be the same shape. Until it is, NOTHING enforces balance at all --
--     `ledger_entries` stores independent rows carrying a direction, so an
--     unbalanced transaction is fully expressible today. See ADR-0005.
--   * chart integrity -- two foreign keys, above. Strictly better than the triggers
--     they replaced: declarative, visible in \d, and impossible to forget.
-- ----------------------------------------------------------------------
-- THE APPLICATION ROLE
--
-- Named as half the append-only mechanism three times in the comments above, and
-- for one commit it did not exist -- the role and its grants lived in the deleted
-- migrations/0001 and were not carried over. A mechanism a document names and the
-- schema does not implement is worse than no mechanism, because it reads as
-- covered. Restored here, and stated for what it is.
--
-- The role gets SELECT and INSERT on the journal and NOTHING ELSE. No UPDATE, no
-- DELETE, no TRUNCATE -- so for this role the six triggers ABOVE are redundant, and
-- that is the point: they exist for the owner, not for the app. (This said "the two
-- triggers below" for as long as the file has existed: wrong count, wrong
-- direction.)
--
-- A GRANT IS NOT A CONSTRAINT, and this schema should not pretend otherwise. It is
-- a point-in-time privilege state that one `GRANT ALL` undoes, it binds no
-- superuser, and it binds nothing at all on a database restored by someone who did
-- not run this file. It is the cheap outer layer. Formance -- Go, PostgreSQL, in
-- production -- ships ZERO grants and zero revokes in its entire repository and
-- relies on its write API being the only caller; pgledger relies on the same
-- convention with the same absence. Neither has an append-only guarantee against a
-- direct INSERT, and that is a choice, not an oversight.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'openledger_app') THEN
        CREATE ROLE openledger_app NOLOGIN;
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO openledger_app;

-- The journal: read and append.
GRANT SELECT, INSERT ON ledger_accounts, ledger_events, ledger_transactions,
                        ledger_entries TO openledger_app;
-- ...and the materialised balance cache, which is meant to be rewritten.
GRANT SELECT, INSERT, UPDATE ON ledger_account_balances TO openledger_app;

-- Reports are readable; the chart is not writable.
GRANT SELECT ON account_types, fs_lines TO openledger_app;
GRANT SELECT ON trial_balance, balance_sheet, income_statement TO openledger_app;

-- ...and belt and braces on the journal, because a later `GRANT ALL ON ALL TABLES`
-- is one statement and this is the line that survives it in review.
REVOKE UPDATE, DELETE, TRUNCATE ON ledger_entries          FROM openledger_app;
REVOKE UPDATE, DELETE, TRUNCATE ON ledger_transactions     FROM openledger_app;
REVOKE        DELETE, TRUNCATE ON ledger_events            FROM openledger_app;
REVOKE        DELETE, TRUNCATE ON ledger_account_balances  FROM openledger_app;

-- PostgreSQL 15+ already removes CREATE on public from PUBLIC. Kept because it is
-- free and because a database created before 15 and upgraded does not get it.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
