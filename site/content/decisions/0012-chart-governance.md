# 0012 — The chart is versioned, the presentation is append-only, and netting is declared per type

**Status:** accepted
**Evidence:** [spike 013](/spikes/013-chart-governance), building on
[spike 004](/spikes/004-chart-of-accounts) and
[0007](/decisions/0007-schema-conventions-and-chart).

## The decision

**An account carries two different kinds of fact about it, and only one of them is ever allowed to
change.**

The first is what the account fundamentally *is* — whether it is something the business owns or
something it owes, and which direction (money coming in, or money going out) makes it grow. That is
fixed the moment any money is booked against it. If it could change, you would be silently rewriting
financial statements you already handed out — something that was a liability yesterday reporting as
an asset today, with every past report quietly restated.

The second is *which line it shows up on* in a report. That can legitimately change — a business may
decide to present something differently, and the accounting rules sometimes require moving an item to
a different line and re-presenting last year the same way for comparison — but when it does, we record
it as a new *version* of the chart, never an edit to the old one. So an old report still looks up the
old version and shows exactly what it always showed, while new reports use the new presentation.
(IAS 1.41 requires exactly this: when you reclassify, the old periods still have to be presentable the
way they were.)

In the schema's terms those two facts are an account type's *identity* and its *presentation*, and
they have different lifetimes. Identity is the type's **category**, its **normal balance** (which
direction makes the account grow), its **counterparty scope**, and its **perimeter status** — none of
it may change under posted history, and `fk_accounts__type` already refuses two of them. Presentation
is the single financial-statement line the type rolls up to; because IAS 1.41 requires *that* to be
able to change, `fs_line` leaves `account_types` and becomes a versioned, append-only mapping,
`chart_presentation (chart_version, type_code)`. **A reclassification is a new chart version, never an
edit.**

| | |
| --- | --- |
| **1. `chart_versions` is append-only, and "current" is `max(version)`** | No singleton row to update, nothing that can disagree with what exists. `note` is `NOT NULL` and non-empty because IAS 1.41(c) requires the *reason* for a reclassification and that is the half a schema can hold. |
| **2. `fs_line` moves to `chart_presentation (chart_version, type_code)`** | It leaves `account_types` entirely. Two copies of one fact is the mistake [spike 009](/spikes/009-where-the-balance-lives) removed from `ledger_entries`; this does not reintroduce it. `fs_lines` is versioned too, because a reclassification routinely adds a line and a caption edit is itself a presentation change. |
| **3. `chart_versions`, `fs_lines`, `chart_presentation` and `perimeter_attestations` are append-only, by the existing trigger pair** | No new trigger function. The invariant, why nothing declarative reaches it, and what it does not protect are below. An in-place reclassification is refused **unconditionally** — not "while posted entries exist", which needs a subquery in a trigger, the exact shape [0004](/decisions/0004-where-logic-lives) deleted nineteen of. |
| **4. The balance-sheet side splits into `asset`, `liability`, `equity`** | Every balance-sheet line is re-declared. `fs_side` stays derived from `category` alone, on both statements, so [0007](/decisions/0007-schema-conventions-and-chart)'s contra-revenue fix is untouched and contra-assets still work. |
| **5. A balance-sheet type may declare `fs_line_contra`; a `per_shard` one must** | The line an opposite-sign position presents under: for `due_to_tenants`, `other_assets`; for `customer_wallet`, `receivables`. **Required** when `counterparty_scope = 'per_shard'` (`ck_presentation__contra_required_for_per_shard`) and **permitted on any balance-sheet type** (`ck_presentation__contra_is_balance_sheet`) — because sign-swing is orthogonal to sharding, a shared payable that goes into a receivable position must present gross too (A10). Held to the opposite side by the same foreign key, and refused on an income-statement type because IAS 32.42 is a rule about financial assets and financial liabilities. |
| **6. `balance_sheet_at` aggregates per account *before* per line** | One account is one counterparty for a `per_shard` type, and each account's position is routed to `fs_line` or, if it has swung to the opposite side and declares one, `fs_line_contra` — by its **position sign**, for any balance-sheet type, not only `per_shard` (A10). Netting *within* one counterparty is left alone — that is one party, and it is permitted. The line's amount is then signed by **the line's side**, not by the account's category. |
| **7. A `per_shard` type may not be held in a house account** | `ck_accounts__per_shard_is_owned`, reading a `counterparty_scope` copied onto `ledger_accounts` and held honest by `fk_accounts__scope`. This is the half no report can supply: a house account is one row per scope, so both counterparties' positions are netted **at write time** and the information is gone. |
| **8. `is_perimeter` gets `perimeter_attestations` and `perimeter_drift`** | The column claims "this account mirrors exactly one external balance and must reconcile against it". Only data about the world can falsify that, so the world's statement is stored: source, business date, balance, append-only. |
| **9. `chart_lint` is one exception view over ten rules** | Empty is passing. It covers what no key can reach: a type the current version does not present, a `shared` type whose accounts are keyed to several owners, a perimeter account nobody outside has ever confirmed, an attestation against an account the chart says is not perimeter, and — added by A9 — a mirror pairing that is undeclared (`warn`) or points at the same side (`error`). |
| **10. The chart stays global. `tenant_id` is a scope inside one reporting entity, not a reporting entity** | Per-tenant charts would need a mapping between charts before any consolidated statement could be produced — reintroducing exactly the mapping layer this project exists to avoid. What it forecloses is below. |
| **11. `ach_pull_returnable` moves from `payables` to `customer_funds` — as chart version 2** | Not as an edit. That is the whole point, and it is how the rule gets exercised: the same posted period is presented under both versions at once, which is what IAS 1.41 asks for. |

**The load-bearing sentence: a statement is reproducible only if the mapping it was presented
through is still exactly what it was, so the mapping has to be a key, not a column somebody
edits.**

## The evidence

### IAS 1.41 asks for two things, and the shipped schema could meet neither

Quoted from the EU's endorsement of IFRS — Commission Regulation (EC) No 1126/2008, consolidated
text `02008R1126-20230101`, which is the freely readable authoritative English text of the
standard. *(EUR-Lex serves an AWS WAF challenge to every automated client we tried; the text below
was read from the Internet Archive's capture of the EUR-Lex page, dated 2024-03-29. That is a
mirror of a primary source, not a summary of one, and it is recorded that way rather than cited as
a direct fetch.)*

> **41** If an entity changes the presentation or classification of items in its financial
> statements, it shall reclassify comparative amounts unless reclassification is impracticable.
> When an entity reclassifies comparative amounts, it shall disclose (including as at the
> beginning of the preceding period): (a) the nature of the reclassification; (b) the amount of
> each item or class of items that is reclassified; and (c) the reason for the reclassification.

**"Reclassify comparative amounts" means the same prior period presented under the new mapping,
alongside the old one.** That is why effective-dating `account_types` is the wrong shape: it makes
the mapping a function of the *entry's* date, so last year can never be re-presented under this
year's chart. And 41(b) — the amount of each item reclassified — is precisely the difference
between two presentations of one period, which is computable only if both still exist. Measured on
the spike's book: `payables` 300.00 under version 1 against 0.00 under version 2, `customer_funds`
0.00 against 300.00, both available at once and permanently.

### The reclassification hole, re-verified and then closed

Re-run 2026-08-27 against the current baseline. `fbo_cash` moved from `restricted_cash` to `cash`
by one `UPDATE`: **cash 1,050.00 → 1,350.00, restricted cash 300.00 → 0.00**, on an
already-issued balance sheet, with every check green. `fk_types__fs_line` bites only *across* a
statement or *across* a side — both of those were refused in the same run, which is what makes the
accepted move the dangerous one. Under this ADR the same `UPDATE` raises
`chart_presentation is append-only`, and so does rewriting an `fs_lines` caption, deleting a
mapping, or re-seeding an edited chart at the same version.

**That last one is worth naming.** `schema/chart.sql` re-seeds with `ON CONFLICT (code) DO UPDATE`,
and its comment defends that against `DO NOTHING` because "a re-seed that silently ignores an edit
is worse than one that fails". Both halves are true and both options are wrong: `DO NOTHING`
ignores the edit, `DO UPDATE` **applies it silently to every issued statement**. A plain `INSERT`
is the third option — an unchanged re-run raises on the primary key and an edited re-run raises
too, which is the loud failure the comment wanted and could not get.

### The balance-sheet side was a two-way check called this schema's best guard

Re-verified: **1,000.00 of paid-in capital presented under "Accounts payable and accrued"**,
the `payables` line 1,300.00 and `equity` 0.00, assets 1,350.00 against
liabilities-and-equity 1,350.00, `balanced = t`, drift views empty. The
income-statement half of `fk_types__fs_line` distinguishes revenue from expense; the balance-sheet
half distinguished only `asset` from `liability_equity`, so `liability`, `equity` and any contra
of either were interchangeable across all five liability-and-equity captions. With the side split
the same row is refused by the key, and the positive control — the same type under an equity
caption — is accepted. The split also lets the statement say `assets`, `liabilities` and `equity`
as three numbers where it previously had two, and lets the synthesised earnings plug declare
itself `equity`, which under a two-valued side could not be said.

### Netting: the report was one level above the account, and so is the fix

Re-verified both halves. A single house `due_to_tenants` account owing t1 425.00 while t2 owes
425.00 prints **a payables line of 0.00** while `trial_balance` holds debits 425.00 and credits
425.00. And **splitting the account per counterparty does not fix it**: with two owner-keyed
accounts holding −425.00 and +425.00, the balance sheet still printed 0.00, because it grouped by
`fs_line` and an account's line was fixed by its type, so the opposite-sign position had no line
to move to.

`fs_line_contra` is that line. With it, the split book prints **`other_assets` 425.00 and
`payables` 425.00** — reconciled against the trial balance's own gross figures, assembled without
touching the chart, and against the whole-statement identity (assets − liabilities − equity over
the chart equals the debit-positive sum over the journal: 50.00 = 50.00 on the spike's book).

**And the fix was incomplete for `shared` types, which A10 completes.** This ADR originally routed the
contra line only for `per_shard` types and forbade it elsewhere — but sign-swing is orthogonal to
sharding, so two *shared* balance-sheet types on one line reopened the same 425/425 hole: a 425.00
debit position in `network_settlement_payable` and a 425.00 credit in `accrued_interest_payable` both
sit on `payables` and net to 0.00; and the `per_shard` `due_to_tenants` contra lands on `other_assets`
where the shared `due_from_treasury` lives, so a swung `due_from_treasury` drove `other_assets`
negative. A10 makes `fs_line_contra` **permitted on any balance-sheet type** and routes on position
sign for all of them; `schema/chart.sql` version 3 declares a contra line on exactly those
swing-capable shared types (`network_settlement_payable`, `accrued_interest_payable` → `other_assets`;
`due_from_treasury` → `payables`), so each swung position now presents gross instead of netting.

**IAS 32.42 permits offset only where there is a legally enforceable right of set-off *and* an
intention to settle net.** This schema declares neither, so two different types facing the same
party are *not* offset either. Gross is the conservative direction and, absent the declaration,
the required one.

**And the half a report cannot supply.** For a house account there is no counterparty grain at
all — `uq_accounts__house` is `(tenant_id, purpose, currency)`, one row per scope, so both sides
of the position were netted at write time. No view can recover that. Hence rule 7: going forward
the shape is unrepresentable, and on the spike's legacy book `VALIDATE CONSTRAINT` refuses and
`chart_lint` names the type.

### The two declarative columns now have consumers — and a wrong value is refused, not just reported

Re-verified on the baseline: **zero views and zero functions** read `counterparty_scope` or
`is_perimeter`; flipping every `is_perimeter` and swapping `due_to_tenants` to `shared` and
`operating_cash` to `per_shard` changed no reported number anywhere. After this ADR **three views
read them**, and the stronger property is that the wrong value cannot be introduced under a live
chart at all: `fk_presentation__type` and `fk_accounts__scope` both refuse it, exactly as
`fk_accounts__type` already refuses a category change. What a key still cannot see — a scope
declared at seed time that the account register later contradicts — is what the lint is for.

`is_perimeter`'s mechanism is one table and one view. **Deleting the column was the live
alternative** and it is defensible; it lost because `is_perimeter` is the only thing in the schema
that names *which* accounts a drift check is owed for, and "zero drift views are deployed" is an
open row in this log. The drift view compares the counterparty's statement date on the
**effective** axis, because a bank statement is dated by the bank's book
([0006](/decisions/0006-time-and-as-of)).

### Prior art, read from source

**Formance versions its chart per ledger, append-only** — and the register's summary of it needs
two corrections. Read at `335bd03c08de46bae6895471702d9656958c64f5`,
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

`ledger` leads the primary key, `InsertSchema` is a bare `INSERT` and no `UpdateSchema` exists, so
their chart is scoped per logical ledger and never rewritten — the same posture this ADR takes,
arrived at independently. **It is not "since v2.3":** the introducing commit
`6c8b565693a139af6d86aabd0beb19f66b09ec4c` is not an ancestor of `v2.3.22`, and the earliest tags
containing it are `v2.4.0-beta.1` and `v2.4.0`. **And v3's "typed account patterns" are a draft,
not shipped**: `docs/drafts/chart-of-accounts.md` exists only on the `v3.0.0-alpha.*` tags, is
headed `**Status:** Draft`, and does not exist on `HEAD`. `type ChartAccountRules struct{}` is
still empty at `HEAD`. What does hold: `grep -rni "reclass"` over their entire Go source returns
**zero hits**, and there is no financial-statement mapping anywhere — their chart is an address
grammar, so reclassification is not a question their design has.

**Their v3 draft argues *against* versioning**, §5.4: *"Every chart change produces a
`SetChartOfAccountsLog` entry in the immutable, hash-linked log chain… The log is the
authoritative history."* That is a real alternative and it is refused below — for a reason that
turns on what the two charts are *for*.

**ERPs scope the chart to the legal entity, not the install.** Odoo's `account.account` carries
`company_ids = fields.Many2many('res.company', …)` (`addons/account/models/account_account.py:106`,
branch `18.0`) — an account may be shared across companies in a group, and a localized chart
template is installed per company (`chart_template.py:132`,
`def try_loading(self, template_code, company, …)`). ERPNext is stricter: `Account`'s `company`
field is `"fieldtype": "Link"`, `"reqd": 1` — one company per account, no sharing. Neither versions
the mapping. *(Xero, NetSuite, SAP and QuickBooks were not re-checked in this pass;
[0007](/decisions/0007-schema-conventions-and-chart) records those docs as unreachable and that is
left standing rather than restated as a finding.)*

**The tenancy question is settled by what a tenant *is* here.** ERPs scope per legal entity because
each entity files its own statements. In this ledger a `tenant_id` is a sub-book of **one**
reporting entity, joined to the others by intercompany clearing accounts — [spike
004](/spikes/004-chart-of-accounts)'s whole due-from/due-to construction, and the reason no
transaction may span tenants. The operator's balance sheet is the consolidated one. A deployment
whose tenants really are separate reporting entities gets a database each, which is also what
[0002](/decisions/0002-scaling) and [0008](/decisions/0008-module-boundaries) imply.

**And versioning, not tenancy, is what fixes the harm the open row actually named.** "One tenant's
reclassification restates every tenant's issued statements" — the harm is *restating issued
statements*, and that is closed by rule 1 regardless of tenancy. Tenancy would only scope which
charts move together, and sub-books of one entity are supposed to move together.

## What we considered

| | Why not |
| --- | --- |
| **Effective-dated chart rows** (`valid_from` / `valid_to` on `account_types`) | Ties the mapping to the *entry's* date, so a prior period can never be re-presented under the new chart. That is exactly what IAS 1.41 requires and this shape makes unbuildable. |
| **Derive the chart's history from the event log**, as Formance's v3 draft proposes | Right for their chart and wrong for ours, and the difference is what the chart is *for*. Theirs validates addresses at write time, so it must be single-valued — their §5.3 says so: *"The chart is a property of the ledger, not of the request."* Ours maps to statement lines at read time, and IAS 1.41 requires one period presented **two ways at once**. A version reconstructed by log replay is also not a key: `chart_presentation → fs_lines` could not be a foreign key per version, and a report could not be pinned to one. |
| **Keep `fs_line` on `account_types` and add a history table beside it** | Two copies of one fact, with nothing holding them equal — the shape [spike 009](/spikes/009-where-the-balance-lives) removed from `ledger_entries`. |
| **Sparse versions: version *N* inherits from *N−1* except where overridden** | Cheaper to write and unfoldable by no foreign key. "Which line was this presented under" becomes a walk down a chain of overrides. A full copy is one `INSERT … SELECT` per table and is trivially correct. |
| **Make the reclassification guard conditional** — refuse only while posted entries reference the type | Needs an `EXISTS` over another table inside a trigger, which is the shape [0004](/decisions/0004-where-logic-lives) deleted nineteen of, and it is *weaker*: a chart edited before the first posting is still an edit to a chart somebody may already have published. Unconditional is simpler and stronger. |
| **Add tenancy to `account_types` and `fs_lines`** | Every chart key gains a column, the seed moves into tenant onboarding with a new failure mode (a tenant that cannot post because it has no chart), and — the one that decides it — a consolidated statement across tenants then needs a mapping *between charts*, which is the layer [the vision](/vision) says other ledgers force on you. |
| **Delete `is_perimeter`** | Honest, and it was close. It is the only column that names which accounts owe an external reconciliation, and nothing else in the schema does. Given a mechanism instead. |
| **A per-counterparty split of the account, instead of a contra line** | Measured not to work: the split book still printed 0.00, because the netting is in the report and an account's line was fixed by its type. It is *necessary* — rule 7 — and it is not *sufficient*. |
| **Let the balance sheet raise on a `per_shard` type in a house account** | [0007](/decisions/0007-schema-conventions-and-chart) already accepts a read-time raise for a mis-typed axis, so this would be consistent. It is a worse failure than an unrepresentable state, and the state is reachable-and-refusable here. |

## What it costs

| | |
| --- | --- |
| **A version is a full copy of the chart** | 33 rows for the reference chart; 500 for a 500-type one. The copy is mechanical (`INSERT … SELECT` per table, then the deltas), so the seed file spells out only what changed — but the row count is real and grows with every reclassification. |
| **A caption typo is no longer fixable in place** | It is a new chart version. [0007](/decisions/0007-schema-conventions-and-chart) argues at length that a caption is what a reader groups by; a book whose captions can be rewritten under an issued statement has the same hole as one whose `fs_line`s can. This is the cost of taking that argument seriously. |
| **`ledger_accounts` gains a fourth copied column** | `counterparty_scope`, alongside `category` and `normal_balance`, each held honest by a composite foreign key. The pattern is the schema's own and each instance is still a denormalisation. |
| **`ck_accounts__per_shard_is_owned` is not migratable in place** | An account row that already carries entries cannot be deleted (`fk_entries__account`), so a deployment already holding a `per_shard` type in a house account adopts this by declaring a **new type** and posting a reclassification — an accounting restatement, not a schema migration. In the baseline the constraint ships validated inside `CREATE TABLE`, because there are no rows yet; in [spike 013](/spikes/013-chart-governance) it is `NOT VALID` only because the spike loads the broken book first, and `VALIDATE CONSTRAINT` is shown failing on it. |
| **More trigger objects on the chart tables, inheriting every hole the journal's have** | The chart tables carry the same append-only and no-truncate guards as the journal, plus two `refuse_stale_chart_version` triggers on `fs_lines` and `chart_presentation` (A15). An owner disables or drops them in one statement, and DDL walks past them — [0009](/decisions/0009-append-only-perimeter) now records that as an **accepted out-of-model limitation** backstopped by the CI snapshot test, covering the chart as well as the journal. |
| **One line of `refuse_mutation()` had to change, and finding out why is the point** | It raises `USING OLD.id`, and none of the four new tables has an `id`. The trigger fired, PL/pgSQL could not resolve the field, and the error read `record "old" has no field "id"` with a `CONTEXT` line naming the function. The write *was* refused either way — but the message named PL/pgSQL instead of append-only, which is the same class of defect as a comment naming a guard that is not there. Reaching the id through `to_jsonb(OLD)->>'id'` returns `NULL` rather than raising and leaves the journal's message byte-identical. |
| **`chart_lint` is ten rules' worth of work in one view, and its errors are one of `reconciliation`'s ten checks** | It is an exception view, not a constraint — but `reconciliation` counts its `error`-severity rows as a check ([0010](/decisions/0010-reconciliation)), so the daily sweep runs it. A view a scheduled sweep reads is better than a column nothing reads, and still not the same as an enforced guard — the sweep is `openledger reconcile` (roadmap M2) and the schema diff is [0007](/decisions/0007-schema-conventions-and-chart)'s snapshot CI. |
| **`perimeter_attestations` is a table no *feed* fills** | The reconciliation view that reads it — `perimeter_drift`, comparing the stored instant against the account's computed balance — is in place, and `is_perimeter` has consumers (`perimeter_drift`, `chart_lint`); the integration *feed* that files a third party's statement into the table is out of scope here (none designed). Until one exists, `perimeter_unattested` fires for every perimeter account in the book — the correct reading, and noise on day one. |
| **The chart stays global, and that forecloses a real deployment** | A platform whose tenants are separate legal entities with their own auditors and their own local-GAAP charts cannot be served by one database here. A tenant also cannot add a purpose the operator's chart lacks. Both are the price of never needing a mapping between charts. |
| **The report-parameter interface is built, in one signature** | Every statement reads its default version from `chart_version_current` and from nowhere else, and emits it as a column. At integration the coordination this row asked for happened: the two statements became **functions** whose signature carries the effective range, [0011](/decisions/0011-period-close-and-report-axes)'s commit-ordered cursor, *and* the chart version (defaulting to current) — `balance_sheet_at(tenant, as_of, cursor, chart_version)`, `income_statement_for(tenant, from, to, cursor, chart_version)`, applied in the baseline. The spike's `balance_sheet_at(int)` was the demonstration that the version is one substitution point; the shipped signature is that demonstration merged with the cursor's. |
| **The balance sheet now aggregates per account before per line** | An extra grouping level over `ledger_entries` on a report that was already a full scan. Unmeasured; the spike's book is fourteen entries and localhost is not a benchmark. |

## Not decided here

| | |
| --- | --- |
| **Whether `due_to_tenants` belongs on `payables` at all** | It is the mirror of `due_from_treasury`, which sits on `other_assets`, so an intercompany obligation is presented as a trade payable while its counterpart is not. An `other_liabilities` line would make the two sides symmetric. Left alone because it is one line beyond the mandate and because the contra mapping already routes the debit side to `other_assets`. |
| **What writes a `perimeter_attestation`** | A bank file, a network settlement report, a trustee statement. All integrations, none designed. |
| **Whether a right of set-off can be declared** | IAS 32.42 needs both an enforceable right and an intention to settle net. Declaring them per counterparty pair would let two types facing one party be presented net, which is currently and deliberately refused. |
| **The period close** | **Now decided by [0011](/decisions/0011-period-close-and-report-axes) and in the schema** — the close is an ordinary posting into `retained_earnings`, the earnings plug nets all temporary accounts at the cursor, and the effective-axis aggregate is bounded by the `ledger_period_balances` checkpoints. The mechanism and its tables are applied in the baseline; the *writer* that posts a close is roadmap work. |
