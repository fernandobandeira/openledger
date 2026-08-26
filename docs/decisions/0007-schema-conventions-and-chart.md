# 0007 — Conventions that make a silent mistake loud, and a chart of accounts that is data

**Status:** accepted
**Evidence:** [spike 001](../../spikes/001-formance/README.md) for the conventions,
[spike 004](../../spikes/004-chart-of-accounts/README.md) for the chart.

## The decision

### Conventions

| | |
| --- | --- |
| **1. Name every object `<prefix>_<table>__<what>`** | Prefix one of `pk_ uq_ ix_ ck_ fk_`; the double underscore survives table names that already contain underscores. `<what>` is a **rule name**, not a column list — `ix_entries__balance_lookup`, `uq_txn__one_reversal`, `ix_entries__asof_recorded` — because a rule name does not go stale when a column joins the index. `<table>` is usually abbreviated (`entries`, `txn`, `balances`), since an index name is capped at 63 characters. |
| **2. A schema snapshot test in CI** | Apply the migrations to an empty database, dump every index, constraint, trigger, and — separately — every `NOT VALID` constraint; diff against a committed snapshot. **This is the highest-leverage item here, and it is not built**: what exists is twenty-one lines containing one `SELECT` that emits a string, with no committed snapshot, no comparison and no failure path — it runs green against the shipped schema and a mutated one alike. |
| **3. Keep foreign keys** | Integrators will do things we never anticipated, and a constraint is the only part of a design that survives an unanticipated caller. |
| **4. Keep Postgres enums** | The historical argument for `text` + `CHECK` was that `ALTER TYPE ... ADD VALUE` could not run inside a transaction block. **Verified on PG18: that restriction was lifted in PG12** — the new value simply cannot be *used* until after commit. So we keep enums, and `sqlx` refuses an unknown value at decode rather than accepting it silently ([0001](./0001-rust-and-postgres.md), which also records the drift this leaves open). |
| **5. `NOT VALID` is a two-step, never a one-step** | The zero-downtime pattern (`ADD CONSTRAINT ... NOT VALID` → `VALIDATE CONSTRAINT` → `SET NOT NULL` → `DROP CONSTRAINT`) is worth adopting, but a `NOT VALID` constraint that never gets validated is a lie in the schema — which is why the snapshot test lists them separately. One surviving past the migration that introduced it is a review failure. |
| **6. Covering indexes only on append-only tables** | `INCLUDE` gives a true index-only scan only when the visibility-map bit is set, which needs a vacuum and holds reliably only on tables that are never updated. Measured: our balance-lookup index reaches zero heap fetches on settled data at +16% index size when freshly built (11 MB against 9736 kB) — but on a **freshly inserted row, which is exactly what the hot path reads**, the bit isn't set and it still costs a heap fetch. And +16% is the *build-time* cost: after a 200,000-row append-only load the live index is **20 MB against 11 MB rebuilt**, because its `DESC` ordering puts every insert at the leftmost page and gives up the rightmost-split fast path. **So `INCLUDE` here is justified by reporting, not by the hot path.** |
| **7. Split a table when its write frequency differs from its parent** | Balance changes on every posting; account identity and metadata almost never. Folding balance into `ledger_accounts` would mean every posting updating a wide row carrying jsonb and several indexes. A narrow balance row is cheap to lock and stays in cache — and that row's lock *is* the system's serialization point ([0002](./0002-scaling.md)). "Cheap to lock" is the most performance-critical property in the schema. |
| **8. Never store JSON in a text column, and `timestamptz` everywhere** | Our `jsonb` stays `jsonb`. |

### The chart of accounts

| | |
| --- | --- |
| **9. The chart of accounts is data, not code** | Account *types* live in a table, each declaring a category, a normal balance, and the financial-statement line it rolls up to; `ledger_accounts.purpose` is a foreign key to it. Purposes like `platform_rev_share_payable` are business-specific — a card program funded by a warehouse line has them, a marketplace wallet does not — so the engine ships the *capability* and the card chart is seed data. |
| **10. `normal_balance` is stored, never derived from `category`** | A loss allowance is an **asset** with a **credit** normal balance. Any design that computes one from the other is wrong the first time someone books one. |
| **11. Completeness is a separate invariant from balance** | The accounting equation does not prove a report enumerated everything, so reports enumerate **from the chart outward**: [`balance_sheet`](../../schema/schema.sql) starts `FROM fs_lines` and left-joins the numbers on, so a line with no activity appears as a zero instead of vanishing. Every account type carries a `NOT NULL` financial-statement line so there is always something to enumerate. |
| **12. The equation is evaluated per currency** | And a currency-blind one is vacuous — below. |
| **13. Where one logical account is split across rows, summing them is netting, and netting has rules** | Each account type declares a `counterparty_scope`; where the split key *is* the counterparty, opposite-sign members must be presented gross rather than netted. |

## Why the conventions

Reading Formance's 54 migrations showed that most of their schema problems are not design mistakes.
They are **process** mistakes a convention would have caught:

- A migration dropped a column; Postgres silently dropped the two indexes built on it. Their
  point-in-time balance read has been a scan-and-sort ever since, unnoticed for sixteen migrations. A
  snapshot diff turns that from a latent performance bug into a failed build.
- A migration named `accounts-metadata-index` creates an index on the `accounts` table, not
  `accounts_metadata`. The real gap — a sequential scan on every metadata write, forever — was hidden
  by the name.
- Two composite primary keys are named in a way that reads like single-column indexes.
- At the commit [spike 009](../../spikes/009-how-other-ledgers-enforce/README.md) read, Formance's
  census is **four `CHECK` constraints, all four unvalidated, and zero foreign keys** — an earlier
  read of five-of-nine was true at a different commit.
- Their canonical record of money movement is a `varchar` holding pretty-printed JSON. It cannot be
  queried, indexed or validated, so four additional jsonb columns and three GIN indexes exist solely
  to make it queryable. They made the same mistake twice.
- They use `timestamp without time zone` throughout and hold UTC by convention — and have a migration
  literally named `fix-invalid-date-format`. **A convention is not a constraint.**

## Why the chart

**A dropped balanced sub-book is invisible; a dropped account is not.** This is the finding the whole
layer exists for. Omit a single account and it drops out of exactly *one* side of the equation —
dropping `interchange_revenue` from the golden trace leaves the two sides differing by exactly that
account's balance, which the equation catches and quantifies. What it cannot catch is omitting a whole
**balanced** sub-book: an entire tenant, an entire currency, an entire entity, any date range
containing only whole transactions. Three tenants holding 10.00 of interchange each, and a report that
misses one shows **20.00 against a true 30.00**, with every check reading `BALANCED`, because what was
dropped was itself balanced. So the risk is not a stray missing account; it is a **dropped sub-book**
— an RLS predicate, a tenant filter, a `date_trunc` boundary, a timezone. The reference product
already says it: *"the bug is never in storage, it's at every boundary that turns an instant into a
bucket."*

**A currency-blind equation is vacuous the moment a second currency exists.** `A = L + E + (R − X)`
follows from total debits equalling total credits, which holds for **any** union of
per-currency-balanced transactions *regardless of denomination* — so a currency-blind check returns
`true` for arbitrary currency mixing and can never detect it. Measured before the fix: 100.00 USD plus
100.00 EUR reported *"assets 200.00, balanced."*

**Netting is a presentation rule with a standard behind it.** IAS 32.42 and ASC 210-20-45-1 permit
offsetting only for amounts due to and from the **same party**, which is why the scope has to be
declared on the type rather than inferred from the split. *Both citations are **unverified** under
this tree's sourcing rule: the IFRS and FASB texts are not freely fetchable, so there is no URL to put
next to them. An earlier draft cited this rule as IAS 1.32 in four files and IAS 32.42 in three; 1.32
is the general prohibition on offsetting, and 32.42 is the one that carries the
legally-enforceable-right-of-set-off test, so 32.42 is what the tree now says throughout.*

**Prior art, checked rather than assumed.** Xero's published [OpenAPI
spec](https://raw.githubusercontent.com/XeroAPI/Xero-OpenAPI/master/xero_accounting.yaml) carries
**three** separate fields on one account, the same split as ours:

```yaml
- Code: "610"
  Name: Accounts Receivable
  Type: CURRENT                   # business meaning
  SystemAccount: DEBTORS          # reserved role
  ReportingCode: ASS.CUR.REC.TRA  # financial-statement line
```

Their `Class` (the five-way category `ASSET|EQUITY|EXPENSE|LIABILITY|REVENUE`) is marked `readOnly`,
derived from `Type` and never set directly — our arrangement too. The instructive difference: their
reporting axis is **hierarchical** (`ASS.CUR.REC.TRA` — asset, current, receivable, trade) where our
`fs_line` is flat. Flat is enough for a balance sheet and an income statement; it is not enough for a
nested statement with subtotals. *(A broader survey of QuickBooks, NetSuite and SAP returned nothing
usable — those docs are unreachable as fetchable content. Absence of evidence recorded as such, not
converted into a claim.)*

## Alternatives

| | Why not |
| --- | --- |
| **No foreign keys** (Formance has essentially none — nullable back-pointers, no referential integrity) | Defensible for an engine chasing unconstrained write throughput; wrong on this project's stated correctness priority. |
| **`text` + `CHECK` instead of enums** | Its one advantage was lifted in PG12. |
| **Column lists in index names** | Go stale the moment the index gains a column. |
| **A covering index on the hot path** | The visibility-map bit is unset on the row it would serve. |
| **Derive `category` from `purpose` in code** | Ships the chart as a `match` in the binary, making every deployment's chart a code change and putting a contra account permanently out of reach. Rejected by point 10. |
| **Trust the accounting equation as the completeness check** | It already exists and costs nothing, which is exactly why it was tempting. It cannot see a balanced omission, and balanced omissions are the ones a filter bug produces. |
| **A hierarchical reporting axis, like Xero's** | Strictly more expressive, and it needs a tree where a flat code needs a column. Deferred, not rejected. |
| **Enumerate reports inward from `ledger_entries`** | Simpler, and what `trial_balance` still does. An account with no entries is then simply absent, which is the failure this ADR names. |

## What it costs

| | |
| --- | --- |
| **Foreign keys cost something real on the bulk-insert path** | A run on the shipped schema (seven foreign keys in the tables under test, same CHECKs and indexes, 50k rows, three trials) gave **3002/3176/3672 ms with them against 1257/1067/793 ms without**. Read it as a direction, not a benchmark — the harness is not in the repo. The cost is on bulk load, and we accept it. |
| **An enum value cannot be removed** | And reordering requires recreating the type. |
| **CI needs the snapshot-diff step before M1 lands** | It is worth more than any test we would write by hand, and until it exists convention 2 is aspiration. |
| **Rule names are not greppable by column** | *"Does this table have an index on X"* still means reading the definitions, which is the price of names that don't go stale. |
| **PostgreSQL 18 adds ~90 catalog rows nobody wrote** | Verified against [`schema/schema.sql`](../../schema/schema.sql): **every index and every named constraint matches `^(pk|uq|ix|ck|fk)_`**, and no object carries a PostgreSQL default name. But PG18 materialises `NOT NULL` as a real catalog constraint, so `pg_constraint` lists ~90 server-generated rows named `<table>_<column>_not_null`. They cannot be supplied in `CREATE TABLE`, and nothing references them. |
| **Reclassification is blocked while accounts exist — in one direction only** | `fk_accounts__type` refuses a change to a type's `category` or `normal_balance` while accounts reference it. It does **not** refuse a move of `fs_line` to another line of the same statement and side: verified, `fbo_cash` moved from `restricted_cash` to `cash` and 440.00 of customer float silently became unrestricted liquidity on an already-issued balance sheet — the exact harm `schema/chart.sql` cites Reg S-X 5-02.1 and ASC 230-10-45-4 for. Open. The blocked direction was worth blocking: changing a type's category silently rewrote the income statement, revenue 9.00 → 0.00 on the golden trace with every check green, because reports join through the type while the guard only fired on the account. |
| **`trial_balance` still enumerates inward** | And is the wrong thing to build a completeness claim on. The accounting-equation view enumerates `FROM ledger_accounts` with the entry aggregate left-joined on, like `balance_sheet`; `trial_balance` has not been rebuilt that way. |
| **A mis-typed reporting axis raises** | Rather than returning an empty, balanced report — the right failure, but at read time rather than an unrepresentable state. |
| **The vocabulary is control account + subsidiary ledger** | And our version is stronger than the classical one: the control balance is *defined as* the sum rather than separately maintained, so it cannot drift. That is why completeness, not reconciliation, is the risk that needed engineering. |

## Not decided here

| | |
| --- | --- |
| **Posting rules** | How a business event becomes entries. Adyen proves its templates balance at design time; we have not designed ours. |
| **A reserved `unallocated` instance** | Per type, for accruals and corrections with no tenant. Xero's `SystemAccount` enum (`RETAINEDEARNINGS`, `ROUNDING`, `UNREALISEDCURRENCYGAIN`, …) is the shape: a reserved role, distinct from the type. |
| **A hierarchical reporting axis** | `fs_line` is flat; nested subtotals need a tree. |
| **Multi-entity elimination in a report** | The theorem gives a balanced *consolidated* set, not a balanced *per-entity* one. Intercompany due-from/due-to accounts are the primitive and the golden trace runs on them — the facility draw, the network settlement and the ACH collection are all cross-scope, and the two sides are asserted to eliminate exactly at every step. Nothing *nets* them in a report, so a consolidated balance sheet presents intercompany balances gross. |
| **There is no period close and no period lock** | So a backdated entry can still restate a reported period — and period close is also what bounds the effective-axis aggregate ([0006](./0006-time-and-as-of.md)). |
| **Several accounting-practice claims could not be verified** against primary sources with the tooling available | They are omitted rather than softened. |
