-- 00001 -- the core ledger, declaratively.
--
-- This is migration 00001, applied by `openledger migrate` (ADR-0003). It is one
-- flat file on purpose: the readability of a single declarative schema is worth
-- more than a change history nobody reads. Until v0.1 is tagged this file is
-- EDITABLE IN PLACE -- the written exception in ADR-0003: no kept database has
-- applied it, so it is not yet history. From the first tagged release, every
-- later change is a NEW numbered migration beside it. There are no down
-- migrations -- a down migration on a ledger is a lie or data loss (ADR-0003).
--
-- IT CARRIES NO `BEGIN;`/`COMMIT;` OF ITS OWN, DELIBERATELY. The runner wraps each
-- migration in a transaction; an inner `COMMIT;` ends it early, so a failure after
-- that line leaves objects behind and is not recorded as applied, and the retry
-- dies on `relation already exists`. That was a real defect in this file's
-- ancestor. Do not add them back.
--
-- WHAT IT DOES NOT CONTAIN. The card reference product -- authorizations, holds
-- and clearing -- is parked in `parked/card/` and is not applied by any migration
-- today (ADR-0014). ADR-0008 decided it returns as its own `card` PostgreSQL
-- schema inside this same migration set; until someone invests in that, a
-- deployment gets the ledger core and nothing else.
--
-- POSTGRESQL 18 IS A FLOOR, NOT A PREFERENCE: `uuidv7()` is the default on four
-- tables here and does not exist before 18. One trusted extension, btree_gist,
-- is required for `ex_periods__no_overlap` (ADR-0011) and installs without
-- superuser on PG13+.
--
-- THE WRITE PATH RUNS AT READ COMMITTED, stated as a deployment constraint
-- rather than an assumption: the balance upsert under REPEATABLE READ or
-- SERIALIZABLE fails with `could not serialize access`, and an in-transaction
-- retry cannot rescue it because the snapshot does not move. The writer issues
-- `BEGIN ISOLATION LEVEL READ COMMITTED` explicitly, which overrides a stricter
-- deployment default (ADR-0013).
--
-- A TRIGGER NEEDS A WRITTEN JUSTIFICATION. The default is none. The invariants
-- that clear that bar are implemented near the bottom of this file -- the
-- append-only guards on the journal, the chart's presentation history and the
-- attestation log, and three event triggers on the DDL channel (ADR-0009);
-- everything else is a CHECK, a key, a GRANT, a POLICY, or one code path in the
-- writer (ADR-0004). No PL/pgSQL business logic, no orchestration, no
-- derivation-with-backfill, and no logic in views beyond reporting. The
-- statement functions near the bottom are reporting SQL with parameters
-- (ADR-0011), not business logic: they write nothing.


CREATE TYPE ledger_category       AS ENUM ('asset','liability','equity','revenue','expense');

CREATE TYPE ledger_normal_balance AS ENUM ('debit','credit');

CREATE TYPE ledger_direction      AS ENUM ('debit','credit');

CREATE TYPE ledger_txn_status     AS ENUM ('pending','posted');

CREATE TYPE account_owner_type    AS ENUM ('company','platform','bank_account','house');

-- ----------------------------------------------------------------------
-- the chart of accounts -- what an account MEANS
--
-- Split along one seam (ADR-0012). An account type has two kinds of property with
-- different lifetimes: IDENTITY -- category, normal balance, counterparty scope,
-- perimeter status -- which may never change under posted history, and
-- PRESENTATION -- which financial-statement line the type rolls up to -- which
-- IAS 1.41 requires to change, with comparatives moving alongside. Identity stays
-- on account_types, unversioned. Presentation lives in chart_presentation, keyed
-- by chart_version, append-only: A RECLASSIFICATION IS A NEW CHART VERSION, NEVER
-- AN EDIT. An issued statement names the version it was presented under, and a
-- version whose content can change identifies nothing.



-- Append-only. A chart version is created, never edited and never deleted.
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

-- "Current" is DERIVED, not stored. Versions are append-only and monotone, so
-- max() IS the current chart: no row to update, no singleton table, and no way
-- for "current" to disagree with what exists.
--
-- THIS RELATION IS THE INTERFACE TO A PINNED REPORT. The statement functions
-- below read their default version from here and from nowhere else, and emit it
-- as a column; a pinned report passes the chosen version instead (ADR-0012).
CREATE VIEW chart_version_current AS
    SELECT max(version) AS chart_version FROM chart_versions;


-- Every account type maps to exactly one financial-statement line PER CHART
-- VERSION. This is what makes omission structurally impossible: reports enumerate
-- from the chart outward, so there is no parameter in which to pass an incomplete
-- account list.
CREATE TABLE fs_lines (
    chart_version int NOT NULL,
    code       text NOT NULL,
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
    -- the balance sheet emits for exactly this reason. What follows is defence in
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
    -- `current_year_earnings` is SYNTHESISED by the balance sheet for un-closed
    -- earnings. A chart that also declares a real line by that code produces two
    -- rows with the same caption and no way to tell them apart -- one an account
    -- subtotal, one a derived plug.
    CONSTRAINT ck_fs_lines__code_reserved
        CHECK (code <> 'current_year_earnings'),
    -- ...AND THE CAPTION, which is the half that actually does the harm the
    -- comment above describes. The balance sheet emits `'current_year_earnings',
    -- 'Undistributed earnings (since inception)'` as LITERALS, so the synthesised
    -- row sits outside uq_fs_lines__caption entirely: a chart line under a
    -- different code could take that caption and be accepted. Measured --
    -- 44,000.00 of customer suspense liability booked to such a line, and a
    -- reader grouping by caption saw 268,000.00 of current year earnings against
    -- a true 224,000.00, with `balanced = t` and the drift views empty.
    CONSTRAINT ck_fs_lines__caption_reserved
        CHECK (lower(btrim(caption, E' \t\n\r\u00a0\u200b\u2007\u202f'))
                 <> 'undistributed earnings (since inception)'),
    -- THE SPLIT (ADR-0012). The income-statement half always distinguished
    -- revenue from expense; the balance-sheet half did not distinguish liability
    -- from equity, so `liability`, `equity` and any contra of either were freely
    -- interchangeable across all five liability-and-equity captions -- 1,000.00
    -- of paid-in capital presented under "Accounts payable and accrued", assets
    -- equal to liabilities-and-equity, every check green. The side is now
    -- three-valued on the balance sheet.
    CONSTRAINT ck_fs_lines__side_matches_statement CHECK (
        (statement = 'balance_sheet'    AND side IN ('asset','liability','equity')) OR
        (statement = 'income_statement' AND side IN ('credit','debit'))),
    sort_order int  NOT NULL DEFAULT 1000,

    CONSTRAINT pk_fs_lines PRIMARY KEY (chart_version, code),
    CONSTRAINT fk_fs_lines__version FOREIGN KEY (chart_version)
        REFERENCES chart_versions (version)
);


-- ...and uniqueness on what the reader distinguishes, not on bytes -- WITHIN a
-- version. Two versions may of course carry the same caption; that is what makes
-- them comparable.
CREATE UNIQUE INDEX uq_fs_lines__caption
    ON fs_lines (chart_version, lower(btrim(caption, E' \t\n\r\u00a0\u200b\u2007\u202f')));


-- ...and the key the presentation's integrity FK points at. This adds no new
-- uniqueness beyond the primary key; it exists so that a composite foreign key
-- can carry `statement` and `side` along with the code, which is what turns "a
-- revenue type may not report under an expense caption" from a trigger into a key.
ALTER TABLE fs_lines ADD CONSTRAINT uq_fs_lines__code_statement_side
    UNIQUE (chart_version, code, statement, side);

CREATE TABLE account_types (
    code           text CONSTRAINT pk_account_types PRIMARY KEY,
    category       ledger_category       NOT NULL,
    -- NOT derivable from category: a loss allowance is an asset with a CREDIT
    -- normal balance. Storing both is the only correct option.
    normal_balance ledger_normal_balance NOT NULL,
    description    text NOT NULL,
    -- WHERE fs_line WENT. It used to live here, unversioned, which is why a
    -- reclassification silently restated every issued statement: the mapping had
    -- no history. It is now a row in chart_presentation per chart version
    -- (ADR-0012), and this table carries identity only.
    --
    -- ...and the key ledger_accounts points at, so an account cannot claim a
    -- category or normal balance its type does not have. Was a trigger.
    CONSTRAINT uq_types__identity UNIQUE (code, category, normal_balance),
    -- mirrors exactly one external balance and must reconcile against it.
    -- CONSUMED by perimeter_attestations, perimeter_drift and chart_lint below
    -- (ADR-0012); it was declarative for as long as nothing read it.
    is_perimeter   boolean NOT NULL DEFAULT false,
    -- Can a set of these accounts be summed for reporting? Only if all members
    -- face ONE counterparty. IAS 32.42 / ASC 210-20-45-1 permit offsetting only
    -- for amounts due to and from the same party; where the shard key IS the
    -- counterparty, opposite-sign members must be presented gross. CONSUMED by
    -- the balance sheet's gross routing and by chart_lint (ADR-0012).
    counterparty_scope text NOT NULL DEFAULT 'none'
        CONSTRAINT ck_types__counterparty_scope
        CHECK (counterparty_scope IN ('none','shared','per_shard')),
    -- The account type holding the OTHER side of the same cross-scope obligation
    -- (ADR-0010). A tenant's due_from_treasury is the same money as the
    -- operator's due_to_tenants, and nothing else in the chart says so; deriving
    -- the pair from the due_from_/due_to_ naming would be a convention, and a
    -- convention is not a constraint (ADR-0007). Declared on ONE side of each
    -- pair, arbitrarily the asset side. Read by recon_scope_breaks.
    mirror_type text
        CONSTRAINT fk_types__mirror REFERENCES account_types (code)
        CONSTRAINT ck_types__mirror_not_self CHECK (mirror_type <> code),
    -- the key chart_presentation points at: the two identity properties
    -- presentation is derived from, carried so the copy cannot disagree.
    CONSTRAINT uq_types__presentable UNIQUE (code, category, counterparty_scope)
);


-- ------------------------------------------------------ chart_presentation
--
-- WHICH LINE A TYPE REPORTS UNDER, per chart version. Append-only: a
-- reclassification is a new version carrying a complete chart, so "which line
-- was this presented under" is one key lookup, never a walk of overrides.
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

    -- WHICH STATEMENT AND WHICH SIDE A CATEGORY IMPLIES. Derived, never supplied,
    -- so it cannot disagree with the category it comes from -- and then carried
    -- into the foreign key below. This replaces assert_type_matches_fs_line, the
    -- trigger this project called its best guard because it refused a wrong chart
    -- at SEED time: the wrong system could not be built and no test had to notice.
    -- A foreign key does the same and is visible in \d.
    fs_statement text GENERATED ALWAYS AS (
        CASE WHEN category IN ('revenue','expense') THEN 'income_statement'
             ELSE 'balance_sheet' END) STORED,
    -- DERIVED FROM CATEGORY ONLY, on both statements. `side` on fs_lines is the
    -- LINE's presentation sign, not the account's lean, and conflating the two
    -- made CONTRA-REVENUE UNBUILDABLE: refunds and chargebacks are revenue
    -- category with a DEBIT normal balance; while this consulted normal_balance
    -- they derived side='debit' and the key admitted exactly one home for them --
    -- a COST line. Measured: 80.00 of refunds against 250.00 gross printed
    -- Revenue 250.00 against a true net 170.00, a 47% overstatement, with NET
    -- INCOME CORRECT, so every aggregate stayed green.
    --
    -- ...and the balance-sheet half is now THREE-valued, which is the whole of
    -- the fix for the two-valued side (ADR-0012). Every income-statement cell and
    -- every asset cell is unchanged; only the liability/equity cells change, from
    -- one value to two.
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
    -- A CONTRA LINE IS ORTHOGONAL TO SHARDING (ADR-0012, amended). The old rule was
    -- `contra IS NOT NULL` iff `per_shard`, which FORBADE a contra line on a
    -- `shared` type -- but a shared type facing one counterparty still swings sides
    -- and must present gross (measured: network_settlement_payable 425 dr netted to
    -- zero against accrued_interest_payable 425 cr on the payables line; and a
    -- per_shard contra line pointing at a `shared` line put a negative asset on the
    -- face). Sign-swing is what needs a contra line, and any asset or liability can
    -- swing. So: a contra line is ALLOWED for any balance-sheet type, REQUIRED for
    -- per_shard (where the split key IS the counterparty and one account is one
    -- counterparty), and meaningless on the income statement.
    CONSTRAINT ck_presentation__contra_required_for_per_shard
        CHECK (counterparty_scope <> 'per_shard' OR fs_line_contra IS NOT NULL),
    -- a contra line is a balance-sheet device: IAS 32.42 opens "A financial asset
    -- and a financial liability shall be offset"; there is no opposite-sign
    -- position in revenue to present gross.
    CONSTRAINT ck_presentation__contra_is_balance_sheet
        CHECK (fs_line_contra IS NULL OR category IN ('asset','liability')),
    -- ...AND per_shard IS A BALANCE-SHEET PROPERTY.
    CONSTRAINT ck_presentation__per_shard_is_balance_sheet
        CHECK (counterparty_scope <> 'per_shard' OR category IN ('asset','liability'))
);


-- ----------------------------------------------------------------------
-- the journal



-- ---------------------------------------------------------------- accounts

CREATE TABLE ledger_accounts (
    tenant_id      text NOT NULL,
    id             uuid NOT NULL DEFAULT uuidv7(),
    owner_type     account_owner_type    NOT NULL,
    owner_id       text,                      -- NULL only when owner_type = 'house'
    -- A NULL-free copy of owner_id, for the freeze key below. owner_id is NULL on
    -- house accounts and a composite FK is MATCH SIMPLE -- one NULL and the
    -- constraint is NOT CHECKED -- so the copy is a GENERATED column (ADR-0009).
    owner_id_key   text GENERATED ALWAYS AS (coalesce(owner_id, '')) STORED,
    purpose        text                  NOT NULL,
    category       ledger_category       NOT NULL,
    -- NOT derivable from category: allowance_for_credit_losses is an asset with a
    -- CREDIT normal balance.
    normal_balance ledger_normal_balance NOT NULL,
    -- COPIED from the type and held honest by fk_accounts__scope, because the
    -- balance sheet's gross routing needs the scope at the account grain and a
    -- CHECK may not read another table (ADR-0012). The writer supplies it, like
    -- category.
    counterparty_scope text NOT NULL,
    currency       char(3)               NOT NULL,
    -- How many stripes the writer should spread this account's balance row
    -- across (ADR-0013). A HINT, not an invariant: a reader SUMs the stripe rows
    -- that exist, never the range 0..n-1, so lowering it can never strand a
    -- balance and raising it needs no backfill.
    stripe_count   smallint NOT NULL DEFAULT 1
        CONSTRAINT ck_accounts__stripe_count CHECK (stripe_count BETWEEN 1 AND 1024),
    metadata       jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at     timestamptz NOT NULL DEFAULT now(),

    -- composite key: tenant leads every key in the schema (ADR-0002). Free now,
    -- expensive later -- it is the prerequisite for both partitioning and sharding.
    CONSTRAINT pk_accounts PRIMARY KEY (tenant_id, id),
    -- tenant_id is a key, not free text: the empty string is reachable after
    -- `RESET app.tenant_id` and would sit under no tenant while satisfying every
    -- NOT NULL. Refused here as it is on `source`/`note` (ADR-0002).
    CONSTRAINT ck_accounts__tenant_non_empty CHECK (btrim(tenant_id) <> ''),
    CONSTRAINT ck_accounts__house_has_no_owner
        CHECK ((owner_type = 'house') = (owner_id IS NULL)),
    CONSTRAINT ck_accounts__currency_iso CHECK (currency ~ '^[A-Z]{3}$'),
    -- AN ACCOUNT MAY NOT DISAGREE WITH ITS TYPE. Carrying category and
    -- normal_balance on the account is deliberate -- a report must not have to join
    -- the chart to know the sign of a balance -- but a copy can drift, so the copy
    -- is a foreign key into the row it was copied from. Was a trigger.
    CONSTRAINT fk_accounts__type FOREIGN KEY (purpose, category, normal_balance)
        REFERENCES account_types (code, category, normal_balance),
    -- ...and the same for the scope copy (ADR-0012).
    CONSTRAINT fk_accounts__scope FOREIGN KEY (purpose, category, counterparty_scope)
        REFERENCES account_types (code, category, counterparty_scope),
    -- A TYPE WHOSE SPLIT KEY IS THE COUNTERPARTY MAY NOT BE HELD IN A HOUSE
    -- ACCOUNT. uq_accounts__house is one row per (tenant, purpose, currency), so
    -- a house account holding a per_shard type has already netted every
    -- counterparty's position at write time, and NO REPORT CAN RECOVER IT. The
    -- gross presentation below and this constraint ship together; neither works
    -- alone (ADR-0012).
    CONSTRAINT ck_accounts__per_shard_is_owned
        CHECK (counterparty_scope <> 'per_shard' OR owner_type <> 'house'),
    -- THE IDENTITY FREEZE (ADR-0009/0012). fk_accounts__type below only requires
    -- the NEW (purpose, category, normal_balance) triple to EXIST in account_types
    -- -- it does nothing to stop reclassifying a posted account from one valid type
    -- to another (measured: one UPDATE turned a customer_wallet into an
    -- operating_cash and restated every issued balance sheet, all checks green).
    -- This is the target a dependent balance row points at under NO ACTION, exactly
    -- as uq_accounts__id_owner freezes the owner: while any balance row references
    -- an account's identity, that identity cannot be UPDATEd. fk_entries__stripe
    -- guarantees a balance row exists for any account that has ever posted, so the
    -- freeze is total for accounts with history.
    CONSTRAINT uq_accounts__id_purpose
        UNIQUE (tenant_id, id, purpose, category, normal_balance)
);


-- Disjoint sets. A plain UNIQUE would not constrain house rows at all, since
-- owner_id is NULL there and NULL <> NULL.
-- Lets entries reference (account, currency) as a unit, so an entry cannot carry a
-- currency its account does not hold. Verified: without this, USD entries sit
-- happily in EUR accounts and the declared currency is decorative.
CREATE UNIQUE INDEX uq_accounts__id_currency
    ON ledger_accounts (tenant_id, id, currency);

-- The freeze key (ADR-0009): lets the balance row reference (account, owner) as a
-- unit, so `UPDATE ledger_accounts SET owner_type='house', owner_id=NULL` -- which
-- left a liability on the balance sheet owed to nobody -- is refused by NO ACTION
-- while any balance row points at the old owner. Same device as
-- fk_entries__account (currency) and fk_entries__txn_effective (effective_at),
-- used for the third time and now deliberately.
CREATE UNIQUE INDEX uq_accounts__id_owner
    ON ledger_accounts (tenant_id, id, owner_type, owner_id_key);


CREATE UNIQUE INDEX uq_accounts__owned
    ON ledger_accounts (tenant_id, owner_type, owner_id, purpose, currency)
    WHERE owner_type <> 'house';

-- House accounts are PER TENANT, not per deployment (ADR-0002): a deployment-global
-- house account makes every tenant contend on one row and blocks tenant-locality.
-- NOTE: this index is NOT what blocked striping -- a stripe is a row in
-- ledger_account_balances, one table down, so N stripes of one house account
-- coexist while two DIFFERENT house accounts of one purpose stay refused here
-- (ADR-0013).
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
    -- THE REPLAY CONTRACT IS TWO STATEMENTS (ADR-0013): an
    -- `INSERT ... ON CONFLICT DO NOTHING RETURNING id`, then -- when the insert
    -- returned nothing -- a SEPARATE `SELECT id, transaction_id, hash = $body`
    -- against the winning row. The one-statement CTE form returns ZERO rows under
    -- exactly the race it exists to handle, and `ON CONFLICT DO NOTHING` alone
    -- swallows a same-key/different-hash replay in silence, which is exactly the
    -- shape a retry loop reaches for. The unique index cannot tell a deliberate
    -- DO NOTHING from a bug. Verified: accepted, no error, no row, no rejection.
    idempotency_hash bytea NOT NULL,
    payload          jsonb NOT NULL,
    effective_at     timestamptz NOT NULL,
    recorded_at      timestamptz NOT NULL DEFAULT now(),
    -- The commit-ordering key (ADR-0011): where an operation that writes no
    -- transaction records its position on the commit axis.
    xact_id          xid8 NOT NULL DEFAULT pg_current_xact_id(),

    CONSTRAINT pk_events PRIMARY KEY (tenant_id, id),
    CONSTRAINT ck_events__tenant_non_empty CHECK (btrim(tenant_id) <> '')
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
    -- NOT NULL (ADR-0013): "every transaction references the event that caused
    -- it" is an invariant now, not a convention -- and it had a deadline. With one
    -- event-less row committed, `SET NOT NULL` is refused, the DELETE that would
    -- fix it is refused by refuse_mutation(), and the only routes left are
    -- DISABLE TRIGGER or fabricating the event. It landed while the journal was
    -- empty, which is the only time it is free.
    event_id        uuid NOT NULL,           -- the event that caused this
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
    -- The database transaction that created this row. xid8, not bigint: the type
    -- carries the commit ordering the as-of cursor is pinned to (ADR-0011), and
    -- the old `::text::bigint` cast discarded it.
    --
    -- STILL A BARE DEFAULT, and the seal it once described is NOT enforced today:
    -- an ordinary INSERT supplying xact_id = 42 is accepted. The seal belongs to
    -- the writer (ADR-0005), which is not built. What the column DOES buy without
    -- the writer is the cursor: an issued report pinned at
    -- `xact_id < pg_snapshot_xmin(...)` cannot be rewritten by a later arrival,
    -- because a later arrival -- including a leg appended to THIS transaction by
    -- a rogue caller -- carries its own, higher id (ADR-0011, proven).
    xact_id         xid8 NOT NULL DEFAULT pg_current_xact_id(),

    CONSTRAINT pk_txn PRIMARY KEY (tenant_id, id),
    CONSTRAINT ck_txn__tenant_non_empty CHECK (btrim(tenant_id) <> ''),
    -- effective_at is a business date the writer copies from the source clock, and
    -- '-infinity'/'infinity' are valid timestamptz values that pass every range
    -- predicate the reports use ("< p_to", "<= p_asof") while belonging to no real
    -- period: an infinity-dated leg lands in every as-of report and no closed
    -- period. Finite is the invariant. (A fat-fingered FINITE date -- year 2226 --
    -- is finite and is surfaced by recon_journal_to_reports' out-of-window bucket.)
    CONSTRAINT ck_txn__effective_finite
        CHECK (effective_at > '-infinity' AND effective_at < 'infinity'),
    -- the target of fk_entries__txn_effective, below
    CONSTRAINT uq_txn__id_effective UNIQUE (tenant_id, id, effective_at),
    -- the target of fk_closes__txn_kind (ADR-0011): lets ledger_period_closes carry
    -- `kind` under a composite FK, so a close can name only a transaction whose kind
    -- is 'period_close'. Adds no uniqueness beyond pk_txn; it exists to be pointed at.
    CONSTRAINT uq_txn__id_kind UNIQUE (tenant_id, id, kind),
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
-- event row. (An event may still cause NONE -- most of the lifecycle does. What
-- it may no longer cause is a transaction with no event: event_id is NOT NULL,
-- so this index lost its WHERE clause.)
CREATE UNIQUE INDEX uq_txn__one_per_event
    ON ledger_transactions (tenant_id, event_id);


CREATE UNIQUE INDEX uq_txn__one_reversal
    ON ledger_transactions (tenant_id, reverses_id) WHERE reverses_id IS NOT NULL;

CREATE UNIQUE INDEX uq_txn__one_resolution
    ON ledger_transactions (tenant_id, resolves_id) WHERE resolves_id IS NOT NULL;


-- ------------------------------------------------------------ balances
-- The write-side serialization point AND the O(1) current-balance read. One atomic
-- upsert returns the new balance and the next sequence number together, so the row
-- lock IS the serialization -- no SELECT max(), no advisory lock, no retry loop.
--
-- input/output kept separate rather than one signed balance: the upsert stays
-- commutative, gross turnover is free, and no row needs to know the sign convention.
--
-- THE CONVENTION, stated once and for the whole schema (ADR-0010 -- it used to
-- live only in a spike): `input` accumulates DEBIT legs, `output` accumulates
-- CREDIT legs, so `input - output` is the DEBIT-POSITIVE arithmetic value of
-- ADR-0007 rule 15. A credit-normal account reads negative from this row and the
-- presentation flip belongs to the reader.
--
-- WHAT THIS ROW MEANS: the POSTED balance (ADR-0010's ruling on the pending
-- question). The writer accumulates input/output for POSTED transactions only;
-- an "available" balance is posted plus the pending population, which
-- recon_pending_bridge enumerates and derives. last_seq, by contrast, advances
-- on EVERY entry -- pending included -- because it issues account_seq and a
-- pending entry needs one.
--
-- THREE JOBS ON ONE ROW -- the write lock, the account_seq counter, and the
-- cached balance -- and ADR-0010 decides to KEEP them there: splitting would cost
-- the atomicity that makes account_seq gapless, and the three failure modes are
-- detected separately by recon_balance_breaks. The recorded trade: they share a
-- blast radius, and detection is periodic.

CREATE TABLE ledger_account_balances (
    tenant_id  text    NOT NULL,
    account_id uuid    NOT NULL,
    currency   char(3) NOT NULL,
    -- WHICH STRIPE THIS ROW IS (ADR-0013). A stripe is NOT an account: it is a
    -- physical partition of one account's balance row -- ADR-0002's "one logical
    -- account is stored as N physical balance rows" -- so the stripe joins this
    -- primary key and each stripe is a separate lock. A reader SUMs the rows
    -- that exist. Unstriped accounts hold exactly row 0.
    stripe     smallint NOT NULL DEFAULT 0
        CONSTRAINT ck_balances__stripe_non_negative CHECK (stripe >= 0),
    -- The owner freeze (ADR-0009): a copy of the account's owner, held honest by
    -- fk_balances__account_owner below. A composite FK freezes its REFERENCED
    -- columns -- NO ACTION refuses an UPDATE of them while a dependent row points
    -- at the old value -- so an account with any balance row cannot have its
    -- owner nulled or reassigned. Declarative, where the alternative was a
    -- seventh trigger.
    owner_type   account_owner_type NOT NULL,
    owner_id_key text    NOT NULL,
    -- The IDENTITY freeze (ADR-0009/0012), the same device as the owner columns
    -- above, one property over: a copy of the account's (purpose, category,
    -- normal_balance), held honest by fk_balances__account_purpose below. A
    -- composite FK freezes its REFERENCED columns under NO ACTION, so while any
    -- balance row points at an account's identity that account cannot be
    -- reclassified. The app role advances the four working columns and never these,
    -- so it cannot forge them; the owner cannot UPDATE the account's identity out
    -- from under a balance row. Was going to be a trigger.
    purpose        text                  NOT NULL,
    category       ledger_category       NOT NULL,
    normal_balance ledger_normal_balance NOT NULL,
    input      bigint  NOT NULL DEFAULT 0,
    output     bigint  NOT NULL DEFAULT 0,
    last_seq   bigint  NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_balances PRIMARY KEY (tenant_id, account_id, currency, stripe),
    -- currency is IN the foreign key, as it is for entries. Without it this row --
    -- the only copy of a balance the app role may write -- accepted a second row
    -- for the same account under 'usd' or 'JPY', splitting one account's balance
    -- across two rows.
    --
    -- THIS ROW IS WHERE THE HOT PATH READS "the balance now". It is the only
    -- copy left: spike 009 dropped the per-entry running balance that used to be
    -- the other answer, so there is no longer a second number to disagree with --
    -- and recon_balance_breaks is what keeps THIS one honest against the journal.
    CONSTRAINT fk_balances__account FOREIGN KEY (tenant_id, account_id, currency)
        REFERENCES ledger_accounts (tenant_id, id, currency),
    CONSTRAINT fk_balances__account_owner
        FOREIGN KEY (tenant_id, account_id, owner_type, owner_id_key)
        REFERENCES ledger_accounts (tenant_id, id, owner_type, owner_id_key),
    -- ...and the identity freeze (ADR-0012), pointing at uq_accounts__id_purpose.
    CONSTRAINT fk_balances__account_purpose
        FOREIGN KEY (tenant_id, account_id, purpose, category, normal_balance)
        REFERENCES ledger_accounts (tenant_id, id, purpose, category, normal_balance),
    CONSTRAINT ck_balances__tenant_non_empty CHECK (btrim(tenant_id) <> ''),
    CONSTRAINT ck_balances__non_negative CHECK (input >= 0 AND output >= 0),
    CONSTRAINT ck_balances__currency_iso CHECK (currency ~ '^[A-Z]{3}$')
);


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
    -- WHICH STRIPE'S COUNTER ISSUED account_seq (ADR-0013). Without it
    -- gaplessness is unfalsifiable under striping: two stripes both issue 5 for
    -- one account and uq_entries__account_seq refuses the second, which would
    -- serialise every writer through a unique index -- the bottleneck striping
    -- exists to remove, moved one table over. Unstriped accounts write stripe 0.
    stripe         smallint NOT NULL DEFAULT 0
        CONSTRAINT ck_entries__stripe_non_negative CHECK (stripe >= 0),
    account_seq    bigint NOT NULL,             -- monotonic per account per stripe
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
    -- over effective_at on ix_entries__effective (ADR-0006), from the last
    -- period checkpoint where one exists (ADR-0011).
    recorded_at    timestamptz NOT NULL DEFAULT now(),
    -- denormalised from the transaction so the effective-axis aggregate is a
    -- single-table index scan.
    effective_at   timestamptz NOT NULL,
    -- The entry's OWN commit-ordering key (ADR-0011). Deliberately NOT under a
    -- composite FK to the transaction's xact_id, the way effective_at and
    -- currency are held honest: the two values are ALLOWED to differ and the
    -- difference is the point. A leg appended to an already-committed transaction
    -- carries its own, HIGHER id, so a report pinned before the append cannot see
    -- it -- under an FK it would inherit the old id and rewrite the issued report.
    xact_id        xid8 NOT NULL DEFAULT pg_current_xact_id(),

    CONSTRAINT pk_entries PRIMARY KEY (tenant_id, id),
    CONSTRAINT ck_entries__tenant_non_empty CHECK (btrim(tenant_id) <> ''),
    CONSTRAINT ck_entries__amount_positive CHECK (amount_minor > 0),
    -- finite, for the reason ck_txn__effective_finite gives: an infinity-dated leg
    -- passes every report range predicate and belongs to no period.
    CONSTRAINT ck_entries__effective_finite
        CHECK (effective_at > '-infinity' AND effective_at < 'infinity'),
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
    -- Gaplessness itself is asserted afterwards by recon_balance_breaks, not
    -- enforced here.
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
    -- ...and the stripe it names must be one that exists: the denormalised copy
    -- is part of a composite key, so an entry cannot name a counter nothing
    -- issued (ADR-0013).
    CONSTRAINT fk_entries__stripe FOREIGN KEY (tenant_id, account_id, currency, stripe)
        REFERENCES ledger_account_balances (tenant_id, account_id, currency, stripe),
    CONSTRAINT uq_entries__account_seq UNIQUE (tenant_id, account_id, stripe, account_seq)
);


-- ------------------------------------------------------------ periods (ADR-0011)
-- The close is an ordinary posting; these three tables are its bookkeeping. A
-- period is a resolved boundary, a close names the transaction that closed it and
-- the cursor it was computed at, and the checkpoint is the effective-axis balance
-- at that boundary -- bounded, off the write path, and exactly recomputable.

-- for ex_periods__no_overlap, below. Trusted on PostgreSQL 13+, so a database
-- owner installs it without superuser. The only dependency outside core.
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE ledger_periods (
    tenant_id  text NOT NULL,
    code       text NOT NULL,              -- '2026-02', 'FY2026Q1' -- a label, not a key of time
    -- HALF-OPEN, AND RESOLVED. starts_at/ends_at are absolute instants, resolved
    -- ONCE from (local date, tz) at the moment the period is created. They are
    -- what a report filters on and what makes an issued statement reproducible:
    -- IANA rules are legislation and change, so a stored (local date, zone) pair
    -- is not a stable instant (ADR-0011).
    starts_at  timestamptz NOT NULL,
    ends_at    timestamptz NOT NULL,
    -- PROVENANCE, not the boundary. Whose business date this period is. Recorded
    -- so a reader can say "February in America/New_York"; never re-resolved.
    tz         text NOT NULL,
    CONSTRAINT pk_periods PRIMARY KEY (tenant_id, code),
    CONSTRAINT ck_periods__tenant_non_empty CHECK (btrim(tenant_id) <> ''),
    CONSTRAINT ck_periods__non_empty CHECK (ends_at > starts_at),
    -- The zone name IS constrainable, declaratively: timezone(text, timestamptz)
    -- is IMMUTABLE, and an unrecognised zone RAISES rather than returning NULL.
    -- WHAT IT DOES NOT DO: re-validate when tzdata changes under the server --
    -- which is the whole reason starts_at/ends_at are stored resolved.
    CONSTRAINT ck_periods__tz_known
        CHECK ((timestamp '2000-01-01 00:00' AT TIME ZONE tz) IS NOT NULL),
    -- the target of fk_closes__period, so a close cannot name a period's code
    -- without also naming the instants that period resolved to
    CONSTRAINT uq_periods__bounds UNIQUE (tenant_id, code, starts_at, ends_at),
    -- A tenant's periods may not overlap. Declarative; no trigger, no application
    -- check. Costs the btree_gist extension, above.
    CONSTRAINT ex_periods__no_overlap EXCLUDE USING gist (
        tenant_id WITH =, tstzrange(starts_at, ends_at, '[)') WITH &&)
);

-- One close per tenant per period per currency, and the close IS an ordinary
-- transaction: this table records which one. That is what lets the income
-- statement exclude closing entries declaratively instead of matching on a
-- free-text `kind`.
CREATE TABLE ledger_period_closes (
    tenant_id      text NOT NULL,
    period_code    text NOT NULL,
    currency       char(3) NOT NULL,
    starts_at      timestamptz NOT NULL,   -- carried from the period, under the FK below
    ends_at        timestamptz NOT NULL,
    -- The closing transaction, posted through the ordinary write primitive
    -- (ADR-0005). Nothing here writes it; this row only names it.
    --
    -- TYPED (ADR-0011). fk_closes__txn only required the transaction to EXIST -- not
    -- that it be a close, not that it fall inside the period, and computed_at_xid
    -- was unrelated to it. The app role could name a REVENUE transaction and erase
    -- it from the income statement, green. Three keys close that: `closing_kind` is
    -- a generated constant carried into a composite FK so the named txn must have
    -- kind='period_close'; `txn_effective_at` is carried under the effective-date FK
    -- and CHECKed to fall inside [starts_at, ends_at); and computed_at_xid is held
    -- to the closing txn's own commit position by the sweep (recon_close_breaks).
    transaction_id uuid NOT NULL,
    -- carried from the closing transaction under fk_closes__txn_effective, and
    -- CHECKed to sit inside the period this close names.
    txn_effective_at timestamptz NOT NULL,
    -- a constant, generated so it cannot be supplied wrong; the composite FK below
    -- turns it into "the named transaction's kind is 'period_close'".
    closing_kind   text GENERATED ALWAYS AS ('period_close') STORED,
    -- THE CURSOR THE CHECKPOINT WAS COMPUTED AT. Everything below it had
    -- committed; nothing below it can ever appear. A later arrival backdated into
    -- this period is accepted (append-only) and lands ABOVE this value, so it is
    -- a tail term rather than an invalidation -- and close_disclosures, below, is
    -- where those arrivals are enumerated. This is the whole reason the
    -- checkpoint is safe.
    computed_at_xid xid8 NOT NULL,
    closed_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_closes PRIMARY KEY (tenant_id, period_code, currency),
    CONSTRAINT ck_closes__tenant_non_empty CHECK (btrim(tenant_id) <> ''),
    CONSTRAINT ck_closes__currency_iso CHECK (currency ~ '^[A-Z]{3}$'),
    -- the closing transaction's business date is inside the period it closes
    CONSTRAINT ck_closes__txn_in_period
        CHECK (txn_effective_at >= starts_at AND txn_effective_at < ends_at),
    CONSTRAINT fk_closes__period FOREIGN KEY (tenant_id, period_code, starts_at, ends_at)
        REFERENCES ledger_periods (tenant_id, code, starts_at, ends_at),
    CONSTRAINT fk_closes__txn FOREIGN KEY (tenant_id, transaction_id)
        REFERENCES ledger_transactions (tenant_id, id),
    -- the named transaction is a period-close transaction, not (say) a revenue one
    CONSTRAINT fk_closes__txn_kind FOREIGN KEY (tenant_id, transaction_id, closing_kind)
        REFERENCES ledger_transactions (tenant_id, id, kind),
    -- ...and its effective date is the one carried here, so ck_closes__txn_in_period
    -- constrains the real transaction rather than a free copy
    CONSTRAINT fk_closes__txn_effective FOREIGN KEY (tenant_id, transaction_id, txn_effective_at)
        REFERENCES ledger_transactions (tenant_id, id, effective_at),
    -- one transaction closes one thing
    CONSTRAINT uq_closes__txn UNIQUE (tenant_id, transaction_id)
);

-- The effective-axis checkpoint. DERIVED AND REBUILDABLE -- every row is exactly
-- recomputable from ledger_entries at (effective_at < ends_at, xact_id <
-- computed_at_xid), which is what separates it from the balance_after column
-- spike 009 deleted: bounded (one row per account per period, not per entry), on
-- the axis people actually query, off the write path, and reconciled by
-- recon_checkpoint_breaks below.
--
-- Same input/output convention as ledger_account_balances: input accumulates
-- DEBIT legs, output CREDIT legs, POSTED entries only.
--
-- AT-CLOSE balances (A4). computed_at_xid is held at or above the closing
-- transaction's own xact_id (recon_close_breaks refuses a cursor that precedes its
-- close), so the closing entries sit BELOW the cursor and ARE included in the
-- checkpoint: a temporary account's row is 0 and retained_earnings carries the
-- swept earnings. A backdated arrival above the close cursor is the tail the as-of
-- arithmetic adds, and it needs no special case.
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
    -- a checkpoint row cannot exist without the close that computed it...
    CONSTRAINT fk_period_balances__close FOREIGN KEY (tenant_id, period_code, currency)
        REFERENCES ledger_period_closes (tenant_id, period_code, currency),
    -- ...and carries currency into the account key, as entries and balances do
    CONSTRAINT fk_period_balances__account FOREIGN KEY (tenant_id, account_id, currency)
        REFERENCES ledger_accounts (tenant_id, id, currency)
);


-- ------------------------------------------------- perimeter attestations (ADR-0012)
-- is_perimeter asserts "this account mirrors exactly one EXTERNAL balance and
-- must reconcile against it". A CHECK could not falsify that -- it is a claim
-- about the world, not about the row -- so the only thing that can is DATA ABOUT
-- THE WORLD. This is where it is stored: what a third party said the balance
-- was, on their statement date. perimeter_drift and chart_lint consume it.
CREATE TABLE perimeter_attestations (
    tenant_id  text    NOT NULL,
    account_id uuid    NOT NULL,
    currency   char(3) NOT NULL,
    -- The COUNTERPARTY's statement date, which is a business date, so the
    -- comparison is on the effective axis (ADR-0006). A bank statement is dated
    -- by the bank's book, never by when we read it.
    as_of      date    NOT NULL,
    -- WHOSE business date `as_of` is (ADR-0011). A bare date is not an instant: the
    -- old perimeter_drift resolved `as_of + 1 day` through the SESSION timezone, so
    -- the same attestation compared against a different slice of the journal
    -- depending on who ran the sweep. The zone is stored, as it is on a period, and
    -- the instant is resolved ONCE, here, never at read time.
    tz         text    NOT NULL,
    source     text    NOT NULL,   -- whose statement: the bank, the network, the trustee
    -- Debit-positive, OUR sign convention, so the comparison needs no
    -- normal_balance and a contra account is not flipped twice (ADR-0007 §15).
    external_balance_minor bigint NOT NULL,
    -- The EXCLUSIVE end instant of the as_of business day in `tz`, resolved once and
    -- stored, so perimeter_drift compares a fixed instant rather than a
    -- session-resolved bare date. timezone(text, timestamp) is IMMUTABLE, so this is
    -- a generated column; an unrecognised zone RAISES at write time.
    as_of_end  timestamptz GENERATED ALWAYS AS
                 (((as_of + 1)::timestamp) AT TIME ZONE tz) STORED,
    recorded_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_perimeter_attest PRIMARY KEY (tenant_id, account_id, currency, as_of, source),
    CONSTRAINT fk_perimeter_attest__account FOREIGN KEY (tenant_id, account_id, currency)
        REFERENCES ledger_accounts (tenant_id, id, currency),
    CONSTRAINT ck_perimeter_attest__tenant_non_empty CHECK (btrim(tenant_id) <> ''),
    CONSTRAINT ck_perimeter_attest__source CHECK (btrim(source) <> ''),
    -- the zone name is constrainable declaratively, as it is on a period
    CONSTRAINT ck_perimeter_attest__tz_known
        CHECK ((timestamp '2000-01-01 00:00' AT TIME ZONE tz) IS NOT NULL),
    CONSTRAINT ck_perimeter_attest__currency_iso CHECK (currency ~ '^[A-Z]{3}$')
);


-- ----------------------------------------------------------------------
-- indexes -- the hot reads named in ADR-0006/0011 and the reference product



-- There is no ix_entries__balance_lookup. It was
--     (tenant_id, account_id, account_seq DESC) INCLUDE (balance_after)
-- and the INCLUDE was its whole reason to exist: the three key columns are
-- already indexed by uq_entries__account_seq. Dropping the column (spike 009)
-- left a straight duplicate, so the column took an entire index with it.

-- There is no ix_entries__asof_recorded either. It was (tenant_id, account_id,
-- recorded_at DESC, account_seq DESC) -- an index on a column ADR-0006 proved
-- cannot order commits, serving a question that cannot be answered correctly.
-- The commit-axis index below replaces it: same three columns' worth of space,
-- two jobs -- "what did this account read as, at cursor C", and the checkpoint's
-- backdated-arrivals tail, which without it scans the whole pre-close prefix.
CREATE INDEX ix_entries__asof_commit
    ON ledger_entries (tenant_id, account_id, xact_id);

-- ...and the effective-axis index carries the cursor, so the as-of aggregate
-- stays a single-table index scan under a pinned report (ADR-0011).
CREATE INDEX ix_entries__effective
    ON ledger_entries (tenant_id, account_id, effective_at, xact_id);

CREATE INDEX ix_entries__txn ON ledger_entries (tenant_id, transaction_id);

-- ----------------------------------------------------------------------
-- reports -- the claim Formance cannot meet without a mapping layer
--
-- THE SHAPE (ADR-0011): the trial balance stays a view -- it is the
-- reconciliation substrate, per-account gross arithmetic at "now", and half the
-- views below read it. THE TWO STATEMENTS ARE FUNCTIONS, not views: an issued
-- statement is a function of its parameters -- an effective range (or as-of
-- instant), a commit-ordered cursor, and a chart version -- and a parameterless
-- view answering "since inception, as of whenever you happen to run it, under
-- whatever chart is current" is exactly the un-reproducible number this project
-- refuses to leave reachable by the shortest query.
--
-- security_invoker on the view: without it, a view runs with its OWNER's rights
-- and the row-level security below is decoration on every read that goes through
-- a report -- measured: a reader scoped to t1 was handed both tenants
-- (ADR-0013). The reconciliation views further down deliberately OMIT it: they
-- aggregate across tenants, run as the owner, and are granted only to the
-- reconciliation role.



-- ------------------------------------------------------------ trial balance

CREATE VIEW trial_balance WITH (security_invoker = true) AS
SELECT a.tenant_id, a.id AS account_id, a.owner_id, a.purpose,
       t.category, t.normal_balance, e.currency,
       -- COALESCE, because an account with only credits returned NULL for debits,
       -- and `WHERE debits - credits <> 0` then DROPS the row instead of flagging
       -- it -- the same NULL-swallowing class as the `NULL NOT IN (...)` bug.
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='debit'), 0)  AS debits,
       COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction='credit'), 0) AS credits,
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


-- ------------------------------------------------------------ the cursor

-- The cursor a report pins itself to (ADR-0011). Everything strictly below this
-- xid8 has committed or aborted and can never grow; a row invisible now carries a
-- HIGHER one. NOT `min(seq)` over visible rows -- the mechanism ADR-0006 first
-- specified -- because a minimum over rows the reporter can SEE says nothing
-- about the row it cannot: a writer holding a LOWER id uncommitted sits below
-- such a watermark and appears afterwards. Refuted by measurement, spike 012.
--
-- THE HONEST COSTS: pg_snapshot_xmin is the CLUSTER's horizon, so one
-- long-running transaction anywhere on the server -- another database included --
-- holds every new report's cursor back (lag, never wrongness: a lagged cursor
-- pins an older, still-correct book). And xid8 does not survive a LOGICAL
-- restore -- pg_dump/pg_restore re-inserts under new transaction ids, so every
-- stored cursor is meaningless in the restored database; physical and PITR
-- restores preserve them.
CREATE FUNCTION report_cursor() RETURNS xid8 LANGUAGE sql VOLATILE AS $$
    SELECT pg_snapshot_xmin(pg_current_snapshot())
$$;


-- ------------------------------------------------------------ the trial balance, pinned

CREATE FUNCTION trial_balance_at(p_tenant text, p_from timestamptz, p_to timestamptz,
                                 p_cursor xid8)
RETURNS TABLE (tenant_id text, account_id uuid, purpose text, category ledger_category,
               currency char(3), debits bigint, credits bigint, balance_debit_positive bigint)
LANGUAGE sql STABLE AS $$
-- amount_minor is summed as `numeric` and cast back at the end (ADR-0013): a
-- single huge-but-legal row overflows a running bigint SUM and raises the whole
-- SELECT, and a report that dies on one large row reports nothing.
SELECT a.tenant_id, a.id, a.purpose, t.category, e.currency,
       COALESCE(SUM(e.amount_minor::numeric) FILTER (WHERE e.direction='debit'), 0)::bigint,
       COALESCE(SUM(e.amount_minor::numeric) FILTER (WHERE e.direction='credit'), 0)::bigint,
       SUM(CASE WHEN e.direction='debit' THEN e.amount_minor::numeric ELSE -e.amount_minor::numeric END)::bigint
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                          AND x.status = 'posted'
JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                      AND a.currency = e.currency
JOIN account_types   t ON t.code = a.purpose
WHERE a.tenant_id = p_tenant
  AND e.effective_at >= p_from AND e.effective_at < p_to
  AND e.xact_id < p_cursor
GROUP BY a.tenant_id, a.id, a.purpose, t.category, e.currency;
$$;


-- ------------------------------------------------------------ income statement
--
-- OVER A PERIOD, at a cursor, under a chart version (default: current). It
-- excludes the closing transaction of any period it covers -- otherwise a closed
-- period reports zero revenue, because the close is exactly the entry that
-- zeroes revenue. ledger_period_closes names it, so this is a key lookup rather
-- than a match on a free-text `kind`.
-- plpgsql, not SQL, for the two guards A13/A14 need (a RAISE cannot live in a bare
-- SELECT): the requested version must EXIST, and every account type with posted
-- entries in the window must be presented at it. It writes nothing; it is reporting
-- SQL wrapped in two refusals and a RETURN QUERY. It also returns the cursor it was
-- pinned at, so a reader can tell a fresh report from one held behind a stale
-- horizon (ADR-0011).
CREATE FUNCTION income_statement_for(p_tenant text, p_from timestamptz, p_to timestamptz,
                                     p_cursor xid8, p_chart_version int DEFAULT NULL)
RETURNS TABLE (tenant_id text, currency char(3), chart_version int, fs_line text,
               caption text, sort_order int, amount_minor bigint, side text,
               pinned_cursor xid8)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cv int;
BEGIN
    -- A13: the chart version must EXIST. The old COALESCE never touched
    -- chart_versions, so income_statement_for(..., 999) returned a fabricated,
    -- all-zero, perfectly balanced statement citing a version nobody created.
    v_cv := COALESCE(p_chart_version, (SELECT max(cvx.version) FROM chart_versions cvx));
    IF v_cv IS NULL THEN
        RAISE EXCEPTION 'no chart version exists: seed a chart before running a statement'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM chart_versions cvx WHERE cvx.version = v_cv) THEN
        RAISE EXCEPTION 'chart version % does not exist', v_cv USING ERRCODE = '23514';
    END IF;
    -- A14: an in-scope account WITH posted entries in-window whose type has no
    -- chart_presentation row at this version is silently DROPPED by the INNER JOIN
    -- below -- a whole sub-book vanishing with the statement still balanced. Refuse.
    IF EXISTS (
        SELECT 1
        FROM ledger_entries e
        JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                                  AND x.status = 'posted'
        JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                              AND a.currency = e.currency
        WHERE e.tenant_id = p_tenant
          AND e.effective_at >= p_from AND e.effective_at < p_to
          AND e.xact_id < p_cursor
          AND NOT EXISTS (SELECT 1 FROM chart_presentation p
                          WHERE p.chart_version = v_cv AND p.type_code = a.purpose)
    ) THEN
        RAISE EXCEPTION
          'chart version % does not present every account type with posted entries in this window (chart_lint.type_unpresented)',
          v_cv USING ERRCODE = '23514';
    END IF;

    RETURN QUERY
    WITH dp AS (
        SELECT e.tenant_id, e.currency, p.fs_line,
               SUM(CASE WHEN e.direction='debit' THEN e.amount_minor::numeric
                        ELSE -e.amount_minor::numeric END) AS v
        FROM ledger_entries e
        JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                                  AND x.status = 'posted'
        JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                              AND a.currency = e.currency
        JOIN chart_presentation p ON p.chart_version = v_cv AND p.type_code = a.purpose
        WHERE e.tenant_id = p_tenant
          AND e.effective_at >= p_from AND e.effective_at < p_to
          AND e.xact_id < p_cursor
          AND NOT EXISTS (SELECT 1 FROM ledger_period_closes c
                          WHERE c.tenant_id = x.tenant_id AND c.transaction_id = x.id)
        GROUP BY e.tenant_id, e.currency, p.fs_line
    ), scopes AS (SELECT DISTINCT l.tenant_id, l.currency FROM ledger_accounts l
                  WHERE l.tenant_id = p_tenant)
    SELECT s.tenant_id, s.currency, v_cv, f.code, f.caption, f.sort_order,
           -- credit-normal lines (revenue) present positive; debit-normal (expense) too
           (CASE WHEN f.side = 'credit' THEN -1 ELSE 1 END * COALESCE(SUM(d.v), 0))::bigint,
           f.side, p_cursor
    FROM scopes s
    JOIN fs_lines f ON f.chart_version = v_cv
    LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency AND d.fs_line = f.code
    WHERE f.statement = 'income_statement'
    GROUP BY s.tenant_id, s.currency, f.code, f.caption, f.sort_order, f.side
    -- ORDERED BY THE CHART. sort_order was written by the seed and read by
    -- nothing, so every value in it could be changed with the suite green -- and the
    -- assertion that claimed to check the order was reading PHYSICAL ROW ORDER.
    ORDER BY 1, 2, 6;
END $$;


-- ------------------------------------------------------------ the balance sheet
--
-- AS AT AN INSTANT, at a cursor, under a chart version. Four things distinguish
-- it from the parameterless view it replaces, each one a recorded failure:
--
-- 1. THE AGGREGATE IS PER ACCOUNT BEFORE IT IS PER LINE. Summing straight to the
--    line is arithmetic netting across every account on it, and ADR-0007 §13
--    says netting has rules: IAS 32.42 / ASC 210-20-45-1 permit offset only
--    between the same two parties. For a type whose split key IS the
--    counterparty, one account is one counterparty (uq_accounts__owned), so the
--    position is evaluated per account and each one is routed to its own line --
--    an opposite-sign position to its declared CONTRA line. Netting WITHIN one
--    counterparty is left alone: that is one party, and it is permitted. What is
--    NOT attempted: offsetting two different types facing the same party -- that
--    needs a declared right of set-off and intent, and this schema declares
--    neither, so the presentation stays gross (ADR-0012).
-- 2. THE SIGN FOLLOWS THE LINE, NOT THE ACCOUNT. A liability position routed to
--    its contra line lands on an ASSET line and must present positive there;
--    signing by the account's category prints it negative on an asset line.
--    f.side is three-valued, and asset is the debit-positive side.
-- 3. THE EARNINGS PLUG IS BOUNDED BY THE LAST CLOSE. With no close it sums all
--    history and says so ("since inception"); after a close, retained earnings
--    are in the retained_earnings ACCOUNT and the plug holds only the open
--    period (ADR-0011).
-- 4. It names its chart version and its cursor is a parameter, so an issued
--    statement is reproducible after any backdated posting (ADR-0011, proven).
-- plpgsql, for the A13/A14 guards income_statement_for carries, and returning its
-- cursor for the same reason (ADR-0011). It writes nothing.
CREATE FUNCTION balance_sheet_at(p_tenant text, p_asof timestamptz, p_cursor xid8,
                                 p_chart_version int DEFAULT NULL)
RETURNS TABLE (tenant_id text, currency char(3), chart_version int, fs_line text,
               caption text, sort_order int, amount_minor bigint, side text,
               pinned_cursor xid8)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cv int;
BEGIN
    v_cv := COALESCE(p_chart_version, (SELECT max(cvx.version) FROM chart_versions cvx));
    IF v_cv IS NULL THEN
        RAISE EXCEPTION 'no chart version exists: seed a chart before running a statement'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM chart_versions cvx WHERE cvx.version = v_cv) THEN
        RAISE EXCEPTION 'chart version % does not exist', v_cv USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM ledger_entries e
        JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                                  AND x.status = 'posted'
        JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                              AND a.currency = e.currency
        WHERE e.tenant_id = p_tenant
          AND e.effective_at < p_asof
          AND e.xact_id < p_cursor
          AND NOT EXISTS (SELECT 1 FROM chart_presentation p
                          WHERE p.chart_version = v_cv AND p.type_code = a.purpose)
    ) THEN
        RAISE EXCEPTION
          'chart version % does not present every account type with posted entries as at this instant (chart_lint.type_unpresented)',
          v_cv USING ERRCODE = '23514';
    END IF;

    RETURN QUERY
    WITH scopes AS (
        -- Enumerated from the ACCOUNTS, not from the entries. A scope that has been
        -- opened but has not yet posted anything is still a scope, and a report that
        -- cannot name it cannot claim completeness over it. HONEST LIMIT: this is
        -- still enumeration from data, one level further out -- there is no tenant
        -- registry, so a scope with no accounts at all remains invisible.
        SELECT DISTINCT l.tenant_id, l.currency FROM ledger_accounts l
        WHERE l.tenant_id = p_tenant
    ), pos AS (
        -- HALF-OPEN (effective_at < p_asof), to match the period model and the
        -- income statement: a balance sheet "as at ends_at" is the period's closing
        -- position, [starts_at, ends_at) (ADR-0011).
        SELECT e.tenant_id, e.currency, e.account_id,
               p.category, p.counterparty_scope, p.fs_line, p.fs_line_contra,
               SUM(CASE WHEN e.direction='debit' THEN e.amount_minor::numeric
                        ELSE -e.amount_minor::numeric END) AS v
        FROM ledger_entries e
        JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                                  AND x.status = 'posted'
        JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                              AND a.currency  = e.currency
        JOIN chart_presentation p ON p.chart_version = v_cv AND p.type_code = a.purpose
        WHERE e.tenant_id = p_tenant AND e.effective_at < p_asof AND e.xact_id < p_cursor
        GROUP BY e.tenant_id, e.currency, e.account_id,
                 p.category, p.counterparty_scope, p.fs_line, p.fs_line_contra
    ), dp AS (
        -- ROUTE ON POSITION SIGN (ADR-0012, amended by A10). A position that has
        -- swung to the opposite side of its normal presents on its declared CONTRA
        -- line -- for ANY balance-sheet type that declares one, not only per_shard.
        -- Sign-swing is orthogonal to sharding: a `shared` payable that has gone
        -- into a receivable position must present gross under its contra line, not
        -- net to zero against another payable on the same line.
        SELECT pos.tenant_id, pos.currency, pos.category,
               CASE WHEN pos.fs_line_contra IS NOT NULL
                         AND ((pos.category = 'asset'     AND pos.v < 0)
                           OR (pos.category = 'liability' AND pos.v > 0))
                    THEN pos.fs_line_contra ELSE pos.fs_line END AS fs_line,
               pos.v
        FROM pos
    ), lines AS (
        SELECT s.tenant_id, s.currency,
               f.code AS fs_line, f.caption, f.sort_order, f.side,
               COALESCE(SUM(CASE WHEN f.side = 'asset' THEN d.v ELSE -d.v END), 0)::bigint
                   AS amount_minor
        FROM scopes s
        JOIN fs_lines f ON f.chart_version = v_cv
        LEFT JOIN dp d ON d.tenant_id = s.tenant_id AND d.currency = s.currency
                      AND d.fs_line = f.code
        WHERE f.statement = 'balance_sheet'
        GROUP BY s.tenant_id, s.currency, f.code, f.caption, f.sort_order, f.side
    ), plug AS (
        -- THE UN-CLOSED-EARNINGS PLUG (A3, replacing the max(ends_at) watermark).
        -- The net of ALL temporary (revenue/expense) positions at the cursor,
        -- INCLUDING closing entries. A closed period's operational entries and its
        -- closing reversal cancel, so what remains is exactly earnings not yet
        -- closed at this cursor: no watermark to walk, no ledger_period_closes read,
        -- and a caption that cannot move under a fixed cursor (a caption that moves
        -- under a fixed cursor is itself a reproducibility break). A backdated
        -- arrival above a close cursor is un-closed until a later close sweeps it,
        -- and shows here rather than dropping from equity forever.
        SELECT s.tenant_id, s.currency,
               (-COALESCE((
                   SELECT SUM(CASE WHEN e.direction='debit' THEN e.amount_minor::numeric
                                   ELSE -e.amount_minor::numeric END)
                   FROM ledger_entries e
                   JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                                             AND x.status = 'posted'
                   JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                                         AND a.currency = e.currency
                   JOIN chart_presentation p ON p.chart_version = v_cv AND p.type_code = a.purpose
                   WHERE e.tenant_id = s.tenant_id AND e.currency = s.currency
                     AND e.effective_at < p_asof AND e.xact_id < p_cursor
                     AND p.category IN ('revenue','expense')
               ), 0))::bigint AS amount_minor
        FROM scopes s
    )
    SELECT l.tenant_id, l.currency, v_cv, l.fs_line, l.caption, l.sort_order,
           l.amount_minor, l.side, p_cursor
    FROM lines l
    UNION ALL
    -- The synthesised un-closed-earnings plug. Its side is 'equity'. The caption is
    -- CONSTANT (A3): the plug always means "earnings not yet closed to retained
    -- earnings", so it does not change with whether a close has happened.
    SELECT g.tenant_id, g.currency, v_cv, 'current_year_earnings',
           'Undistributed earnings (since inception)', 9000,
           g.amount_minor, 'equity', p_cursor
    FROM plug g
    ORDER BY 1, 2, 6;
END $$;


-- ----------------------------------------------------------------------
-- reconciliation -- every pair of numbers that should agree, compared (ADR-0010)
--
-- Break lists that must return zero rows on a healthy book, reconciliation
-- statements that always return rows and must foot, and one summary an operator
-- runs as a single query. No triggers: these are SELECTs, they add no write-path
-- object, hold no lock and change no plan on the hot path. They run as the OWNER
-- on purpose -- reconciliation aggregates across tenants -- and are granted to
-- the reconciliation role, not to readers.

-- ----------------------------------------------------------------------
-- 1 - the balance cache against the journal
--
-- The cache is derived state and the journal is append-only, so this comparison
-- is genuinely independent -- which the running balance it replaces was not: the
-- writer computed that one FROM the cache, in the same transaction, from the same
-- locked row (spike 009). Per STRIPE, because the lock, the counter and the
-- cached number all live at stripe grain.
--
-- Six break classes, not one. Three of them are the three jobs of that row
-- failing separately, which is the whole argument for leaving the three on one
-- row. NOTE the asymmetry ADR-0010 measured: last_seq BELOW the journal fails
-- closed (the next writer is handed a number an entry already holds and
-- uq_entries__account_seq refuses it); last_seq ABOVE the journal fails SILENTLY
-- (the next entry skips the difference and gaplessness is gone with no error
-- anywhere).
--
-- THE CACHE MEANS POSTED (ADR-0010): input/output are compared against the
-- POSTED half of the journal, while last_seq is compared against ALL entries,
-- because the counter issues account_seq for pending entries too.
CREATE VIEW recon_balance_breaks AS
WITH j AS (
    SELECT e.tenant_id, e.account_id, e.currency, e.stripe,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'
                                                AND x.status = 'posted'), 0)  AS posted_input,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'
                                                AND x.status = 'posted'), 0) AS posted_output,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'
                                                AND x.status <> 'posted'), 0)  AS pending_input,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'
                                                AND x.status <> 'posted'), 0) AS pending_output,
           COUNT(*)              AS entry_count,
           MAX(e.account_seq)    AS max_seq
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
    GROUP BY e.tenant_id, e.account_id, e.currency, e.stripe
), joined AS (
    SELECT COALESCE(b.tenant_id,  j.tenant_id)  AS tenant_id,
           COALESCE(b.account_id, j.account_id) AS account_id,
           COALESCE(b.currency,   j.currency)   AS currency,
           COALESCE(b.stripe,     j.stripe)     AS stripe,
           b.tenant_id IS NULL AS cache_missing,
           j.tenant_id IS NULL AS journal_empty,
           COALESCE(b.input, 0)    AS cache_input,
           COALESCE(b.output, 0)   AS cache_output,
           COALESCE(b.last_seq, 0) AS cache_last_seq,
           COALESCE(j.posted_input, 0)   AS posted_input,
           COALESCE(j.posted_output, 0)  AS posted_output,
           COALESCE(j.pending_input, 0)  AS pending_input,
           COALESCE(j.pending_output, 0) AS pending_output,
           COALESCE(j.entry_count, 0)    AS entry_count,
           COALESCE(j.max_seq, 0)        AS max_seq
    FROM ledger_account_balances b
    FULL JOIN j
           ON j.tenant_id = b.tenant_id AND j.account_id = b.account_id
          AND j.currency  = b.currency  AND j.stripe = b.stripe
)
SELECT tenant_id, account_id, currency, stripe,
       cache_input, cache_output, cache_input - cache_output AS cache_balance_minor,
       posted_input, posted_output, posted_input - posted_output AS posted_balance_minor,
       pending_input, pending_output,
       cache_last_seq, max_seq, entry_count,
       (cache_input::numeric - cache_output::numeric)
         - (posted_input::numeric - posted_output::numeric) AS drift_minor,
       -- turnover drift, because a cache with both sides inflated by the same
       -- amount has the right balance and the wrong gross. ::numeric (ADR-0010): a
       -- large legal append made this bigint subtraction overflow and RAISE on the
       -- very row the break list exists to show.
       (cache_input::numeric + cache_output::numeric)
         - (posted_input::numeric + posted_output::numeric) AS drift_turnover_minor,
       ARRAY_REMOVE(ARRAY[
         CASE WHEN cache_input <> posted_input OR cache_output <> posted_output
              THEN 'balance_drift' END,
         CASE WHEN NOT cache_missing AND cache_last_seq < max_seq THEN 'seq_behind' END,
         CASE WHEN NOT cache_missing AND cache_last_seq > max_seq THEN 'seq_ahead' END,
         -- 1..N with nothing skipped. ADR-0004: gaplessness is enforced when the
         -- number is ISSUED and checked nowhere afterwards. This is afterwards.
         CASE WHEN entry_count <> max_seq THEN 'seq_gap' END,
         -- no row to lock: the next writer's upsert INSERTs and starts the
         -- stripe at seq 1 again, on a stripe that already has history
         CASE WHEN cache_missing THEN 'no_cache_row' END,
         CASE WHEN journal_empty AND (cache_input <> 0 OR cache_output <> 0
                                      OR cache_last_seq <> 0) THEN 'no_entries' END
       ], NULL) AS reasons
FROM joined
WHERE cache_input <> posted_input
   OR cache_output <> posted_output
   OR cache_missing
   OR (NOT cache_missing AND cache_last_seq <> max_seq)
   OR entry_count <> max_seq
   OR (journal_empty AND (cache_input <> 0 OR cache_output <> 0 OR cache_last_seq <> 0));


-- ----------------------------------------------------------------------
-- 2 - entries no report can count
--
-- WHAT AN ORPHAN IS, stated rather than assumed: an entry that every report
-- structurally cannot include, for a reason other than its status. Every report
-- joins the same three tables the same way -- ledger_transactions on (tenant,
-- id), ledger_accounts on (tenant, id, currency), account_types on purpose -- so
-- the orphan population is exactly the entries that fail one of those joins. A
-- pending entry is NOT an orphan: it is excluded on purpose and is a reconciling
-- item (recon_pending_bridge).
--
-- Every one of those joins is backed by a foreign key, so this view is empty on
-- any path that enforces them. It is not empty on the paths that do not:
-- session_replication_role='replica' (logical replication apply, and what
-- `pg_restore --disable-triggers` sets) skips the FK triggers, all of which ship
-- ENABLE ORIGIN -- ADR-0009 records why that stays.
CREATE VIEW recon_entry_breaks AS
SELECT e.tenant_id, e.id AS entry_id, e.transaction_id, e.account_id,
       e.currency, e.direction, e.amount_minor, e.stripe, e.account_seq,
       e.effective_at, e.recorded_at,
       CASE WHEN x.id   IS NULL THEN 'no_transaction'
            WHEN a.id   IS NULL THEN 'no_account'
            WHEN t.code IS NULL THEN 'no_account_type'
       END AS reason
FROM ledger_entries e
LEFT JOIN ledger_transactions x
       ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
LEFT JOIN ledger_accounts a
       ON a.tenant_id = e.tenant_id AND a.id = e.account_id
      AND a.currency  = e.currency
LEFT JOIN account_types t ON t.code = a.purpose
WHERE x.id IS NULL OR a.id IS NULL OR t.code IS NULL;


-- ----------------------------------------------------------------------
-- 3 - transactions that do not balance
--
-- Nothing else in the artefact reports this. ADR-0005 puts balance in the
-- writer's type, where a caller cannot express one leg -- and until that writer
-- exists ledger_entries stores independent rows carrying a direction, so an
-- unbalanced transaction is fully expressible. This view does not enforce it and
-- is not a substitute for the type: it is the exception list that says whether
-- the claim is true of the data.
--
-- PER CURRENCY (ADR-0007 rule 12). A transaction whose USD legs are short by
-- 100.00 and whose EUR legs are long by 100.00 balances in neither currency and
-- in no meaningful sense; grouped currency-blind it would foot to zero.
--
-- A one-entry transaction is caught by the same arithmetic (amount_minor > 0, so
-- a single leg can never be zero); a ZERO-entry transaction has no currency to
-- group by and needs the LEFT JOIN. Both were reached on this schema.
CREATE VIEW recon_transaction_breaks AS
WITH legs AS (
    -- Aggregated first, then joined: the other form is a merge join driven by an
    -- index scan over every entry -- 931 ms against 754 ms at 1,000,000 entries.
    SELECT e.tenant_id, e.transaction_id, e.currency,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'), 0)  AS debits,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'), 0) AS credits,
           COUNT(*) AS leg_count
    FROM ledger_entries e
    GROUP BY e.tenant_id, e.transaction_id, e.currency
)
SELECT x.tenant_id, x.id AS transaction_id, x.status, x.kind,
       x.effective_at, x.recorded_at,
       g.currency,
       COALESCE(g.debits, 0)  AS debits,
       COALESCE(g.credits, 0) AS credits,
       COALESCE(g.debits, 0) - COALESCE(g.credits, 0) AS imbalance_minor,
       COALESCE(g.leg_count, 0) AS leg_count,
       CASE WHEN g.transaction_id IS NULL THEN 'no_entries'
            WHEN g.leg_count = 1          THEN 'single_leg'
            ELSE 'debits_ne_credits' END AS reason
FROM ledger_transactions x
LEFT JOIN legs g ON g.tenant_id = x.tenant_id AND g.transaction_id = x.id
WHERE g.transaction_id IS NULL OR g.debits <> g.credits;


-- ----------------------------------------------------------------------
-- 4 - the two sides of a cross-scope obligation
--
-- Tenant-locality is correctness, not optimization: no transaction spans two
-- tenants, so a movement between scopes is TWO transactions joined by clearing
-- accounts. Each side balances on its own, which is why nothing in a per-tenant
-- report can notice that the two sides disagree. The comparison has to aggregate
-- ACROSS tenants, and it is the only break list here that does.
--
-- THE INVARIANT: for a mirrored pair of account types (account_types.mirror_type),
-- the sum of the DEBIT-POSITIVE balance over both types is zero, per currency, PER
-- COUNTERPARTY. It works because the pair is opposite-signed by construction -- a
-- claim on the operator is an asset to the tenant and a liability to the operator.
--
-- GROUPED BY COUNTERPARTY, not deployment-wide (A9). The near side (a tenant's
-- claim, e.g. due_from_treasury) lives in that tenant's own book, so its
-- counterparty identity is tb.tenant_id. The far side (the operator's obligation,
-- due_to_tenants) is owner-keyed in the operator's book, so its counterparty is
-- tb.owner_id. A deployment-wide sum let a THIRD scope's offsetting position cancel
-- a real gap between two others -- 425 short to tenant A hidden by 425 long to
-- tenant B. Matched per counterparty, an unmatched leg cannot be cancelled by an
-- unrelated one.
CREATE VIEW recon_scope_breaks AS
WITH pairs AS (
    SELECT t.code AS near_type, t.mirror_type AS far_type
    FROM account_types t
    JOIN account_types m ON m.code = t.mirror_type
    WHERE t.mirror_type IS NOT NULL
), near AS (
    SELECT p.near_type, p.far_type, tb.currency,
           tb.tenant_id AS counterparty,
           SUM(tb.balance_debit_positive) AS near_minor
    FROM pairs p
    JOIN trial_balance tb ON tb.purpose = p.near_type
    GROUP BY p.near_type, p.far_type, tb.currency, tb.tenant_id
), far AS (
    SELECT p.near_type, p.far_type, tb.currency,
           tb.owner_id AS counterparty,
           SUM(tb.balance_debit_positive) AS far_minor
    FROM pairs p
    JOIN trial_balance tb ON tb.purpose = p.far_type
    GROUP BY p.near_type, p.far_type, tb.currency, tb.owner_id
)
SELECT COALESCE(n.near_type, f.near_type)   AS near_type,
       COALESCE(n.far_type,  f.far_type)    AS far_type,
       COALESCE(n.currency,  f.currency)    AS currency,
       COALESCE(n.counterparty, f.counterparty) AS counterparty,
       COALESCE(n.near_minor, 0)            AS near_minor,
       COALESCE(f.far_minor, 0)             AS far_minor,
       COALESCE(n.near_minor, 0) + COALESCE(f.far_minor, 0) AS gap_minor
FROM near n
FULL JOIN far f
       ON f.near_type = n.near_type AND f.far_type = n.far_type
      AND f.currency = n.currency  AND f.counterparty IS NOT DISTINCT FROM n.counterparty
WHERE COALESCE(n.near_minor, 0) + COALESCE(f.far_minor, 0) <> 0;


-- ----------------------------------------------------------------------
-- 5 - the journal against the reports
--
-- A RECONCILIATION STATEMENT, not a break list: it always returns a row per
-- (tenant, currency) and every row must foot. The shape is the one a bank
-- reconciliation has -- open with the source figure, subtract each reconciling
-- item by name, and what is left unexplained is the break.
--
--     journal debits
--       - pending (excluded by every report on purpose)
--       - orphaned (recon_entry_breaks)
--       = what a report SHOULD show
--       - what trial_balance ACTUALLY shows
--       = unexplained, which must be zero
--
-- "Three lines of SQL would surface it" -- the decision log's old claim -- was
-- wrong: the raw journal-minus-report difference is NONZERO ON EVERY HEALTHY
-- BOOK carrying a hold, so the naive subtraction cries wolf and gets ignored. A
-- reconciliation names its reconciling items. The last subtraction is the half
-- that matters: `reported_*` is computed from the journal by this view's own
-- classification, and `tb_*` is read from the shipped view. If the two ever
-- disagree the report has grown a filter this classification does not know
-- about, which is precisely the "dropped balanced sub-book" ADR-0007 is about.
-- FALSIFIABLE (A7). The old `r` side read trial_balance, which classifies entries
-- with exactly the three joins `classified` uses -- so `reported` and `tb` were the
-- same multiset and `unexplained` was structurally zero: a check that could never
-- fail. `r` now sums the population the STATEMENT FUNCTIONS actually enumerate:
-- posted, valid, AND presented by the current chart version (the chart_presentation
-- join the statements do). An account type with posted entries but no presentation
-- row at the current version is in `reported` (the journal thinks it reportable)
-- and NOT in `r` (the statements drop it) -- so unexplained <> 0, the very
-- dropped-sub-book the check exists to catch (it converges with the A14 RAISE).
--
-- FOUR named reconciling items now, not two (A5, A17): a pending transaction that
-- has since been RESOLVED or REVERSED is `superseded`, not `pending` (nothing else
-- retired it); an otherwise-reportable entry whose effective_at falls outside a
-- sane window -- a fat-fingered year 2226 -- is `out_of_window`, surfaced rather
-- than silently `reported`.
CREATE VIEW recon_journal_to_reports AS
WITH classified AS (
    SELECT e.tenant_id, e.currency, e.direction, e.amount_minor,
           CASE
             WHEN x.id IS NULL OR a.id IS NULL OR t.code IS NULL THEN 'orphan'
             WHEN x.status <> 'posted' AND EXISTS (
                    SELECT 1 FROM ledger_transactions rr
                    WHERE rr.tenant_id = x.tenant_id
                      AND (rr.resolves_id = x.id OR rr.reverses_id = x.id))
                  THEN 'superseded'
             WHEN x.status <> 'posted' THEN 'pending'
             WHEN e.effective_at < TIMESTAMPTZ '1900-01-01'
               OR e.effective_at >= now() + interval '1 year' THEN 'out_of_window'
             ELSE 'reported' END AS bucket
    FROM ledger_entries e
    LEFT JOIN ledger_transactions x
           ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
    LEFT JOIN ledger_accounts a
           ON a.tenant_id = e.tenant_id AND a.id = e.account_id
          AND a.currency  = e.currency
    LEFT JOIN account_types t ON t.code = a.purpose
), j AS (
    SELECT tenant_id, currency,
           COALESCE(SUM(amount_minor::numeric) FILTER (WHERE direction = 'debit'), 0)  AS journal_debits,
           COALESCE(SUM(amount_minor::numeric) FILTER (WHERE direction = 'credit'), 0) AS journal_credits,
           COALESCE(SUM(amount_minor::numeric) FILTER (WHERE direction = 'debit'  AND bucket = 'pending'), 0) AS pending_debits,
           COALESCE(SUM(amount_minor::numeric) FILTER (WHERE direction = 'credit' AND bucket = 'pending'), 0) AS pending_credits,
           COALESCE(SUM(amount_minor::numeric) FILTER (WHERE direction = 'debit'  AND bucket = 'superseded'), 0) AS superseded_debits,
           COALESCE(SUM(amount_minor::numeric) FILTER (WHERE direction = 'credit' AND bucket = 'superseded'), 0) AS superseded_credits,
           COALESCE(SUM(amount_minor::numeric) FILTER (WHERE direction = 'debit'  AND bucket = 'out_of_window'), 0) AS out_of_window_debits,
           COALESCE(SUM(amount_minor::numeric) FILTER (WHERE direction = 'credit' AND bucket = 'out_of_window'), 0) AS out_of_window_credits,
           COALESCE(SUM(amount_minor::numeric) FILTER (WHERE direction = 'debit'  AND bucket = 'orphan'), 0)  AS orphan_debits,
           COALESCE(SUM(amount_minor::numeric) FILTER (WHERE direction = 'credit' AND bucket = 'orphan'), 0)  AS orphan_credits,
           COALESCE(SUM(amount_minor::numeric) FILTER (WHERE direction = 'debit'  AND bucket = 'reported'), 0) AS reported_debits,
           COALESCE(SUM(amount_minor::numeric) FILTER (WHERE direction = 'credit' AND bucket = 'reported'), 0) AS reported_credits
    FROM classified GROUP BY tenant_id, currency
), r AS (
    SELECT e.tenant_id, e.currency,
           COALESCE(SUM(e.amount_minor::numeric) FILTER (WHERE e.direction = 'debit'), 0)  AS tb_debits,
           COALESCE(SUM(e.amount_minor::numeric) FILTER (WHERE e.direction = 'credit'), 0) AS tb_credits
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                              AND x.status = 'posted'
    JOIN ledger_accounts a ON a.tenant_id = e.tenant_id AND a.id = e.account_id
                          AND a.currency = e.currency
    JOIN account_types ty ON ty.code = a.purpose
    CROSS JOIN chart_version_current cv
    JOIN chart_presentation p ON p.chart_version = cv.chart_version AND p.type_code = a.purpose
    GROUP BY e.tenant_id, e.currency
)
SELECT COALESCE(j.tenant_id, r.tenant_id) AS tenant_id,
       COALESCE(j.currency,  r.currency)  AS currency,
       COALESCE(j.journal_debits, 0)   AS journal_debits,
       COALESCE(j.journal_credits, 0)  AS journal_credits,
       COALESCE(j.pending_debits, 0)   AS pending_debits,
       COALESCE(j.pending_credits, 0)  AS pending_credits,
       COALESCE(j.superseded_debits, 0)  AS superseded_debits,
       COALESCE(j.superseded_credits, 0) AS superseded_credits,
       COALESCE(j.out_of_window_debits, 0)  AS out_of_window_debits,
       COALESCE(j.out_of_window_credits, 0) AS out_of_window_credits,
       COALESCE(j.orphan_debits, 0)    AS orphan_debits,
       COALESCE(j.orphan_credits, 0)   AS orphan_credits,
       COALESCE(j.reported_debits, 0)  AS reported_debits,
       COALESCE(j.reported_credits, 0) AS reported_credits,
       COALESCE(r.tb_debits, 0)        AS tb_debits,
       COALESCE(r.tb_credits, 0)       AS tb_credits,
       COALESCE(j.reported_debits, 0)  - COALESCE(r.tb_debits, 0)  AS unexplained_debits,
       COALESCE(j.reported_credits, 0) - COALESCE(r.tb_credits, 0) AS unexplained_credits,
       -- the number the decision log measured at 50,000.00 and no view reported
       COALESCE(j.journal_debits, 0) - COALESCE(r.tb_debits, 0)    AS journal_minus_report_debits
FROM j FULL JOIN r ON r.tenant_id = j.tenant_id AND r.currency = j.currency;


-- ----------------------------------------------------------------------
-- 6 - the pending bridge: posted, plus pending, is available
--
-- The bridge between the two numbers this system publishes (ADR-0010). The cache
-- holds the POSTED balance; the pending population is a real one -- transactions
-- accepted and not yet resolved -- and "available" is DERIVED here as posted
-- plus pending, never stored. Not a break list: a row is a reconciling item,
-- enumerated and aged. Whether the cache actually equals the posted journal is
-- recon_balance_breaks' question, deliberately not re-asked here -- a break
-- counted twice is a break argued about twice.
CREATE VIEW recon_pending_bridge AS
WITH pend AS (
    SELECT e.tenant_id, e.account_id, e.currency,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'debit'), 0)  AS pending_debits,
           COALESCE(SUM(e.amount_minor) FILTER (WHERE e.direction = 'credit'), 0) AS pending_credits,
           COUNT(DISTINCT e.transaction_id) AS pending_txns,
           MIN(x.effective_at)              AS oldest_pending_effective_at
    FROM ledger_entries e
    JOIN ledger_transactions x
      ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
    WHERE x.status <> 'posted'
      -- ...and NOT already retired (A5). A hold that has been resolved (a posted
      -- transaction whose resolves_id names it) or reversed is no longer part of
      -- the pending population -- it has landed or been undone. Nothing read
      -- resolves_id/reverses_id here, so every hold ever placed counted forever and
      -- the available balance drifted from the posted one by the whole resolved
      -- history. `superseded` in recon_journal_to_reports is the matching item.
      AND NOT EXISTS (
          SELECT 1 FROM ledger_transactions rr
          WHERE rr.tenant_id = x.tenant_id
            AND (rr.resolves_id = x.id OR rr.reverses_id = x.id))
    GROUP BY e.tenant_id, e.account_id, e.currency
), cache AS (
    SELECT b.tenant_id, b.account_id, b.currency,
           SUM(b.input - b.output) AS posted_balance_minor
    FROM ledger_account_balances b
    GROUP BY b.tenant_id, b.account_id, b.currency
)
SELECT p.tenant_id, p.account_id, a.purpose, p.currency,
       COALESCE(c.posted_balance_minor, 0)             AS posted_balance_minor,
       p.pending_debits - p.pending_credits            AS pending_balance_minor,
       COALESCE(c.posted_balance_minor, 0)
         + (p.pending_debits - p.pending_credits)      AS available_balance_minor,
       p.pending_debits, p.pending_credits, p.pending_txns,
       p.oldest_pending_effective_at
FROM pend p
JOIN ledger_accounts a
  ON a.tenant_id = p.tenant_id AND a.id = p.account_id AND a.currency = p.currency
LEFT JOIN cache c
  ON c.tenant_id = p.tenant_id AND c.account_id = p.account_id AND c.currency = p.currency;


-- ----------------------------------------------------------------------
-- 7 - the checkpoint against the journal (ADR-0011)
--
-- ledger_period_balances is exactly recomputable from ledger_entries at its
-- stored cursor -- that is what makes it checkable, and this is the check. The
-- same sweep as recon_balance_breaks, one axis over: a checkpoint that nothing
-- reconciles is the balance_after column with better manners.
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
-- COMPARE VALUES, not mere presence (A11). The recompute joins ledger_entries, so a
-- DORMANT account -- one the close wrote a 0/0 checkpoint row for but which has no
-- entries in the window -- has a stored row and no recomputed row. That is not a
-- break: 0 = 0. A missing recomputed row only matters when the stored values are
-- non-zero, and a missing stored row only matters when the recomputed values are.
WHERE COALESCE(s.input, 0)  <> COALESCE(r.input, 0)
   OR COALESCE(s.output, 0) <> COALESCE(r.output, 0);


-- ----------------------------------------------------------------------
-- 8 - entries backdated past a close (ADR-0011)
--
-- NOT a break list -- these entries are LEGAL, and refusing them is the period
-- lock this design deliberately does not take: a late clearing carrying a closed
-- period's business date is normal, and a refused one is money that exists
-- nowhere. This is the disclosure instead: the analogue of IAS 1.41's
-- reclassification disclosure, one index scan on ix_entries__asof_commit. A row
-- here means an already-issued report for that period no longer matches a
-- re-run at "now" -- which is exactly why issued reports pin a cursor.
CREATE VIEW close_disclosures AS
SELECT c.tenant_id, c.period_code, c.currency, c.computed_at_xid,
       e.id AS entry_id, e.transaction_id, e.account_id, e.direction,
       e.amount_minor, e.effective_at, e.xact_id, e.recorded_at
FROM ledger_period_closes c
JOIN ledger_entries e
  ON e.tenant_id = c.tenant_id AND e.currency = c.currency
 AND e.effective_at < c.ends_at AND e.xact_id >= c.computed_at_xid
JOIN ledger_transactions x
  ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id AND x.status = 'posted'
WHERE NOT EXISTS (SELECT 1 FROM ledger_period_closes c2
                  WHERE c2.tenant_id = x.tenant_id AND c2.transaction_id = x.id);


-- ------------------------------------------------------------ perimeter drift
--
-- is_perimeter's consumer (ADR-0012). Compares what a third party says the
-- balance was on their statement date against what our book says on the same
-- BUSINESS date -- the effective axis, because a counterparty's statement is
-- dated by their book (ADR-0006). The bound is the STORED instant `as_of_end` --
-- the exclusive end of the as_of business day in the attestation's own zone,
-- resolved once at write time (A16). The old `(as_of + 1)::timestamptz` resolved
-- the bare date through the SESSION timezone, so the same attestation compared
-- against a different slice of the journal depending on who ran the sweep.
CREATE VIEW perimeter_drift AS
SELECT at.tenant_id, at.account_id, a.purpose, at.currency, at.as_of, at.source,
       t.is_perimeter,
       at.external_balance_minor,
       COALESCE(ours.v, 0)                             AS ledger_balance_minor,
       COALESCE(ours.v, 0) - at.external_balance_minor AS drift_minor
FROM perimeter_attestations at
JOIN ledger_accounts a ON a.tenant_id = at.tenant_id AND a.id = at.account_id
                      AND a.currency = at.currency
JOIN account_types t ON t.code = a.purpose
LEFT JOIN LATERAL (
    SELECT SUM(CASE WHEN e.direction='debit' THEN e.amount_minor::numeric
                    ELSE -e.amount_minor::numeric END)::bigint AS v
    FROM ledger_entries e
    JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
                              AND x.status = 'posted'
    WHERE e.tenant_id = at.tenant_id AND e.account_id = at.account_id
      AND e.currency = at.currency
      AND e.effective_at < at.as_of_end
) ours ON true;


-- ------------------------------------------------------------ the chart lint
--
-- WHAT THIS IS FOR (ADR-0012). A wrong counterparty_scope CHANGES A REPORTED
-- NUMBER -- declaring due_to_tenants `shared` collapses the gross presentation
-- back to a netted zero -- which is the strongest kind of detectability and also
-- the most dangerous, because the number stays balanced. These rules catch the
-- SHAPE instead: a chart claim that the account register contradicts. They are
-- exception views, so empty is the passing state.
--
-- They are lints and not constraints because every one is a statement about a
-- POPULATION of rows in another table, which no CHECK and no key can reach. The
-- one rule that could be made declarative -- per_shard implies not house -- IS:
-- ck_accounts__per_shard_is_owned, and it appears here too so a deployment that
-- adopted the constraint NOT VALID still sees its legacy rows.
CREATE VIEW chart_lint AS
-- 1. every type must be presented by EVERY chart version, not just the current one
--    (A14). An issued statement pins a version; if an older version failed to
--    present a type that has entries, re-running that pinned report DROPS the type
--    -- the same silent sub-book loss the statement functions now RAISE on. At-most-
--    one is pk_presentation; at-least-one is mandatory participation across two
--    tables, which is not declaratively expressible in PostgreSQL.
SELECT 'type_unpresented' AS rule, 'error' AS severity,
       t.code || ' @ v' || cv.version AS subject,
       'account type has no chart_presentation row in chart version ' || cv.version AS detail
FROM account_types t
CROSS JOIN chart_versions cv
WHERE NOT EXISTS (SELECT 1 FROM chart_presentation p
                   WHERE p.chart_version = cv.version AND p.type_code = t.code)
UNION ALL
-- 2. a line nothing can reach. Not an error -- a chart may carry a line ahead of
--    the type that will use it -- but a caption no account can ever reach is a
--    zero on the face of every statement forever, and ADR-0007 §11 makes zeros
--    meaningful, so an unreachable one is noise in the one report whose job is
--    completeness.
SELECT 'line_unreachable', 'info', f.code,
       'fs_line has no account type mapped to it in this chart version'
FROM fs_lines f, chart_version_current cv
WHERE f.chart_version = cv.chart_version
  AND NOT EXISTS (SELECT 1 FROM chart_presentation p
                   WHERE p.chart_version = f.chart_version
                     AND (p.fs_line = f.code OR p.fs_line_contra = f.code))
UNION ALL
-- 3. counterparty_scope = 'per_shard' held in a house account. The grain the
--    gross presentation needs does not exist, and no report can recover it.
--    Refused at account-open time by ck_accounts__per_shard_is_owned; listed
--    here for books that predate the constraint.
SELECT 'per_shard_in_house_account', 'error', t.code,
       'per_shard type held in ' || count(*) || ' house account(s): opposite-sign '
       'positions against different counterparties are already netted at write time'
FROM account_types t
JOIN ledger_accounts a ON a.purpose = t.code AND a.owner_type = 'house'
WHERE t.counterparty_scope = 'per_shard'
GROUP BY t.code
UNION ALL
-- 4. counterparty_scope = 'shared' -- "all members face ONE counterparty" -- on a
--    type whose accounts are keyed to more than one owner inside a scope. The
--    split key demonstrably IS a counterparty distinction, so the declaration is
--    false and the statement is netting parties it may not net.
SELECT 'shared_but_split_by_owner', 'error', t.code,
       'counterparty_scope=shared but accounts are keyed to ' || count(DISTINCT a.owner_id)
       || ' distinct owners'
FROM account_types t
JOIN ledger_accounts a ON a.purpose = t.code AND a.owner_type <> 'house'
WHERE t.counterparty_scope = 'shared'
GROUP BY t.code
HAVING count(DISTINCT a.owner_id) > 1
UNION ALL
-- 5. counterparty_scope = 'none' -- no counterparty at all -- on an owner-keyed
--    type. Either the owner is a counterparty and the scope is wrong, or the
--    owner is a reporting dimension and the account register is using the wrong
--    column for it.
SELECT 'none_but_owner_keyed', 'warn', t.code,
       'counterparty_scope=none but ' || count(*) || ' account(s) are owner-keyed'
FROM account_types t
JOIN ledger_accounts a ON a.purpose = t.code AND a.owner_type <> 'house'
WHERE t.counterparty_scope = 'none'
GROUP BY t.code
UNION ALL
-- 6. is_perimeter = true and nobody outside has ever confirmed the balance. The
--    column's whole claim is "must reconcile against an external balance"; an
--    account with posted entries and no attestation has never been reconciled,
--    and until now that was not observable anywhere.
SELECT 'perimeter_unattested', 'error', t.code || ' / ' || a.tenant_id || ' / ' || a.id::text,
       'is_perimeter account carries posted entries and has no attestation'
FROM account_types t
JOIN ledger_accounts a ON a.purpose = t.code
WHERE t.is_perimeter
  AND EXISTS (SELECT 1 FROM ledger_entries e
              JOIN ledger_transactions x ON x.tenant_id=e.tenant_id AND x.id=e.transaction_id
                                        AND x.status='posted'
              WHERE e.tenant_id=a.tenant_id AND e.account_id=a.id)
  AND NOT EXISTS (SELECT 1 FROM perimeter_attestations at
                  WHERE at.tenant_id=a.tenant_id AND at.account_id=a.id)
UNION ALL
-- 7. ...and the other direction. Somebody outside confirms this balance, and the
--    chart says it is not a perimeter account. One of the two is wrong, and it
--    is usually the chart -- this is the shape that caught
--    network_settlement_payable in spike 004, found by reading rather than by a
--    check.
SELECT 'attested_but_not_perimeter', 'warn', a.purpose || ' / ' || at.source,
       'attestation exists for an account whose type declares is_perimeter = false'
FROM perimeter_attestations at
JOIN ledger_accounts a ON a.tenant_id=at.tenant_id AND a.id=at.account_id AND a.currency=at.currency
JOIN account_types t ON t.code = a.purpose
WHERE NOT t.is_perimeter
GROUP BY a.purpose, at.source
UNION ALL
-- 8. the drift itself, on the most recent attestation per account and source.
SELECT 'perimeter_drift', 'error',
       d.purpose || ' / ' || d.tenant_id || ' / ' || d.source,
       'ledger ' || d.ledger_balance_minor || ' against attested '
       || d.external_balance_minor || ' as of ' || d.as_of
FROM perimeter_drift d
WHERE d.drift_minor <> 0
  AND d.as_of = (SELECT max(d2.as_of) FROM perimeter_drift d2
                  WHERE d2.tenant_id=d.tenant_id AND d2.account_id=d.account_id
                    AND d2.currency=d.currency AND d2.source=d.source)
UNION ALL
-- 9. a declared mirror pair that is NOT opposite-signed (A9). recon_scope_breaks
--    sums the two types to zero per counterparty, which only foots when one side is
--    debit-normal and the other credit-normal -- a claim on the operator is an
--    asset to the tenant and a liability to the operator. A same-side pairing can
--    never net to zero, so the elimination is silently unfalsifiable.
SELECT 'mirror_same_side', 'error', t.code || ' / ' || t.mirror_type,
       'mirror pair ' || t.code || ' <-> ' || t.mirror_type
         || ' share normal_balance ' || t.normal_balance::text
         || '; a mirror must be opposite-signed to eliminate to zero'
FROM account_types t
JOIN account_types m ON m.code = t.mirror_type
WHERE t.mirror_type IS NOT NULL
  AND t.normal_balance = m.normal_balance
UNION ALL
-- 10. a balance-sheet type that carries a counterparty scope but has no declared
--     elimination path (A9): no mirror_type, is not the target of one, and is not a
--     perimeter account (which reconciles against an external attestation instead).
--     Its cross-scope position, if it takes one, is checked by nothing --
--     recon_scope_breaks needs a declared pair to see it. Warn, because a
--     counterparty-scoped type need not have a cross-scope counterpart, but it is
--     the shape that hides an unreconciled obligation.
SELECT 'mirror_undeclared', 'warn', t.code,
       'counterparty_scope=' || t.counterparty_scope
         || ' but no mirror_type declared, not a mirror target, and not a perimeter '
         || 'account: a cross-scope position of this type is reconciled by nothing'
FROM account_types t
WHERE t.counterparty_scope <> 'none'
  AND t.category IN ('asset','liability')
  AND NOT t.is_perimeter
  AND t.mirror_type IS NULL
  AND NOT EXISTS (SELECT 1 FROM account_types m WHERE m.mirror_type = t.code)
  AND EXISTS (SELECT 1 FROM ledger_accounts a
              WHERE a.purpose = t.code AND a.owner_type <> 'house');


-- ----------------------------------------------------------------------
-- 9 - the close names its own transaction's commit position (ADR-0011)
--
-- fk_closes__txn_kind and fk_closes__txn_effective type the close's transaction
-- declaratively (A4). computed_at_xid is the one property no key reaches: it must
-- be at or after the closing transaction's own commit position, or the checkpoint
-- was computed at a cursor that could not have seen the close it records. A
-- computed_at_xid of 1 makes recon_checkpoint_breaks vacuously green (it recomputes
-- entries below the cursor -- none -- against a checkpoint that should also be
-- empty). This is the sweep's assertion of the relationship a CHECK cannot express
-- across the two tables.
--
-- NOTE (for the doc pass): this REVERSES the "PRE-CLOSE" framing in ADR-0011 and in
-- the ledger_period_balances comment. With computed_at_xid >= the closing txn's
-- xact_id, the closing entries sit BELOW the cursor and ARE included in the
-- checkpoint; recon_checkpoint_breaks recomputes them, and the checkpoint is the
-- AT-close position, not the pre-close one.
CREATE VIEW recon_close_breaks AS
SELECT c.tenant_id, c.period_code, c.currency, c.transaction_id,
       c.computed_at_xid, x.xact_id AS txn_xact_id, 'cursor_precedes_close' AS reason
FROM ledger_period_closes c
JOIN ledger_transactions x
  ON x.tenant_id = c.tenant_id AND x.id = c.transaction_id
WHERE c.computed_at_xid < x.xact_id;


-- ----------------------------------------------------------------------
-- 10 - entries whose commit key is impossible (ADR-0011)
--
-- xact_id decides what a pinned report can see, and the column-level INSERT grant
-- (below) stops the APP role forging it -- but the owner can still write one, and a
-- forged xact_id silences no check today. Two shapes are impossible on an honest
-- book: an xact_id at or above the current snapshot's xmin (a committed row's
-- commit position is always retired below the horizon by the time the sweep runs),
-- and an entry whose xact_id is BELOW its own transaction's -- a leg claiming to
-- have committed before the transaction that carries it. A legitimately appended
-- leg carries a HIGHER id than its transaction and passes.
CREATE VIEW recon_cursor_breaks AS
SELECT e.tenant_id, e.id AS entry_id, e.transaction_id, e.xact_id,
       x.xact_id AS txn_xact_id,
       CASE WHEN e.xact_id > pg_snapshot_xmin(pg_current_snapshot()) THEN 'above_horizon'
            WHEN e.xact_id < x.xact_id THEN 'predates_txn' END AS reason
FROM ledger_entries e
JOIN ledger_transactions x ON x.tenant_id = e.tenant_id AND x.id = e.transaction_id
WHERE e.xact_id > pg_snapshot_xmin(pg_current_snapshot())
   OR e.xact_id < x.xact_id;


-- ----------------------------------------------------------------------
-- 11 - the accounting equation, on the FACE of the balance sheet (A6)
--
-- THE HIGHEST-LEVERAGE CHECK on the list. reconciliation compared the cache, the
-- journal, the trial balance and the checkpoint -- and never the statements
-- themselves, so a balance sheet could be made wrong half a dozen ways (a mis-
-- bounded plug, a mis-typed close, a swung position netted away) with every break
-- list green. This runs balance_sheet_at per tenant and asserts assets = liabilities
-- + equity + earnings, per currency, which no journal-level check can falsify: the
-- journal always foots to zero by construction; the PRESENTATION is where it breaks.
--
-- A FUNCTION, because balance_sheet_at is parameterised on a cursor and an as-of
-- instant. reconciliation calls it at (report_cursor(), 'infinity'); the sweep can
-- call it at any pinned cursor to test an issued statement. ::numeric so a huge
-- legal line cannot raise the check (A12).
CREATE FUNCTION recon_equation_breaks(p_cursor xid8, p_asof timestamptz)
RETURNS TABLE (tenant_id text, currency char(3),
               assets_minor numeric, liab_equity_minor numeric, gap_minor numeric)
LANGUAGE sql STABLE AS $$
    WITH tenants AS (SELECT DISTINCT l.tenant_id FROM ledger_accounts l),
    bs AS (
        SELECT b.tenant_id, b.currency, b.side, b.amount_minor
        FROM tenants tn
        CROSS JOIN LATERAL balance_sheet_at(tn.tenant_id, p_asof, p_cursor) b
    )
    SELECT bs.tenant_id, bs.currency,
           COALESCE(SUM(bs.amount_minor::numeric) FILTER (WHERE bs.side = 'asset'), 0) AS assets_minor,
           COALESCE(SUM(bs.amount_minor::numeric) FILTER (WHERE bs.side IN ('liability','equity')), 0) AS liab_equity_minor,
           COALESCE(SUM(bs.amount_minor::numeric) FILTER (WHERE bs.side = 'asset'), 0)
             - COALESCE(SUM(bs.amount_minor::numeric) FILTER (WHERE bs.side IN ('liability','equity')), 0) AS gap_minor
    FROM bs
    GROUP BY bs.tenant_id, bs.currency
    HAVING COALESCE(SUM(bs.amount_minor::numeric) FILTER (WHERE bs.side = 'asset'), 0)
        <> COALESCE(SUM(bs.amount_minor::numeric) FILTER (WHERE bs.side IN ('liability','equity')), 0);
$$;


-- ----------------------------------------------------------------------
-- 12 - the one query an operator runs
--
-- `SELECT * FROM reconciliation WHERE breaks <> 0` is the whole interface. One row
-- per check, always the same rows -- a check that returns nothing because it was
-- never run is indistinguishable from a check that passed, and ADR-0004's TRUNCATE
-- finding is exactly that failure: "there was nothing left to disagree with --
-- silence read as assent". The pending bridge and the close disclosures are
-- deliberately NOT here: their rows are legitimate populations, not breaks. The
-- accounting-equation and cursor checks are pinned at the CURRENT report cursor and
-- since inception ('infinity'); a report issued at an older cursor is re-tested by
-- the sweep passing that cursor to recon_equation_breaks directly.
CREATE VIEW reconciliation AS
SELECT 'balance_cache'      AS check_name, COUNT(*) AS breaks FROM recon_balance_breaks
UNION ALL
SELECT 'orphan_entries',           COUNT(*) FROM recon_entry_breaks
UNION ALL
SELECT 'unbalanced_transactions',  COUNT(*) FROM recon_transaction_breaks
UNION ALL
SELECT 'cross_scope_mirror',       COUNT(*) FROM recon_scope_breaks
UNION ALL
SELECT 'journal_to_reports',       COUNT(*) FROM recon_journal_to_reports
                                   WHERE unexplained_debits <> 0 OR unexplained_credits <> 0
UNION ALL
SELECT 'checkpoint_drift',         COUNT(*) FROM recon_checkpoint_breaks
UNION ALL
SELECT 'close_typing',             COUNT(*) FROM recon_close_breaks
UNION ALL
SELECT 'cursor_forgery',           COUNT(*) FROM recon_cursor_breaks
UNION ALL
SELECT 'accounting_equation',      COUNT(*) FROM recon_equation_breaks(report_cursor(), 'infinity')
UNION ALL
SELECT 'chart_lint',               COUNT(*) FROM chart_lint WHERE severity = 'error';


-- ----------------------------------------------------------------------
-- THE ONLY TRIGGERS IN THIS SCHEMA, AND WHY EACH ONE IS HERE
--
-- The rule: a trigger states (1) the invariant it holds, (2) why nothing
-- declarative can hold it, and (3) what it does NOT protect against. ADR-0004
-- records what happened to the other nineteen.
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

-- (1) THE JOURNAL IS APPEND-ONLY -- AND SO IS THE CHART'S PRESENTATION HISTORY,
-- AND THE ATTESTATION LOG, AND THE PERIOD RECORD.
--
-- INVARIANT: no row in ledger_entries, ledger_transactions or ledger_events may
-- ever be updated or deleted. A correction is a new row. This is the claim the
-- whole project rests on -- every other guarantee is downstream of "the history
-- you are reading is the history that happened". The same claim extends to
-- chart_versions, fs_lines and chart_presentation (an issued statement is
-- reproducible only if the mapping it was presented through is still exactly
-- what it was -- a reclassification is a NEW VERSION, ADR-0012), to
-- perimeter_attestations (a record of what a third party said that can be edited
-- afterwards to match our books is not evidence of anything), and to
-- ledger_periods and ledger_period_closes (a close happened; its boundary and
-- cursor are what issued reports were computed against).
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
--
-- The exception message reaches the id through to_jsonb(), which returns NULL
-- for a missing key rather than raising: the chart tables have no `id`, and the
-- old `OLD.id` form refused the write while naming PL/pgSQL instead of
-- append-only (ADR-0012 found it).
CREATE FUNCTION refuse_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only: % on % refused. Correct it with a new row.',
        TG_TABLE_NAME, TG_OP, COALESCE(to_jsonb(OLD)->>'id', '(row)')
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
--
-- KNOWN, AND NOT CLOSABLE IN THE SCHEMA (ADR-0009): `pg_restore --disable-triggers`
-- emits DISABLE TRIGGER ALL, which beats ENABLE ALWAYS -- and the matching
-- ENABLE TRIGGER ALL afterwards restores these to ENABLE ORIGIN, not ENABLE
-- ALWAYS: one data-only restore silently and permanently downgrades every guard
-- here. The rule is: restore schema-and-data, never data-only. The schema
-- snapshot test dumps tgenabled so the downgrade at least shows.
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

CREATE TRIGGER ck_perimeter_attest__append_only BEFORE UPDATE OR DELETE ON perimeter_attestations
    FOR EACH ROW EXECUTE FUNCTION refuse_mutation();
ALTER TABLE perimeter_attestations ENABLE ALWAYS TRIGGER ck_perimeter_attest__append_only;
CREATE TRIGGER ck_perimeter_attest__no_truncate BEFORE TRUNCATE ON perimeter_attestations
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE perimeter_attestations ENABLE ALWAYS TRIGGER ck_perimeter_attest__no_truncate;

CREATE TRIGGER ck_periods__append_only BEFORE UPDATE OR DELETE ON ledger_periods
    FOR EACH ROW EXECUTE FUNCTION refuse_mutation();
ALTER TABLE ledger_periods ENABLE ALWAYS TRIGGER ck_periods__append_only;
CREATE TRIGGER ck_periods__no_truncate BEFORE TRUNCATE ON ledger_periods
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE ledger_periods ENABLE ALWAYS TRIGGER ck_periods__no_truncate;

CREATE TRIGGER ck_closes__append_only BEFORE UPDATE OR DELETE ON ledger_period_closes
    FOR EACH ROW EXECUTE FUNCTION refuse_mutation();
ALTER TABLE ledger_period_closes ENABLE ALWAYS TRIGGER ck_closes__append_only;
CREATE TRIGGER ck_closes__no_truncate BEFORE TRUNCATE ON ledger_period_closes
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_truncate();
ALTER TABLE ledger_period_closes ENABLE ALWAYS TRIGGER ck_closes__no_truncate;

-- (3) A CHART VERSION IS APPEND-ONLY AS A WHOLE, NOT ONLY ROW-BY-ROW.
--
-- INVARIANT: no fs_lines or chart_presentation row may be inserted for a chart
-- version below the current maximum. A version is a COMPLETE, FROZEN chart: an
-- issued statement names the version it was presented under, and "a version whose
-- content can change identifies nothing" (ADR-0012). refuse_mutation above blocks
-- UPDATE and DELETE, so an existing row cannot change -- but INSERT is how the chart
-- is built, and nothing stopped a late INSERT into an ALREADY-SUPERSEDED version,
-- which silently restates every report pinned to it. Building the CURRENT (max)
-- version is still open; back-filling a superseded one is not.
--
-- WHY NOTHING DECLARATIVE HOLDS IT: the rule is "NEW.chart_version >= max(version)
-- over chart_versions", and a CHECK constraint may not read another table, let
-- alone aggregate one -- max() over a sibling table is exactly what a CHECK cannot
-- reach. A composite FK freezes a referenced value; it cannot express "greatest".
-- fk_fs_lines__version / fk_presentation__version already guarantee the version
-- EXISTS, so the only writable violation is a version strictly below the max.
--
-- WHAT IT DOES NOT PROTECT AGAINST: inserting more rows into the CURRENT version
-- (that is the version still being built, deliberately open); an owner who disables
-- or drops it, the same owner-shaped hole every guard here has; and it says nothing
-- about chart_versions itself -- creating a new highest version is how you move
-- forward, and refuse_mutation is what keeps an existing version row unedited.
CREATE FUNCTION refuse_stale_chart_version() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    current_max int;
BEGIN
    SELECT max(version) INTO current_max FROM chart_versions;
    IF current_max IS NOT NULL AND NEW.chart_version < current_max THEN
        RAISE EXCEPTION
          '% names chart version %, below the current maximum % -- a superseded '
          'chart version is frozen history; append a new version instead',
          TG_TABLE_NAME, NEW.chart_version, current_max
          USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER ck_fs_lines__no_stale_version BEFORE INSERT ON fs_lines
    FOR EACH ROW EXECUTE FUNCTION refuse_stale_chart_version();
ALTER TABLE fs_lines ENABLE ALWAYS TRIGGER ck_fs_lines__no_stale_version;
CREATE TRIGGER ck_presentation__no_stale_version BEFORE INSERT ON chart_presentation
    FOR EACH ROW EXECUTE FUNCTION refuse_stale_chart_version();
ALTER TABLE chart_presentation ENABLE ALWAYS TRIGGER ck_presentation__no_stale_version;

-- WHAT DELIBERATELY HAS NO GUARD, so the absence reads as a decision:
--
--   * ledger_account_balances -- MATERIALISED state, rebuildable from the journal.
--     It is supposed to be updated; that is what it is for. recon_balance_breaks
--     is what keeps it honest.
--   * ledger_period_balances -- derived and rebuildable, same as the cache one
--     axis over; recon_checkpoint_breaks is its keeper. Unlike the cache it is
--     never legitimately UPDATEd, but the repair for a forged checkpoint is
--     recomputation, and append-only would make recomputation impossible.
--   * account_types, ledger_accounts -- the type register and the account
--     register. They are NOT history -- a type is added, an account's metadata is
--     edited -- and their dangerous edits are individually refused by keys.
--     fk_accounts__type and fk_accounts__scope do NOT freeze identity: they only
--     require the NEW (purpose, category, scope) triple to EXIST, so a posted
--     account could be reclassified from one valid type to another (measured, and
--     the reason this line no longer claims otherwise). The freeze is the pair of
--     dependent-row keys: fk_balances__account_purpose freezes the identity and
--     fk_balances__account_owner the owner, both NO ACTION against a balance row
--     that fk_entries__stripe guarantees exists for any account with history
--     (ADR-0009/0012). The chart's PRESENTATION, which used to be the admitted hole
--     here, is now append-only history above.
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
--     unbalanced transaction is fully expressible today, and
--     recon_transaction_breaks is the exception list that says whether it happened.
--     See ADR-0005.
--   * chart integrity -- foreign keys, above. Strictly better than the triggers
--     they replaced: declarative, visible in \d, and impossible to forget.

-- ----------------------------------------------------------------------
-- THE DDL PERIMETER (ADR-0009)
--
-- AN EVENT TRIGGER NEEDS A WRITTEN JUSTIFICATION TOO.
--
-- INVARIANT: posted history is not editable by DDL either. `ALTER TABLE
-- ledger_entries ALTER COLUMN account_seq TYPE bigint USING (account_seq * 10)`
-- rewrote every row with both DML triggers ENABLE ALWAYS and neither firing, and
-- destroyed gaplessness -- the property that makes "no entry is missing"
-- checkable. A child table carries three inherited CHECKs and no key, no index,
-- no FK and no trigger, is visible through the parent to every view, and both
-- doubles and removes parent-visible rows. DROP TABLE removes the lot. The same
-- argument covers every append-only table above, so the protected list is all of
-- them, not just the journal.
--
-- WHY NOTHING DECLARATIVE HOLDS IT: there is no CHECK, key or GRANT whose subject
-- is a DDL statement, and withholding the privilege means withholding ownership --
-- which is the role that runs migrations. `SELECT ... ONLY` in the views hides the
-- child from the reports and from nothing else, and excludes PARTITIONS
-- identically: measured, `FROM ONLY p` returns 0 rows on a populated partitioned
-- table. tenant_id leads every key here so partitioning stays available (ADR-0002),
-- so ONLY is a silent zero-revenue report waiting on a future migration.
--
-- WHAT IT DOES NOT PROTECT AGAINST: TRUNCATE (PostgreSQL: `event triggers are not
-- supported for TRUNCATE TABLE` -- hence the statement-level triggers above);
-- ALTER TABLE ... DROP COLUMN, which rewrites nothing; ALTER TABLE ... DISABLE
-- TRIGGER USER, which the plain table owner may still run; and itself -- the manual
-- says the event "does not occur for commands targeting event triggers themselves".
--
-- AND IT IS DECORATION IF THE MIGRATOR OWNS THE DATABASE. `public` is owned by
-- pg_database_owner, so a database-owner migrator drops this function CASCADE and
-- takes all three event triggers with it. The migrator must own the TABLES and not
-- the DATABASE. Measured both ways in spike 010. CREATE EVENT TRIGGER itself
-- needs a superuser, which is a deployment constraint M4 must answer on RDS.
CREATE FUNCTION refuse_journal_ddl() RETURNS event_trigger LANGUAGE plpgsql AS $$
DECLARE
    protected CONSTANT text[] := ARRAY['public.ledger_entries',
                                       'public.ledger_transactions',
                                       'public.ledger_events',
                                       'public.chart_versions',
                                       'public.fs_lines',
                                       'public.chart_presentation',
                                       'public.perimeter_attestations',
                                       'public.ledger_periods',
                                       'public.ledger_period_closes'];
    victim  text;
BEGIN
    IF TG_EVENT = 'table_rewrite' THEN
        victim := (SELECT format('%s.%s', n.nspname, c.relname)
                   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE c.oid = pg_event_trigger_table_rewrite_oid());
        IF victim = ANY (protected) THEN
            RAISE EXCEPTION
              '% is posted history and may not be rewritten by DDL (rewrite reason %)',
              victim, pg_event_trigger_table_rewrite_reason()
              USING ERRCODE = '23514',
                    HINT = 'Add a new column or a new table; posted rows are not editable, by DDL either.';
        END IF;

    ELSIF TG_EVENT = 'sql_drop' THEN
        -- named as TEXT, not regclass: by the time sql_drop fires the relation is
        -- gone, and 'ledger_entries'::regclass raises `relation does not exist`.
        SELECT format('%s.%s', schema_name, object_name) INTO victim
        FROM pg_event_trigger_dropped_objects()
        WHERE object_type = 'table'
          AND format('%s.%s', schema_name, object_name) = ANY (protected)
        LIMIT 1;
        IF victim IS NOT NULL THEN
            RAISE EXCEPTION '% is posted history and may not be dropped', victim
              USING ERRCODE = '23514';
        END IF;

    ELSE  -- ddl_command_end. A STATE assertion, not a command parse: it asks whether
          -- a protected table has acquired a child, so CREATE TABLE ... INHERITS and
          -- ALTER TABLE ... INHERIT are both caught without knowing either grammar.
        SELECT format('%s.%s', cn.nspname, c.relname) INTO victim
        FROM pg_inherits i
        JOIN pg_class c      ON c.oid  = i.inhrelid
        JOIN pg_namespace cn ON cn.oid = c.relnamespace
        JOIN pg_class p      ON p.oid  = i.inhparent
        JOIN pg_namespace pn ON pn.oid = p.relnamespace
        WHERE format('%s.%s', pn.nspname, p.relname) = ANY (protected)
        LIMIT 1;
        IF victim IS NOT NULL THEN
            RAISE EXCEPTION
              '% inherits from posted history: a child carries none of the parent''s keys or triggers and is visible through it to every report',
              victim USING ERRCODE = '23514';
        END IF;
    END IF;
END $$;

-- ENABLE ALWAYS on all three, for the reason the DML triggers are: an event
-- trigger left in the default ENABLE ORIGIN state does not fire under
-- session_replication_role = 'replica'. Counterfactual measured: the same rewrite
-- succeeds, account_seq 1 -> 10.
CREATE EVENT TRIGGER ck_journal__no_rewrite ON table_rewrite
    EXECUTE FUNCTION refuse_journal_ddl();
ALTER EVENT TRIGGER ck_journal__no_rewrite ENABLE ALWAYS;

CREATE EVENT TRIGGER ck_journal__no_drop ON sql_drop
    EXECUTE FUNCTION refuse_journal_ddl();
ALTER EVENT TRIGGER ck_journal__no_drop ENABLE ALWAYS;

CREATE EVENT TRIGGER ck_journal__no_inherit ON ddl_command_end
    WHEN TAG IN ('CREATE TABLE', 'ALTER TABLE')
    EXECUTE FUNCTION refuse_journal_ddl();
ALTER EVENT TRIGGER ck_journal__no_inherit ENABLE ALWAYS;

-- ----------------------------------------------------------------------
-- THE ROLES
--
-- Three, each named for what it may do, none for who logs in as it (ADR-0013).
--
--   * openledger_app   -- the WRITER. Appends to the journal, upserts the balance
--     cache (four columns of it), and reads what it serves. Its RLS policy
--     admits every tenant: the write path is the one code path reviewed line by
--     line, it carries tenant_id in every key, and BYPASSRLS -- the other way to
--     say this -- is ungrantable on RDS and Aurora entirely.
--   * openledger_read  -- REPORTING. SELECT only, scoped to one tenant per
--     session by the RLS policies below: `SET app.tenant_id = ...` then read.
--     RLS is worth most exactly where a query is easiest to get wrong -- a
--     report, an ad-hoc read, an integrator's query.
--   * openledger_recon -- the SWEEP. Reads everything, writes nothing. NOT
--     openledger_app, because that role holds UPDATE on ledger_account_balances --
--     it can write the thing recon_balance_breaks checks, and a check whose
--     subject the checker may rewrite is not a check (ADR-0004, ADR-0010).
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
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'openledger_read') THEN
        CREATE ROLE openledger_read NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'openledger_recon') THEN
        CREATE ROLE openledger_recon NOLOGIN;
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO openledger_app, openledger_read, openledger_recon;

-- The journal: read and append. COLUMN-LEVEL INSERT on the three append-only
-- tables (A1/ADR-0011): the app role may write every column EXCEPT `xact_id` and
-- `recorded_at`, so both take their DEFAULT (pg_current_xact_id(), now()) and
-- cannot be supplied. A forged xact_id decides what a pinned report can see -- a
-- leg claiming to predate its own transaction rewrites an issued statement -- and a
-- table-wide INSERT grant let the app supply it. A column-level INSERT grant that
-- omits a column REFUSES any INSERT naming it: `permission denied for table` (this
-- DOES hold for INSERT; verified). `account_seq` stays grantable -- the writer
-- issues it under the balance-row lock (ADR-0013). The reader/sweep grants below
-- are SELECT-only, so they need no such split.
GRANT SELECT, INSERT ON ledger_accounts TO openledger_app;
GRANT SELECT ON ledger_events, ledger_transactions, ledger_entries TO openledger_app;
GRANT INSERT (tenant_id, id, kind, source, idempotency_key, idempotency_hash,
              payload, effective_at)
    ON ledger_events TO openledger_app;
GRANT INSERT (tenant_id, id, event_id, kind, status, effective_at,
              resolves_id, reverses_id, external_ref, metadata)
    ON ledger_transactions TO openledger_app;
GRANT INSERT (tenant_id, id, transaction_id, account_id, direction, amount_minor,
              currency, stripe, account_seq, effective_at)
    ON ledger_entries TO openledger_app;
-- ...the materialised balance cache, which is meant to be rewritten -- but only
-- its four working columns. The owner copy is frozen by column-level grants as
-- well as by the FK: the app role can advance the numbers and cannot re-home the
-- row (ADR-0009).
GRANT SELECT, INSERT ON ledger_account_balances TO openledger_app;
GRANT UPDATE (input, output, last_seq, updated_at) ON ledger_account_balances TO openledger_app;
-- ...and the period record, which the close (an ordinary posting, ADR-0011) writes.
GRANT SELECT, INSERT ON ledger_periods, ledger_period_closes, ledger_period_balances
    TO openledger_app;
GRANT SELECT, INSERT ON perimeter_attestations TO openledger_app;

-- Reports are readable; the chart is not writable.
GRANT SELECT ON account_types, fs_lines, chart_versions, chart_presentation,
                chart_version_current TO openledger_app;
GRANT SELECT ON trial_balance, recon_pending_bridge, perimeter_drift, chart_lint
    TO openledger_app;

-- The reader: SELECT on the book, scoped by RLS.
GRANT SELECT ON ledger_accounts, ledger_events, ledger_transactions, ledger_entries,
                ledger_account_balances, ledger_periods, ledger_period_closes,
                ledger_period_balances, perimeter_attestations TO openledger_read;
GRANT SELECT ON account_types, fs_lines, chart_versions, chart_presentation,
                chart_version_current TO openledger_read;
GRANT SELECT ON trial_balance TO openledger_read;

-- The sweep: read everything, including the break lists.
GRANT SELECT ON ledger_accounts, ledger_events, ledger_transactions, ledger_entries,
                ledger_account_balances, ledger_periods, ledger_period_closes,
                ledger_period_balances, perimeter_attestations TO openledger_recon;
GRANT SELECT ON account_types, fs_lines, chart_versions, chart_presentation,
                chart_version_current TO openledger_recon;
GRANT SELECT ON trial_balance, recon_balance_breaks, recon_entry_breaks,
                recon_transaction_breaks, recon_scope_breaks,
                recon_journal_to_reports, recon_pending_bridge,
                recon_checkpoint_breaks, recon_close_breaks, recon_cursor_breaks,
                close_disclosures, perimeter_drift,
                chart_lint, reconciliation TO openledger_recon;
-- recon_equation_breaks is a function (balance_sheet_at is parameterised); EXECUTE
-- is PUBLIC by default, and it reads only through the SECURITY INVOKER statement
-- function, so the sweep runs it under its own read-everything grants.

-- ...and belt and braces on the journal, because a later `GRANT ALL ON ALL TABLES`
-- is one statement and this is the line that survives it in review.
REVOKE UPDATE, DELETE, TRUNCATE ON ledger_entries          FROM openledger_app;
REVOKE UPDATE, DELETE, TRUNCATE ON ledger_transactions     FROM openledger_app;
REVOKE        DELETE, TRUNCATE ON ledger_events            FROM openledger_app;
REVOKE        DELETE, TRUNCATE ON ledger_account_balances  FROM openledger_app;
REVOKE UPDATE, DELETE, TRUNCATE ON ledger_periods, ledger_period_closes,
                                   perimeter_attestations  FROM openledger_app;
REVOKE UPDATE, DELETE, TRUNCATE ON ledger_period_balances  FROM openledger_app;

-- PostgreSQL 15+ already removes CREATE on public from PUBLIC. Kept because it is
-- free and because a database created before 15 and upgraded does not get it.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- ----------------------------------------------------------------------
-- ROW-LEVEL SECURITY (ADR-0013)
--
-- Tenant isolation on the READ surface, structurally. Three policies per
-- tenant-keyed table: the reader is scoped to `app.tenant_id`, the writer is
-- admitted whole (see the role comment above), and the sweep is admitted whole
-- EXPLICITLY -- reconciliation aggregates across tenants, and a sweep silently
-- scoped to no tenant would report zero breaks on every book, which is this
-- project's nightmare shape: a green check that did not execute.
--
-- The tenant policy is written the one way that measured correctly: the scalar
-- subquery forces a once-per-statement InitPlan rather than a per-row
-- re-evaluation, and the TWO-argument current_setting returns NULL when the GUC
-- is unset -- `tenant_id = NULL` matches nothing, so an unscoped session FAILS
-- CLOSED.
--
-- The chart tables get no policy: they are deployment-global and carry no
-- tenant_id, which the decision log records (ADR-0012 keeps the chart global on
-- purpose).
--
-- What this does NOT cover: `FORCE ROW LEVEL SECURITY` is deliberately not set --
-- it would take COPY from the migration role and the restore path -- so the
-- OWNER is not bound by these policies, exactly as the owner is not bound by
-- grants. Same perimeter, same honesty (ADR-0009).

ALTER TABLE ledger_accounts         ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_events           ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_transactions     ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_entries          ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_account_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_periods          ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_period_closes    ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_period_balances  ENABLE ROW LEVEL SECURITY;
ALTER TABLE perimeter_attestations  ENABLE ROW LEVEL SECURITY;

CREATE POLICY rls_accounts__tenant ON ledger_accounts
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));
CREATE POLICY rls_events__tenant ON ledger_events
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));
CREATE POLICY rls_txn__tenant ON ledger_transactions
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));
CREATE POLICY rls_entries__tenant ON ledger_entries
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));
CREATE POLICY rls_balances__tenant ON ledger_account_balances
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));
CREATE POLICY rls_periods__tenant ON ledger_periods
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));
CREATE POLICY rls_closes__tenant ON ledger_period_closes
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));
CREATE POLICY rls_period_balances__tenant ON ledger_period_balances
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));
CREATE POLICY rls_perimeter_attest__tenant ON perimeter_attestations
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));

CREATE POLICY rls_accounts__writer ON ledger_accounts
    FOR ALL TO openledger_app USING (true) WITH CHECK (true);
CREATE POLICY rls_events__writer ON ledger_events
    FOR ALL TO openledger_app USING (true) WITH CHECK (true);
CREATE POLICY rls_txn__writer ON ledger_transactions
    FOR ALL TO openledger_app USING (true) WITH CHECK (true);
CREATE POLICY rls_entries__writer ON ledger_entries
    FOR ALL TO openledger_app USING (true) WITH CHECK (true);
CREATE POLICY rls_balances__writer ON ledger_account_balances
    FOR ALL TO openledger_app USING (true) WITH CHECK (true);
CREATE POLICY rls_periods__writer ON ledger_periods
    FOR ALL TO openledger_app USING (true) WITH CHECK (true);
CREATE POLICY rls_closes__writer ON ledger_period_closes
    FOR ALL TO openledger_app USING (true) WITH CHECK (true);
CREATE POLICY rls_period_balances__writer ON ledger_period_balances
    FOR ALL TO openledger_app USING (true) WITH CHECK (true);
CREATE POLICY rls_perimeter_attest__writer ON perimeter_attestations
    FOR ALL TO openledger_app USING (true) WITH CHECK (true);

CREATE POLICY rls_accounts__recon ON ledger_accounts
    FOR SELECT TO openledger_recon USING (true);
CREATE POLICY rls_events__recon ON ledger_events
    FOR SELECT TO openledger_recon USING (true);
CREATE POLICY rls_txn__recon ON ledger_transactions
    FOR SELECT TO openledger_recon USING (true);
CREATE POLICY rls_entries__recon ON ledger_entries
    FOR SELECT TO openledger_recon USING (true);
CREATE POLICY rls_balances__recon ON ledger_account_balances
    FOR SELECT TO openledger_recon USING (true);
CREATE POLICY rls_periods__recon ON ledger_periods
    FOR SELECT TO openledger_recon USING (true);
CREATE POLICY rls_closes__recon ON ledger_period_closes
    FOR SELECT TO openledger_recon USING (true);
CREATE POLICY rls_period_balances__recon ON ledger_period_balances
    FOR SELECT TO openledger_recon USING (true);
CREATE POLICY rls_perimeter_attest__recon ON perimeter_attestations
    FOR SELECT TO openledger_recon USING (true);


-- ----------------------------------------------------------------------
-- CATALOG DOCUMENTATION (ADR-0007)
--
-- COMMENT ON, so the LIVE schema documents itself: a client, an ORM introspector
-- or an AI reading `\d+`, obj_description()/col_description() or information_schema
-- gets the intent of each object from the catalog, without opening this file.
-- Distilled from the inline comments above: each is navigational -- what the object
-- is plus the one gotcha -- and cites the ADR that carries the rationale rather than
-- repeating it. The schema-snapshot test dumps pg_description, so a dropped or
-- drifted comment shows in the diff like any other schema change (ADR-0007 conv. 2).

-- ------------------------------------------------------------ tables
COMMENT ON TABLE ledger_events IS
  'The idempotency spine: every accepted operation, INCLUDING the ones that write no ledger transaction (an account opened, a limit changed, a posting rejected). Append-only. One event causes at most one transaction (uq_txn__one_per_event). Replay contract: same idempotency_key + same idempotency_hash replays the stored result, same key + different hash is rejected (ADR-0005, ADR-0013).';
COMMENT ON TABLE ledger_transactions IS
  'The unit of atomicity and the event''s bookkeeping. Append-only; status NEVER mutates -- a pending->posted change is a NEW row via resolves_id, not an UPDATE. Every transaction references the event that caused it (event_id NOT NULL). Reports read status=''posted'' only (ADR-0009, ADR-0011).';
COMMENT ON TABLE ledger_entries IS
  'The append-only journal: one leg of one movement (direction + amount_minor), the ground truth every report and drift check derives from. NO running balance (spike 009) -- ''balance now'' is ledger_account_balances and ''as of a business date'' aggregates over effective_at. For a reproducible as-of read, filter effective_at and xact_id < :cursor (ADR-0006, ADR-0009, ADR-0011).';
COMMENT ON TABLE ledger_accounts IS
  'The account register: whose money, in what currency, of what type (purpose). NOT history -- metadata is editable -- but an account''s identity (purpose/category/normal_balance) and owner are FROZEN while any balance row references them (NO ACTION on fk_balances__account_purpose / _owner) (ADR-0009, ADR-0012).';
COMMENT ON TABLE ledger_account_balances IS
  'The O(1) cached POSTED balance AND the write-side serialization point: one atomic upsert returns the new balance and the next account_seq together, so the row lock IS the serialization. balance = input - output. Physically striped -- a reader SUMs the stripe rows that exist for an account, never a range. Kept honest against the journal by recon_balance_breaks (ADR-0010, ADR-0013).';
COMMENT ON TABLE account_types IS
  'The chart of accounts -- what an account MEANS. IDENTITY only (category, normal_balance, counterparty_scope, is_perimeter, mirror_type); which financial-statement line a type reports under is PRESENTATION and lives in chart_presentation, keyed by chart_version. Seed data, shipped by schema/chart.sql, not by this migration (ADR-0012).';
COMMENT ON TABLE fs_lines IS
  'The financial-statement lines, one set PER chart_version. Reports enumerate FROM here outward (LEFT JOIN the numbers on), so an inactive line prints a zero instead of vanishing -- omission is structurally impossible. Consumers key on the code, NOT the caption (a caption is display text and Unicode-confusable) (ADR-0007, ADR-0012).';
COMMENT ON TABLE chart_versions IS
  'The chart as append-only history. A reclassification is a NEW version carrying a complete chart, never an edit -- an issued statement names the version it was presented under. "Current" is DERIVED as max(version) (see chart_version_current), never stored (ADR-0012).';
COMMENT ON TABLE chart_presentation IS
  'Which fs_line a type reports under, per chart_version. Append-only: so "which line was this presented under" is one key lookup, never a walk of overrides. category and counterparty_scope are copied from account_types under a composite FK; fs_statement/fs_side are GENERATED from category (ADR-0012).';
COMMENT ON TABLE ledger_periods IS
  'A resolved period boundary [starts_at, ends_at). HALF-OPEN, and the instants are resolved ONCE from (local date, tz) at creation and never re-resolved -- IANA rules change, so a stored (date, zone) pair is not a stable instant. A tenant''s periods may not overlap (ex_periods__no_overlap) (ADR-0011).';
COMMENT ON TABLE ledger_period_closes IS
  'One close per tenant/period/currency: names the transaction that closed the period (an ordinary posting, kind=''period_close'') and the commit cursor computed_at_xid it was computed at. Lets the income statement exclude closing entries declaratively instead of matching a free-text kind (ADR-0011).';
COMMENT ON TABLE ledger_period_balances IS
  'The effective-axis checkpoint: the at-close balance per account per period. DERIVED and exactly recomputable from ledger_entries at (effective_at < ends_at, xact_id < computed_at_xid); reconciled by recon_checkpoint_breaks. Same input/output convention as ledger_account_balances, posted entries only (ADR-0011).';
COMMENT ON TABLE perimeter_attestations IS
  'What a third party (bank, network, trustee) said an is_perimeter account''s balance was on their statement date. The only thing that can falsify is_perimeter''s "must reconcile against an external balance" claim, since a CHECK cannot. Compared on the EFFECTIVE axis by perimeter_drift; append-only (ADR-0012).';

-- ------------------------------------------------------------ columns: ledger_events
COMMENT ON COLUMN ledger_events.idempotency_key IS
  'The retry key. Same key + same idempotency_hash replays the stored result; same key + DIFFERENT hash is rejected -- silently replaying the wrong result is worse than failing (ADR-0013).';
COMMENT ON COLUMN ledger_events.idempotency_hash IS
  'sha256 of the canonical request body. Distinguishes a genuine replay (same body) from a same-key/different-body conflict (ADR-0013).';
COMMENT ON COLUMN ledger_events.effective_at IS
  'The business-date axis: the source''s clock. Contrast recorded_at, the wall clock (ADR-0006).';
COMMENT ON COLUMN ledger_events.recorded_at IS
  'The wall-clock axis: when we recorded the event. Contrast effective_at, the business date (ADR-0006).';
COMMENT ON COLUMN ledger_events.xact_id IS
  'The commit-ordering key (ADR-0011) for an operation that writes no transaction -- where it records its position on the commit axis.';

-- ------------------------------------------------------------ columns: ledger_transactions
COMMENT ON COLUMN ledger_transactions.event_id IS
  'The event that caused this transaction. NOT NULL: every transaction references its event, and one event causes at most one transaction (ADR-0013).';
COMMENT ON COLUMN ledger_transactions.status IS
  'pending or posted, and it NEVER mutates. Reports read status=''posted'' only; a pending->posted transition is a NEW row (resolves_id), not an update (ADR-0009, ADR-0011).';
COMMENT ON COLUMN ledger_transactions.effective_at IS
  'The business date, copied from the SOURCE''s clock (a clearing''s network date), never now(). Finite (no +/-infinity). The axis every as-of report filters on (ADR-0006).';
COMMENT ON COLUMN ledger_transactions.recorded_at IS
  'The wall clock: when this row was written. Contrast effective_at, the business date (ADR-0006).';
COMMENT ON COLUMN ledger_transactions.xact_id IS
  'The commit-ordering key the as-of cursor pins to. Filter xact_id < :cursor for a reproducible as-of read: a later arrival carries its own, HIGHER id and cannot rewrite an already-issued report (ADR-0011).';

-- ------------------------------------------------------------ columns: ledger_entries
COMMENT ON COLUMN ledger_entries.direction IS
  'debit or credit -- direction carries the SIGN of the leg; amount_minor never does.';
COMMENT ON COLUMN ledger_entries.amount_minor IS
  'The leg amount in minor units, always POSITIVE (> 0). The sign lives in direction. Roll up as SUM(CASE WHEN direction=''debit'' THEN amount ELSE -amount END) for a debit-positive value (ADR-0007 rule 15).';
COMMENT ON COLUMN ledger_entries.currency IS
  'ISO 4217, uppercase. Part of a composite FK to the account, so an entry cannot carry a currency its account does not hold.';
COMMENT ON COLUMN ledger_entries.stripe IS
  'Which of the account''s physical balance stripes issued this entry''s account_seq. A reader SUMs the stripes that exist; unstriped accounts write stripe 0 (ADR-0013).';
COMMENT ON COLUMN ledger_entries.account_seq IS
  'Monotonic, GAPLESS per account per stripe -- issued by the writer under the balance-row lock, not a Postgres sequence (an aborted nextval leaves a hole). The key a drift check walks and every as-of reconstruction depends on; gaplessness is asserted afterwards by recon_balance_breaks (ADR-0004, ADR-0013).';
COMMENT ON COLUMN ledger_entries.effective_at IS
  'The business date, DENORMALISED from the transaction and held honest by a composite FK (fk_entries__txn_effective) so it cannot disagree. The basis of ADR-0006 and every business-date report; the effective-axis aggregate is a single-table index scan on ix_entries__effective.';
COMMENT ON COLUMN ledger_entries.recorded_at IS
  'The wall clock. NOT the axis as-of questions are asked on -- that is effective_at (ADR-0006).';
COMMENT ON COLUMN ledger_entries.xact_id IS
  'The entry''s OWN commit-ordering key (ADR-0011). Filter xact_id < :cursor for a reproducible as-of read. Deliberately NOT tied to the transaction''s xact_id under an FK: a leg appended to an already-committed transaction carries a HIGHER id, so a report pinned before the append cannot see it.';

-- ------------------------------------------------------------ columns: ledger_accounts
COMMENT ON COLUMN ledger_accounts.purpose IS
  'The account''s type: a FK to account_types.code. Carried into composite keys that freeze identity while balance rows exist.';
COMMENT ON COLUMN ledger_accounts.category IS
  'Copied from the account''s type and held honest by fk_accounts__type, so a report need not join the chart to know a balance''s sign (ADR-0012).';
COMMENT ON COLUMN ledger_accounts.normal_balance IS
  'Copied from the type (fk_accounts__type). NOT derivable from category: a loss allowance is an asset with a CREDIT normal balance (ADR-0007 rule 10).';
COMMENT ON COLUMN ledger_accounts.counterparty_scope IS
  'Copied from the type (fk_accounts__scope). Drives the balance sheet''s gross routing; a CHECK may not read another table, so the copy is held honest by a composite FK (ADR-0012).';
COMMENT ON COLUMN ledger_accounts.owner_id_key IS
  'A NULL-free copy of owner_id (coalesce to '''') so the owner-freeze composite key (MATCH SIMPLE) is not silently satisfied by a NULL on house accounts (ADR-0009).';
COMMENT ON COLUMN ledger_accounts.stripe_count IS
  'How many stripes the writer should spread this account''s balance across. A HINT, not an invariant: a reader SUMs the stripe rows that exist, so lowering it strands nothing and raising it needs no backfill (ADR-0013).';

-- ------------------------------------------------------------ columns: ledger_account_balances
COMMENT ON COLUMN ledger_account_balances.stripe IS
  'Which physical stripe of one account''s balance this row is -- a partition, not an account. Each stripe is a separate lock; a reader SUMs the stripes that exist. Unstriped accounts hold row 0 (ADR-0013).';
COMMENT ON COLUMN ledger_account_balances.input IS
  'Accumulates DEBIT legs of POSTED transactions. balance = input - output (the debit-positive value of ADR-0007 rule 15); a credit-normal account reads negative and the reader applies the presentation flip (ADR-0010).';
COMMENT ON COLUMN ledger_account_balances.output IS
  'Accumulates CREDIT legs of POSTED transactions. balance = input - output. Kept separate from input so the upsert stays commutative and gross turnover is free (ADR-0010).';
COMMENT ON COLUMN ledger_account_balances.last_seq IS
  'The account_seq counter for this stripe. Advances on EVERY entry, PENDING included (it issues the seq), whereas input/output move on posted entries only (ADR-0010).';
COMMENT ON COLUMN ledger_account_balances.owner_type IS
  'A frozen copy of the account''s owner, held honest by fk_balances__account_owner (NO ACTION), so an account with any balance row cannot have its owner nulled or reassigned (ADR-0009).';
COMMENT ON COLUMN ledger_account_balances.owner_id_key IS
  'A frozen copy of the account''s owner_id_key; with owner_type, the owner freeze (fk_balances__account_owner) (ADR-0009).';
COMMENT ON COLUMN ledger_account_balances.purpose IS
  'A frozen copy of the account''s identity; with category/normal_balance, held by fk_balances__account_purpose (NO ACTION) so a posted account cannot be reclassified (ADR-0009, ADR-0012).';
COMMENT ON COLUMN ledger_account_balances.category IS
  'Part of the frozen identity copy (fk_balances__account_purpose) (ADR-0012).';
COMMENT ON COLUMN ledger_account_balances.normal_balance IS
  'Part of the frozen identity copy (fk_balances__account_purpose) (ADR-0012).';

-- ------------------------------------------------------------ columns: account_types
COMMENT ON COLUMN account_types.normal_balance IS
  'Which direction increases this type. NOT derivable from category: a loss allowance is an asset with a CREDIT normal balance -- storing both is the only correct option (ADR-0007 rule 10).';
COMMENT ON COLUMN account_types.counterparty_scope IS
  'none / shared / per_shard. Can a set of these accounts be summed for reporting? Only if all face ONE counterparty (IAS 32.42). Consumed by the balance sheet''s gross routing and by chart_lint (ADR-0012).';
COMMENT ON COLUMN account_types.is_perimeter IS
  'This type mirrors exactly one EXTERNAL balance and must reconcile against it. Consumed by perimeter_attestations, perimeter_drift and chart_lint -- a claim about the world, falsifiable only by an attestation (ADR-0012).';
COMMENT ON COLUMN account_types.mirror_type IS
  'The account type holding the OTHER side of the same cross-scope obligation (e.g. due_from_treasury <-> due_to_tenants). Declared on one side, arbitrarily the asset side; read by recon_scope_breaks to eliminate the pair to zero (ADR-0010, ADR-0012).';

-- ------------------------------------------------------------ columns: fs_lines / chart
COMMENT ON COLUMN fs_lines.chart_version IS
  'The chart version this line belongs to. A line''s identity is (chart_version, code); the same caption may recur across versions -- that is what makes them comparable (ADR-0012).';
COMMENT ON COLUMN fs_lines.code IS
  'The STABLE identity of the line -- what consumers key on and what the balance sheet emits. The caption is display text and is Unicode-confusable, so it is never keyed on (ADR-0007).';
COMMENT ON COLUMN fs_lines.caption IS
  'Display text a reader sees, NOT an identity: never key on it (Unicode confusables pass every CHECK and print identically). Whitespace/case-normalised as defence in depth against typos only (ADR-0007).';
COMMENT ON COLUMN fs_lines.statement IS
  'balance_sheet or income_statement. Carried into a composite FK with side so a type cannot report under a line that contradicts its category (ADR-0012).';
COMMENT ON COLUMN fs_lines.side IS
  'Which side of the statement the line sits on -- declared, not inferred. THREE-valued on the balance sheet (asset/liability/equity), two-valued on the income statement (credit/debit) (ADR-0012).';
COMMENT ON COLUMN chart_versions.note IS
  'The IAS 1.41 REASON for a reclassification. NOT NULL and non-empty -- the half of the disclosure a schema can hold; the amounts are derivable by presenting one period under both versions (ADR-0012).';
COMMENT ON COLUMN chart_presentation.chart_version IS
  'The chart version this mapping belongs to. A reclassification is a new version, so which line a type presented under is one key lookup (ADR-0012).';
COMMENT ON COLUMN chart_presentation.category IS
  'Copied from account_types under a composite FK (fk_presentation__type), because fs_statement/fs_side are GENERATED from it and a generated column may not read another table (ADR-0012).';
COMMENT ON COLUMN chart_presentation.counterparty_scope IS
  'Copied from account_types under fk_presentation__type; determines whether a contra line is required (per_shard) (ADR-0012).';
COMMENT ON COLUMN chart_presentation.fs_line IS
  'The financial-statement line this type reports under, in this chart version. Held to the type''s statement and side by a composite FK (ADR-0012).';
COMMENT ON COLUMN chart_presentation.fs_line_contra IS
  'The line an OPPOSITE-SIGN position of this type presents under (a payable gone into a receivable). Required for per_shard, allowed for any balance-sheet type, meaningless on the income statement (IAS 32.42, ADR-0012).';
COMMENT ON COLUMN chart_presentation.fs_statement IS
  'GENERATED from category (revenue/expense -> income_statement, else balance_sheet), so it cannot disagree with the category; carried into the fs_line FK (ADR-0012).';
COMMENT ON COLUMN chart_presentation.fs_side IS
  'GENERATED from category ONLY (not normal_balance) and THREE-valued on the balance sheet. Derived so a contra-revenue type cannot be forced onto a cost line; carried into the fs_line FK (ADR-0012).';

-- ------------------------------------------------------------ columns: periods
COMMENT ON COLUMN ledger_period_closes.transaction_id IS
  'The closing transaction, posted through the ordinary write primitive; this row only NAMES it. Typed to kind=''period_close'' and to a date inside the period by composite FKs (ADR-0011).';
COMMENT ON COLUMN ledger_period_closes.computed_at_xid IS
  'The commit cursor the checkpoint was computed at: everything below it had committed, nothing below it can ever appear. A backdated arrival lands ABOVE it and is a tail term (close_disclosures enumerates them), never an invalidation (ADR-0011).';
COMMENT ON COLUMN ledger_period_closes.closing_kind IS
  'A generated constant (''period_close'') carried into fk_closes__txn_kind, turning "the named transaction is a close" into a key rather than a free-text match (ADR-0011).';
COMMENT ON COLUMN perimeter_attestations.as_of IS
  'The COUNTERPARTY''s statement date -- a business date, so the comparison is on the effective axis (a bank statement is dated by the bank''s book) (ADR-0006, ADR-0012).';
COMMENT ON COLUMN perimeter_attestations.external_balance_minor IS
  'What the third party said the balance was, in OUR debit-positive sign convention, so the comparison needs no normal_balance flip (ADR-0007 rule 15).';
COMMENT ON COLUMN perimeter_attestations.as_of_end IS
  'GENERATED exclusive end instant of the as_of business day in tz, resolved once at write time so perimeter_drift compares a fixed instant rather than a session-resolved bare date (ADR-0011).';

-- ------------------------------------------------------------ report surfaces (views + functions)
COMMENT ON VIEW trial_balance IS
  'Per-account gross arithmetic at "now" and the reconciliation substrate half the recon views read. security_invoker, so RLS scopes it. Publishes both balance_minor (normal-balance-signed, for showing one account) and balance_debit_positive (roll up with THIS one). Enumerates INWARD from entries -- not the completeness surface (ADR-0011).';
COMMENT ON VIEW chart_version_current IS
  'The current chart version, DERIVED as max(version) -- the default the statement functions read when no version is passed (ADR-0012).';
COMMENT ON FUNCTION report_cursor() IS
  'The commit cursor a report pins itself to: pg_snapshot_xmin of the current snapshot. Everything strictly below it has committed or aborted and can never grow; a row invisible now carries a HIGHER id. Pass it as :cursor to the statement functions (ADR-0011).';
COMMENT ON FUNCTION trial_balance_at(text, timestamptz, timestamptz, xid8) IS
  'The trial balance pinned: per-account debits/credits/debit-positive balance for one tenant over an effective range [p_from, p_to) at a commit cursor (xact_id < p_cursor). Sums as numeric to survive a huge legal row (ADR-0011, ADR-0013).';
COMMENT ON FUNCTION income_statement_for(text, timestamptz, timestamptz, xid8, int) IS
  'The income statement over an effective range [p_from, p_to), at a commit cursor, under a chart version (default: current). Enumerates FROM the chart; RAISES if the version does not exist or does not present every posted account type in-window; excludes the period''s closing transaction. Returns its pinned cursor (ADR-0011).';
COMMENT ON FUNCTION balance_sheet_at(text, timestamptz, xid8, int) IS
  'The balance sheet as at an instant p_asof (effective_at < p_asof, half-open), at a commit cursor, under a chart version (default: current). Enumerates FROM the chart; positions are per-account then routed to a contra line on sign-swing; synthesises the un-closed-earnings plug; RAISES on an unpresented type. Returns its pinned cursor (ADR-0011, ADR-0012).';
COMMENT ON FUNCTION recon_equation_breaks(xid8, timestamptz) IS
  'The accounting equation on the FACE of the balance sheet: runs balance_sheet_at per tenant at (p_cursor, p_asof) and returns a row only where assets <> liabilities + equity + earnings, per currency. The highest-leverage check -- no journal-level test can falsify presentation (ADR-0011).';

COMMENT ON VIEW recon_balance_breaks IS
  'The cached balance against the recomputed sum over the journal, per account/currency/stripe -- a nonzero row is drift the cache introduced. Six break classes (balance_drift, seq_behind/ahead/gap, no_cache_row, no_entries); input/output vs POSTED entries, last_seq vs ALL entries (ADR-0010).';
COMMENT ON VIEW recon_entry_breaks IS
  'Journal entries that fail one of the three joins every report makes -- no_transaction, no_account or no_account_type, one row each. Empty wherever the foreign keys are enforced; a pending entry is not an orphan (ADR-0009).';
COMMENT ON VIEW recon_transaction_breaks IS
  'Transactions whose entries do not balance per currency (debits_ne_credits), plus single-leg and entryless ones. The exception list for the balance invariant the writer''s type will eventually make unrepresentable (ADR-0005, ADR-0007).';
COMMENT ON VIEW recon_scope_breaks IS
  'The two sides of a cross-scope obligation that fail to eliminate: for a mirrored account-type pair, the debit-positive sum over both types must be zero, per currency and per counterparty. The one check that aggregates across tenants (ADR-0010).';
COMMENT ON VIEW recon_journal_to_reports IS
  'A reconciliation statement (one row per tenant/currency, always footing): journal debits minus the named reconciling items -- pending, superseded, out_of_window, orphan -- against what trial_balance actually shows; the unexplained remainder must be zero (ADR-0010).';
COMMENT ON VIEW recon_pending_bridge IS
  'The available balance derived, not stored: the posted cache plus the live pending population (retired holds excluded), per account. A reconciling population, not a break list (ADR-0010).';
COMMENT ON VIEW recon_checkpoint_breaks IS
  'The stored period checkpoint against ledger_entries recomputed at the checkpoint''s own cursor, per account -- missing, spurious or value-drifted rows. Compares values, so a dormant 0/0 row is not a break (ADR-0011).';
COMMENT ON VIEW close_disclosures IS
  'Entries legally backdated past a close (effective_at before ends_at, xact_id at/after computed_at_xid) -- not a break: the analogue of IAS 1.41''s reclassification disclosure, so a row here means an already-issued report no longer matches a re-run at "now" (ADR-0011).';
COMMENT ON VIEW perimeter_drift IS
  'What a third party attested against what our book says on the same business date (effective axis, bounded by the stored as_of_end instant), per is_perimeter account -- the drift is the difference. Fed into chart_lint (ADR-0012).';
COMMENT ON VIEW chart_lint IS
  'Chart claims the account register contradicts: a type no version presents, a per_shard type in a house account, a same-side mirror pair, an unattested perimeter account, live drift, and more -- ten shape rules a CHECK or key cannot reach. Empty is passing; reconciliation counts the error-severity rows (ADR-0012).';
COMMENT ON VIEW recon_close_breaks IS
  'Closes whose computed_at_xid precedes their own closing transaction''s xact_id -- a checkpoint computed at a cursor that could not have seen the close it records (ADR-0011).';
COMMENT ON VIEW recon_cursor_breaks IS
  'Entries whose commit key is impossible -- an xact_id above the current snapshot horizon, or below its own transaction''s (a leg claiming to predate its transaction). Where a forged xact_id shows, since it silences no other check (ADR-0011).';
COMMENT ON VIEW reconciliation IS
  'The daily sweep operators run (openledger reconcile, roadmap M2): one row per check -- cache-vs-journal, orphan entries, imbalance, cross-scope, journal-vs-reports, checkpoint, close typing, cursor forgery, the accounting equation, chart lint -- with its break count, all zero on a healthy book. SELECT * FROM reconciliation WHERE breaks <> 0 is the whole interface; the pending bridge and close disclosures are excluded as legitimate populations (ADR-0004, ADR-0010).';
