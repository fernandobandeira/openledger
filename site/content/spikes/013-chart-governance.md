# Spike 013 — Who owns the chart of accounts, and what happens when it changes?

**Status:** closed. Feeds [ADR-0012](/decisions/0012-chart-governance). Closes six of the
decision log's then-open design holes and amends
[0007](/decisions/0007-schema-conventions-and-chart).

**Question.** `account_types.fs_line` decides which line of the balance sheet an account reports
under, and one `UPDATE` changes it. Issued statements move. Nothing records that they moved.
Meanwhile two columns on the same table — `counterparty_scope` and `is_perimeter` — are read by no
view and no function, so a wrong value in either is undetectable by anything. What has to change so
that a reclassification is a *recorded event* rather than an edit, and so that those two columns
are load-bearing?

**Ran** 2026-08-27 · PostgreSQL 18.6 · scratch database `spike_wsd`, recreated from
`migrations/00001_baseline.sql` on every run. Every number below is reproduced by
`spikes/015-chart-governance/run.sh`. Third-party source read from a clone at a pinned commit;
the accounting standard read from the EU's endorsement of IFRS, sourced as described at the end.
> **Note on reproducing this spike.** Its runs predate the 2026-08-27 integration that folded the
> proposed DDL of ADRs 0009–0013 into `migrations/00001_baseline.sql`
> ([0003](/decisions/0003-migrations)'s editable-until-v0.1 exception), so the overlay files in this
> spike's directory target the *pre-merge* baseline — recover it from git history to re-run them
> verbatim. The merged baseline was re-verified end to end at integration time.

---

## The answer

**Split the account type in two along the line that separates what may never change from what must.**

Category, normal balance, counterparty scope and perimeter status are the type's **identity**.
They may not change under posted history — `fk_accounts__type` already refuses two of them — and
they stay on `account_types`, unversioned.

Which financial-statement line the type rolls up to is its **presentation**. IAS 1.41 *requires*
that to change, and requires the comparatives to move with it. It leaves `account_types` entirely
for `chart_presentation (chart_version, type_code)`, which is append-only. So a reclassification is
a new chart version, and the old one stays readable forever.

Three things follow that were not obvious before the split:

| | |
| --- | --- |
| **The balance-sheet side has to become three-valued** | `asset`, `liability`, `equity`. It was two, and that is why 1,000.00 of paid-in capital could be presented under "Accounts payable and accrued" with every check green. |
| **A type whose split key is the counterparty needs a *second* line** | The one its opposite-sign position presents under. Without it a tenant who *owes* the operator has nowhere to go, and the report nets it against a tenant the operator owes — 425.00 against 425.00 printing zero. |
| **And the gross presentation needs a grain the account register has to supply** | A `per_shard` type held in a house account has already netted both counterparties **at write time**. No view recovers that. The report fix and the account constraint ship together or neither works. |

**The chart stays global.** `tenant_id` here is a sub-book of one reporting entity, not a reporting
entity — which is why no transaction may span tenants and why intercompany clearing accounts exist
at all. Per-tenant charts would need a mapping *between charts* before a consolidated statement
could be produced, which is the layer this project exists to avoid. And the harm the open row named
— *one tenant's reclassification restates every tenant's issued statements* — is fixed by
versioning, not by tenancy.

---

# The evidence

## 1 · Every hole, re-reproduced first

`10_repro_baseline.sql`, against the shipped baseline with a fixture of two scopes: `op`, holding
one house `due_to_tenants` account, 1,000.00 of paid-in capital, 300.00 of ACH-collected customer
cash and 300.00 of FBO float; and `op2`, holding the same two tenant positions **split per
counterparty**.

**R1 — a statement line reclassified under posted history.** `UPDATE account_types SET
fs_line='cash' WHERE code='fbo_cash'`:

| | before | after |
| --- | --- | --- |
| Cash and cash equivalents | 1,050.00 | **1,350.00** |
| Restricted cash | 300.00 | **0.00** |

300.00 of customer float became unrestricted liquidity on an already-issued balance sheet. No
error, no record, every check green.

**R3 — what `fk_types__fs_line` does refuse.** Both of these raised in the same run:

```
Key (fs_line, fs_statement, fs_side)=(revenue, balance_sheet, liability_equity) is not present
Key (fs_line, fs_statement, fs_side)=(cash,    balance_sheet, liability_equity) is not present
```

Across a statement, and across a side. **A move to another line of the same statement and the same
side is accepted**, which is what makes R1 and R2 the dangerous ones.

**R2 — the balance-sheet side is two-valued.** `paid_in_capital` moved to `payables`:

```
 payables              | Accounts payable and accrued | liability_equity | 1300
 equity                | Shareholders equity          | liability_equity |    0
 assets 1350.00 | liabilities and equity 1350.00 | balanced = t
```

**R4a — the balance sheet nets counterparties the chart declares un-nettable.** One house
`due_to_tenants` account, owing t1 425.00 and owed 425.00 by t2:

| | |
| --- | --- |
| `trial_balance` | debits **425.00**, credits **425.00**, net 0.00 |
| `balance_sheet` payables line | **0.00** |

**R4b — splitting the account per counterparty does not fix it.** Two owner-keyed accounts, `t1`
at −425.00 and `t2` at +425.00 in the trial balance:

```
 receivables  | Accounts receivable          |   0
 other_assets | Other assets                 |   0
 payables     | Accounts payable and accrued |   0
```

The netting is in the **report**, one level above the account, and an account's line was fixed by
its type — so t2's opposite-sign position had no line to move to even though the accounts were
already separate.

**R5 — the two declarative columns.**

```
views_reading_either      | 0
functions_reading_either  | 0
```

Then the mutation: `due_to_tenants` declared `shared`, `operating_cash` declared `per_shard`, and
every `is_perimeter` flipped. **The payables line did not move.** Nothing anywhere did.

**R6 — and a small correction to the register.** The open row says the `payables` line "hosts six
types mixing `per_shard` and `shared` scopes". It hosts **five**:

```
 accrued_interest_payable   | liability | shared    | f
 ach_pull_returnable        | liability | per_shard | f
 due_to_tenants             | liability | per_shard | f
 network_settlement_payable | liability | shared    | t
 platform_rev_share_payable | liability | per_shard | f
```

The mixing is real and the count is not. It is also **dissolved** by the fix rather than by the
`ach_pull_returnable` correction: once the presentation is decided per type, a line hosting both
scopes is no longer a defect, because each type's positions are routed by its own declaration.

## 2 · The seam, and what falls out of it

`20_versioned_chart.sql`. `fs_line`, `fs_statement` and `fs_side` leave `account_types`;
`chart_presentation` gets them, keyed by `chart_version`, with the two derived columns unchanged
except that the balance-sheet half of `fs_side` is now three-valued.

The copied columns are the schema's own trick, not a new one. `chart_presentation` carries
`category` and `counterparty_scope` because a generated column may not read another table, and
`fk_presentation__type (type_code, category, counterparty_scope)` makes the copies part of a
composite key — exactly as `fk_entries__account` does for currency and `fk_entries__txn_effective`
for the business date.

`fs_line_contra` is the new column, and `fs_side_contra` is derived from it:

```sql
fs_side_contra text GENERATED ALWAYS AS (
    CASE WHEN fs_line_contra IS NULL THEN NULL
         WHEN category = 'asset'     THEN 'liability'
         WHEN category = 'liability' THEN 'asset' END) STORED,
```

An asset position gone credit is a liability; a liability position gone debit is an asset. Carried
into `fk_presentation__fs_line_contra`, so a contra line on the wrong side is unwritable. Two
CHECKs finish it: a contra line exists **exactly** where `counterparty_scope = 'per_shard'`, and
`per_shard` is refused on an income-statement type — IAS 32.42 opens *"A financial asset and a
financial liability shall be offset…"*, so there is no such thing as an opposite-sign position in
revenue to present gross.

All four bite (`40_verify.sql`, V2 and V2b):

| probe | result |
| --- | --- |
| equity type under a **liability** caption | `fk_presentation__fs_line` — `(1, payables, balance_sheet, equity) is not present` |
| the same type under an **equity** caption | accepted, `fs_side = equity` |
| `per_shard` liability whose contra line is another **liability** caption | `fk_presentation__fs_line_contra` |
| `per_shard` type with **no** contra line | `ck_presentation__contra_iff_per_shard` |
| `per_shard` on a **revenue** type | `ck_presentation__per_shard_is_balance_sheet` |

**And the split changes nothing it was not supposed to.** `fs_side` is derived from `category`
alone on both halves, which is what [ADR-0007](/decisions/0007-schema-conventions-and-chart) fixed
when contra-revenue turned out to be unbuildable. Re-checked (`40_verify.sql`, V7): a
`revenue`/`debit` type still derives `fs_side = credit` and still reports under Revenue, and
`allowance_for_credit_losses` — `asset`/`credit` — still reports under Accounts receivable with
`fs_side = asset`. Only the eight liability-and-equity cells of the cross-product moved, and they
moved from one value to two.

## 3 · An in-place reclassification is refused unconditionally

Four tables become append-only through the trigger pair the journal already uses —
`chart_versions`, `fs_lines`, `chart_presentation`, `perimeter_attestations`. No new function.

```
ERROR:  chart_presentation is append-only: UPDATE on (row) refused. Correct it with a new row.
ERROR:  fs_lines is append-only: UPDATE on (row) refused. Correct it with a new row.
ERROR:  chart_presentation is append-only: DELETE on (row) refused. Correct it with a new row.
ERROR:  duplicate key value violates unique constraint "pk_presentation"
```

The last one is the re-seed. `schema/chart.sql` uses `ON CONFLICT (code) DO UPDATE`, and its own
comment defends that against `DO NOTHING` because *"a re-seed that silently ignores an edit is
worse than one that fails"*. Both halves are true and **both options are wrong**: `DO NOTHING`
ignores the edit, `DO UPDATE` applies it silently to every issued statement. A plain `INSERT` is
the third option, and it is the loud failure the comment wanted.

**Refusing conditionally was considered and is weaker.** "Refuse while any posted entry references
the type" needs an `EXISTS` over another table inside a trigger — the shape
[ADR-0004](/decisions/0004-where-logic-lives) deleted nineteen of — and it still permits editing a
chart that has been published but not yet posted to.

### One line of `refuse_mutation()` had to change, and the failure is the interesting part

`refuse_mutation()` raises `USING OLD.id`, and none of the four new tables has an `id` column. The
first run gave:

```
ERROR:  record "old" has no field "id"
CONTEXT:  PL/pgSQL expression "OLD.id"
```

The write **was** refused — the transaction aborts either way — but the message named PL/pgSQL
instead of append-only. That is the same class of defect as a comment naming a guard that is not
there, in a schema whose own comments say so twice. `COALESCE(to_jsonb(OLD)->>'id', '(row)')`
returns `NULL` for a missing key rather than raising, and leaves the journal's message
byte-identical because every journal table has an `id`.

## 4 · Netting, presented gross

`30_reports.sql`. Two changes to `balance_sheet` and the rest is the shipped view.

**The aggregate is per account before it is per line.** For a `per_shard` type,
`uq_accounts__owned (tenant_id, owner_type, owner_id, purpose, currency)` makes one account one
counterparty, so the position is evaluated per account and routed by sign:

```sql
CASE WHEN counterparty_scope = 'per_shard'
          AND ((category = 'asset'     AND v < 0)
            OR (category = 'liability' AND v > 0))
     THEN fs_line_contra ELSE fs_line END
```

**And the sign follows the line, not the account.** The shipped view signed by
`d.category = 'asset'`; a liability position routed to its contra line lands on an *asset* line and
must present positive there. `f.side = 'asset'` is the debit-positive side, and this is the same
correction [ADR-0007](/decisions/0007-schema-conventions-and-chart) made when it stopped deriving
`fs_side` from `normal_balance`: key the rule on what the chart declares, not on what the account
leans.

On `op2` — the same book that printed three zeros in R4b:

```
 other_assets | Other assets                 | asset     | 425
 payables     | Accounts payable and accrued | liability | 425
```

**Reconciled against the trial balance, gross against gross** — assembled from `trial_balance`
alone, without touching the chart:

| | |
| --- | --- |
| `trial_balance` debit positions on `due_to_tenants` | **425.00** |
| `trial_balance` credit positions on `due_to_tenants` | **425.00** |
| `balance_sheet` `other_assets` | **425.00** |
| `balance_sheet` `payables` | **425.00** |

And the whole-statement identity, which is not `0 = 0`: assets − liabilities − equity over the
chart equals the debit-positive sum over the journal, **50.00 = 50.00** on `op` and 0.00 = 0.00 on
`op2`. A position dropped by the sign routing, or counted twice, breaks that and nothing else
would notice.

The statement still balances, and now says three numbers where it said two:

| tenant | assets | liabilities | equity | balanced |
| --- | --- | --- | --- | --- |
| op | 1,350.00 | 300.00 | 1,050.00 | t |
| op2 | 425.00 | 425.00 | 0.00 | t |

**What is deliberately *not* attempted:** offsetting two different types facing the same party.
IAS 32.42 requires both a legally enforceable right of set-off *and* an intention to settle net,
and this schema declares neither. Gross is the conservative direction and, absent the declaration,
the required one.

### The half no report can supply

`op` still prints `payables` 300.00 and `other_assets` 0.00 under the fixed view, because its
`due_to_tenants` position lives in **one house account** — `uq_accounts__house` is
`(tenant_id, purpose, currency)` — and both counterparties were netted at write time. There is
nothing left to route.

So `ck_accounts__per_shard_is_owned` closes it going forward:

```
ERROR:  new row for relation "ledger_accounts" violates check constraint
        "ck_accounts__per_shard_is_owned"
DETAIL:  Failing row contains (op2, …, house, null, due_to_tenants, liability, credit, USD, …, per_shard)
```

and on the legacy book, `ALTER TABLE ledger_accounts VALIDATE CONSTRAINT` refuses:
`check constraint … is violated by some row`. **That refusal is the honest cost.** An account row
carrying entries cannot be deleted (`fk_entries__account`), so an existing deployment adopts this
by declaring a new type and posting a reclassification — an accounting restatement, not a
migration. `chart_lint` names the type meanwhile.

## 5 · The two declarative columns, made load-bearing

After the rebuild, **three views** read `counterparty_scope` or `is_perimeter`, against zero
before. The stronger property is that the wrong value can no longer be *introduced*:

```
-- under a live chart
ERROR:  update or delete on table "account_types" violates foreign key constraint
        "fk_presentation__type" on table "chart_presentation"
-- and under live accounts, which is the copy the CHECK reads
ERROR:  insert or update on table "ledger_accounts" violates foreign key constraint
        "fk_accounts__scope"
DETAIL:  Key (purpose, category, counterparty_scope)=(due_to_tenants, liability, shared)
         is not present in table "account_types".
```

Exactly the property `fk_accounts__type` already gives `category` and `normal_balance`, and for
the same reason: a copy that is part of a composite key cannot disagree with its source.

What a key still cannot reach is a scope declared correctly at seed time that the **account
register** later contradicts. `chart_lint` is eight rules in one exception view, empty when
passing. On the spike's book:

```
 per_shard_in_house_account | error | due_to_tenants     | per_shard type held in 1 house account(s)…
 perimeter_unattested       | error | fbo_cash / op / …  | is_perimeter account carries posted entries and has no attestation
 perimeter_unattested       | error | operating_cash / op / …
 perimeter_unattested       | error | operating_cash / op2 / …
```

### `is_perimeter` gets a mechanism, and deleting it was the live alternative

The baseline's comment gets the shape right and draws the wrong conclusion from it: *"There is no
CHECK either, and a CHECK could not help: the column is a claim about the world, not about the
row."* Correct — and what follows is not that the column is unenforceable, it is that **only data
about the world can falsify it**. So store the world's statement.

`perimeter_attestations` is one append-only table — tenant, account, currency, the counterparty's
statement date, who said so, and the balance debit-positive in our sign convention.
`perimeter_drift` compares it on the **effective** axis, because a bank statement is dated by the
bank's book ([ADR-0006](/decisions/0006-time-and-as-of)):

| purpose | source | as_of | attested | ours | drift |
| --- | --- | --- | --- | --- | --- |
| fbo_cash | trustee_stmt | 2026-01-04 | 300.00 | 300.00 | 0.00 |
| operating_cash | acme_bank_stmt | 2026-01-04 | 1,000.00 | 1,000.00 | 0.00 |
| operating_cash | acme_bank_stmt | 2026-01-05 | 1,000.00 | 1,050.00 | **50.00** |

`chart_lint` picks up the latest attestation per account and source and reports
`ledger 105000 against attested 100000 as of 2026-01-05`. The other direction fires too — an
attestation filed against an account the chart says is *not* perimeter:

```
 attested_but_not_perimeter | warn | due_to_tenants / tenant_confirm
```

That is the shape that caught `network_settlement_payable` in
[spike 004](/spikes/004-chart-of-accounts), found by reading rather than by a check. And an
attestation is evidence, so it is append-only: `UPDATE` on one is refused.

**Deleting the column instead was close.** It lost because `is_perimeter` is the only thing in the
schema that names *which* accounts a drift check is owed for, and the decision log carries "zero
drift views are deployed" as open. The cost is a table nothing writes yet, so
`perimeter_unattested` fires for every perimeter account on day one — the correct reading, and
also noise.

## 6 · IAS 1.41, satisfied

The standard, quoted from the EU's endorsement of IFRS — Commission Regulation (EC) No 1126/2008,
consolidated text `02008R1126-20230101`:

> **41** If an entity changes the presentation or classification of items in its financial
> statements, it shall reclassify comparative amounts unless reclassification is impracticable.
> When an entity reclassifies comparative amounts, it shall disclose (including as at the
> beginning of the preceding period): (a) the nature of the reclassification; (b) the amount of
> each item or class of items that is reclassified; and (c) the reason for the reclassification.

And ¶42, for when it cannot be done:

> **42** When it is impracticable to reclassify comparative amounts, an entity shall disclose:
> (a) the reason for not reclassifying the amounts, and (b) the nature of the adjustments that
> would have been made if the amounts had been reclassified.

"Impracticable" is IAS 8 ¶5's term, not IAS 1's: *"Applying a requirement is impracticable when
the entity cannot apply it after making every reasonable effort to do so."*

**"Reclassify comparative amounts" means the same prior period presented under the new mapping,
alongside the old one.** That single clause decides the design: an effective-dated
`account_types` makes the mapping a function of the *entry's* date, so a prior period can never be
re-presented under the current chart. A version can.

`50_ias1_41.sql` does the `ach_pull_returnable` correction as **chart version 2** — customer cash
inside an ACH return window presented as a trade payable, the mirror of the
`outbound_transfer_in_transit` correction already in the chart, and the same argument: presenting
it under "Accounts payable and accrued" understates customer funds payable and overstates what the
operator owes its own suppliers.

```
    fs_line     |          caption_v1          | under_v1 | under_v2 | reclassified
----------------+------------------------------+----------+----------+--------------
 payables       | Accounts payable and accrued |      300 |        0 |         -300
 customer_funds | Customer funds payable       |        0 |      300 |          300
```

Both presentations of one period, available at once and permanently. That query **is** 41(b) —
the amount of each item reclassified. 41(a) and (c) are `chart_versions.note`, which is `NOT NULL`
and non-empty.

**A version is a complete chart, not a diff.** Otherwise "which line was this presented under"
means walking a chain of overrides, and no foreign key expresses that. The copy is mechanical —
one `INSERT … SELECT` per table — so version 2's file spells out only what changed, while the
stored version is whole.

### The interface to a pinned report

Every statement view reads its version from one relation:

```sql
CREATE VIEW chart_version_current AS SELECT max(version) AS chart_version FROM chart_versions;
```

"Current" is derived, not stored — versions are append-only and monotone, so there is no row to
update and no way for "current" to disagree with what exists. And **a pinned report substitutes a
one-row relation for that one, and nothing else in the view body changes.**
`balance_sheet_at(p_chart_version int)` in `50_ias1_41.sql` is `balance_sheet` with exactly that
substitution; it produced the table above.

The commit-ordered cursor that pins *which entries* a report sees is a second parameter on a
different axis, is [ADR-0006](/decisions/0006-time-and-as-of)'s, and is not designed here. The two
belong in one signature. That signature does not exist yet, and this spike does not invent half
of it.

## 7 · Who else versions a chart, and who scopes it to the entity

**Formance, read from source** at `335bd03c08de46bae6895471702d9656958c64f5`,
`internal/storage/bucket/migrations/47-add-schema/up.sql`:

```sql
create table schemas (
    ledger varchar,
    version text not null,
    created_at timestamp without time zone not null default now(),
    chart jsonb not null,
    primary key (ledger, version)
);
```

**Per ledger, append-only.** `ledger` leads the primary key, `InsertSchema` is a bare `INSERT`,
and no `UpdateSchema` exists in `internal/storage/ledger/`. `FindLatestSchemaVersion` orders by
`created_at DESC LIMIT 1` — the same "current is derived" shape reached here independently.

Two corrections to what this repository says about it:

| claim | measured |
| --- | --- |
| *"a versioned `schemas(chart jsonb)` table since v2.3"* | The introducing commit `6c8b565693a139af6d86aabd0beb19f66b09ec4c` is **not** an ancestor of `v2.3.22`. The earliest tags containing it are `v2.4.0-beta.1` and `v2.4.0`. |
| *"typed account patterns in v3"* | `docs/drafts/chart-of-accounts.md` exists only on the `v3.0.0-alpha.*` tags, is headed `**Status:** Draft`, and is **not** on `HEAD`. `type ChartAccountRules struct{}` is still empty at `HEAD`, so that half of the claim stands. |

**And their chart has no notion of reclassification, because it is not a presentation mapping.**
`grep -rni "reclass"` over their entire Go source returns **zero hits**, and nothing maps an
address to a financial-statement line. Theirs is an address grammar validated at *write* time;
ours is a presentation mapping applied at *read* time.

**That difference decides the one place they argue the opposite of this spike.** Their v3 draft,
§5, is titled *"Why Chart Versioning Is Not Needed"*, and §5.3 says:

> "The chart is a property of the **ledger**, not of the request. If transaction A is validated
> against chart v2 and transaction B against chart v3 in the same ledger, the structural integrity
> of the ledger depends on which client sent which request."

Correct — **for a validation chart**, which must be single-valued. A presentation mapping must be
multi-valued, because IAS 1.41 requires one period presented two ways at once. §5.4 offers the
other alternative — *"Every chart change produces a `SetChartOfAccountsLog` entry in the
immutable, hash-linked log chain… The log is the authoritative history."* A version reconstructed
by log replay is not a key: `chart_presentation → fs_lines` could not be a foreign key per version,
and a report could not be pinned to one.

**ERPs scope the chart to the legal entity, not the install.** Odoo's `account.account`
(`addons/account/models/account_account.py:106`, branch `18.0`):

```python
company_ids = fields.Many2many('res.company', string='Companies', required=True, …)
```

Many-to-many, so one account may be shared across companies in a group; a localized chart template
is installed **per company** (`chart_template.py:132`,
`def try_loading(self, template_code, company, install_demo=False, force_create=True)`). ERPNext
is stricter — `Account`'s `company` field is `"fieldtype": "Link"`, `"reqd": 1`: one company per
account, no sharing. **Neither versions the mapping.**

*(Xero, NetSuite, SAP and QuickBooks were not re-checked. ADR-0007 records those docs as
unreachable as fetchable content, and that stands as an absence rather than being restated as a
finding.)*

### Which is why the chart stays global here

An ERP scopes per legal entity because each entity files its own statements. **In this ledger a
`tenant_id` is a sub-book of one reporting entity** — that is why no transaction may span tenants,
why intercompany due-from/due-to accounts exist, and why the theorem's "every per-tenant slice
balances" needs tenant-locality to hold. The operator's balance sheet is the consolidated one.

Adding tenancy costs a column on every chart key, moves the seed into tenant onboarding with a new
failure mode, and — the one that decides it — makes a consolidated statement need a **mapping
between charts**, which is precisely the layer [the vision](/vision) says other ledgers force on
you. A deployment whose tenants really are separate reporting entities gets a database each.

**And the harm the open row named is not a tenancy harm.** *"One tenant's reclassification restates
every tenant's issued statements"* — the harm is restating issued statements, closed by versioning
regardless of tenancy. Tenancy would only scope which charts move together, and sub-books of one
entity are supposed to move together.

---

## What is in the repository

`spikes/015-chart-governance/` — `run.sh` recreates `spike_wsd` from
`migrations/00001_baseline.sql` and runs everything in order. *(The directory number and the spike
number differ; the directory follows the next free slot under `spikes/`.)*

| file | what it is |
| --- | --- |
| `00_fixture.sql` | two scopes, fourteen entries |
| `10_repro_baseline.sql` | R1–R6 above, against the shipped baseline |
| `20_versioned_chart.sql` | proposed DDL: versions, the side split, `chart_presentation`, append-only |
| `21_scope_and_perimeter.sql` | proposed DDL: `counterparty_scope` on the account, `perimeter_attestations` |
| `22_chart_v1.sql` | the re-declared chart as version 1 — the proposed replacement for `schema/chart.sql` |
| `30_reports.sql` | the rebuilt statements, `perimeter_drift`, `chart_lint` |
| `40_verify.sql` | V1–V7: every reproduction refused or caught, plus the contra-revenue regression |
| `50_ias1_41.sql` | chart version 2, and `balance_sheet_at(int)` |

Nothing here ships. It is evidence, per
[ADR-0007](/decisions/0007-schema-conventions-and-chart); the DDL it proposes belongs in a
migration beside `00001_baseline.sql`, not in `spikes/`.

## On the sourcing of the standard

**EUR-Lex serves an AWS WAF challenge to every automated client tried** — `curl` and the fetch
tool both got `HTTP 202` with `x-amzn-waf-action: challenge` and an empty body, on the HTML, ELI
and PDF endpoints alike. IAS 1 ¶41, ¶42 and IAS 8 ¶5 above were read from the Internet Archive's
capture of the EUR-Lex consolidated-regulation page, dated 2024-03-29:
`web.archive.org/web/20240329045251/https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX:02008R1126-20230101`.

That is a **mirror of a primary source**, not a summary of one, and the distinction is worth
keeping: it is the EU's own endorsed English text, retrieved through an archive because the origin
would not serve it. The IFRS Foundation's own copy is paywalled.
[ADR-0007](/decisions/0007-schema-conventions-and-chart) paraphrases IAS 32.42 and says so; this
spike quotes IAS 1 and says where from.

**One terminology trap, recorded so it is not walked into.** IAS 1 also defines *"reclassification
adjustment"* (¶7, ¶92–93), which means an amount moved out of other comprehensive income into
profit or loss. That is **not** ¶41's "reclassify comparative amounts", which is a change in how
prior-period figures are presented. They share a word root and are structurally different
requirements; nothing in this ADR is about the OCI one.
