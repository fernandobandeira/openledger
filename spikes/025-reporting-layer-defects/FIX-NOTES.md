# Spike 025 — fix notes

One section per reproduced finding: the fix shape, and what it costs **in this project's terms**.
No migration is written here; ADR-0003 and `scripts/check-migrations-immutable.sh` make
`migrations/00001_baseline.sql` immutable with no opt-out marker, so every fix below is a new
numbered migration by definition and that is not repeated in each entry.

The four costs that get named each time:

- **snapshot** — `schema/snapshot.txt` pins view bodies via `pg_get_viewdef` and function bodies via
  `pg_get_functiondef` (`crates/e2e/tests/e2e/schema_snapshot.rs:234-247`), so *any* change to a view
  or function moves it. Regenerated with `make schema-snapshot`, compared in CI.
- **check count** — `EXPECTED_CHECKS = 10` in `crates/db/src/reconcile.rs:41`, the
  `assert_eq!(checks.len(), 10, ...)` oracle in `crates/e2e/tests/e2e/support/book.rs:496`, and
  `ALL_CHECKS: [&str; 10]` in `crates/e2e/tests/e2e/reconcile.rs`. All three move together or the
  binary refuses the sweep, which is the intended behaviour.
- **grants** — a new view or function needs its own `GRANT` to `openledger_recon` in the same
  migration, and the recon views deliberately omit `security_invoker`.
- **RLS** — nothing below changes a policy except where said.

---

## F1 — the equation check is an identity

**There is no fix to `recon_equation_breaks` itself.** `gap_minor` is the sum of every presented
position; that is what the expression computes, and no rewrite of the same inputs computes anything
else. The honest options, in ascending cost:

1. **Correct the comment and the claim (cheapest, and it should happen regardless).** The view's
   header calls itself *"THE HIGHEST-LEVERAGE CHECK on the list"* and lists three defects it does not
   catch (a mis-bounded plug, a mis-typed close, a swung position netted away — F2 is the second and
   is green). ADR-0010 carries the same claim. A comment-only change moves the **snapshot** (the
   function body is dumped) and nothing else. It does not fix a defect; it stops a wrong belief,
   which on this project's own terms is the more expensive of the two.
2. **Check the face against something independent of the face.** The only independent statement about
   presentation is the chart's own intent, and the chart has no such statement — `chart_presentation`
   *is* the intent. So a real check needs a second declaration to disagree with: a per-type expected
   line asserted somewhere outside the chart version being tested, or a stored issued statement to
   diff a re-run against. Both are new tables, so a new migration, a **snapshot** change, a
   **grant**, and a **new check** taking the count to 11. Neither exists in any form today, and
   neither is a small change to reporting SQL.
3. **Bound the presentation declaratively where it is bounded at all.** Two rules are expressible
   and are not asserted: a type whose `is_perimeter` or `counterparty_scope` implies restricted or
   customer money must not share an `fs_line` with a type that does not (the restricted-cash argument
   in `fs_lines`' own comment, generalised), and an `fs_line` may not receive types of more than one
   `counterparty_scope`. Both are `chart_lint` rules — SQL in an existing view, no new check row, a
   **snapshot** change, no grant and no RLS change. They would have caught this reproduction's
   `customer_wallet → payables` and are cheap. They would not have caught
   `paid_in_capital → retained_earnings`, which is two `'none'`-scope equity types on two equity
   lines and is indistinguishable from a legitimate chart by any rule over the chart alone.

**Recommendation: 1 and 3.** 2 is a genuine feature and belongs in a decision, not a fix.

---

## F2 — the close is keyed in one direction only

**(a) a `period_close` transaction with no close row.** The fix is a `chart_lint`-shaped exception
rule, not a key: *a posted transaction of kind `period_close` that no `ledger_period_closes` row
names*. It cannot be a foreign key — the transaction is written before the close row, so a NOT NULL
reference from journal to period record is unwritable in the order the close happens — and it cannot
be a `CHECK`, because it is a statement about the absence of a row in another table. It is exactly
the shape ADR-0004 admits a lint for. Two placements:

- **as an eleventh `reconciliation` check** (`recon_close_orphan_breaks`, or fold it into
  `recon_close_breaks` as a second `reason`). Folding it into `recon_close_breaks` is the cheaper
  one: the view already returns a `reason` column, the check count **stays at 10**, and
  `close_typing` gains a second red path. Costs a **snapshot** change, no new grant (the view is
  already granted to `openledger_recon`), no RLS change. The e2e suite needs one new red-path test
  next to `a_close_whose_cursor_precedes_it_is_a_close_typing_break`.
- **as a `chart_lint` rule** — wrong home: `chart_lint` is about the chart, and this is about the
  journal.

Note what the fix cannot recover: the *income statement was already wrong* for as long as the close
row was missing, and a check tells the operator, not the reader of the issued statement. If the
project wants the statement itself to refuse, `income_statement_for` needs an A15-shaped guard —
*"refuse if a `kind='period_close'` transaction inside the window has no close row"* — which is a
function body change (**snapshot**), no new check, and a new class of refusal on the read path. That
is the same trade A14 already made and is consistent with it.

**(b) a revenue transaction labelled `period_close`.** `kind` is free `text` with no `CHECK` and is
in the app role's column-level `INSERT` grant. Three fixes, and only the third addresses the
substance:

1. `CHECK (kind IN (...))` on `ledger_transactions`. Cheap (**snapshot**), and it does not help: the
   attack needs `'period_close'` to be a *legal* value, which it must be.
2. Remove `kind` from the app role's `INSERT` grant and have the writer take it from a generated
   default. This is the F8-shaped fix and it is real — it moves (b) from "the writer role can do
   this" to "only the owner can" — but it breaks the writer: `crates/ledger/postgres/src/repository.rs`
   supplies `'posting'` explicitly in both `CLAIM_AND_APPEND` and the batched statement, and a
   column-level grant that omits a column **refuses any INSERT naming it**. So this is a **grant
   change plus a writer change**, and the writer would then have no way to write a close at all —
   which is fine today, because nothing writes one.
3. **Constrain what the named transaction contains, not what it is labelled.** A close's entries must
   net every revenue and expense account to zero over the period and route the net to
   `retained_earnings`. That is a statement about a population, so it is a lint: a
   `recon_close_breaks` `reason` of `close_does_not_sweep`, comparing the closed period's
   revenue/expense positions at `computed_at_xid` against zero. Same cost profile as (a)'s folded
   rule — **snapshot**, no new grant, check count **stays 10** — and it is the only one of the three
   that makes a mislabelled fee detectable rather than merely harder to write.

---

## F3 — no function is `STRICT` and none guards its parameters

The cheapest correct fix is to make all five functions refuse a NULL, and the two `plpgsql` ones can
do it with a message:

```
IF p_cursor IS NULL OR p_asof IS NULL OR p_tenant IS NULL THEN
    RAISE EXCEPTION 'balance_sheet_at requires a tenant, an as-of instant and a cursor'
        USING ERRCODE = '22004';
END IF;
```

`trial_balance_at` is bare SQL, where a `RAISE` cannot live, so it either becomes `plpgsql` — which
changes its volatility surface and how it inlines — or is declared `STRICT`, which returns NULL for
the whole call rather than raising. `STRICT` on a `RETURNS TABLE` function returns **zero rows**,
which is the same silence in a different costume, so `STRICT` is the wrong tool here and the guard
belongs in the body.

`recon_equation_breaks` is the one that matters most and is bare SQL too: its NULL-cursor answer is
zero rows, which the summary counts as **zero breaks**. Making it `plpgsql` for one guard is a real
change to the function that `reconciliation` calls, so the alternative worth considering is that the
summary stop passing a value that can be NULL at all — `report_cursor()` cannot return NULL, so
today's call site is safe and the exposure is entirely to *other* callers.

Costs: function bodies change, so **snapshot**. Check count **stays 10**. No grant, no RLS change.
`report_cursor()` takes no arguments and needs nothing. One behavioural note for the changelog: any
existing caller passing NULL today gets rows and would then get an error — there are none in this
repo (`grep` finds no non-test caller of either statement function), so the blast radius is SQL-level
readers only.

---

## F4 — `recon_journal_to_reports` does not foot

Two independent fixes, and they should land together.

**The window.** Give the `r` CTE the same `effective_at` predicate `classified` uses, so `reported`
and `tb` are drawn from the same population and `unexplained` becomes what the header claims: the
pure presentation-divergence figure. Then move the bound off `now()`, because a check whose verdict
changes with the wall clock and no write is not re-runnable — either two literals, or the shape the
statement functions already use (caller-supplied bounds), which turns the view into a function.

**The disclosure.** Once out-of-window stops reaching `unexplained`, the out-of-window population is
disclosed in a column nothing counts. It needs its own summary row, and that is where the cost lands:
`EXPECTED_CHECKS` 10 → 11, the e2e oracle's ten, and `ALL_CHECKS`. **Check count changes.**

**The coupled cost, and it is the one to flag.** `an_out_of_window_posting_is_a_journal_to_reports_break`
currently pins `unexplained_debits = -700` as *correct*. After the fix that assertion inverts, and
`journal_to_reports` loses its only red path in that file — its remaining red path is the presentation
divergence, which converges with F5's A14 raise. So **F4 and F5 must be fixed as a pair**, or
`journal_to_reports` has no reachable red at all and becomes the thing this project fears most.

**snapshot**: both `recon_journal_to_reports` and `reconciliation` bodies move; turning the view into
a function moves it from the view section to the routine section of the dump. **grants**: an in-place
view replacement needs none (already granted to `openledger_recon`); a new view or function needs its
own `GRANT` and the same deliberate omission of `security_invoker`. **RLS**: unaffected — the recon
views run as owner.

---

## F5 — one unpresented type turns the summary into an error

The fix is to make the summary survive a failing check, and there are exactly two shapes.

**Shape A — make the check not raise.** Give `recon_equation_breaks` a version that tolerates A14 by
catching it: wrap the `LATERAL` call in a `plpgsql` loop with a `BEGIN … EXCEPTION WHEN OTHERS` per
tenant, and emit a row for the tenant that raised. Cheap in mechanism, expensive in principle: a
blanket `EXCEPTION WHEN OTHERS` inside the one check whose job is to notice that the face is wrong is
how a check becomes green for the wrong reason, and this project has a recorded failure of exactly
that shape (ADR-0004's `TRUNCATE`). If it is done, it must emit a **break row**, never swallow, and
the reason must be the raise's own `SQLSTATE`/message.

**Shape B — order the summary so the diagnosis outlives the failure.** The structural problem is that
one branch of a `UNION ALL` can abort the other nine. Nothing in SQL fixes that inside one statement,
so the fix is in the sweep: `crates/db/src/reconcile.rs` reads the ten rows in one `SELECT`, and it
could instead read the nine non-raising checks first and the equation check second, reporting the
raise as an eleventh outcome rather than as a failure to read anything. That is a **crate change, no
migration, no snapshot change**, it keeps `EXPECTED_CHECKS` at 10 for the view, and it costs the
one-snapshot guarantee the sweep currently has — `sweep_in_one_snapshot` exists so that the ten
numbers are mutually consistent, and two statements are two snapshots unless the sweep takes an
explicit `REPEATABLE READ` transaction. ADR-0010's own comment says the isolation level is *"declared
for the day the sweep grows a second statement"*, so the machinery is already there for this.

**Shape B is the better one** and it is the cheaper one: it changes no SQL, breaks no grant, moves no
snapshot, and it converts "the operator sees nothing" into "the operator sees nine results and a
named refusal". Shape A additionally deserves consideration on its own merits, because `chart_lint`
already counts `type_unpresented` and the equation check dying adds nothing.

A third, orthogonal note: A14 raising at all is a decision (ADR-0012, A14) and is right for an
*issued statement* — a statement that silently drops a sub-book is worse than no statement. It is
wrong for a *sweep*, which wants a number. The two callers want different behaviour from the same
function, which is the actual root cause; a `p_strict boolean DEFAULT true` parameter would let the
sweep ask for the lenient form. That is a signature change: **snapshot**, and every call site.

---

## F6 — REFUTED, and the inverted defect it exposed

**Nothing to fix in the three views the finding names.** They already publish `numeric`, and
`schema/snapshot.txt` has recorded that since M1.

**The shape that does need a migration is the opposite one.** `trial_balance_at`,
`income_statement_for` and `balance_sheet_at` declare `amount_minor bigint` / `debits bigint` in their
`RETURNS TABLE` and force a `::bigint` on a total a legal book can put past 2^63−1 — so the report
that "dies on one large row and reports nothing" is the one the comment claims is protected. Widening
those declarations to `numeric` and dropping the casts is one function per statement, and it costs:

- **a drop-and-recreate, not a replace.** A changed return type cannot go through
  `CREATE OR REPLACE FUNCTION`, so the migration must `DROP` `recon_equation_breaks` first — it reads
  `balance_sheet_at` through `CROSS JOIN LATERAL` — and recreate it after. Its own
  `assets_minor`/`liab_equity_minor` are already `numeric`, so its signature does not move.
- **snapshot**: the three functions' argument and return signatures are recorded, so the M1 drift gate
  fails until `make schema-snapshot` is re-run.
- **check count unchanged**: `EXPECTED_CHECKS = 10` and the ten-check oracle both stand, and
  `reconciliation` is untouched.
- **no grant and no RLS change**: `EXECUTE` is `PUBLIC` by default on all three and none is named in
  the `GRANT` block; both `plpgsql` functions stay `SECURITY INVOKER` over the same tables.
- **the part that actually costs review**: `sqlx` return types for any caller move from `i64` to a
  decimal type. Nothing in `crates/` calls these functions today, so the cost is bounded to whatever
  the read path adds next — which is exactly the moment to decide, because a `numeric` on the wire is
  an API decision, not a schema one.

**A second, separate fix, outside reporting.** The batched writer's cross-member coalesce
(`crates/ledger/postgres/src/repository.rs`) re-adds at `bigint`, so two legal ceiling-sized postings
to one account turn into an `internal` 500 — or do not — depending on who else happened to be posting
in the same window. It wants a named refusal; `overflow` is already in the error-type grammar
(ADR-0014). No migration, no snapshot, no grant: a crate change and one e2e test.

---

## F7 — the current chart version's content can still change

The fix is to close the version. `refuse_stale_chart_version` refuses inserts below
`max(chart_versions.version)`; the missing half is a *seal*, so that the current version is closed
too once it has been reported through.

The mechanism that fits this schema: a nullable `sealed_at timestamptz` on `chart_versions`, the
trigger extended to refuse any `fs_lines` / `chart_presentation` insert naming a sealed version, and
both statement functions refusing to present through an **unsealed** version unless the caller names
it explicitly. That last clause is what makes it work: today's danger is not that a version is open,
it is that the open version is the *default*.

Costs: a new column (**snapshot**), the trigger function body (**snapshot**), both statement function
bodies (**snapshot**), a `chart_versions` `UPDATE` grant for whoever seals — which collides with
`refuse_mutation`, since `chart_versions` is append-only, so the seal cannot be an `UPDATE` and has to
be a separate `chart_version_seals` table with an `INSERT`-only grant. **Check count stays 10.** No
RLS change (the chart tables carry no policy by decision). `schema/chart.sql` gains a seal insert per
version and its comment about the A18 commit window gets shorter.

A much cheaper partial: promote `chart_lint`'s `line_unreachable` from `info` to `warn`, and add an
error rule for *an `fs_lines` row in the current version created after the version's first reported
statement* — which is unimplementable, because nothing records when a version was first reported
through. That absence is the finding, stated from the other side.

---

## F8 — `computed_at_xid` is bounded from below only

Two fixes, one trivial and one that costs a grant.

**The bound.** `recon_close_breaks` gains a second predicate and a second reason:

```
WHERE c.computed_at_xid < x.xact_id                                    -- cursor_precedes_close
   OR c.computed_at_xid > pg_snapshot_xmax(pg_current_snapshot())      -- cursor_above_assigned
```

`pg_snapshot_xmax` rather than `xmin`, for exactly F10's reason: `xmin` would make an honest close
break whenever a neighbour holds the horizon. **snapshot** changes (view body), check count **stays
10** (`close_typing` gains a reason), no grant, no RLS change. One e2e red-path test, next to the
existing `computed_at_xid = 1` one, which this pairs with symmetrically.

**The grant.** `computed_at_xid` sits under a table-wide `INSERT` on `ledger_period_closes` while
`ledger_entries.xact_id` is withheld by a column-level grant for the identical reason — a forged
value decides what a pinned report can see. The consistent fix is a column-level `INSERT` grant on
`ledger_period_closes` omitting `computed_at_xid`, and a `DEFAULT pg_current_xact_id()` on the column
so it takes the writer's own commit position. **That is a grant change and a column default change
(both snapshot), and it forecloses a design option**: a close that computes its checkpoint in one
transaction and records it in another could not then state the cursor it actually used. Whether a
one-transaction close can store a value all three predicates agree on is a separate spike's question,
and this grant change should wait for its answer.

**What neither fix repairs.** The reproduction showed the first backdated arrival lighting
`checkpoint_drift` with a `value_drift` reason pointing at the checkpoint, which was correct when
written. ADR-0010's disposition table says the checkpoint is derived and rebuildable, so the natural
operator response — rebuild it — returns the book to green with the disclosure still off. If
`recon_close_breaks` gains the bound above, the sweep names the cursor instead and the misdiagnosis
goes away; that is the strongest argument for the trivial fix.

---

## F9 — a wrong tenant is answered with silence, and the shape is not pinned

**The silence.** A fourth guard in the two `plpgsql` functions —
`IF NOT EXISTS (SELECT 1 FROM ledger_accounts l WHERE l.tenant_id = p_tenant) THEN RAISE …` — costs a
**snapshot** change and nothing else, and **it interacts badly with RLS, which is the real cost.**
There is no tenant registry, so "unknown tenant" can only be inferred from `ledger_accounts`, the
exact table the reader's policy filters. A `SECURITY INVOKER` guard therefore raises *"tenant t2 has
no accounts"* for a reader that merely lacks scope: it turns today's silence into a lie, and asserts
404 where the truth is 403. Three options, ascending:

1. **Word the raise so it is true under both mechanisms** — *"tenant % is not readable in this
   session, or has no accounts"*. The standard 403/404 collapse, one migration, **snapshot**, nothing
   else. Recommended.
2. **A `SECURITY DEFINER` existence probe**, which gives a correct 403-vs-404 distinction and hands
   every reader a **tenant-enumeration oracle** it does not have today. Today's silence is arguably a
   confidentiality *feature* being traded away.
3. **A `ledger_tenants` registry** — the only thing that distinguishes "no such tenant" from "empty
   tenant". A new table, an FK from every tenant-keyed table if it is to mean anything, its own RLS
   policy, and it reopens a question ADR-0011 closed twice.

`trial_balance_at` cannot carry any of this without becoming `plpgsql`.

**The `PUBLIC EXECUTE` half is separable and much cheaper, and should be done on its own.**
`REVOKE EXECUTE ON FUNCTION recon_equation_breaks(xid8, timestamptz) FROM PUBLIC;` plus a
`GRANT … TO openledger_recon;` is two lines in a migration, moves the **snapshot** (the ACL appears in
the routine section), and breaks nothing: `reconciliation` is owner-executed and the sweep is already
a member. It removes the "green over zero tenants" shape from every non-sweep role. The two statement
functions should stay `PUBLIC` — they are the read surface, and RLS is what scopes them.

**The shape.** Two shapes, both a migration and a **snapshot** change:

- Derive the `scopes` currency from pinned entries `UNION` accounts. This **undoes a deliberate
  decision** — the CTE's comment says an opened-but-unposted scope is still a scope and *"a report
  that cannot name it cannot claim completeness over it"* — so it is a decision reversal needing an
  ADR amendment, not a bug fix.
- Give `ledger_accounts` an `xact_id xid8 NOT NULL DEFAULT pg_current_xact_id()` and filter it in both
  `scopes` CTEs, pinning account existence exactly as entry existence is pinned. A new column on the
  account register, a new column-level `INSERT` grant exclusion for `openledger_app` (same reasoning
  as `ledger_entries.xact_id`), and a backfill decision for any deployed database. This is the honest
  one.

Neither changes the check count: no existing check reads account existence at a cursor. If the project
wants the defect *detected* rather than fixed, that is an eleventh check comparing a re-run
statement's `(currency, fs_line)` set against a stored issued face — which moves `EXPECTED_CHECKS`,
the oracle and `ALL_CHECKS`, and needs somewhere to store issued faces, which does not exist.

---

## F10 — `recon_cursor_breaks`' justification is wrong

The fix is the substitution the reproduction evaluated: `> pg_snapshot_xmin(...)` becomes
`>= pg_snapshot_xmax(pg_current_snapshot())` in `recon_cursor_breaks`, in both the `CASE` and the
`WHERE`. It removed the false positive and kept a far-future forgery, measured side by side.

Costs: one view body, so **snapshot**. Check count **stays 10**. No grant, no RLS change. And two
comments must change with it, because they are the finding: `recon_cursor_breaks`' claim that a
committed row's position *"is always retired below the horizon by the time the sweep runs"* is false
and must go, and `report_cursor()`'s honest-costs note should be cross-referenced from it rather than
contradicted forty lines later.

What the substitution gives up, stated so it is a choice and not an oversight: an `xact_id` forged
into the narrow band between the horizon and xmax — the currently-in-flight ids — is no longer
caught. That band is bounded by concurrency rather than by time, and the forgeries that buy anything
lie below the horizon (`predates_txn`, still caught by the second predicate) or far above it (still
caught). `pg_snapshot_xmax` must **not** be substituted into `report_cursor()`, which is the same
expression serving a different question: a report pinned at xmax would include rows still in flight.

The e2e suite should also lose a tolerance it no longer needs.
`a_sweep_racing_live_writers_never_reads_them_as_drift` currently accepts a transient
`cursor_forgery` and asserts only that no *other* check fires; with the xmax bound, the mid-race sweep
should be able to assert exit 0 unconditionally, which is a strictly stronger test. That is a crate
test change with no migration.
