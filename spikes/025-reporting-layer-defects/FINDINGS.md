# Spike 025 — findings

Ten findings, each headed **REPRODUCED**, **REPRODUCED WITH LIMITS** or **REFUTED**. The negative
control for every one of them is the ten-row summary in `SPEC.md`; where a finding claims the checks
stay green, all ten rows are pasted here.

**The count.** Eight reproduced (three of them with limits stated exactly), one refuted outright,
and one — F2 — reproduced twice by two independent routes, which is why the ranking at the end has
eleven rows for ten findings.

Three things are worth reading before the list.

**Two of the auditor's proposed injections are unwritable.** F1's cross-side routing is refused by
`fk_presentation__fs_line`, and F7's re-pointing of an existing presentation row is refused three
different ways. In both cases the finding's *substance* survives by a route the keys do leave open,
and both the refusal and the substitute are recorded.

**F6 is refuted outright, and the defect is inverted.** `SUM(bigint)` returns `numeric` in
PostgreSQL, so the three "unprotected" aggregates were never at risk — `schema/snapshot.txt` has
recorded `trial_balance.debits: numeric` since M1. The two functions the finding holds up as *fixed*
are the two that raise `bigint out of range` on a legal book, because they cast the total back to a
declared `bigint`. The state was reached through the shipped writer over HTTP in six calls.

**One finding came back stronger than it was filed.** F9's `EXECUTE … TO PUBLIC` half hands any role
with schema `USAGE` a **green** `recon_equation_breaks` over zero tenants — verbatim the *"green check
that did not execute"* the `reconciliation` view and the RLS block both say they exist to prevent.
That is not what the finding claimed, and it is the cheapest thing on the fix list.

---

## F1 — `recon_equation_breaks` is an algebraic identity that cannot falsify a presentation defect

### REPRODUCED — with the proposed injection REFUTED and replaced

**The algebra first, because it is the finding.** `lines` computes, per balance-sheet line,
`amount = SUM(CASE WHEN f.side = 'asset' THEN v ELSE -v END)`, and the check then forms
`gap = SUM(amount WHERE side='asset') - SUM(amount WHERE side IN ('liability','equity'))`. The
second subtraction re-flips the sign the first applied, so

```
gap = SUM(v over asset lines) + SUM(v over liability/equity lines) - plug
    = SUM(v over balance-sheet positions) + SUM(v over revenue/expense positions)
    = SUM(v over every posted, presented, in-scope position at the cursor)
```

which is zero on any journal that foots per (tenant, currency). **Which line a position was routed
to, and which of the three sides that line carries, cancel out of the expression entirely.** The
auditor's reading is correct.

### Part 1 — the proposed injection is REFUTED by three keys

The finding asks for a liability type presented on a balance-sheet line whose `side` is `'asset'`.
`chart_presentation.fs_side` is a `GENERATED` column derived from `category` and carried into
`fk_presentation__fs_line`, so the line a presentation row names must carry the same side. Attempted
in a new (therefore open) chart version 4:

```
--- ...onto an asset-side line
ERROR:  insert or update on table "chart_presentation" violates foreign key constraint "fk_presentation__fs_line"
DETAIL:  Key (chart_version, fs_line, fs_statement, fs_side)=(4, receivables, balance_sheet, liability) is not present in table "fs_lines".

--- ...onto an income-statement line (fs_statement is generated too)
ERROR:  insert or update on table "chart_presentation" violates foreign key constraint "fk_presentation__fs_line"
DETAIL:  Key (chart_version, fs_line, fs_statement, fs_side)=(4, revenue, balance_sheet, liability) is not present in table "fs_lines".

--- ...nor can a balance-sheet line carry a side outside the three-valued split
ERROR:  new row for relation "fs_lines" violates check constraint "ck_fs_lines__side_matches_statement"
DETAIL:  Failing row contains (4, limbo, Limbo, balance_sheet, debit, 999).
```

So the specific mechanism the finding names — *"routing a liability position to an asset-side line
moves it from `liab_equity_minor` into `assets_minor`"* — **cannot be written**. The
liability/equity/asset split introduced by ADR-0012 is enforced end to end.

### Part 2 — the routing the keys DO allow is exactly as invisible

Chart version 4 below is a complete, well-formed chart that differs from version 3 in two
presentation rows, both staying **inside** the side their category declares:

```sql
INSERT INTO chart_presentation (chart_version, type_code, category, counterparty_scope,
                                fs_line, fs_line_contra)
SELECT 4, type_code, category, counterparty_scope,
       CASE type_code WHEN 'customer_wallet'  THEN 'payables'
                      WHEN 'paid_in_capital'  THEN 'retained_earnings'
                      ELSE fs_line END,
       fs_line_contra
FROM chart_presentation WHERE chart_version = 3;
```

The face at the same cursor, under the new current version:

```
        fs_line        |                 caption                  |   side    | amount_minor
-----------------------+------------------------------------------+-----------+--------------
 cash                  | Cash and cash equivalents                | asset     |            0
 restricted_cash       | Restricted cash                          | asset     |            0
 receivables           | Accounts receivable                      | asset     |      1750000
 other_assets          | Other assets                             | asset     |            0
 payables              | Accounts payable and accrued             | liability |       530000
 customer_funds        | Customer funds payable                   | liability |            0
 borrowings            | Borrowings                               | liability |            0
 equity                | Shareholders equity                      | equity    |            0
 retained_earnings     | Retained earnings                        | equity    |      1000000
 current_year_earnings | Undistributed earnings (since inception) | equity    |       220000
(10 rows)
```

**Customer funds payable reads 0.00 against a true 500,000.00**, and the money is inside "Accounts
payable and accrued" — which is precisely the defect the shipped seed spends an entire chart version
correcting for `ach_pull_returnable`, whose version-2 note says presenting customer money under
trade payables *"understates customer funds payable and overstates what the operator owes its
suppliers."* **Shareholders equity reads 0.00 against a true 1,000,000.00 of contributed capital,
now sitting in Retained earnings** — a distributable-reserves claim the entity has not earned.

`recon_equation_breaks` at the same cursor:

```
 tenant_id | currency | assets_minor | liab_equity_minor | gap_minor
-----------+----------+--------------+-------------------+-----------
(0 rows)
```

And the whole summary:

```
       check_name        | breaks
-------------------------+--------
 balance_cache           |      0
 orphan_entries          |      0
 unbalanced_transactions |      0
 cross_scope_mirror      |      0
 journal_to_reports      |      0
 checkpoint_drift        |      0
 close_typing            |      0
 cursor_forgery          |      0
 accounting_equation     |      0
 chart_lint              |      0
(10 rows)
```

`chart_lint` is quiet because version 4 presents every type; `journal_to_reports` is quiet because
its `r` side joins `chart_presentation` on type, not on line.

### The bound: what the check CAN still catch

`gap_minor` is the sum of every presented position, so the only way to move it is to remove a
position from that sum or to add one with no opposite. Both are **journal-level**, not
presentation-level, and the reachable sub-classes are:

| class | also caught by |
| --- | --- |
| a posted transaction whose legs do not foot per (tenant, currency) | `unbalanced_transactions` |
| an entry dropped by the account or account-type join | `orphan_entries` |
| legs of one transaction straddling the report cursor | `cursor_forgery` |

Nothing inside the chart can move it: a position cannot be routed across sides
(`fk_presentation__fs_line`), cannot be routed onto the other statement (`fs_statement` is
generated), cannot be routed to a line with an unrecognised side
(`ck_fs_lines__side_matches_statement`), cannot be routed to a line that does not exist
(`fk_presentation__fs_line_contra` pins the contra line too), and cannot fall between `lines` and
`plug` — because `p.category IN ('revenue','expense')` and `f.statement = 'income_statement'` are
the same predicate expressed twice, tied together by the same generated column.

Confirmed empirically. The published red — `crates/e2e/tests/e2e/reconcile.rs:585`, a forged single
leg — is the journal-does-not-foot class, and its own doc comment says so: *"the equation check
exists for PRESENTATION bugs, which live in the statement functions this suite cannot honestly
mutate."* Reproduced on this book (`REPRO/F1b_what_the_equation_check_sees.sql`):

```
 tenant_id | currency | assets_minor | liab_equity_minor | gap_minor
-----------+----------+--------------+-------------------+-----------
 t1        | USD      |      1750000 |           1750250 |      -250

       check_name        | breaks
-------------------------+--------
 unbalanced_transactions |      1
 accounting_equation     |      1
 ...the other eight at 0

--- the sum of every posted, presented, in-scope position at this cursor
 tenant_id | currency | sum_of_every_presented_position
-----------+----------+---------------------------------
 t1        | USD      |                            -250
 t2        | USD      |                               0
```

`gap_minor` and the direct sum agree to the unit, which is the identity stated as a measurement.

**So the check's claim to be "THE HIGHEST-LEVERAGE CHECK on the list" is not supported** — a claim
that is also in the catalog and therefore in `schema/snapshot.txt` line 1778: *"The highest-leverage
check -- no journal-level test can falsify presentation (ADR-0011)."* Every red it can produce **is**
a journal-level test's red. Its own
comment says it exists because *"a balance sheet could be made wrong half a dozen ways (a
mis-bounded plug, a mis-typed close, a swung position netted away) with every break list green"* —
and it catches none of those three. A mis-typed close is F2, and the equation check is green on it
(below). A swung position netted away moves value between two balance-sheet lines and cancels. Every
red it can produce is already produced by a journal-level break list in the same sweep. Severity is
in the *claim*, not in the SQL: an operator reading the comment believes the face is checked.

---

## F2 — the close is keyed in one direction only

### (a) A genuine close with no close row — REPRODUCED

`fk_closes__txn_kind` forces a `ledger_period_closes` row to name a `kind='period_close'`
transaction. Nothing forces the converse, and nothing could: the transaction is written first, so
there is no key from the journal into the period record.

`income_statement_for` excludes the closing transaction by key lookup —

```sql
AND NOT EXISTS (SELECT 1 FROM ledger_period_closes c
                WHERE c.tenant_id = x.tenant_id AND c.transaction_id = x.id)
```

— so with no close row the lookup finds nothing and the close's own sweep, the entry whose whole job
is to zero revenue, is **counted as operating activity**.

Written as `openledger_app`, the role the write path actually runs as: `kind` is in the app role's
column-level `INSERT` grant on `ledger_transactions`, and `ledger_periods` /
`ledger_period_closes` are under a table-wide one.

```
  current_user
----------------
 openledger_app

--- no close row was written:
 close_rows
------------
          0

--- and nothing refuses the transaction that should have one:
 tenant_id |     kind     | status |      effective_at
-----------+--------------+--------+------------------------
 t1        | period_close | posted | 2026-08-31 00:00:00+00
```

August, before and after. The sweep is the real thing — revenue 250,000.00 out, expense 30,000.00
back, the net 220,000.00 into `retained_earnings`, balanced, dated inside the period.

```
--- before (the control)                    --- after
     fs_line     |  side  | amount_minor         fs_line     |  side  | amount_minor
-----------------+--------+--------------   -----------------+--------+--------------
 revenue         | credit |       250000     revenue         | credit |            0
 cost_of_revenue | debit  |        30000     cost_of_revenue | debit  |            0
 credit_losses   | debit  |            0     credit_losses   | debit  |            0
 interest        | debit  |            0     interest        | debit  |            0
```

**And the balance sheet is correct, which is what makes it plausible** — the plug bounded itself
without reading `ledger_period_closes` at all, exactly as A3 designed:

```
        fs_line        |   side    | amount_minor
-----------------------+-----------+--------------
 receivables           | asset     |      1750000
 payables              | liability |        30000
 customer_funds        | liability |       500000
 equity                | equity    |      1000000
 retained_earnings     | equity    |       220000
 current_year_earnings | equity    |            0
 (cash, restricted_cash, other_assets, borrowings all 0)
(10 rows)
```

All ten checks, and the shipped sweep:

```
       check_name        | breaks
-------------------------+--------
 balance_cache           |      0
 orphan_entries          |      0
 unbalanced_transactions |      0
 cross_scope_mirror      |      0
 journal_to_reports      |      0
 checkpoint_drift        |      0
 close_typing            |      0
 cursor_forgery          |      0
 accounting_equation     |      0
 chart_lint              |      0
(10 rows)

$ DATABASE_URL=... ./target/debug/openledger reconcile
book reconciled — 10 checks, 0 breaks, 35 ms
exit=0
```

**A period that earned 250,000.00 reports zero revenue and zero expense, the balance sheet is right,
and the sweep says the book reconciles.** Note that `checkpoint_drift` and `close_typing` are green
for the same reason the income statement is wrong: with no close row there is nothing for either to
check. The three keys ADR-0011 added to type a close all hang off the close row; delete the row from
the picture and every one of them is vacuous.

### (b) A revenue transaction labelled `kind='period_close'` — REPRODUCED

ADR-0011 records the defect this was meant to close: *"The app role could name a REVENUE transaction
and erase it from the income statement, green."* Three keys were added. **None of them constrains
what the named transaction contains** — `fk_closes__txn_kind` checks `kind`, and `kind` is a
caller-supplied string:

```
--- there is no CHECK on ledger_transactions.kind at all
          conname          |                       pg_get_constraintdef
---------------------------+---------------------------------------------------------------
 ck_txn__effective_finite  | CHECK (((effective_at > '-infinity'::timestamptz) AND ...))
 ck_txn__no_self_reference | CHECK (((id IS DISTINCT FROM reverses_id) AND ...))
 ck_txn__not_both          | CHECK ((NOT ((reverses_id IS NOT NULL) AND ...)))
 ck_txn__tenant_non_empty  | CHECK ((btrim(tenant_id) <> ''::text))
(4 rows)

--- and `kind` is one of the columns the app role may INSERT
                                    app_insertable_columns
-------------------------------------------------------------------------------------------
 effective_at, event_id, external_ref, id, kind, metadata, resolves_id, reverses_id, status, tenant_id
```

A 700,000.00 fee, ordinary in every respect except the label, named by a **fully valid** close row —
`ck_closes__txn_in_period` satisfied (2026-08-28 is inside August), `computed_at_xid` equal to the
transaction's own commit position so `recon_close_breaks` passes, and a checkpoint computed exactly
as `recon_checkpoint_breaks` recomputes it. All as `openledger_app`.

```
--- 1. the journal says 950,000.00 of fee revenue in August
   purpose   | credits
-------------+---------
 fee_revenue |  950000

--- 2. the income statement says 250,000.00
     fs_line     |  side  | amount_minor
-----------------+--------+--------------
 revenue         | credit |       250000
 cost_of_revenue | debit  |        30000
 credit_losses   | debit  |            0
 interest        | debit  |            0

--- 3. the balance sheet carries all of it, and foots
        fs_line        |   side    | amount_minor
-----------------------+-----------+--------------
 receivables           | asset     |      2450000
 payables              | liability |        30000
 customer_funds        | liability |       500000
 equity                | equity    |      1000000
 retained_earnings     | equity    |            0
 current_year_earnings | equity    |       920000

--- 4. all ten checks
 balance_cache 0 | orphan_entries 0 | unbalanced_transactions 0 | cross_scope_mirror 0
 journal_to_reports 0 | checkpoint_drift 0 | close_typing 0 | cursor_forgery 0
 accounting_equation 0 | chart_lint 0        (10 rows)

$ ./target/debug/openledger reconcile
book reconciled — 10 checks, 0 breaks, 33 ms
exit=0
```

**700,000.00 of revenue erased from the income statement, on a book whose balance sheet is right to
the unit and whose sweep exits 0.**

### The bound on (b), honestly

The three keys did narrow it, and the narrowing is real:

```
--- a second erasure in the same period
ERROR:  duplicate key value violates unique constraint "pk_closes"
DETAIL:  Key (tenant_id, period_code, currency)=(t1, 2026-08, USD) already exists.

--- a close row naming a transaction whose kind is not period_close (t2, August still open)
ERROR:  insert or update on table "ledger_period_closes" violates foreign key constraint "fk_closes__txn_kind"
DETAIL:  Key (tenant_id, transaction_id, closing_kind)=(t2, 01a05d75-59a3-71c0-b3dd-a44d410322d9, period_close) is not present in table "ledger_transactions".
```

So: **one** transaction per (tenant, period, currency), it must be dated inside the period, and only
where no genuine close row already holds the slot. On a deployment that closes every period
promptly, (b) is a race for a slot that is about to be taken. On one that does not close at all — the
state of every deployment of this artefact today, since nothing writes a close — every period is an
open slot, and (a) does not even need the slot.

**(a) is the more severe half and the finding under-rates it.** (b) needs a forged label and a
forged close row and wins one period; (a) needs an *honest* close and a *forgotten* insert, is a
plain omission rather than an attack, erases the whole period's income statement, and is what a
half-implemented close routine produces on its first run.

---

## F3 — a NULL cursor yields a complete, all-zero, perfectly balanced statement

### REPRODUCED — and the NULL cursor is the least dangerous of the four NULLs

No reporting function is `STRICT` and none guards any parameter:

```
        proname        | security_definer | is_strict |  acl
-----------------------+------------------+-----------+--------
 balance_sheet_at      | f                | f         | (null)
 income_statement_for  | f                | f         | (null)
 recon_equation_breaks | f                | f         | (null)
 report_cursor         | f                | f         | (null)
 trial_balance_at      | f                | f         | (null)
(5 rows)
```

`proacl` NULL means default privileges, which for a function is `EXECUTE` to `PUBLIC`. Confirmed
directly rather than inferred:

```
                                            fn                                             | execute_to_public
-------------------------------------------------------------------------------------------+-------------------
 balance_sheet_at(text,timestamp with time zone,xid8,integer)                              | t
 income_statement_for(text,timestamp with time zone,timestamp with time zone,xid8,integer) | t
 recon_equation_breaks(xid8,timestamp with time zone)                                      | t
 report_cursor()                                                                           | t
 trial_balance_at(text,timestamp with time zone,timestamp with time zone,xid8)             | t
```

`balance_sheet_at('t1','infinity', NULL)` — the full face, at zero, and it balances:

```
        fs_line        |   side    | amount_minor | pinned_cursor
-----------------------+-----------+--------------+---------------
 cash                  | asset     |            0 |        (null)
 restricted_cash       | asset     |            0 |        (null)
 receivables           | asset     |            0 |        (null)
 other_assets          | asset     |            0 |        (null)
 payables              | liability |            0 |        (null)
 customer_funds        | liability |            0 |        (null)
 borrowings            | liability |            0 |        (null)
 equity                | equity    |            0 |        (null)
 retained_earnings     | equity    |            0 |        (null)
 current_year_earnings | equity    |            0 |        (null)
(10 rows)

 assets | liab_equity | gap
--------+-------------+-----
      0 |           0 |   0
```

`income_statement_for` the same, and the A14 guard is vacuous for exactly the input that needs it,
because the guard carries the same `e.xact_id < p_cursor` predicate as the body it guards:

```
 entries_a14_can_see_at_an_honest_cursor      entries_a14_can_see_at_a_null_cursor
-----------------------------------------    --------------------------------------
                                      10                                         0
```

`recon_equation_breaks(NULL, 'infinity')` — the green-check-that-did-not-execute, with nothing at all
to distinguish it from a healthy book:

```
 tenant_id | currency | assets_minor | liab_equity_minor | gap_minor
-----------+----------+--------------+-------------------+-----------
(0 rows)

 breaks_reported
-----------------
               0
```

### The refinement the finding missed: `pinned_cursor` tells, and the other three NULLs do not

A NULL **cursor** is the one NULL that leaves evidence: `pinned_cursor` comes back NULL in every
row, so a consumer that reads the column it was given for exactly this purpose (ADR-0011: *"so a
reader can tell a fresh report from one held behind a stale horizon"*) can detect it.

A NULL **as-of instant** or a NULL **period bound** leaves none. Same all-zero face, and a perfectly
valid cursor stamped on every row:

```
--- balance_sheet_at('t1', NULL, report_cursor())      --- income_statement_for('t1', NULL, NULL, report_cursor())
        fs_line        | amount_minor                       fs_line     | amount_minor
-----------------------+--------------                 -----------------+--------------
 cash                  |            0                   revenue         |            0
 ... all ten at 0                                       ... all four at 0

--- trial_balance_at('t1', NULL, NULL, report_cursor())
 tenant_id | account_id | purpose | ... | balance_debit_positive
-----------+------------+---------+-----+------------------------
(0 rows)

--- and a NULL tenant
 rows_for_a_null_tenant
------------------------
                      0
```

So the ranking inside F3 inverts what was filed: **`p_asof` and `p_from`/`p_to` are the dangerous
NULLs**, because they produce an all-zero statement that is indistinguishable from an honest one in
every column the function returns. And note the difference between the two statement functions and
`trial_balance_at`: the statements return a **complete, plausible, balancing face**, while
`trial_balance_at` returns zero rows, which at least looks like nothing happened.

---
## F4 — `recon_journal_to_reports` does not foot

### REPRODUCED

The `classified` CTE buckets `out_of_window` out of `reported_debits`; the `r` CTE, which produces
`tb_debits`, joins transactions, accounts, types and `chart_presentation` and carries **no
`effective_at` predicate at all**. So exactly two error classes can move
`unexplained = reported − tb`, and they have **opposite signs**:

| class | effect on `reported` | effect on `tb` | sign of `unexplained` |
| --- | --- | --- | --- |
| an out-of-window entry | removed | left in | **down** |
| an entry on a type with no presentation row at the current version | left in | dropped | **up** |

### 1. The false positive — one entry effective 2226 on an otherwise clean book

`REPRO/F4a_journal_to_reports.sql`. One balanced posted transaction dated `2226-01-01` — a
fat-fingered year, which `ck_txn__effective_finite` permits, since only ±infinity is refused — with a
real event row, `account_seq` continued and the cache advanced.

```
=== 1. the negative control                          === 5. every check: which moved, which did not
       check_name        | breaks                            check_name        | breaks
-------------------------+--------                    -------------------------+--------
 balance_cache           |      0                      balance_cache           |      0
 orphan_entries          |      0                      orphan_entries          |      0
 unbalanced_transactions |      0                      unbalanced_transactions |      0
 cross_scope_mirror      |      0                      cross_scope_mirror      |      0
 journal_to_reports      |      0                      journal_to_reports      |      1
 checkpoint_drift        |      0                      checkpoint_drift        |      0
 close_typing            |      0                      close_typing            |      0
 cursor_forgery          |      0                      cursor_forgery          |      0
 accounting_equation     |      0                      accounting_equation     |      0
 chart_lint              |      0                      chart_lint              |      0
(10 rows)                                             (10 rows)
```

The full row — the same 70,000 disclosed as a reconciling item, subtracted from `reported`, and still
sitting in `tb`:

```
-[ RECORD 1 ]---------------+--------
tenant_id                   | t1
currency                    | USD
journal_debits              | 1900000
pending_debits              | 50000
superseded_debits           | 0
out_of_window_debits        | 70000
orphan_debits               | 0
reported_debits             | 1780000
tb_debits                   | 1850000
unexplained_debits          | -70000
unexplained_credits         | -70000
journal_minus_report_debits | 50000
```

And the reports are correct — the face foots and the two statement-side checks are empty:

```
 currency | chart_version |        fs_line        |   side    | amount_minor
----------+---------------+-----------------------+-----------+--------------
 USD      |             3 | receivables           | asset     |      1820000
 USD      |             3 | payables              | liability |        30000
 USD      |             3 | customer_funds        | liability |       500000
 USD      |             3 | equity                | equity    |      1000000
 USD      |             3 | current_year_earnings | equity    |       290000
 (cash, restricted_cash, other_assets, borrowings, retained_earnings all 0)
(10 rows)

--- the accounting-equation check at the same cursor (must be EMPTY)
(0 rows)
--- and the cache agrees with the journal (must be EMPTY)
(0 rows)

$ ./target/debug/openledger reconcile
openledger: reconciliation found breaks in 1 of 10 checks:
  journal_to_reports: 1 break(s)
exit=1
```

**The suite already pins the non-footing as intended.**
`crates/e2e/tests/e2e/reconcile.rs::an_out_of_window_posting_is_a_journal_to_reports_break` asserts
`out_of_window_debits = 700 AND unexplained_debits = -700` — so the arithmetic is not an accident and
not a regression. What the view's own header claims about itself (*"what is left unexplained is the
break"*, *"unexplained, which must be zero"*) and what the suite pins are different statements, and
the suite's is the true one.

### 2. The compensating error — REPRODUCED WITH LIMITS

`REPRO/F4b_journal_to_reports.sql`. Chart version 4 = version 3 minus the
`platform_rev_share_expense` / `platform_rev_share_payable` presentation rows, plus one 2226-dated
transaction for exactly 30,000 — the rev-share sub-book's turnover on each side.

```
=== 5. the statement, every column: both remainders are zero
-[ RECORD 1 ]---------------+--------
journal_debits              | 1860000
pending_debits              | 50000
out_of_window_debits        | 30000
orphan_debits               | 0
reported_debits             | 1780000
tb_debits                   | 1780000
unexplained_debits          | 0
unexplained_credits         | 0
journal_minus_report_debits | 80000
```

`tb_debits = 1780000` is **byte-identical to the negative control's**, so the report side looks
untouched — while a whole balanced sub-book is out of the presented population:

```
          purpose           | debits  | credits | presented_at_current_version
----------------------------+---------+---------+------------------------------
 customer_receivable        | 1780000 |       0 | t
 customer_wallet            |       0 |  500000 | t
 fee_revenue                |       0 |  280000 | t
 paid_in_capital            |       0 | 1000000 | t
 platform_rev_share_expense |   30000 |       0 | f
 platform_rev_share_payable |       0 |   30000 | f

 dropped_debits | dropped_credits
----------------+-----------------
          30000 |           30000
```

**The limits, exactly.** The state is not globally silent, and the presentation half cannot be made
silent:

1. `SELECT * FROM reconciliation` cannot be read at all — F5's A14 raise fires first. So
   `journal_to_reports = 0` had to be shown by spelling out the nine branches that touch no statement
   function:

   ```
          check_name        | breaks
   -------------------------+--------
    balance_cache           |      0
    orphan_entries          |      0
    unbalanced_transactions |      0
    cross_scope_mirror      |      0
    journal_to_reports      |      0     <-- the designated dropped-sub-book detector
    checkpoint_drift        |      0
    close_typing            |      0
    cursor_forgery          |      0
    chart_lint              |      2
   (9 rows)
   ```
2. `chart_lint.type_unpresented` fires. It is an error rule over every
   `account_types × chart_versions` pair, so **any** presentation gap trips it whether entries exist
   or not — there is no reachable state where the presentation half is invisible to `chart_lint`.
   What it names is the chart, not the money:

   ```
          rule       | severity |             subject             | detail
   ------------------+----------+---------------------------------+-------------------------------
    type_unpresented | error    | platform_rev_share_payable @ v4 | account type has no chart_presentation row ...
    type_unpresented | error    | platform_rev_share_expense @ v4 | account type has no chart_presentation row ...
   ```
3. At version 3, which presents the pair, the journal is intact — so only the presentation is
   missing, not the money.

So: the cancellation is real and exact, and `journal_to_reports` — the one check whose stated job is
the dropped balanced sub-book — reads **zero** on a book that has one. The operator is warned, by a
different check, about the chart rather than about the money. **The compensation matters most as a
dependency:** `journal_to_reports` is only redundant here because F5's raise and `chart_lint` happen
to cover the same ground. Relax either and the sub-book vanishes with every check green.

### 3. The wall-clock dependence — REPRODUCED

`REPRO/F4c_journal_to_reports.sql`. One honest balanced posted transaction, 33,000, effective
twenty-five seconds above the bound. Red first, then a bounded server-side poll on the *bucket*,
writing nothing:

```
--- the check is red, and the whole 330.00 is disclosed as out_of_window
 journal_to_reports      |      1     (the other nine at 0; ten rows)
 tenant_id | currency | out_of_window_debits | reported_debits | tb_debits | unexplained_debits
-----------+----------+----------------------+-----------------+-----------+--------------------
 t1        | USD      |                33000 |         1780000 |   1813000 |             -33000

=== 3. wait for the clock, write nothing, read the view again
NOTICE:  the bucket changed after 125 poll(s) of 0.2s
--- ten checks, zero breaks: the break repaired itself
 balance_cache 0 | orphan_entries 0 | unbalanced_transactions 0 | cross_scope_mirror 0
 journal_to_reports 0 | checkpoint_drift 0 | close_typing 0 | cursor_forgery 0
 accounting_equation 0 | chart_lint 0        (10 rows)

 tenant_id | currency | out_of_window_debits | reported_debits | tb_debits | unexplained_debits
-----------+----------+----------------------+-----------------+-----------+--------------------
 t1        | USD      |                    0 |         1813000 |   1813000 |                  0

--- and nothing was written between the two readings
 events_unchanged | transactions_unchanged | entries_unchanged | journal_high_water_unchanged | cache_unchanged
------------------+------------------------+-------------------+------------------------------+-----------------
 t                | t                      | t                 | t                            | t
```

The same transition through the shipped sweep's exit codes:

```
=== sweep #1, immediately
openledger: reconciliation found breaks in 1 of 10 checks:
  journal_to_reports: 1 break(s)
exit=1
bucket cleared after 183 polls
=== sweep #2, same book, nothing written since sweep #1
book reconciled — 10 checks, 0 breaks, 34 ms
exit=0
14 entries, max xact_id 937        (before sweep #1: 14 entries, max xact_id 937)
```

Two-sided, three entries on one book with the bound printed beside each:

```
 amount_minor |         effective_at          |      bound_when_this_ran      | distance_from_bound |    bucket
--------------+-------------------------------+-------------------------------+---------------------+---------------
        11000 | 2027-09-01 15:06:24.963281+00 | 2027-09-01 15:08:24.967135+00 | -00:02:00.003854    | reported
        33000 | 2027-09-01 15:08:24.543521+00 | 2027-09-01 15:08:24.967135+00 | -00:00:00.423614    | reported
        22000 | 2027-09-01 15:10:24.963281+00 | 2027-09-01 15:08:24.967135+00 | 00:01:59.996146     | out_of_window
```

Two entries four minutes apart in effective date, identical in every other respect, on opposite sides
of the verdict.

**And the direction of drift is the wrong one.** `now()` only moves forward, so the only clock-driven
transition is `out_of_window → reported`: a `journal_to_reports` break of this class **always
self-heals and never appears**. The fat-fingered date the bucket exists to surface ends up reported
into every statement forever, and the sweep goes green on its own with no write and no operator
action.

One incidental fact worth recording: `now()` is the *transaction* timestamp, so the bucket is frozen
inside one transaction and moves between them. The classification is stable exactly where it does not
need to be and unstable in the one dimension a re-runnable check must be stable in — ADR-0011 makes
the commit horizon a parameter for precisely this reason, and this window bound was left ambient.

---

## F5 — one unpresented account type turns the whole `reconciliation` view into an error

### REPRODUCED

`reconciliation` counts `recon_equation_breaks(report_cursor(),'infinity')`, which
`CROSS JOIN LATERAL`s `balance_sheet_at` per tenant, which `RAISE`s on A14. A `RAISE` inside one
branch of a `UNION ALL` aborts the whole statement.

The state, reached by appending a chart version 4 that is complete except for one presentation row —
`refuse_stale_chart_version` refuses inserts *below* the maximum only, and both statements `COALESCE`
their version to `max(version)`, so version 4 becomes what every default-version report is presented
through the instant it commits:

```
--- customer_wallet has 500,000.00 of posted entries and no line to print on
     purpose     | currency | debits | credits | balance_debit_positive
-----------------+----------+--------+---------+------------------------
 customer_wallet | USD      |      0 |  500000 |                -500000
```

**The operator interface:**

```
$ psql -c 'SELECT * FROM reconciliation'
ERROR:  chart version 4 does not present every account type with posted entries as at this instant (chart_lint.type_unpresented)
CONTEXT:  PL/pgSQL function balance_sheet_at(text,timestamp with time zone,xid8,integer) line 26 at RAISE
```

No rows. Not nine rows and a gap — nothing.

**And this is the half that matters: two of the nine surviving checks are RED, and the operator
cannot see either.** Read individually, one branch at a time:

```
       check_name        | breaks
-------------------------+--------
 balance_cache           |      0
 orphan_entries          |      0
 unbalanced_transactions |      0
 cross_scope_mirror      |      0
 journal_to_reports      |      1
 checkpoint_drift        |      0
 close_typing            |      0
 cursor_forgery          |      0
 chart_lint              |      1
(9 rows)

--- the chart_lint rows that name the same problem, and do not die
       rule       | severity |       subject        |                            detail
------------------+----------+----------------------+---------------------------------------------------------------
 type_unpresented | error    | customer_wallet @ v4 | account type has no chart_presentation row in chart version 4
```

`chart_lint.type_unpresented` — the rule whose name the `RAISE` message itself cites — reports the
identical fact as a count, and `journal_to_reports` independently reports the dropped sub-book. Both
are inside the statement that died. **The one check that diagnoses the problem is killed by the
problem.**

The shipped sweep:

```
$ DATABASE_URL=... ./target/debug/openledger reconcile
openledger: could not read the reconciliation view: error returned from database: chart version 4 does not present every account type with posted entries as at this instant (chart_lint.type_unpresented) at line 3909
exit=1
```

Exit 1 is correct and deliberate — `crates/openledger/src/failure.rs` maps `Failed` and `Drift` to
the same code with the reason written down: *"an operator reads the error first."* So the exit code
is not the defect. What the operator loses is (i) the nine other check results, (ii) the
`EXPECTED_CHECKS = 10` assertion, which never runs because the `SELECT` never returns, and (iii) the
diagnosis, which is present in `chart_lint` and unreachable.

The failure is version-scoped, not permanent — `balance_sheet_at('t1','infinity', C, 3)` still
returns ten rows — so the remedy is available. It is just not visible from the interface an operator
is told to use.

---

## F6 — the `numeric` lesson was applied in two places and missed in three

### REFUTED on all three aggregates — and the finding is backwards

**`SUM(bigint)` returns `numeric` in PostgreSQL.** A bare `SUM(amount_minor)` never had a `bigint`
accumulator to overflow. The two places that cast to `::numeric` are the two that **do** raise,
because they cast the total back to a declared `bigint`.

Confirmed on the server rather than argued:

```
 sum_of_bigint | sum_of_numeric | bigint_plus_bigint
---------------+----------------+--------------------
 numeric       | numeric        | bigint
```

The three "unprotected" aggregates already publish `numeric`, and **`schema/snapshot.txt` has been
carrying the refutation since M1** — line 342 reads `trial_balance.debits: numeric`:

```
           view           |         column          |  type
--------------------------+-------------------------+---------
 recon_pending_bridge     | pending_debits          | numeric
 recon_transaction_breaks | debits                  | numeric
 trial_balance            | debits                  | numeric
 trial_balance            | balance_debit_positive  | numeric
```

### The ceiling, from the schema

```
    column    |  type  |         constraint          |         definition
--------------+--------+-----------------------------+----------------------------
 amount_minor | bigint | ck_entries__amount_positive | CHECK ((amount_minor > 0))

 column |  type  |        constraint         |                definition
--------+--------+---------------------------+------------------------------------------
 input  | bigint | ck_balances__non_negative | CHECK (((input >= 0) AND (output >= 0)))
 output | bigint | ck_balances__non_negative | CHECK (((input >= 0) AND (output >= 0)))
```

`amount_minor` is bounded **below only** — no upper CHECK anywhere, and `crates/ledger/src/domain.rs`
refuses only `<= 0` — so one legal entry is `[1, 2^63-1]`. `2^63-1 × 2 = 18446744073709551614`
already exceeds `bigint`, and `ck_accounts__stripe_count` allows up to 1024 stripes, so **the
finding's reachability arithmetic is correct**. Only the consequence is wrong.

### `trial_balance` view — REFUTED

The claimed state was built exactly as described and **entirely through the shipped writer over
HTTP**: six sequential `POST /v1/transactions`, each `amount_minor: 9223372036854775807`, against a
64-stripe account. Consecutive calls reach consecutive dispatchers and each dispatcher stripes on the
index it holds (ADR-0018 §1), so the writer put one ceiling-sized entry on each of six stripes by
itself:

```
              account_id              | stripe |        input        | output | last_seq
--------------------------------------+--------+---------------------+--------+----------
 00000000-0000-4000-8000-0000000000c1 |      6 | 9223372036854775807 |      0 |        1
 00000000-0000-4000-8000-0000000000c1 |      7 | 9223372036854775807 |      0 |        1
 00000000-0000-4000-8000-0000000000c1 |      8 | 9223372036854775807 |      0 |        1
 00000000-0000-4000-8000-0000000000c1 |      9 | 9223372036854775807 |      0 |        1
 00000000-0000-4000-8000-0000000000c1 |     10 | 9223372036854775807 |      0 |        1
 00000000-0000-4000-8000-0000000000c1 |     11 | 9223372036854775807 |      0 |        1
```

Every row legal and at the ceiling; the view groups across all six and reports, without error:

```
-[ RECORD 1 ]----------+-------------------------------------
purpose                | platform_rev_share_expense
debits                 | 55340232221128654842
credits                | 0
balance_debit_positive | 55340232221128654842
```

`55340232221128654842` = 6 × (2^63−1) — six times past the `bigint` ceiling. Same answer through
`openledger_read`'s own grant, which matters because the view is `security_invoker`.

**And at that same state, the function the finding holds up as fixed:**

```
$ SELECT * FROM trial_balance_at('t4','-infinity','infinity', report_cursor());
ERROR:  bigint out of range
```

Isolated to the cast, one half at a time:

```
                  id                  |    the_sum_alone
--------------------------------------+----------------------
 00000000-0000-4000-8000-0000000000c1 | 55340232221128654842
-- the same expression with ::bigint appended:
ERROR:  bigint out of range
```

The `SUM(amount_minor::numeric)` is fine. The `::bigint` that
`RETURNS TABLE (… debits bigint …)` forces is what raises. `income_statement_for` fails the same way
at `fs_line` grain (`(… COALESCE(SUM(d.v), 0))::bigint`); `balance_sheet_at` survived only because the
provisioning arranged revenue and expense to net to zero.

### `recon_transaction_breaks`' `legs` CTE — REFUTED

One HTTP call, two postings of `9223372036854775807` to two different debit accounts — two
ceiling-sized legs on *one* account are refused by the writer's own `checked_add`
(`{"type":"invalid_request","detail":"the posting amounts overflow 64-bit minor units"}`, HTTP 422).
The CTE, run verbatim:

```
            transaction_id            | currency |        debits        |       credits        | leg_count | debits_type
--------------------------------------+----------+----------------------+----------------------+-----------+-------------
 01a05d86-9d9c-7f71-8409-a15dcc389fcd | USD      | 18446744073709551614 | 18446744073709551614 |         4 | numeric
```

And the view **emits** such a value in a row it returns, not merely computes and filters it — an
extra ceiling-sized leg appended as `openledger_app`:

```
-[ RECORD 1 ]---+-------------------------------------
debits          | 18446744073709551614
credits         | 9223372036854775807
imbalance_minor | 9223372036854775807
leg_count       | 3
reason          | debits_ne_credits
```

### `recon_pending_bridge`' `pend` CTE — REFUTED, and the easiest of the three to reach

No striping needed at all: a pending entry advances `last_seq` and not `input`/`output` (ADR-0010 —
the cache means posted), so the per-stripe cache ceiling never enters into it. Two ordinary HTTP
calls with `"status":"pending"`, both debiting one **unstriped** account at the ceiling:

```
-[ RECORD 1 ]---------------+-------------------------------------
purpose                     | platform_rev_share_expense
posted_balance_minor        | 9223372036854775807
pending_balance_minor       | 18446744073709551614
available_balance_minor     | 27670116110564327421
pending_debits              | 18446744073709551614
pending_txns                | 2
```

Published, not raised.

### Blast radius: none from F6

`trial_balance` is read by `recon_scope_breaks`, which `reconciliation` counts. At the state above the
operator query reports normally:

```
       check_name        | breaks
-------------------------+--------
 balance_cache           |      0
 orphan_entries          |      0
 unbalanced_transactions |      0
 cross_scope_mirror      |      0
 journal_to_reports      |      0
 checkpoint_drift        |      0
 close_typing            |      0
 cursor_forgery          |      0
 accounting_equation     |      0
 chart_lint              |      0
(10 rows)

$ ./target/debug/openledger reconcile
book reconciled — 10 checks, 0 breaks, 41 ms
exit=0
```

With a forged imbalance added on top, the break list does its job and still does not raise:

```
openledger: reconciliation found breaks in 1 of 10 checks:
  unbalanced_transactions: 2 break(s)
exit=1
```

### Two real write-path refusals found on the way

Neither is F6, both worth recording:

- **The batched statement's cross-member coalesce re-adds at `bigint`.** Two ceiling-sized postings to
  one account sent *simultaneously* were collected into one shared statement (ADR-0018 §4) and both
  refused: server log `write failed: … bigint out of range`, callers
  `HTTP 500 {"type":"internal","detail":"the write failed; nothing was committed"}`. Nothing
  committed. Whether two simultaneous posts batch is not deterministic — both outcomes were observed
  across runs — so this is a **sometimes**-500 on legal amounts, and the caller is told `internal`
  rather than `overflow`, which the error-type grammar already has.
- **The per-stripe cache row is the real amount ceiling.** A stripe holds at most 2^63−1 per side, so
  on an unstriped account the *second* ceiling-sized posting is refused by the cache upsert rather
  than by any stated rule — again `500 internal`, not one of the nine named types.

**So the finding is not merely wrong: the direction of the defect is inverted.** The report that
"dies on one large row and reports nothing" is the one the comment claims is protected — and the claim
is not only in the migration, it is in the catalog, dumped into `schema/snapshot.txt` line 1780:

> `function trial_balance_at(...) = ... Sums as numeric to survive a huge legal row (ADR-0011,
> ADR-0013).`

It sums as `numeric` and then casts back to `bigint`, so it does not survive. The three views that
never cast do.

---

## F7 — the default chart version is the one version whose content can still change

### REPRODUCED WITH LIMITS

The limits, stated first: **the shape of an issued statement moves; its numbers move only in one
reachable case; and the finding's proposed re-pointing of an existing presentation row is refused.**

### The shape moves

One `fs_lines` row appended to version 3 — the current, "deliberately open" version. Accepted, as
`refuse_stale_chart_version`'s own comment says it must be:

```sql
INSERT INTO fs_lines (chart_version, code, caption, statement, side, sort_order)
VALUES (3,'goodwill','Goodwill','balance_sheet','asset',250);
```

The same call, at the same literal cursor `'839'` and the same version:

```
--- BEFORE                                                         --- AFTER
 chart_version |        fs_line        | sort_order | amount        chart_version |        fs_line        | sort_order | amount
---------------+-----------------------+------------+---------     ---------------+-----------------------+------------+---------
             3 | cash                  |        100 |       0                  3 | cash                  |        100 |       0
             3 | restricted_cash       |        150 |       0                  3 | restricted_cash       |        150 |       0
             3 | receivables           |        200 | 1750000                  3 | receivables           |        200 | 1750000
                                                                              3 | goodwill              |        250 |       0   <--
             3 | other_assets          |        300 |       0                  3 | other_assets          |        300 |       0
             3 | payables              |        400 |   30000                  3 | payables              |        400 |   30000
             3 | customer_funds        |        500 |  500000                  3 | customer_funds        |        500 |  500000
             3 | borrowings            |        600 |       0                  3 | borrowings            |        600 |       0
             3 | equity                |        700 | 1000000                  3 | equity                |        700 | 1000000
             3 | retained_earnings     |        800 |       0                  3 | retained_earnings     |        800 |       0
             3 | current_year_earnings |       9000 |  220000                  3 | current_year_earnings |       9000 |  220000
(10 rows)                                                          (11 rows)
```

`chart_version` reads **3** in both runs and `pinned_cursor` reads **839** in both runs. Eleven rows
where ten were issued. All ten checks green afterwards:

```
 balance_cache 0 | orphan_entries 0 | unbalanced_transactions 0 | cross_scope_mirror 0
 journal_to_reports 0 | checkpoint_drift 0 | close_typing 0 | cursor_forgery 0
 accounting_equation 0 | chart_lint 0        (10 rows)
```

`chart_lint`'s `line_unreachable` rule does name the new line — but at severity `info`, which the
summary does not count, and its own comment explains why: *"a chart may carry a line ahead of the
type that will use it."* That reasoning is sound for a version being built and wrong for a version
being reported through, and the schema cannot tell the two apart because they are the same version.

### The numbers move, in the one case the keys allow

The only way a *number* moves inside a fixed version is a type that has posted entries and no
presentation row — F5's state — because that is the only presentation row a version can still gain.
The transition is from a **refusal** to a **statement**, at identical coordinates:

```
--- the statement at (839, 4) -- FIRST RUN
ERROR:  chart version 4 does not present every account type with posted entries as at this instant (chart_lint.type_unpresented)

--- the missing row, appended to version 4, which is still current and still open
INSERT INTO chart_presentation (chart_version, type_code, ...)
VALUES (4,'customer_wallet','liability','per_shard','customer_funds','receivables');

--- the statement at (839, 4) -- SECOND RUN, identical call
 chart_version |        fs_line        | amount_minor
---------------+-----------------------+--------------
             4 | receivables           |      1750000
             4 | payables              |        30000
             4 | customer_funds        |       500000   <-- 500,000.00 appeared
             4 | equity                |      1000000
             4 | current_year_earnings |       220000
             (11 rows)
```

### REFUTED: an existing type cannot be re-pointed within a version

The finding asks to *"add or re-point a `chart_presentation` row in that same version."* Adding
works, as above. Re-pointing does not, by three separate mechanisms:

```
--- a second presentation row for the same type
ERROR:  duplicate key value violates unique constraint "pk_presentation"
DETAIL:  Key (chart_version, type_code)=(4, customer_wallet) already exists.

--- an UPDATE
ERROR:  chart_presentation is append-only: UPDATE on (row) refused. Correct it with a new row.

--- a DELETE-then-reinsert
ERROR:  chart_presentation is append-only: DELETE on (row) refused. Correct it with a new row.

--- and an fs_lines caption, which is what a reader actually reads
ERROR:  fs_lines is append-only: UPDATE on (row) refused. Correct it with a new row.
```

So the version's *existing* content really is frozen; only its *absent* content is open. The finding
overstates the reach and is right about the principle: ADR-0012's *"a version whose content can
change identifies nothing"* is violated by the current version, and the two things that can change
in it — a new line, and a first presentation for an unpresented type — are exactly the two that
change what an issued statement says.

---

## F8 — `computed_at_xid` is bounded from below only, and the app role may supply it

### REPRODUCED WITH LIMITS

`recon_close_breaks` tests one thing — `WHERE c.computed_at_xid < x.xact_id` — so a cursor at or
above the closing transaction's commit position passes, and "at or above" has no ceiling.
`close_disclosures` selects arrivals **above** the stored cursor (`e.xact_id >= c.computed_at_xid`),
so a cursor at the top of the `xid8` range makes that view permanently empty for the period. And
`computed_at_xid` sits under a table-wide `INSERT` grant on `ledger_period_closes`, unlike
`ledger_entries.xact_id`, which the column-level grant withholds.

**This reproduction carries its own control.** Two tenants, two honest closes of August, differing in
`computed_at_xid` and in nothing else — t1 at the top of the range, t2 at its closing transaction's
own commit position. Both written as `openledger_app`.

```
 tenant_id | period_code |   computed_at_xid    | txn_xact_id | horizon_now
-----------+-------------+----------------------+-------------+-------------
 t1        | 2026-08     | 18446744073709551615 |         919 |         920
 t2        | 2026-08     |                  919 |         919 |         920
```

`recon_close_breaks` is green on both — the check is one-sided:

```
 tenant_id | period_code | currency | transaction_id | computed_at_xid | txn_xact_id | reason
-----------+-------------+----------+----------------+-----------------+-------------+--------
(0 rows)

       check_name        | breaks
-------------------------+--------
 balance_cache           |      0
 orphan_entries          |      0
 unbalanced_transactions |      0
 cross_scope_mirror      |      0
 journal_to_reports      |      0
 checkpoint_drift        |      0
 close_typing            |      0
 cursor_forgery          |      0
 accounting_equation     |      0
 chart_lint              |      0
(10 rows)
```

Then one backdated arrival into each closed August — a late clearing carrying a closed period's
business date, which ADR-0011 says is *"normal, and a refused one is money that exists nowhere."*

```
--- close_disclosures -- the enumeration this design ships INSTEAD of a period lock
 tenant_id | period_code |               entry_id               | direction | amount | effective_at | xact_id
-----------+-------------+--------------------------------------+-----------+--------+--------------+---------
 t2        | 2026-08     | 01a05d81-4fad-7a62-9886-e9501e0cf5ed | debit     |  40000 | 2026-08-15   |     920
 t2        | 2026-08     | 01a05d81-4fad-7b03-bbe5-b2cc903f7ccc | credit    |  40000 | 2026-08-15   |     920
(2 rows)

 tenant_id | disclosed
-----------+-----------
 t2        |         2
```

**t2 discloses its arrival; t1 has nothing to disclose and never will.** The IAS 1.41-shaped
disclosure is silently switched off for that period, by one column value, written by the role the
write path runs as.

### The limit: the arrival is not silent, it is misdiagnosed

```
       check_name        | breaks
-------------------------+--------
 checkpoint_drift        |      2
 ...the other nine at 0

 tenant_id | period_code |              account_id              | stored_input | stored_output | recomputed_input | recomputed_output |   reason
-----------+-------------+--------------------------------------+--------------+---------------+------------------+-------------------+-------------
 t1        | 2026-08     | 01a05d75-587b-74d4-bd38-ec19c9744f6b |      1750000 |             0 |          1790000 |                 0 | value_drift
 t1        | 2026-08     | 01a05d75-587c-714a-afef-969e86f71704 |            0 |         30000 |                0 |             70000 | value_drift
(2 rows)
```

Because the stored cursor is unbounded, `recon_checkpoint_breaks`' recompute is unbounded too, so the
arrival lands inside the recompute and disagrees with a checkpoint that was correct when it was
written. So:

- **Between the close and the first arrival, the state is entirely green with the disclosure off.**
- **The first arrival produces a red — on the wrong check, naming the wrong culprit.**
  `checkpoint_drift` says the stored checkpoint drifted. It did not. The forged cursor did, and
  `close_typing` — the check that exists for exactly the cursor-to-close relationship — stays green.
  ADR-0010's disposition table says the checkpoint is derived and rebuildable, so the natural
  operator response is to **rebuild the checkpoint from the forged cursor**, which returns the book
  to green and leaves the disclosure off.
- t2's honest close stays green throughout and discloses correctly, which is what makes the
  comparison a control rather than an assertion.

So the finding's mechanism is exactly right and its consequence needs one word changed: a later
backdated arrival goes **unenumerated**, not unnoticed.

---
## F9 — a wrong or unauthorised `p_tenant` is answered with silence

### REPRODUCED WITH LIMITS — and one consequence the finding did not name

Read as a `LOGIN` role `spike025_read_login` inheriting `openledger_read`, created with the same
guarded `DO` block as `crates/e2e/tests/e2e/support/postgres.rs::ensure_login_role`:

```
       rolname       | rolcanlogin | rolbypassrls | inherits_read
---------------------+-------------+--------------+---------------
 spike025_read_login | t           | f            | t
```

### The silence, and the asymmetry it sits next to

Scoped by `SET app.tenant_id = 't1'`, its own tenant answers with the real face (ten rows,
`receivables 1750000`, `customer_funds 500000`, `equity 1000000`, `current_year_earnings 220000`).
Then:

```
--- balance_sheet_at('t2','infinity', report_cursor())  -- t2 exists and carries a posted 100,000 charge
 tenant_id | currency | chart_version | fs_line | ... | pinned_cursor
-----------+----------+---------------+---------+-----+---------------
(0 rows)

--- balance_sheet_at('t_does_not_exist','infinity', report_cursor())
(0 rows)

--- proven identical by a two-way EXCEPT ALL rather than eyeballed
 unauthorised_rows | nonexistent_rows | identical
-------------------+------------------+-----------
                 0 |                0 | t

--- ...while a typo'd chart version is a refusal
ERROR:  chart version 999 does not exist
CONTEXT:  PL/pgSQL function balance_sheet_at(text,timestamp with time zone,xid8,integer) line 11 at RAISE
```

`income_statement_for` behaves identically in all four cases. `trial_balance_at` has no guards at all
— it is bare SQL with no `p_chart_version` and no `RAISE` — so all three tenants differ only in row
count:

```
      asked       | count
------------------+-------
 t1               |     6
 t2               |     0
 t_does_not_exist |     0
```

### The limit: two mechanisms, one answer, and only one of them is what the finding claims

The finding calls this *"a wrong or unauthorised `p_tenant`"* as though it were one defect. It is
two, and they have different severities. Run as the **OWNER**, whom `FORCE ROW LEVEL SECURITY`
deliberately does not bind:

```
=== 1. t2 as the OWNER: the real face. The function was never unwilling.
 t2 | USD | receivables           | asset  | 100000
 t2 | USD | current_year_earnings | equity | 100000     (+ 8 zero lines)
(10 rows)

=== 2. t_does_not_exist as the OWNER: still zero rows, with no RLS in play.
(0 rows)
```

- **`t2` as the reader is RLS filtering the `scopes` CTE.** The reader can see zero t2 accounts
  (`t2_accounts_visible = 0`), so `SELECT DISTINCT l.tenant_id, l.currency FROM ledger_accounts l
  WHERE l.tenant_id = p_tenant` returns nothing and the whole `LEFT JOIN fs_lines` face collapses.
  RLS **held**; no t2 datum reached the reader. **So this is not an authorisation defect** — calling
  it one overstates it. It is a denial reported as an empty book: low as confidentiality, moderate as
  diagnostics, because an integrator's dashboard renders a legitimate-looking all-zero balance sheet
  for a tenant it merely lacks scope for.
- **`t_does_not_exist` for anyone, owner included, is the `WHERE l.tenant_id = p_tenant` predicate
  finding nothing.** RLS is not in the picture. This *is* the diagnostics defect the finding claims,
  and it is present for the owner too.

Both collapse onto a third, legitimate case — a real tenant with no accounts yet — which the
baseline's own `scopes` comment already admits: *"a scope with no accounts at all remains
invisible."* Three causes, one answer.

### The consequence the finding did not name, and it is the worst of them

`EXECUTE` really is `PUBLIC` on all five functions, and all five are `SECURITY INVOKER`:

```
        proname        | prosecdef | proacl | default_privileges_so_execute_is_public
-----------------------+-----------+--------+-----------------------------------------
 balance_sheet_at      | f         | (null) | t
 income_statement_for  | f         | (null) | t
 recon_equation_breaks | f         | (null) | t
 report_cursor         | f         | (null) | t
 trial_balance_at      | f         | (null) | t
```

Because they are `SECURITY INVOKER`, `PUBLIC EXECUTE` buys almost nothing — the caller's own grants
and policies still gate every read. But it buys **one** thing. The reader is not granted the
`reconciliation` view:

```
ERROR:  permission denied for view reconciliation
```

…and can nonetheless run the sweep's own highest-leverage check directly, and gets a **green** answer
scoped to one tenant out of two:

```
 tenant_id | currency | assets_minor | liab_equity_minor | gap_minor
-----------+----------+--------------+-------------------+-----------
(0 rows)

 breaks_seen_by_a_t1_scoped_reader
-----------------------------------
                                 0
```

With the GUC unset it is green over **no tenants at all** — the
`tenants AS (SELECT DISTINCT l.tenant_id FROM ledger_accounts l)` CTE is emptied by RLS, so the
`HAVING` clause has nothing to fail:

```
 accounts_visible                     → 0
 breaks_seen_by_an_unscoped_reader    → 0
 t1_balance_sheet_rows                → 0
```

Against the owner running the same check over the whole book:

```
 tenant_id | balance_sheet_rows
-----------+--------------------
 t1        |                 10
 t2        |                 10
```

**That is "a green check that did not execute"** — verbatim the failure the `reconciliation` view's own
comment says it exists to prevent, and the RLS comment's *"a sweep silently scoped to no tenant would
report zero breaks on every book, which is this project's nightmare shape"* — reachable by any role
with `USAGE` on the schema. It cannot mislead the shipped sweep, which `SET ROLE openledger_recon`
and reads the owner-executed view. It can mislead anything else that calls the function, and the
grant comment beside it says the function was left `PUBLIC` precisely because *"it reads only through
the SECURITY INVOKER statement function"* — which is true and is the mechanism.

### The second half — the shape is not pinned — REPRODUCED

The `scopes` CTE reads `ledger_accounts`, which has no `xact_id`, so account existence is not pinned
by the cursor. Cursor captured as a literal (`C = 859`) after the horizon settled
(`max_entry 774 < report_cursor 859`), then **one account opened and nothing posted to it**:

```sql
INSERT INTO ledger_accounts (tenant_id, owner_type, owner_id, purpose, category,
                             normal_balance, counterparty_scope, currency)
VALUES ('t1','house',NULL,'due_from_treasury','asset','debit','shared','EUR');
```

Before: 10 rows, 1 currency block, pinned at 859. After, at the **identical literal cursor**: 20 rows,
2 currency blocks. What the issued statement *gained*:

```
 t1 | EUR | 3 | cash                  | Cash and cash equivalents                |  100 | 0 | asset     | 859
 t1 | EUR | 3 | restricted_cash       | Restricted cash                          |  150 | 0 | asset     | 859
 t1 | EUR | 3 | receivables           | Accounts receivable                      |  200 | 0 | asset     | 859
 t1 | EUR | 3 | other_assets          | Other assets                             |  300 | 0 | asset     | 859
 t1 | EUR | 3 | payables              | Accounts payable and accrued             |  400 | 0 | liability | 859
 t1 | EUR | 3 | customer_funds        | Customer funds payable                   |  500 | 0 | liability | 859
 t1 | EUR | 3 | borrowings            | Borrowings                               |  600 | 0 | liability | 859
 t1 | EUR | 3 | equity                | Shareholders equity                      |  700 | 0 | equity    | 859
 t1 | EUR | 3 | retained_earnings     | Retained earnings                        |  800 | 0 | equity    | 859
 t1 | EUR | 3 | current_year_earnings | Undistributed earnings (since inception) | 9000 | 0 | equity    | 859
(10 rows)
```

What it *lost*: nothing (`0 rows`). Every USD row byte-identical in both directions
(`usd_rows_that_moved = 0`). `income_statement_for` gains the same EUR block at the same cursor. And
no check notices:

```
       check_name        | breaks
-------------------------+--------
 balance_cache           |      0
 orphan_entries          |      0
 unbalanced_transactions |      0
 cross_scope_mirror      |      0
 journal_to_reports      |      0
 checkpoint_drift        |      0
 close_typing            |      0
 cursor_forgery          |      0
 accounting_equation     |      0
 chart_lint              |      0
(10 rows)
```

Nor could one: `recon_equation_breaks` groups by `(tenant_id, currency)`, and the EUR block is
`assets = 0`, `liab+equity = 0`, so the `HAVING` clause is satisfied by construction. **A
cursor-pinned statement is reproducible in its numbers and not in its face** — which qualifies
ADR-0011's *"an issued statement is reproducible after any backdated posting"*: true of the amounts,
false of the shape. The effect is not confined to a new currency; opening the first account for a
wholly new tenant makes that tenant reportable at an already-issued cursor.

---

## F10 — `recon_cursor_breaks`' stated justification

### REPRODUCED

Two comments in one file, about the same function, forty lines apart. `recon_cursor_breaks`:

> *"an xact_id at or above the current snapshot's xmin (a committed row's commit position is always
> retired below the horizon by the time the sweep runs)"*

`report_cursor()`:

> *"pg_snapshot_xmin is the CLUSTER's horizon, so one long-running transaction anywhere on the server
> — another database included — holds every new report's cursor back (lag, never wrongness …)"*

They cannot both be right. For `report_cursor()` a held-back xmin is lag; for
`recon_cursor_breaks` the same held-back xmin is a **forgery verdict on a committed, honest row**.

`REPRO/F10_cursor_breaks_horizon.sh`, on its own instance, because it holds a transaction open and
that drags the horizon for every database on the cluster — which is the finding.

```
=== 0. the negative control: an honest book, nothing held, ten checks at zero
 balance_cache 0 | orphan_entries 0 | unbalanced_transactions 0 | cross_scope_mirror 0
 journal_to_reports 0 | checkpoint_drift 0 | close_typing 0 | cursor_forgery 0
 accounting_equation 0 | chart_lint 0        (10 rows)

 horizon | max_entry | cursor_breaks
---------+-----------+---------------
     785 |       774 |             0

=== 1. a long-running transaction in ANOTHER DATABASE on the same instance
 pid |      datname       |        state        | backend_xid
-----+--------------------+---------------------+-------------
 123 | spike025_neighbour | idle in transaction |         785

=== 2. one honest commit on the BOOK, while the neighbour holds
=== 3. recon_cursor_breaks now reports above_horizon on an honest book
    reason     | count
---------------+-------
 above_horizon |     2

               entry_id               | xact_id | txn_xact_id |    reason
--------------------------------------+---------+-------------+---------------
 01a05d82-858e-7611-b6f1-edfebbc83dab |     788 |         787 | above_horizon
 01a05d82-858f-7022-a2ff-2d10a64b80f7 |     788 |         787 | above_horizon

 horizon_xmin | horizon_xmax | max_entry
--------------+--------------+-----------
          785 |          791 |       788

       check_name        | breaks
-------------------------+--------
 balance_cache           |      0
 orphan_entries          |      0
 unbalanced_transactions |      0
 cross_scope_mirror      |      0
 journal_to_reports      |      0
 checkpoint_drift        |      0
 close_typing            |      0
 cursor_forgery          |      2
 accounting_equation     |      0
 chart_lint              |      0
(10 rows)

=== 4. the shipped sweep, while the neighbour holds
openledger: reconciliation found breaks in 1 of 10 checks:
  cursor_forgery: 2 break(s)
exit=1
```

The entry is honest in every respect — committed, balanced, cache-consistent, `xact_id` taken from
its own `DEFAULT`, `xact_id 788 > txn_xact_id 787` exactly as a legitimately appended leg should be.
The verdict is `above_horizon` because a database this book has never heard of has a transaction
open.

This was also reproduced **by accident, before it was reproduced on purpose**, on the shared port-5433
cluster: 12 `above_horizon` breaks on a book written entirely through the shipped writer, caused by a
neighbouring agent's `idle in transaction` backend on database `spike024arms` holding xid 15760 for
almost four minutes (`SPEC.md` carries that capture). The duration is the point: this is not a
millisecond race that a retry rides out.

### The limit: the project knows about the transient, and does not know about this cause

`crates/e2e/tests/e2e/reconcile.rs::a_sweep_racing_live_writers_never_reads_them_as_drift` already
tolerates it — *"One tolerance, and it is ADR-0010's own: a sweep whose snapshot catches entries above
the cluster horizon may transiently report `cursor_forgery` (the quiescence assumption the clean tests
wait out on purpose)"* — and `wait_for_the_horizon_to_retire_this_book` even names the neighbour in
its timeout message. So the *effect* is known. What is not is the framing: every one of those places
treats it as **this book's own concurrent writers**, bounded by the writers finishing. The cause
reproduced here is unbounded by anything this deployment controls, and `recon_cursor_breaks`' comment
asserts it cannot happen. The shipped sweep carries no wait at all, so a scheduled sweep exits 1 on
an honest book for as long as the neighbour holds — and the operator is handed the word "forgery".

### The candidate fix, evaluated in place

`pg_snapshot_xmax` is one past the highest xid that has been *assigned*, so every committed row is
strictly below it regardless of who holds an old transaction open. It is **not** a horizon and must
never be a report cursor — a report pinned at xmax would include rows still in flight — but the
forgery check asks a different question: *is this `xact_id` one that could have been assigned by
now?*

```
--- with the neighbour holding, on the honest book
      bound       | breaks
------------------+--------
 xmin (shipped)   |      2
 xmax (candidate) |      0

--- and after appending a far-future forged xact_id ('9000000000000000000', two legs, as the OWNER)
      bound       | breaks
------------------+--------
 xmin (shipped)   |      4
 xmax (candidate) |      2
```

**The substitution removes the false positive and keeps the forgery.** Note the comparison operator
changes with it: `> xmin` becomes `>= xmax`, because xmax is one past the highest assigned rather
than the highest retired. Releasing the neighbour leaves exactly the two forged rows, and the horizon
clears past the honest ones:

```
    reason     | count
---------------+-------
 above_horizon |     2

 horizon_xmin | max_honest_entry
--------------+------------------
          794 |              788
```

What the candidate gives up: it no longer catches an entry whose `xact_id` is *between* the horizon
and xmax — i.e. one forged into the narrow band of currently-in-flight ids. That band is bounded by
concurrency, not by time, and an attacker who can supply `xact_id` at all (the owner, per the
column-level grant) has no reason to forge a value inside it: the forgeries that buy anything are
below the horizon (`predates_txn`, which the second predicate still catches) or far above it (still
caught). The trade is a real narrowing of the check in exchange for it being usable on a shared
cluster.

---
## Severity, ranked

Ranked by *what a wrong number costs a reader who trusts the ten green checks*, and how cheaply the
state is reached. Reachability is stated as the role that can reach it, because that is the difference
between a bug and an attack.

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

### Why F2(a) leads

It is the only reproduction in this spike that needs **no adversary and no unusual privilege**. Every
other entry needs someone to append a chart version, forge a label, supply a cursor, pass a NULL, or
hold a transaction open. F2(a) needs a close routine whose author wrote the transaction and forgot the
`ledger_period_closes` insert — the exact shape a half-implemented close produces on its first run —
and it takes out the entire income statement of every period it touches, with the balance sheet
correct, `close_typing` green, `checkpoint_drift` green, and the shipped sweep printing *"book
reconciled — 10 checks, 0 breaks"*.

### The pattern under the list

Six of the eleven rows are the same defect wearing different clothes: **a check whose green means "I
found nothing" and whose green also means "I could not look."** F3's NULL cursor, F5's raise, F8's
unbounded cursor, F9's RLS-emptied tenant set, F4's self-healing window, and F1's cancelling identity
are all the shape ADR-0004 named — *"there was nothing left to disagree with — silence read as
assent"* — reached by six different routes. The `reconciliation` view's own header says it exists to
prevent exactly this, and it prevents it only for the case of a check row going *missing*.

The second pattern is narrower and is the auditor's real contribution: **the keys ADR-0011 and
ADR-0012 added are sound and they all guard the same side of their relationship.**
`fk_closes__txn_kind` constrains what a close row may name and not what the named transaction
contains. `fk_presentation__fs_line` constrains which side a line sits on and not which line a
position belongs on. `recon_close_breaks` bounds `computed_at_xid` below and not above.
`refuse_stale_chart_version` freezes versions below the maximum and not the maximum. In every case the
unguarded side is where the reproduction went.
