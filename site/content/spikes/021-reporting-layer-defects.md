# Spike 021 — Which of the reporting layer's reported defects are real on a real book?

**Status:** closed. **Eight of the ten subjects reproduced (three with their limits stated exactly),
one reproduced twice by two independent routes, and one refuted outright — with its defect
*inverted*: the two functions held up as already protected are the two that raise.** The findings are
reproduced and the fixes are **specified but unbuilt** — every fix is a new numbered migration
(`00004` is the next number and does not exist), a view or function body change, or a crate change,
and `spikes/025-reporting-layer-defects/FIX-NOTES.md` carries each one's cost in this project's own
terms. Feeds [ADR-0010](/decisions/0010-reconciliation),
[ADR-0011](/decisions/0011-period-close-and-report-axes),
[ADR-0012](/decisions/0012-chart-governance) and roadmap [M5](/roadmap#m5--bitemporal-reads).
*(Directory `spikes/025-reporting-layer-defects/`; the spike directories carry their own numbering.)*

**Question.** An adversarial read-only round produced **twelve findings** against the shipped
reporting functions and the reconciliation views, collapsed to **ten subjects**. Which of them are
real on a real book? This project's standard is *proved red before trusted green*, and a finding that
cannot be reproduced is withdrawn rather than fixed — **so this spike is as much a check on the
auditor as on the schema.** Every subject is either reproduced against a live book with the exact
statement and the exact output recorded, or refuted by naming the constraint that makes the state
unwritable. The deliverables are in the repository at `spikes/025-reporting-layer-defects/`:
`SPEC.md` (the book, the control and the shape of each reproduction), `FINDINGS.md` (the verdicts and
the pasted output), `FIX-NOTES.md` (the fix shape and its cost per finding) and `REPRO/` (a
self-contained script per finding). **No timing runs at all** — nothing here is a performance
question, no loadavg was recorded and no comparison of durations is made or implied.

---

## Method — a ten-zero negative control before every injection

[Spike 011](/spikes/011-reconciliation)'s rule, and its reason: ADR-0007 records a schema-snapshot
check of *"twenty-one lines containing one `SELECT` that emits a string, with no committed snapshot,
no comparison and no failure path."* **A red that was already red proves nothing.** So every
reproduction opens with `SELECT * FROM reconciliation` returning ten rows at zero breaks, and where a
finding claims the checks stay green, all ten rows are pasted rather than the one that was expected to
move.

The book is ten accounts across two tenants, one currency, **six posted transactions written through
the shipped writer over HTTP** plus one pending withdrawal — the pending item is there for spike 011's
reason, because the journal-to-reports statement is non-zero on a healthy book that has a hold on it
and a control that never exercises a reconciling item cannot show the item being subtracted by name.
The control:

```
       check_name        | breaks              tenant_id | currency | journal_debits | pending_debits | reported_debits | tb_debits | unexplained_debits
-------------------------+--------            -----------+----------+----------------+----------------+-----------------+-----------+--------------------
 balance_cache           |      0              t1        | USD      |        1830000 |          50000 |         1780000 |   1780000 |                  0
 orphan_entries          |      0              t2        | USD      |         100000 |              0 |          100000 |    100000 |                  0
 unbalanced_transactions |      0
 cross_scope_mirror      |      0             assets 1,750,000 against liabilities-and-equity 1,750,000,
 journal_to_reports      |      0             and the 50,000 the journal carries above the reports is the
 checkpoint_drift        |      0             pending withdrawal, named and subtracted.
 close_typing            |      0
 cursor_forgery          |      0
 accounting_equation     |      0
 chart_lint              |      0
(10 rows)
```

Four ground rules are worth stating because each one is load-bearing:

- **No perimeter type is in the book, deliberately.** `chart_lint`'s `perimeter_unattested` is an
  **error** rule and fires for every `is_perimeter` account carrying posted entries until an
  attestation feed exists — which no part of this artefact has yet (roadmap M7). A book holding
  `operating_cash` therefore cannot reach ten zeros, and a control that starts at nine zeros and one
  red cannot support any of the claims below.
- **The horizon wait is part of the control, not an incidental.** `report_cursor()` is
  `pg_snapshot_xmin(pg_current_snapshot())`, so every cursor-pinned statement reads an all-zero book
  until the cluster horizon retires the seed's own entries — and `recon_equation_breaks` over an
  all-zero book returns zero rows, which reads **green**. Every script polls the horizon past the
  newest entry before reading anything pinned, bounded and server-side, exactly as the e2e suite's
  `wait_for_the_horizon_to_retire_this_book` does. **A green produced by a lagged cursor is the shape
  this spike exists to distrust.**
- **Forward-only injections, and an exact restore.** `refuse_mutation()` refuses `UPDATE` and `DELETE`
  on the journal, the chart tables, `ledger_periods` and `ledger_period_closes`, so a reproduction
  cannot tidy up after itself; the control book is restored from a `TEMPLATE` copy taken once.
- **The role is named per reproduction**, because *"the writer can reach this"* and *"only the owner can
  reach this"* are different severities. Two reproductions and one other run as `openledger_app`
  deliberately; one runs as a `LOGIN` role inheriting `openledger_read`; the rest run as the owner and
  say so.

**The deviation, stated plainly: this spike ran on two private containers rather than on the shared
cluster** — one on port 5455 for the book and the per-finding scratch databases, one on 5456 for F10's
book and the neighbour database whose transaction is held. Both reasons are themselves a finding.
First, **the shared cluster's horizon was held back by a neighbour, so the ten-zero control was
unobtainable there**: a backend on database `spike024arms`, `idle in transaction`, held xid 15760 for
almost four minutes while this book's entries sat at 15777–15782, and the freshly seeded database
reported `cursor_forgery: 12` with `accounting_equation: 0` green only because the balance sheet at
`report_cursor()` was entirely zero. That is **F10 reproduced by accident before it was reproduced on
purpose**, on a book written entirely by the shipped writer. Second, F10 *on purpose* needs a
long-running transaction in a second database on the same instance, and doing that on the shared
cluster would have dragged two other agents' horizons back — the very effect the finding is about.
Nothing on the shared cluster was written to.

---

## F6 — refuted on all three counts, and the defect is inverted

**`SUM(bigint)` returns `numeric` in PostgreSQL**, so a bare `SUM(amount_minor)` never had a `bigint`
accumulator to overflow. Confirmed on the server rather than argued:

```
 sum_of_bigint | sum_of_numeric | bigint_plus_bigint
---------------+----------------+--------------------
 numeric       | numeric        | bigint
```

The three aggregates the finding called unprotected — `trial_balance`, `recon_transaction_breaks`'
`legs` CTE and `recon_pending_bridge`' `pend` CTE — **already publish `numeric`, and
`schema/snapshot.txt` has been carrying the refutation since M1**: line 342 reads
`trial_balance.debits: numeric`.

**The finding's reachability arithmetic is correct and only its consequence is wrong.** `amount_minor`
is bounded **below only** — `ck_entries__amount_positive CHECK (amount_minor > 0)`, no upper `CHECK`
anywhere, and `crates/ledger/src/domain.rs` refuses only `<= 0` — so one legal entry is
`[1, 2^63-1]`, and `ck_accounts__stripe_count` allows up to 1024 stripes.

The state was reached **entirely through the shipped writer over HTTP**: six sequential
`POST /v1/transactions`, each `amount_minor: 9223372036854775807`, against a 64-stripe account.
Consecutive calls reach consecutive dispatchers and each dispatcher stripes on the index it holds
([ADR-0018](/decisions/0018-batching-and-stripe-selection) §1), so the writer put one ceiling-sized
entry on each of six stripes by itself. Every row legal and at the ceiling; the view groups across all
six and reports, without error:

```
purpose                | platform_rev_share_expense
debits                 | 55340232221128654842        -- 6 × (2^63−1), six times past the bigint ceiling
balance_debit_positive | 55340232221128654842
```

Same answer through `openledger_read`'s own grant, which matters because the view is
`security_invoker`. `recon_transaction_breaks` publishes `18446744073709551614` and **emits** such a
value in a row it returns rather than merely computing and filtering it; `recon_pending_bridge` is the
easiest of the three to reach and needs no striping at all — two ordinary pending HTTP calls on one
**unstriped** account give `pending_balance_minor 18446744073709551614` and
`available_balance_minor 27670116110564327421`, published, not raised.

**And at that same state, the function the finding holds up as fixed:**

```
$ SELECT * FROM trial_balance_at('t4','-infinity','infinity', report_cursor());
ERROR:  bigint out of range
```

Isolated to the cast, one half at a time: `SUM(amount_minor::numeric)` alone returns
`55340232221128654842`; **the same expression with `::bigint` appended raises.** The cast is the one
`RETURNS TABLE (… debits bigint …)` forces. `income_statement_for` fails the same way at `fs_line`
grain; `balance_sheet_at` survived only because the provisioning arranged revenue and expense to net
to zero.

**So the direction of the defect is inverted: the report that "dies on one large row and reports
nothing" is the one the comment claims is protected — and the claim is not only in the migration, it is
in the catalog**, dumped into `schema/snapshot.txt` line 1780:

> `function trial_balance_at(...) = ... Sums as numeric to survive a huge legal row (ADR-0011, ADR-0013).`

It sums as `numeric` and then casts back to `bigint`, so it does not survive. **The three views that
never cast do.** Blast radius from F6 itself: none — at that state the operator query reports ten
checks at zero and `openledger reconcile` exits 0, and with a forged imbalance added on top the break
list does its job (`unbalanced_transactions: 2 break(s)`, exit 1) and still does not raise.

**Two real write-path refusals were found on the way**, neither of them F6:

- **The batched statement's cross-member coalesce re-adds at `bigint`.** Two ceiling-sized postings to
  one account sent *simultaneously* were collected into one shared statement and both refused — server
  log `write failed: … bigint out of range`, callers `HTTP 500 {"type":"internal","detail":"the write
  failed; nothing was committed"}`. Nothing committed. Whether two simultaneous posts batch is not
  deterministic and both outcomes were observed across runs, so this is a **sometimes**-500 on legal
  amounts, and the caller is told `internal` rather than `overflow`, which the error-type grammar
  already has.
- **The per-stripe cache row is the real amount ceiling.** A stripe holds at most 2^63−1 per side, so on
  an unstriped account the *second* ceiling-sized posting is refused by the cache upsert rather than by
  any stated rule — again `500 internal`, not one of the nine named types. *(Two ceiling-sized legs
  inside one posting are refused properly, by the writer's own `checked_add`:
  `{"type":"invalid_request","detail":"the posting amounts overflow 64-bit minor units"}`, HTTP 422.)*

## Three findings whose reproduction path was wrong, and whose substance held

**F1's proposed injection is refused by three keys.** The finding asks for a liability type presented
on a balance-sheet line whose `side` is `'asset'`. `chart_presentation.fs_side` is a `GENERATED` column
derived from `category` and carried into `fk_presentation__fs_line`, so the line a presentation row
names must carry the same side:

```
ERROR:  insert or update on table "chart_presentation" violates foreign key constraint "fk_presentation__fs_line"
DETAIL:  Key (chart_version, fs_line, fs_statement, fs_side)=(4, receivables, balance_sheet, liability) is not present in table "fs_lines".
--- ...onto an income-statement line (fs_statement is generated too): the same refusal
--- ...nor can a balance-sheet line carry a side outside the three-valued split
ERROR:  new row for relation "fs_lines" violates check constraint "ck_fs_lines__side_matches_statement"
```

**The specific mechanism the finding names cannot be written**, and [ADR-0012](/decisions/0012-chart-governance)'s
liability/equity/asset split is enforced end to end. The routing the keys *do* allow is exactly as
invisible, which is the section below.

**F3's internal ranking inverts.** The finding leads with the NULL cursor; the NULL cursor is the
**least** dangerous of the four NULLs, because `pinned_cursor` comes back NULL on every row and a
consumer reading the column it was given for exactly that purpose can detect it. A NULL **as-of
instant** or a NULL **period bound** leaves no evidence at all: the same all-zero face, with a
perfectly valid cursor stamped on every row. And the two statement functions return a **complete,
plausible, balancing** face while `trial_balance_at` returns zero rows, which at least looks like
nothing happened. *(The class itself reproduced: no reporting function is `STRICT`, `proacl` is NULL on
all five so `EXECUTE` is `PUBLIC`, `recon_equation_breaks(NULL,'infinity')` reports zero breaks, and the
A14 guard is vacuous for the very input that needs it because it carries the same
`e.xact_id < p_cursor` predicate as the body it guards — 10 entries visible to it at an honest cursor,
0 at a NULL one.)*

**F7's proposed re-pointing is refused three ways, and the finding overstates its reach.** *Adding* to
the current chart version works; changing what is already there does not:

```
--- a second presentation row for the same type
ERROR:  duplicate key value violates unique constraint "pk_presentation"
--- an UPDATE
ERROR:  chart_presentation is append-only: UPDATE on (row) refused. Correct it with a new row.
--- a DELETE-then-reinsert
ERROR:  chart_presentation is append-only: DELETE on (row) refused. Correct it with a new row.
--- and an fs_lines caption, which is what a reader actually reads
ERROR:  fs_lines is append-only: UPDATE on (row) refused. Correct it with a new row.
```

So a version's *existing* content really is frozen and only its *absent* content is open — and the
finding is right about the principle. One `fs_lines` row appended to version 3, the current
"deliberately open" version, changed an issued statement at identical coordinates: **eleven rows where
ten were issued**, with `chart_version` reading 3 and `pinned_cursor` reading 839 in both runs, and all
ten checks green afterwards. `chart_lint`'s `line_unreachable` rule does name the new line — at severity
`info`, which the summary does not count, and its own comment explains why: *"a chart may carry a line
ahead of the type that will use it."* **That reasoning is sound for a version being built and wrong for
a version being reported through, and the schema cannot tell the two apart because they are the same
version.** A *number* moves in exactly one reachable case: a type with posted entries and no
presentation row, where the transition is from a **refusal** to a statement — 500,000.00 appearing at
an identical `(cursor, version)` once the missing row is appended.

## The most severe reproduction needs no adversary at all

**F2(a) — a genuine close whose `ledger_period_closes` row was never inserted.** `fk_closes__txn_kind`
forces a close row to name a `kind='period_close'` transaction. **Nothing forces the converse, and
nothing could**: the transaction is written first, so there is no key from the journal into the period
record. `income_statement_for` excludes the closing transaction by key lookup —
`AND NOT EXISTS (SELECT 1 FROM ledger_period_closes c WHERE c.tenant_id = x.tenant_id AND c.transaction_id = x.id)`
— so with no close row the lookup finds nothing and **the close's own sweep, the entry whose whole job
is to zero revenue, is counted as operating activity.**

Written as `openledger_app`, the role the write path actually runs as. The sweep is the real thing:
revenue 250,000.00 out, expense 30,000.00 back, the net 220,000.00 into `retained_earnings`, balanced,
dated inside the period. August, before and after:

```
--- before (the control)                    --- after
     fs_line     |  side  | amount_minor         fs_line     |  side  | amount_minor
-----------------+--------+--------------   -----------------+--------+--------------
 revenue         | credit |       250000     revenue         | credit |            0
 cost_of_revenue | debit  |        30000     cost_of_revenue | debit  |            0
```

**And the balance sheet is correct to the unit, which is what makes it plausible** — the plug bounded
itself without reading `ledger_period_closes` at all, exactly as ADR-0011 §A3 designed: receivables
1,750,000, payables 30,000, customer funds 500,000, equity 1,000,000, retained earnings 220,000,
`current_year_earnings` 0, and it foots. All ten checks read zero, and the shipped sweep:

```
$ DATABASE_URL=... ./target/debug/openledger reconcile
book reconciled — 10 checks, 0 breaks, 35 ms
exit=0
```

**A period that earned 250,000.00 reports zero revenue and zero expense, the balance sheet is right,
and the sweep says the book reconciles.** Note *why* `checkpoint_drift` and `close_typing` are green:
for the same reason the income statement is wrong. **The three keys ADR-0011 added to type a close all
hang off the close row; delete the row from the picture and every one of them is vacuous.**

**F2(b) — a revenue transaction labelled `period_close` — also reproduced**, which is the second of the
two independent routes into this finding. ADR-0011 records the defect the three keys were meant to
close: *"The app role could name a REVENUE transaction and erase it from the income statement,
green."* **None of the three constrains what the named transaction contains**: `fk_closes__txn_kind`
checks `kind`, there is no `CHECK` on `ledger_transactions.kind` at all, and `kind` is one of the
columns the app role may `INSERT`. A 700,000.00 fee, ordinary in every respect except the label, named
by a **fully valid** close row — inside the period, `computed_at_xid` equal to the transaction's own
commit position, checkpoint computed exactly as `recon_checkpoint_breaks` recomputes it, all as
`openledger_app`:

```
--- 1. the journal says 950,000.00 of fee revenue in August
--- 2. the income statement says 250,000.00
--- 3. the balance sheet carries all of it and foots
--- 4. all ten checks at zero; reconcile: book reconciled — 10 checks, 0 breaks, 33 ms; exit=0
```

**700,000.00 of revenue erased from the income statement, on a book whose balance sheet is right to the
unit and whose sweep exits 0.**

**The bound on (b), honestly.** The three keys did narrow it, and the narrowing is real: `pk_closes`
allows **one** transaction per `(tenant, period, currency)`, `ck_closes__txn_in_period` requires it to
be dated inside the period, and `fk_closes__txn_kind` refuses a close row naming a transaction whose
kind is not `period_close`. On a deployment that closes every period promptly, (b) is a race for a slot
that is about to be taken. On one that does not close at all — the state of every deployment of this
artefact today, since nothing writes a close — every period is an open slot, and **(a) does not even
need the slot.**

**(a) is the more severe half and the finding under-rates it.** (b) needs a forged label and a forged
close row and wins one period; (a) needs an *honest* close and a *forgotten* insert, is a plain
omission rather than an attack, erases the whole period's income statement, and is what a
half-implemented close routine produces on its first run.

## F1 — the check that claims to watch the face cannot

**The algebra is the finding.** `lines` computes, per balance-sheet line,
`amount = SUM(CASE WHEN f.side = 'asset' THEN v ELSE -v END)`, and the check then forms
`gap = SUM(amount WHERE side='asset') - SUM(amount WHERE side IN ('liability','equity'))`. The second
subtraction re-flips the sign the first applied, so

```
gap = SUM(v over every posted, presented, in-scope position at the cursor)
```

which is zero on any journal that foots per `(tenant, currency)`. **Which line a position was routed to,
and which of the three sides that line carries, cancel out of the expression entirely.**

Demonstrated with a complete, well-formed chart version 4 that differs from version 3 in two
presentation rows, both staying **inside** the side their category declares — `customer_wallet` routed
to `payables`, `paid_in_capital` routed to `retained_earnings`:

```
 payables              | Accounts payable and accrued             | liability |       530000
 customer_funds        | Customer funds payable                   | liability |            0
 equity                | Shareholders equity                      | equity    |            0
 retained_earnings     | Retained earnings                        | equity    |      1000000
```

**Customer funds payable reads 0.00 against a true 500,000.00**, with the money inside "Accounts
payable and accrued" — precisely the defect the shipped seed spends an entire chart version correcting
for `ach_pull_returnable`, whose version-2 note says presenting customer money under trade payables
*"understates customer funds payable and overstates what the operator owes its suppliers."* **And
Shareholders equity reads 0.00 against a true 1,000,000.00 of contributed capital, now sitting in
Retained earnings** — a distributable-reserves claim the entity has not earned. `recon_equation_breaks`
at the same cursor returns **zero rows**, and all ten checks read zero: `chart_lint` is quiet because
version 4 presents every type, and `journal_to_reports` is quiet because its report side joins
`chart_presentation` on type, not on line.

**The bound, which is what makes this a claim about a comment rather than about SQL.** `gap_minor` is the
sum of every presented position, so the only way to move it is to remove a position from that sum or add
one with no opposite — and both are **journal-level**. Nothing inside the chart can move it: a position
cannot be routed across sides, onto the other statement, to a line with an unrecognised side, or to a
line that does not exist. The reachable classes are a transaction whose legs do not foot (also caught by
`unbalanced_transactions`), an entry dropped by the account or type join (`orphan_entries`), and legs
straddling the cursor (`cursor_forgery`). Confirmed empirically against the published red — a forged
single leg — where `gap_minor` and the direct sum of every presented position agree to the unit at
**−250**.

**So the check's claim to be "THE HIGHEST-LEVERAGE CHECK on the list" is not supported**, and the claim
is in the catalog and therefore in `schema/snapshot.txt` line 1778: *"The highest-leverage check -- no
journal-level test can falsify presentation (ADR-0011)."* Its own comment says it exists because *"a
balance sheet could be made wrong half a dozen ways (a mis-bounded plug, a mis-typed close, a swung
position netted away) with every break list green"* — **and it catches none of those three.** A mis-typed
close is F2, and the equation check is green on it. A swung position moves value between two
balance-sheet lines and cancels. **Severity is in the claim, not in the SQL**: an operator reading the
comment believes the face is checked. `FIX-NOTES.md` is explicit that there is no fix to the view
itself — no rewrite of the same inputs computes anything else — so the cheapest honest step is to correct
the comment, and the two declarative `chart_lint` rules that *are* expressible would have caught this
reproduction's `customer_wallet → payables` and would **not** have caught `paid_in_capital →
retained_earnings`, which is two `'none'`-scope equity types on two equity lines and is indistinguishable
from a legitimate chart by any rule over the chart alone.

## The finding nobody filed — `EXECUTE` is `PUBLIC`, so a scoped reader gets a green check over zero tenants

F9 was filed as *"a wrong or unauthorised `p_tenant` is answered with silence"*. The silence reproduced,
read as a `LOGIN` role inheriting `openledger_read`: its own tenant answers with the real face, while
`t2` (which exists and carries a posted 100,000 charge) and `t_does_not_exist` are **proven identical by
a two-way `EXCEPT ALL` rather than eyeballed** — and a typo'd chart version, by contrast, raises.

**But it is two mechanisms, not one, and only one of them is what the finding claims.** Run as the
**owner**, whom `FORCE ROW LEVEL SECURITY` deliberately does not bind, `t2` returns its real face — the
function was never unwilling — while `t_does_not_exist` still returns zero rows with no RLS in play. So
`t2` as the reader is RLS filtering the `scopes` CTE: the reader can see zero t2 accounts, so
`SELECT DISTINCT tenant_id, currency FROM ledger_accounts WHERE tenant_id = p_tenant` returns nothing and
the whole face collapses. **RLS held; no t2 datum reached the reader, so this is not an authorisation
defect** — calling it one overstates it. It is a denial reported as an empty book: low as confidentiality,
moderate as diagnostics, because an integrator's dashboard renders a legitimate-looking all-zero balance
sheet for a tenant it merely lacks scope for. Both collapse onto a third, legitimate case — a real tenant
with no accounts yet — which the baseline's own `scopes` comment already admits.

**The consequence the finding did not name is the worst of them, and it is the cheapest thing on the fix
list.** `EXECUTE` really is `PUBLIC` on all five functions and all five are `SECURITY INVOKER`, which
buys almost nothing — the caller's own grants and policies still gate every read. It buys **one** thing.
The reader is *not* granted the `reconciliation` view (`ERROR: permission denied for view
reconciliation`) and can nonetheless run the sweep's own highest-leverage check directly, getting a
**green** answer scoped to one tenant out of two — and with the GUC unset, green over **no tenants at
all**, because the `tenants AS (SELECT DISTINCT tenant_id FROM ledger_accounts)` CTE is emptied by RLS and
the `HAVING` clause has nothing to fail:

```
 accounts_visible                     → 0        against the owner running the same check:
 breaks_seen_by_an_unscoped_reader    → 0         t1 | 10 balance-sheet rows
 t1_balance_sheet_rows                → 0         t2 | 10 balance-sheet rows
```

**That is "a green check that did not execute"** — verbatim the failure the `reconciliation` view's own
comment says it exists to prevent, and the RLS comment's *"a sweep silently scoped to no tenant would
report zero breaks on every book, which is this project's nightmare shape"* — reachable by any role with
`USAGE` on the schema. It cannot mislead the shipped sweep, which `SET ROLE openledger_recon` and reads
the owner-executed view. It can mislead anything else that calls the function. Two lines in a migration
revoke it.

**F9's second half is [spike 019](/spikes/019-read-path-contract)'s unpinned row set, reached
independently.** Cursor captured as a literal (839 in one run, 859 in another, each after the horizon
settled), one EUR house account opened and nothing posted to it: **10 rows → 20 rows**, two currency
blocks where there was one, at the identical literal cursor. Nothing was lost
(`usd_rows_that_moved = 0`), and no check notices — nor could one: `recon_equation_breaks` groups by
`(tenant_id, currency)` and the EUR block is assets 0, liabilities-plus-equity 0, so the `HAVING` clause
is satisfied by construction. **A cursor-pinned statement is reproducible in its numbers and not in its
face**, and the effect is not confined to a new currency: opening the first account for a wholly new
tenant makes that tenant reportable at an already-issued cursor.

## F4 and F5 must be fixed as a pair, and that is what constrains the fix

**F4 — `recon_journal_to_reports` does not foot.** The `classified` CTE buckets `out_of_window` out of
`reported_debits`; the CTE that produces `tb_debits` joins transactions, accounts, types and
`chart_presentation` and carries **no `effective_at` predicate at all**. So exactly two error classes can
move `unexplained = reported − tb`, and they have **opposite signs** — an out-of-window entry pushes it
down, an entry on a type with no presentation row at the current version pushes it up. All three parts
reproduced:

1. **The false positive.** One balanced posted transaction dated `2226-01-01` — a fat-fingered year, which
   `ck_txn__effective_finite` permits since only ±infinity is refused — on an otherwise clean book gives
   `out_of_window_debits 70000`, `reported_debits 1780000`, `tb_debits 1850000` and
   `unexplained_debits −70000`, with `journal_to_reports: 1` the only check that moved, exit 1 — **while
   the reports are correct, the face foots, and both statement-side checks are empty.** The suite already
   pins the non-footing as intended: `an_out_of_window_posting_is_a_journal_to_reports_break` asserts
   `unexplained_debits = -700`, so the arithmetic is not an accident and not a regression. **What the
   view's own header claims about itself and what the suite pins are different statements, and the
   suite's is the true one.**
2. **The compensating error.** A chart version 4 that drops the `platform_rev_share_expense` /
   `platform_rev_share_payable` presentation rows, plus one 2226-dated transaction for exactly 30,000 —
   the rev-share sub-book's turnover on each side — gives `unexplained_debits 0` and
   `unexplained_credits 0`, with `tb_debits = 1780000` **byte-identical to the negative control's**,
   while a whole balanced sub-book (30,000 each side) sits outside the presented population. **The one
   check whose stated job is the dropped balanced sub-book reads zero on a book that has one.** The
   limits, exactly: the summary cannot be read at all, because F5's raise fires first, so the nine
   non-raising branches had to be spelled out one at a time; and `chart_lint.type_unpresented` fires two
   error rows, naming the chart rather than the money. **The compensation matters most as a dependency** —
   `journal_to_reports` is only redundant here because F5's raise and `chart_lint` happen to cover the
   same ground.
3. **The wall-clock dependence.** One honest balanced posted transaction, 33,000, effective twenty-five
   seconds above the bound. Red first — the whole 330.00 disclosed as `out_of_window`,
   `unexplained_debits −33000`, sweep exit 1 — then a bounded server-side poll on the *bucket* that writes
   nothing (125 polls of 0.2 s in the view run, 183 in the sweep run), and **the break repaired itself**:
   ten checks at zero, `out_of_window_debits 0`, `unexplained_debits 0`, sweep exit 0, with events,
   transactions, entries, journal high-water mark and cache all provably unchanged between the two
   readings. Two entries four minutes apart in effective date, identical in every other respect, land on
   opposite sides of the verdict. **And the direction of drift is the wrong one**: `now()` only moves
   forward, so the only clock-driven transition is `out_of_window → reported`. A break of this class
   **always self-heals and never appears** — the fat-fingered date the bucket exists to surface ends up
   reported into every statement forever, and the sweep goes green on its own with no write and no
   operator action. One incidental fact worth recording: `now()` is the *transaction* timestamp, so the
   classification is stable inside one transaction and unstable between them — stable exactly where it
   does not need to be, and unstable in the one dimension a re-runnable check must be stable in. ADR-0011
   makes the commit horizon a parameter for precisely this reason, and this window bound was left
   ambient.

**F5 — one unpresented account type turns the whole `reconciliation` view into an error.** `reconciliation`
counts `recon_equation_breaks`, which `CROSS JOIN LATERAL`s `balance_sheet_at` per tenant, which `RAISE`s
on A14 — and a `RAISE` inside one branch of a `UNION ALL` aborts the whole statement. The state is a
chart version 4 that is complete except for one presentation row, for a type carrying 500,000.00 of
posted entries:

```
$ psql -c 'SELECT * FROM reconciliation'
ERROR:  chart version 4 does not present every account type with posted entries as at this instant (chart_lint.type_unpresented)
CONTEXT:  PL/pgSQL function balance_sheet_at(...) line 26 at RAISE
```

No rows. **Not nine rows and a gap — nothing.** And two of the nine surviving checks are RED, read one
branch at a time: `journal_to_reports: 1` and `chart_lint: 1`, the latter naming the identical fact the
`RAISE` message itself cites. **The one check that diagnoses the problem is killed by the problem.** Exit
1 is correct and deliberate — `failure.rs` maps `Failed` and `Drift` to the same code because *"an
operator reads the error first"* — so the exit code is not the defect. What the operator loses is the nine
other results, the `EXPECTED_CHECKS = 10` assertion that never runs because the `SELECT` never returns,
and the diagnosis, which is present in `chart_lint` and unreachable. The failure is version-scoped rather
than permanent — the same statement at version 3 still returns ten rows — so the remedy exists; it is just
not visible from the interface an operator is told to use.

**The coupling, stated because it constrains the fix.** F4's window fix inverts the assertion
`an_out_of_window_posting_is_a_journal_to_reports_break` currently pins, and `journal_to_reports` then
loses its only red path in that file — its remaining red path is the presentation divergence, which
converges with F5's A14 raise. **So F4 and F5 must land together, or `journal_to_reports` has no reachable
red at all** and becomes the thing this project fears most. `FIX-NOTES.md` also records that F4's
disclosure half is the one fix on the list that moves the check count: `EXPECTED_CHECKS` 10 → 11, the e2e
oracle's ten, and `ALL_CHECKS`. F5's cheaper shape is a crate change with no migration and no snapshot
move — read the nine non-raising checks first and report the raise as an eleventh outcome — which turns
*"the operator sees nothing"* into *"the operator sees nine results and a named refusal"*, at the cost of
the one-snapshot guarantee unless the sweep takes the `REPEATABLE READ` transaction ADR-0010's own comment
says is *"declared for the day the sweep grows a second statement."*

## Two one-sided bounds, and a stranger's transaction

**F8 — `computed_at_xid` is bounded from below only, and the app role may supply it.** `recon_close_breaks`
tests one thing, `c.computed_at_xid < x.xact_id`, so a cursor at or above the closing transaction's commit
position passes and *"at or above"* has no ceiling; `close_disclosures` selects arrivals **above** the
stored cursor, so a cursor at the top of the `xid8` range makes that view permanently empty for the
period. **This reproduction carries its own control** — two tenants, two honest closes of August, differing
in `computed_at_xid` and in nothing else, both written as `openledger_app`:

```
 tenant_id | period_code |   computed_at_xid    | txn_xact_id | horizon_now
-----------+-------------+----------------------+-------------+-------------
 t1        | 2026-08     | 18446744073709551615 |         919 |         920
 t2        | 2026-08     |                  919 |         919 |         920
```

`recon_close_breaks` is green on both. Then one backdated arrival into each closed August — which ADR-0011
says is *"normal, and a refused one is money that exists nowhere"* — and **t2 discloses its two entries
while t1 has nothing to disclose and never will.** The IAS 1.41-shaped disclosure is silently switched off
for that period by one column value, written by the role the write path runs as.

**The limit: the arrival is not silent, it is misdiagnosed.** Because the stored cursor is unbounded,
`recon_checkpoint_breaks`' recompute is unbounded too, so the arrival lands inside the recompute and
`checkpoint_drift` reports two `value_drift` rows against a checkpoint that was correct when it was
written — while `close_typing`, the check that exists for exactly the cursor-to-close relationship, stays
green. ADR-0010's disposition table says the checkpoint is derived and rebuildable, so **the natural
operator response is to rebuild the checkpoint from the forged cursor, which returns the book to green and
leaves the disclosure off.** So the finding's mechanism is exactly right and its consequence needs one word
changed: a later backdated arrival goes **unenumerated**, not unnoticed.

**F10 — `recon_cursor_breaks`' stated justification is wrong.** Two comments in one file, about the same
function, forty lines apart. `recon_cursor_breaks` says an `xact_id` at or above the current snapshot's
xmin cannot belong to a committed row, because *"a committed row's commit position is always retired below
the horizon by the time the sweep runs"*; `report_cursor()` says `pg_snapshot_xmin` is the **cluster's**
horizon, so one long-running transaction anywhere on the server — another database included — holds every
new report's cursor back, *"lag, never wrongness"*. **They cannot both be right.** With a held transaction
in a second database on the same instance and one honest commit on the book:

```
    reason     | count            entry_id (2 rows) | xact_id | txn_xact_id |    reason
---------------+-------           ------------------+---------+-------------+---------------
 above_horizon |     2                          ... |     788 |         787 | above_horizon

 cursor_forgery |  2   in the ten-check summary; the shipped sweep exits 1
```

The entry is honest in every respect — committed, balanced, cache-consistent, `xact_id` taken from its own
`DEFAULT`, and `788 > 787` exactly as a legitimately appended leg should be. **The verdict is
`above_horizon` because a database this book has never heard of has a transaction open**, and the operator
is handed the word "forgery". The project knows about the transient — the e2e suite tolerates it, and one
helper even names the neighbour in its timeout message — but every one of those places treats it as *this
book's own* concurrent writers, bounded by the writers finishing. **The cause reproduced here is unbounded
by anything this deployment controls**, and the shipped sweep carries no wait at all.

**The candidate fix was evaluated in place, as a query beside the shipped one, never as DDL.**
`pg_snapshot_xmax` is one past the highest xid that has been *assigned*, so every committed row is strictly
below it regardless of who holds an old transaction open:

```
--- with the neighbour holding, on the honest book        --- and after appending a far-future forged xact_id
      bound       | breaks                                      bound       | breaks
------------------+--------                              ------------------+--------
 xmin (shipped)   |      2                                xmin (shipped)   |      4
 xmax (candidate) |      0                                xmax (candidate) |      2
```

**The substitution removes the false positive and keeps the forgery**, with the comparison operator changing
alongside it (`> xmin` becomes `>= xmax`). What it gives up, stated so it is a choice rather than an
oversight: an `xact_id` forged into the narrow band of currently-in-flight ids is no longer caught. That
band is bounded by concurrency rather than by time, and the forgeries that buy anything lie below the
horizon (still caught by the second predicate) or far above it (still caught). **`pg_snapshot_xmax` must
not be substituted into `report_cursor()`**, which is the same expression serving a different question: a
report pinned at xmax would include rows still in flight.

---

## The pattern under the list

**Six of the eleven ranked rows are the same defect wearing different clothes: a check whose green means
"I found nothing" and whose green also means "I could not look."** F3's NULL cursor, F5's raise, F8's
unbounded cursor, F9's RLS-emptied tenant set, F4's self-healing window and F1's cancelling identity are
all the shape [ADR-0004](/decisions/0004-where-logic-lives) named — *"there was nothing left to disagree
with — silence read as assent"* — reached by six different routes. The `reconciliation` view's own header
says it exists to prevent exactly this, and **it prevents it only for the case of a check row going
missing.**

**The second pattern is narrower and is the auditor's real contribution: the keys ADR-0011 and ADR-0012
added are sound, and they all guard the same side of their relationship.** `fk_closes__txn_kind` constrains
what a close row may name and not what the named transaction contains. `fk_presentation__fs_line`
constrains which side a line sits on and not which line a position belongs on. `recon_close_breaks` bounds
`computed_at_xid` below and not above. `refuse_stale_chart_version` freezes versions below the maximum and
not the maximum. **In every case the unguarded side is where the reproduction went.**

## Severity, as the spike ranked it

Ranked by what a wrong number costs a reader who trusts the ten green checks, and how cheaply the state is
reached. **Reachability is stated as the role that can reach it, because that is the difference between a
bug and an attack.**

| # | finding | verdict | reachable by | what the reader is told |
| --- | --- | --- | --- | --- |
| **1** | **F2(a)** — a genuine close with no close row | REPRODUCED | `openledger_app`, and by **omission**, not attack | a period that earned reports **0.00 revenue and 0.00 expense**; ten checks green; sweep exits 0 |
| **2** | **F5** — one unpresented type errors the summary | REPRODUCED | anyone who can append a chart version | `SELECT * FROM reconciliation` returns **nothing**, hiding two real reds including the one that names the cause |
| **3** | **F1** — the equation check is an identity | REPRODUCED (mechanism refuted, substance reproduced) | anyone who can append a chart version | customer funds payable **0.00 against a true 500,000.00**; the check that claims to watch the face cannot |
| **4** | **F2(b)** — a fee labelled `period_close` | REPRODUCED | `openledger_app` | **700,000.00 of revenue erased** from the income statement, balance sheet correct, sweep exits 0 |
| **5** | **F4** — `recon_journal_to_reports` does not foot | REPRODUCED | any writer with a fat-fingered date | a break that **self-heals with the wall clock**, and a real dropped sub-book that reads zero |
| **6** | **F6** — the inverted `numeric` defect | REFUTED as filed | the **shipped writer over HTTP**, six calls | `trial_balance_at` raises `bigint out of range` on a legal book; the statement dies rather than reporting |
| **7** | **F3** — no function guards its parameters | REPRODUCED | any caller | a **complete, plausible, balancing** all-zero statement, and a green check that did not execute |
| **8** | **F9** — silence, and the shape is not pinned | REPRODUCED WITH LIMITS | any reader | a green `recon_equation_breaks` over **zero tenants**; a wrong tenant answered as an empty book |
| **9** | **F10** — the cursor check's justification | REPRODUCED | a **stranger's** transaction on the same cluster | `cursor_forgery` on an honest book, for as long as the neighbour holds; the word is "forgery" |
| **10** | **F8** — `computed_at_xid` unbounded above | REPRODUCED WITH LIMITS | `openledger_app` | `close_disclosures` permanently empty; the first arrival is **misdiagnosed** as checkpoint drift |
| **11** | **F7** — the current chart version is open | REPRODUCED WITH LIMITS | anyone who can append to the chart | an issued statement at a fixed `(cursor, version)` gains a line; numbers move only from a refusal |

Eleven rows for ten subjects, because F2 reproduced twice by two independent routes.

## What this spike did not do

- **It built nothing.** No SQL in this spike modifies the shipped schema, and where a fix had to be
  evaluated the candidate expression was run **as a query, side by side with the shipped one**, inside a
  scratch database — never as DDL against a migration. Every fix in `FIX-NOTES.md` is costed and none is
  applied; `migrations/00004` is the pending work.
- **It measured nothing.** No timing runs, no configurations compared, no loadavg recorded. Severity here
  is about what a reader is told, not about what anything costs to run.
- **It could not run on the shared cluster**, so nothing here is evidence about the shared cluster's own
  book — the accidental `cursor_forgery: 12` capture is the only thing read from it.
- **The fix shapes were argued, not tried.** F5's two candidate shapes — a per-tenant exception handler
  inside the check, or reading the nine non-raising checks first in the sweep — and the `p_strict`
  parameter that would let an issued statement and a sweep ask different things of the same function are
  reasoning in `FIX-NOTES.md`, with no code behind them. The only candidate expression actually run beside
  its shipped counterpart is F10's `pg_snapshot_xmax` substitution.
- **Nothing was proved about a deployment that closes its periods.** Both halves of F2 are cheapest on a
  book with no closes at all, which is every deployment of this artefact today, and the interaction between
  a real close routine and either half is unexplored.
