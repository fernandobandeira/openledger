# Spike 024 — findings

Every claim below is labelled **proven** (with the command and the captured output) or
**unmeasured / reasoned** (with the reasoning). Nothing here is a millisecond: the timing pass is
specified in `MEASUREMENT-PLAN.md` and has not been run.

Raw evidence is in `out/`. The commands are `./build-book.sh`, `MODE=identity DB=spike024i
./build-book.sh`, `./run-cursor-arms.sh`, `./run-adversary.sh`, `./run-out-of-order.sh`,
`./run-empty-close.sh`, `./run-partitioning.sh`, `./run-plans.sh`, and the `psql -f sql/…` files each
of those names.

---

## 0 · The headline

**The checkpoint can be wired into `balance_sheet_at` and `trial_balance_at`, and the rewritten form
agrees with the from-inception form to the minor unit at all 60 (tenant, cursor, as-of) points on a
book containing every case that could break it — under *both* close conventions.** It cannot be
wired into `income_statement_for`, and the reason is structural rather than incidental.

**But the checkpoint does not currently mean what the schema says it means.** ADR-0011 §3's A4
sentence — *"a temporary account's checkpoint row is exactly 0 and `retained_earnings` carries the
swept earnings"* — is **false on the shipped mechanism**, and it is not satisfiable by any
one-transaction close that also keeps a reproducible cursor. Fixing it is a change to the close's own
arithmetic and to two reconciliation views, and it must land in the same migration as the read path.

**`recon_checkpoint_breaks` can be bounded**, with full drift-class coverage, at the cost of two
invariants the schema does not state — one of which is the same invariant the A4 sentence needs.

**Partitioning `ledger_period_balances` by period is legal and cheap in constraints**, keeps both
foreign keys, all three RLS policies and every grant, and leaves the reconciliation sweep at ten
zeros. What it costs is DDL the app role cannot issue, a partition-per-tenant-vocabulary problem, and
a **hole in the schema-snapshot test**, which cannot see a partition key, a partition bound, or a
detachment.

Four defects were found along the way that nobody was looking for: a false-positive
`cursor_precedes_close`, a false-positive `cursor_forgery` that makes `openledger reconcile` exit 1
on a healthy book, an unbounded-above `computed_at_xid` under a table-wide `INSERT` grant, and a
period with no revenue or expense that cannot be closed without breaking the sweep.

---

## 1 · What a one-transaction close can actually store — **proven**

`./run-cursor-arms.sh` → `out/cursor-arms.txt`. Six cells, three cursor values × two horizon states.

| arm | `computed_at_xid` vs close's own `xact_id` | stored checkpoint | `close_typing` | `checkpoint_drift` | reader vs from-inception |
| --- | --- | --- | --- | --- | --- |
| `xmin_strict`, horizon caught up | 16000 = 16000, **equal** | `fee_revenue = -500`, **no `retained_earnings` row** → **pre-close** | 0 | 0 | **0 disagreements** |
| `xmin_strict`, older writer commits after the close | 16024 **<** 16025 | pre-close | **1** | 0 | 0 disagreements |
| `own_xid`, horizon caught up | equal by construction | `fee_revenue = 0`, `retained_earnings = -500` → **at-close** | 0 | **2** | **2 disagreements** |
| `own_xid`, older writer | equal by construction | at-close | 0 | **4** | **4 disagreements** |
| `identity`, horizon caught up | 16108 = 16108 | **at-close** | 0 | 2 *(shipped view, see below)* | **0 disagreements** |
| `identity`, older writer | 16132 **<** 16134 | **at-close** | **1** | 2 *(shipped view)* | **0 disagreements** |

Five things fall out, and each is separately load-bearing.

### 1.1 Equality is what the shipped close stores, and only on an idle cluster — **proven**

`spike_close` binds `pg_snapshot_xmin(pg_current_snapshot())` before acquiring an xid. On an idle
cluster the snapshot's xmin *is* the next xid to be assigned, which is the one this transaction is
about to take — so `computed_at_xid` comes out **exactly equal** to the closing transaction's own
`xact_id`. Measured on the main book: all four closes equal
(`out/checkpoint-content-asspecified.txt`, `equal = t` four times). `recon_close_breaks` admits
equality (`c.computed_at_xid < x.xact_id`), so it is green.

Put one other write transaction on the cluster and equality is gone: 16024 < 16025, and
`recon_close_breaks` fires `cursor_precedes_close` on a close whose checkpoint reconciles cleanly and
whose reader agrees with the journal to the minor unit. **`cursor_precedes_close` is a false positive
on any cluster that is not idle.** The audit's hypothesis is confirmed by observing both states.

### 1.2 The shipped checkpoint is the PRE-close position, and three artifacts say otherwise — **proven**

On the main book, `bk/2026-01/USD` (`out/checkpoint-content-asspecified.txt`):

```
 period_code |       purpose       | input | output | dr_pos
 2026-01     | fee_revenue         |     0 |    500 |   -500
 2026-01     | credit_loss_expense |   100 |      0 |    100
 (no retained_earnings row at all)
```

`fee_revenue` is **−500**, not 0, and `retained_earnings` has **no row**. The closing entries carry
the closing transaction's own `xact_id`, which under equality equals `computed_at_xid`, and the
recompute's bound is **strict** — so they are excluded from both the stored row and the recompute.
Self-consistent, and the opposite of what these three say:

- `migrations/00001_baseline.sql:882-893` (the `ledger_period_balances` comment): *"AT-CLOSE balances
  (A4) … so a temporary account's row is 0 and retained_earnings carries the swept earnings."*
- `migrations/00001_baseline.sql:1985-1990` (`recon_close_breaks`' header note): *"the closing
  entries sit BELOW the cursor and ARE included in the checkpoint … the checkpoint is the AT-close
  position, not the pre-close one."*
- ADR-0011 §3: the same sentence.

**The prose is wrong, not the arithmetic.** `close_disclosures`' `NOT EXISTS` carve-out is the tell
the audit spotted: it is only needed because the closing entries *are* at or above
`computed_at_xid` — i.e. because the checkpoint is pre-close.

### 1.3 AT-close and reproducible-cursor are mutually exclusive in one transaction — **proven for the two reachable values, reasoned for the impossibility**

**Proven:** the `own_xid` arm gets an at-close checkpoint and loses reproducibility. With an older
writer holding an uncommitted posting of 70 across the close and committing after it, the checkpoint
reader **loses that posting entirely**:

```
       purpose       | inception_dr | reader_dr | inception_cr | reader_cr
 customer_receivable |        10570 |     10500 |            0 |         0
 paid_in_capital     |            0 |         0 |        10070 |     10000
```

The held entry's `xact_id` is *below* `computed_at_xid` (it was assigned earlier), so it is not in
tail B; and it was invisible to the close's own `INSERT … SELECT`, so it is not in the checkpoint
either. **A silent, permanent understatement of a real position** — and `recon_checkpoint_breaks`
reports it (4 rows), so it is at least detectable, but the statement is already wrong.

**Reasoned:** ADR-0011 §1 proves the cursor must be a value below which the set of rows is fixed for
all time, and that `pg_snapshot_xmin` is the only such value in this schema. `pg_snapshot_xmin` is
`<=` the caller's own xid whenever the caller holds one, so a cursor **above** the closing
transaction's own entries is not reachable from inside the transaction that writes them. There is no
third value: `pg_snapshot_xmax` is `latestCompletedXid + 1` and admits in-flight transactions that
commit later, which is the `max(xact_id) + 1` failure ADR-0011 §1 already refutes; and `xid8` has no
successor operator, so `own_xid + 1` is not expressible without a text or numeric round trip.
**A4 as written is unsatisfiable.**

### 1.4 The fix is to name the transaction, not to loosen the inequality — **proven**

The audit's cheapest proposal was `e.xact_id <= c.computed_at_xid` in the recompute and
`e.xact_id > c.computed_at_xid` in `close_disclosures`. **Tested and refused.** `<=` is equivalent to
"include the close's own entries" *only when* `computed_at_xid` equals the closing transaction's own
xid — which is the `own_xid` arm, which §1.3 just proved is not a reproducible cursor. On a busy
cluster the two values differ (16132 vs 16134, measured), `<=` admits nothing extra, and the stored
row silently reverts to pre-close while the prose still says at-close.

**The close's own transaction is already named** in `ledger_period_closes.transaction_id`, under
`fk_closes__txn`, `fk_closes__txn_kind` and `uq_closes__txn`. So it does not need to be reachable
through the cursor at all. The bound becomes

```sql
e.xact_id < c.computed_at_xid OR e.transaction_id = c.transaction_id
```

and the cursor keeps its one job — bounding *everything else* — with no relationship to the closing
transaction's own position required.

Measured: the `identity` arm stores the at-close position under **both** horizon states, and the
reader agrees with the from-inception aggregate in both (`reader_disagreements = 0`). On the main
book built this way (`MODE=identity DB=spike024i ./build-book.sh`,
`out/checkpoint-content-identity.txt`), every temporary account is exactly 0 at every close and
`retained_earnings` carries −400, −1200, −2160 across the three:

```
 period_code |       purpose       | input | output | dr_pos
 2026-03     | fee_revenue         |  1260 |   1260 |      0
 2026-03     | interchange_revenue |   900 |    900 |      0
 2026-03     | credit_loss_expense |   200 |    200 |      0
 2026-03     | retained_earnings   |   100 |   2260 |  -2160
```

That is A4's sentence, true for the first time.

### 1.5 The two conventions produce the *same statement* — **proven**

The 60-point grid returns **zero disagreements on both books**, and the worked balance sheet at
2026-04-01 is byte-identical between them: receivables 12,290 / equity 10,000 / retained earnings
2,160 / undistributed 130, in both currencies (`out/agreement-as-specified.txt` §7–8,
`out/agreement-identity.txt` §7–8). **What differs is what a human reading `ledger_period_balances`
directly is told** — a pre-closing trial balance under a comment promising a post-closing one. That
is the whole cost of getting it wrong, and it is a documentation-shaped cost with a real audience:
the checkpoint is the one derived table an adopter can read without writing Rust.

### 1.6 What must change, and where

| artifact | change |
| --- | --- |
| the close's `INSERT … SELECT` (writer, M5) | bound becomes `xact_id < C OR transaction_id = <this close>`, and the checkpoint must be written **after** the closing entries so they exist to aggregate |
| `recon_checkpoint_breaks` | same bound. **Must land in the same migration**: an at-close checkpoint under the shipped strict recompute reports drift on every close — measured **12 rows** on the identity book (`out/book-identity.txt`), falling to **0** once `sql/26_recon_identity.sql` is applied |
| `close_disclosures` | `xact_id >= computed_at_xid AND transaction_id <> c.transaction_id`. The wide `NOT EXISTS` carve-out becomes dead — see §3.4, where it is tested rather than assumed |
| `recon_close_breaks` | `cursor_precedes_close` is **withdrawn** as a false positive (§1.1) and replaced by four real classes (§3.3). Note the inversion: the shipped check refuses a cursor *below* the close; the correct one refuses a cursor *above* it |
| `ledger_period_balances` comment, `recon_close_breaks` header note, ADR-0011 §3, roadmap M5 | the AT-close claim becomes true rather than aspirational; the mechanism sentence changes from "held at or above the closing transaction's own `xact_id`" to "the close's own transaction is admitted by identity" |

---

## 2 · The statements, rewritten

### 2.1 `balance_sheet_at` takes the treatment; the rewritten form agrees everywhere — **proven**

`sql/20_candidates.sql` + `sql/25_candidates_identity.sql`; differential in `sql/30_agreement.sql`.

```
=== 2. the same, as one number. MUST be 0 ===
 total_balance_sheet_disagreements
                                 0
=== 3. every disagreeing line, if any ===
(0 rows)
```

60 points on the `xmin_strict` book (`out/agreement-as-specified.txt`) and 60 on the `identity` book
(`out/agreement-identity.txt`), each comparing 20 statement lines by amount, caption, side and sort
order through a FULL JOIN. Covered: no close at all (`nc`), one close, three closes, a backdated
ordinary posting, a resolution backdated into a closed period, a reversal of a posted transaction
backdated into a closed period, a voided pending, a pending never resolved, two currencies closed to
different depths, as-of exactly on each of three close boundaries, as-of mid-period, and as-of
`infinity`. Re-verified on the 30,024-entry / 12-close book (`out/plans.txt`): 0 disagreements at
four instants.

**Three things in the rewritten body are not in ADR-0011 §3**, and each was necessary:

1. **The boundary is chosen per CURRENCY.** `pk_closes` is `(tenant_id, period_code, currency)`, so
   USD closed through March and EUR through January is an ordinary state — and it is the state the
   book is built in, on purpose. A boundary chosen per *tenant* reads the wrong checkpoint for one of
   them.
2. **The anchor must be visible at the report's cursor.** A checkpoint computed at C is the set
   `{xact_id < C}`; a report pinned at P < C must not see rows between P and C. Under the identity
   convention the last thing to become visible is the *closing transaction*, so the guard is on
   **its** `xact_id`, not on `computed_at_xid`. Without it, a close that happened after a statement
   was issued restates that statement upward — the exact property the cursor exists to prevent. The
   P0 column of the grid is what tests it: P0 was captured before any close existed, and the
   rewritten form still agrees with the from-inception form at all ten as-of instants.
3. **The three terms are disjoint and their union is exact.** checkpoint = `eff < boundary` and
   admitted by the cursor-or-identity rule; tail B = `eff < boundary`, `xact_id >= C`, *and not the
   close's own transaction*; tail A = `eff >= boundary`. Drop the "not the close's own transaction"
   clause and the closing legs are counted twice — measured in the `own_xid` arm as `fee_revenue`
   reading 1,000 against a true 500.

With **no close at all** the form degrades to today's behaviour with no special case: boundary is
`-infinity` (and `ck_entries__effective_finite` forbids an entry there), so tail B is empty, tail A
is everything, and the checkpoint term joins nothing. Tenant `nc` is the proof.

### 2.2 The A14 guard takes the same treatment — **proven for the positive case, and a red proof is owed**

`balance_sheet_at` is `plpgsql` for two reasons and the second, A14, runs its own `EXISTS` over
`ledger_entries` with **no lower bound**. Wiring the aggregate and leaving the guard scanning from
inception leaves the function exactly as slow as it was.

The equivalent form asks the same question of the checkpoint population, gated on
`debits + credits > 0`. That is exact because `ck_entries__amount_positive` is
`CHECK (amount_minor > 0)` — so an account with any posted entry below the boundary has a non-zero
*gross* checkpoint row, and a dormant account for which the close wrote 0/0 is correctly *not*
treated as having entries, matching the shipped guard. Verified indirectly by the grid: the rewritten
function is called 120 times across the two books and raises in none of them, and the chart presents
every type in use.

**Unmeasured:** the negative control — an account type with posted entries and no
`chart_presentation` row at the requested version — was **not** run against the rewritten guard. The
chart is seeded whole by `schema/chart.sql` and constructing a partially-presented chart version
needs `chart_versions` / `chart_presentation` rows this spike did not build. The equivalence argument
above is the reasoning; the red proof is owed and belongs in the migration's own test.

### 2.3 `trial_balance_at` takes it, as a difference of two positions — **proven, with a defect found and fixed**

`trial_balance_at` is a **flow** over `[p_from, p_to)`, so the checkpoint can only enter as
`prefix(to) − prefix(from)`. That is exact because `prefix()` sums *gross* debits and credits over
`{eff < x, xact_id < cursor, posted}` and that set is monotone in x. Zero disagreements across 9
windows × 60 cells on both books.

**The first version of the difference form was wrong, and the grid caught it.** With `p_from > p_to`
— an inverted window — the shipped body returns **no rows** (`eff >= from AND eff < to` is empty)
while the difference form returns **negative** debits and credits:

```
              account_id              | currency | shipped_dr | cand_dr | shipped_cr | cand_cr
 0ae3f014-ccec-53d6-68be-369e6e633da4 | EUR      |            |       0 |            |  -10000
 198e4c3f-2fa9-9871-7f17-f3406a745aeb | USD      |            |    -300 |            |       0
```

(`out/inverted-window.txt`.) Nothing in the shipped signature refuses an inverted window and nothing
would have noticed: a negative gross debit is not a value any caller checks. `PROPOSAL.sql` therefore
carries an explicit refusal, which makes the function's contract *stronger* than the one it replaces.

**What the difference form costs, and it is not free.** Each prefix carries a tail from its own
boundary, so the work is roughly `(to − boundary_to) + (from − boundary_from)` rather than
`(to − from)`. For a window well inside one period that is **more** work than the shipped body does;
for a window whose lower bound is deep in history — the position reading, `p_from = '-infinity'` — it
is bounded by two period lengths where the shipped body is unbounded. **Which side of that trade a
caller is on is a number and is in `MEASUREMENT-PLAN.md`.**

### 2.4 `income_statement_for` cannot take it, and the reason is structural — **proven**

Three independent reasons, and the third is decisive:

1. **It is a flow.** ADR-0011 §4 says so in as many words: *"a **flow**, so a half-open range"*. A
   cumulative checkpoint is a position; entering it requires the same difference form as §2.3.
2. **The accounts it reports are exactly the accounts the close zeroes.** Under the canonical
   at-close convention every revenue and expense checkpoint row is **exactly 0** — measured, §1.4. So
   the checkpoint stores nothing but zeros for every line the income statement prints, and
   `prefix(to) − prefix(from)` between two close boundaries is `0 − 0 = 0`. The flow is recoverable
   only by adding back the closing entries — which the income statement is specified to *exclude*
   (`NOT EXISTS` against `ledger_period_closes`, the mechanism ADR-0011 §2 chose over hledger's tag,
   ERPNext's flag and Odoo's account type).
3. **There is nothing from-inception to remove.** Its `dp` CTE carries
   `e.effective_at >= p_from AND e.effective_at < p_to`. Its cost is O(entries in the window) and the
   window is the caller's period. The checkpoint cannot beat a range scan of the range it was asked
   about.

**`income_statement_for` needs no checkpoint and gets none.** That is the answer either way, said
plainly.

### 2.5 A prior claim withdrawn: "they scan `ledger_entries` from inception" is true of one function out of three

**Refuted.** Both of these say it of all three:

- ADR-0011 §3: *"`balance_sheet_at`, `income_statement_for` and `trial_balance_at` never reference
  `ledger_period_balances` (proven from `pg_get_functiondef`), so they **aggregate `ledger_entries`
  from inception**."*
- roadmap M5: *"the shipped `balance_sheet_at` / `income_statement_for` / `trial_balance_at` never
  read `ledger_period_balances` — proven from `pg_get_functiondef` — so they **scan `ledger_entries`
  from inception**."*

The first half of each sentence is correct and is spike 020's finding. The second half is correct of
**`balance_sheet_at` only.** `income_statement_for` and `trial_balance_at` both carry
`e.effective_at >= p_from`, a caller-supplied lower bound, so neither scans from inception unless the
caller passes `-infinity`. Read from the shipped bodies at `migrations/00001_baseline.sql:1052`
(`trial_balance_at`), `:1090` (`income_statement_for`) and `:1194` (`balance_sheet_at`).

The correction matters because it changes what M5 is *for*: the from-inception scan to be removed is
`balance_sheet_at`'s position aggregate, its earnings plug and its A14 guard — three scans in one
function — plus `recon_equation_breaks`, which calls that function at `('infinity', report_cursor())`
per tenant on **every reconciliation sweep**. It is not three functions that need fixing; it is one
function that the sweep calls.

### 2.6 The tail indexes: one is served today, one is not — **proven (plans), unmeasured (worth)**

`./run-plans.sh` → `out/plans.txt`. 203 accounts, 30,024 entries, 12 closes. Plain `EXPLAIN`; every
number is the planner's **estimate**.

| term, tenant-wide | default plan | forced index | with the candidate index |
| --- | --- | --- | --- |
| tail A — `effective_at` in `[boundary, as_of)` | **Seq Scan**, est. 1243.60 | Bitmap Index Scan on `ix_entries__effective`, est. **946.65** | Bitmap Index Scan on `ix_entries__tenant_effective`, est. **45.44** |
| tail B — `effective_at < boundary`, `xact_id >= C` | **Index Scan on `ix_entries__asof_commit`**, est. 730.09, `Index Cond: tenant_id … AND xact_id >= … AND xact_id < …`, `effective_at` in **Filter** | — | Index Scan on `ix_entries__tenant_commit`, est. **224.62**, `effective_at` moves **into** the Index Cond |

So: **PostgreSQL 18's btree skip scan does rescue tail B** — `ix_entries__asof_commit` is chosen
without help even though `account_id` sits between `tenant_id` and `xact_id`. ADR-0011 §3's cited
plan (`Index Scan using ix_entries__asof_commit`) therefore holds tenant-wide as well as
single-account, which is more than the ADR's own measurement established: for contrast, the
single-account form it actually measured plans at est. **8.32**.

Tail A is **not** served: the planner prefers a sequential scan, and forcing the index costs ~21×
more than the leading-column alternative by estimate — at 203 accounts. The skip factor gets worse
with account count, which is the direction any real book moves.

**What the candidate indexes cost, measured on this book:** `ix_entries__tenant_effective` and
`ix_entries__tenant_commit` are **224 kB each** against a 3,944 kB heap and 6,448 kB of existing
indexes — about **7% more index bytes** for both — and each is *smaller* than `ix_entries__effective`
(992 kB) because it drops `account_id`. **Whether that is worth its write-path cost is a number** and
is in `MEASUREMENT-PLAN.md`: ADR-0013 does not get to wave through two new indexes on the hot table
on an estimate.

### 2.7 The statement functions are opaque to `EXPLAIN` — **proven, and it undermines a claim in ADR-0011 §4**

```
EXPLAIN SELECT * FROM balance_sheet_at_ckpt('big', '2027-01-01 00:00+00', report_cursor());
 Function Scan on balance_sheet_at_ckpt  (cost=0.26..10.26 rows=1000 width=184)
```

Identical for the shipped `balance_sheet_at`. Both are `plpgsql`, so `EXPLAIN` shows a `Function
Scan` and nothing about the inner query. ADR-0011 §4 states *"their inner query plans the same nested
loop"* — **that is not observable through `EXPLAIN` on the function** and cannot have been verified
that way. It is checkable with `auto_explain.log_nested_statements`, which this spike did not enable.
Recorded as unverified rather than contradicted.

---

## 3 · The bounded reconciliation

### 3.1 The bounded form, and why it is bounded — **design; the shape is proven from the plan, the cost is unmeasured**

`sql/50_bounded_recon.sql`. The checkpoint is **cumulative** — the recompute has no lower bound on
`effective_at` — so consecutive checkpoints differ by exactly one close's own arrivals. Instead of
recomputing C levels, assign each entry the index of the **first close whose checkpoint contains
it**:

```sql
LEAST(
  NULLIF(GREATEST(width_bucket(e.effective_at, <ends ascending>)      + 1,
                  width_bucket(e.xact_id,      <cursors, same order>) + 1),
         n + 1),
  <the index of the close whose transaction this entry belongs to>   -- identity term
)
```

`width_bucket(anyelement, anyarray)` is a binary search, so the assignment is **O(log C) per entry**
rather than O(C); `xid8` has a default btree opclass (`xid8_ops`, `opcdefault = t`, verified from
`pg_opclass`) so it works on the cursor axis too. `LEAST` ignores NULLs in PostgreSQL, so the identity
term can only pull the index earlier and is inert for an ordinary entry.

Then compare the *difference* of consecutive stored levels against the sum of entries at that index.
**Proven from the plan** (`out/bounded-plan.txt`): the entries side is exactly

```
->  Seq Scan on ledger_entries e  (cost=0.00..793.24 rows=30024 width=68)
```

**one pass**, against the level form's bitmap scan inside a nested loop over 12 closes emitting
40,037 rows into a `HashAggregate` (est. 7011.24).

The honest bound is **O(entries + stored rows)**, not O(entries). The presence half (§3.2) inspects
every stored checkpoint row, and that is the floor: you cannot check N stored rows in fewer than N.
Since stored rows = accounts × closes, that term is the size of the table being checked.

**A first draft was 8× worse than this and the plan said so.** Referencing the two close-index views
plainly re-planned them at every reference — seven `WindowAgg` nodes — and the estimate for the whole
view was 60,100, dominated by that rather than by the single entries pass. Materializing them (a
dozen rows) brought it to 6,987.

**The estimates at 12 closes and 30,024 entries are a dead heat**: level **7,199.08**, bounded
**7,363.12**. That is not a refutation of the asymptotic claim — 12 closes on 30k entries is exactly
where O(E×C) has not yet hurt — but it is the honest state of the evidence, and it is why the ladder
in `MEASUREMENT-PLAN.md` runs to 48 closes and not 12.

### 3.2 The difference comparison alone LOSES a drift class, and the presence half restores it — **proven**

`sql/55_drift_classes.sql` and `sql/56_span_is_load_bearing.sql`, run on both books
(`out/drift-classes-both.txt`).

| cell | level form | bounded form | bounded reasons |
| --- | --- | --- | --- |
| **clean book (negative control)** | **0** | **0** | — |
| value forged by +1 on a middle close | 1 | **2** | `spurious_row, value_drift` |
| spurious row, 4,242 on an unused account | 1 | **2** | `spurious_row, value_drift` |
| missing row, middle close, account moved | 1 | **3** | `missing_row, row_span, value_drift` |
| **missing row, trailing close, account did NOT move** | 1 | **1** | **`row_span`** |

And the falsification of "the presence half matters" (`out/span-load-bearing.txt`):

```
 level_form | bounded_with_span | bounded_without_span
          1 |                 1 |                    0
```

**Every drift class the level form catches, the bounded form catches** — and the last row is the whole
reason the presence half exists. A trailing checkpoint row deleted for an account that had no arrivals
in that period produces a stored difference of 0 against recomputed arrivals of 0: a pure difference
comparison has *nothing to disagree about*. The level form sees a missing row against a non-zero
recomputed level. Without the span check the bounded form reports **0** where the level form reports
1 — a cheaper check that misses a drift class, which is a regression. With it, 1 and 1.

Key-set equivalence on the clean book is exact: zero rows on either side of the `level_only` /
`bounded_only` comparison, on both books.

**Two interface changes an operator will see**, and they must be documented rather than discovered:

- **A single forged value produces two rows, not one** — the difference at close *k* and at close
  *k+1* both disagree. More sensitive, not less; a different row count.
- **The `reason` labels are less precise.** A forged value shows as `spurious_row, value_drift` where
  the level form says `value_drift`, because the second affected difference has no arrivals row to
  pair with. The break is real and the account and period are right; the word is misleading. A fourth
  reason (`delta_drift`) would fix it and is left to the ADR.

### 3.3 The bounded form needs two invariants the schema does not state — **proven**

`./run-out-of-order.sh` → `out/out-of-order.txt`. February closed **after** March, which nothing in
the schema forbids: `pk_closes` is `(tenant_id, period_code, currency)` and `ex_periods__no_overlap`
orders the *periods*, not the closes over them.

```
 period_code |        ends_at         | computed_at_xid | close_txn_xid
 2026-01     | 2026-02-01 00:00:00+00 |           16512 |         16512
 2026-02     | 2026-03-01 00:00:00+00 |           16511 |         16511

shipped sweep total breaks = 0
```

**Legal.** Ten checks, zero breaks. And then:

| | |
| --- | --- |
| the **level** form | **0** breaks — each checkpoint is individually recomputable at its own cursor, so nothing is wrong with either row |
| the **bounded** form | **2** breaks, `value_drift` — **false positives**. The stored levels no longer nest, so their difference is not a difference of nested sets |
| the **reader** | **0** disagreements at all four as-of instants — out-of-order closing is a problem for the *check*, not for the *statement* |
| the AT-close claim | degrades: January's checkpoint carries `retained_earnings = -500` and February's `-1200`, because February swept before January existed |

So the bounded form ships **with the check that states the invariant**, and the coverage argument
becomes: order broken ⟹ reported as its own class; order clean ⟹ the difference comparison is
equivalent to the level comparison. `recon_close_order` (`sql/50_bounded_recon.sql`) catches this book
with two reasons at once:

```
 period_code | computed_at_xid | txn_xact_id | prev_cursor | prev_txn_xact_id |           reason
 2026-02     |           16511 |       16511 |       16512 |            16512 | cursor_not_monotone
 2026-02     |           16511 |       16511 |       16512 |            16512 | previous_close_above_cursor
```

`previous_close_above_cursor` is the one that matters most, and it is **not** only the bounded form's
requirement: it is the condition that makes the AT-close claim true for *every* close. If close *k*'s
cursor does not clear close *k−1*'s own transaction, close *k*'s checkpoint silently omits the
previous sweep. It is satisfiable in any healthy deployment — the horizon advances between two monthly
closes — and where it is not, ADR-0011 already accepts that *"a close cannot complete while xmin is
pinned below it"*. So the close should **refuse to run** while the horizon has not cleared the previous
close: a precondition check, not a trigger.

`recon_close_order` also carries the two forgery bounds of §3.5. All four classes report zero on every
clean book in this spike.

### 3.4 `close_disclosures`' wide carve-out becomes dead — but only under the order invariant — **proven both ways**

`sql/27_carveout_dead.sql`. On the identity book (`out/carveout-dead.txt`):

```
 with_wide_carveout | without_it | rows_only_without_it
                 18 |         18 |                    0
```

Dead: removing the wide `NOT EXISTS` changes no row, and the population that would make it live —
*another* close's entries falling below this close's boundary and above its cursor — is empty.

On the **out-of-order** book the same query says:

```
 with_wide_carveout | without_it | rows_only_without_it
                  0 |          2 |                    2
 this_close | other_close | entries
 2026-02    | 2026-01     |       2
```

**Not dead.** January's own closing legs are effective below February's boundary and above February's
cursor, so without the wide carve-out they would be disclosed as backdated arrivals. So the removal is
safe **exactly when `recon_close_order` is green**, and the ADR should say that rather than describe
the carve-out as redundant.

### 3.5 `computed_at_xid` is bounded from below only, and sits under a table-wide grant — **proven**

`./run-adversary.sh` → `out/adversary.txt`.

**Forged upward to 2^62:**

| | |
| --- | --- |
| `recon_close_breaks` | **0** — green |
| `close_disclosures` for that period | **0** — the disclosure feed for that period is silenced entirely |
| `recon_checkpoint_breaks` | 4, labelled **`value_drift`** |
| the proposed `recon_close_order` | **2**: `cursor_above_close`, `cursor_above_horizon` |

The audit predicted the drift would surface "only later"; on this book it surfaces immediately, because
backdated arrivals above the true cursor already exist and the inflated recompute picks them up. **On a
book with no arrivals above the true cursor it would not surface at all** — and either way it is
labelled as a value discrepancy when the cause is a forged cursor. Precise statement: detected on this
book, mislabelled, and undetectable in general.

**Forged downward to 1:** `recon_close_breaks` **1** (caught), `recon_checkpoint_breaks` 8, proposed
check 2 (`cursor_not_monotone`, `previous_close_above_cursor`).

**The correct upper bound is `pg_snapshot_xmin`, not `pg_snapshot_xmax`** — tighter than the audit
suggested, and for a reason: `computed_at_xid` is a *captured* xmin, and the cluster xmin is
non-decreasing (it is the minimum over the running set, xids are assigned monotonically, and the set
only loses members or gains larger ones). So any honestly captured value is `<=` the current xmin.
`xmax` would admit a cursor above the current horizon, which is exactly the forgery
`recon_cursor_breaks` refuses for an entry. **Reasoned, not measured**: the forged-2^62 cell shows the
check firing, not that the bound is the tightest sound one.

**The grant surface is confirmed:**

```
       relname        |     attname     | app_can_insert
 ledger_entries       | xact_id         | f
 ledger_period_closes | computed_at_xid | t
```

`ledger_entries` carries a **column-list** `INSERT` grant that omits `xact_id` (ten columns granted,
verified from `pg_attribute.attacl`). `ledger_period_closes` carries a **table-wide**
`GRANT SELECT, INSERT` (`migrations/00001_baseline.sql:2518-2519`), so the app role can supply any
`computed_at_xid` it likes. But note what a column-list grant *cannot* do here: the close must write
`computed_at_xid`, so the column cannot be withheld from the writer. **The fix is the upper-bound
check, not the grant** — and that is the difference from the journal case, where the writer never
needs to supply `xact_id` at all.

---

## 4 · Two defects found by the correctness gate

### 4.1 `recon_cursor_breaks` reports `above_horizon` for honest entries — **proven**

`./run-adversary.sh` cell A. A holder acquires an xid with `pg_current_xact_id()` and writes nothing; a
second session commits one ordinary posting; a third session runs the sweep **exactly as `openledger
reconcile` does — `BEGIN TRANSACTION READ ONLY`, holding no xid of its own**:

```
 xmin_pinned_by_the_holder | xmax  | newest_committed_entry_xid
                     16164 | 16166 |                      16165

 shipped_above_horizon_breaks | xmax_bounded_breaks | sweep_would_exit_1
                            2 |                   0 |                  1
```

`recon_cursor_breaks` bounds an entry's `xact_id` by `pg_snapshot_xmin`, whose comment asserts *"a
committed row's commit position is always retired below the horizon by the time the sweep runs"*. That
is false whenever any transaction older than the entry is still running — which on a busy database is
most recent entries. **`SELECT * FROM reconciliation` reports `cursor_forgery <> 0` and `openledger
reconcile` exits 1 on a healthy book.**

Not hypothetical, and not only reachable by construction: the first run of `run-cursor-arms.sh` observed
**6 total breaks** on a correct book while the other spike held the cluster horizon at 15797 — and the
stored checkpoints came out **empty** for the same reason. Every close in every script in this spike is
now preceded by a horizon poll because of it.

**The fix is one word.** `pg_snapshot_xmax` is `latestCompletedXid + 1`, so no *committed* xid can reach
it: `xmax_bounded_breaks = 0` on the same book at the same instant. An earlier version of this cell
posted *inside* the measuring transaction and reported 2 under both bounds — a snapshot's xmax equals
the observer's own xid, so the observer was flagging itself. The sweep holds no xid, which is why the
corrected cell is the one that answers the question.

### 4.2 A period with no revenue or expense cannot be closed without breaking the sweep — **proven**

`./run-empty-close.sh` → `out/empty-close.txt`. A book with a capital injection and nothing else — a
real balance sheet, no temporary-account movement:

```
before the close:  breaks = 0

after closing a period with nothing to sweep:
       check_name        | breaks
 unbalanced_transactions |      1

            transaction_id            |     kind     | status | leg_count |   reason
 01a05d7f-8c38-7f07-9429-846797e79a9e | period_close | posted |         0 | no_entries

openledger reconcile would exit 1
```

The close sweeps one posting per temporary account with a non-zero balance (ADR-0011 §2, and the
`HAVING` in every implementation of it), so a period with nothing to sweep writes a `period_close`
transaction with **zero entries** — and `recon_transaction_breaks` flags every entryless transaction as
`no_entries`, the ADR-0004 TRUNCATE scar's class. Migration 00003 carved out the **void** and nothing
else. The close is otherwise entirely well-formed: the `ledger_period_closes` row is there,
`computed_at_xid` is right, and the checkpoint has its two rows.

The narrow carve-out closes it, tested on the same book:

```
 breaks_with_the_close_carve_out
                               0
```

`x.kind = 'period_close' AND EXISTS (a ledger_period_closes row naming it)` — a key lookup, exactly the
device ADR-0011 §2 chose for the income statement's exclusion, and tight: `fk_closes__txn_kind` already
forces the kind and `uq_closes__txn` makes the naming one-to-one.

**Operational note, measured incidentally:** the close upserts the balance-cache row of every temporary
account it sweeps, so **any open writer holding one of those rows blocks the close**. The first version
of `run-cursor-arms.sh` hung on exactly this; the concurrent holder was moved off `fee_revenue` for the
experiment, and the finding is recorded here instead.

---

## 5 · Partitioning `ledger_period_balances` by period

`./run-partitioning.sh` → `out/partitioning.txt`. Applied by hand in `spike024part`; two tenants with
**different period-code vocabularies** (`2026-01`, `2026-02` and `FY2026Q1`) on purpose.

### 5.1 `PARTITION BY LIST (period_code)` is legal under the tenant-leading primary key — **proven**

```
   partition_key
 LIST (period_code)

 pk_period_balances | PRIMARY KEY (tenant_id, period_code, currency, account_id)
```

The primary key is **unchanged** and still tenant-leading. A partition key must be a *subset* of every
unique constraint, not a prefix of it — and `period_code` is in `pk_period_balances` because the period
needed it, not because anyone was planning this. The tenant-leading convention costs nothing here.

### 5.2 Both foreign keys survive and still refuse — **proven**

```
 fk_period_balances__account | FOREIGN KEY (tenant_id, account_id, currency) REFERENCES ledger_accounts(...)      | ledger_period_balances
 fk_period_balances__close   | FOREIGN KEY (tenant_id, period_code, currency) REFERENCES ledger_period_closes(...) | ledger_period_balances
```

…on the parent **and** on all four partitions, and both fire on a real violation through the parent:

```
ERROR:  insert or update on table "ledger_period_balances_p2026_01" violates foreign key constraint "fk_period_balances__account"
ERROR:  insert or update on table "ledger_period_balances_pdefault" violates foreign key constraint "fk_period_balances__close"
```

Both are *outgoing* foreign keys from the partitioned table, supported since PostgreSQL 12. Nothing
references `ledger_period_balances`, so the harder case does not arise.

### 5.3 All three RLS policies survive, and the reader is still scoped — **proven**

```
 ledger_period_balances | rls_period_balances__recon  | r | openledger_recon | true
 ledger_period_balances | rls_period_balances__tenant | r | openledger_read  | (tenant_id = (SELECT current_setting('app.tenant_id', true)))
 ledger_period_balances | rls_period_balances__writer | * | openledger_app   | true

as openledger_read scoped to t1:  t1 | 7
as openledger_read scoped to t2:  t2 | 3
with NO app.tenant_id set:        rows_when_unscoped | 0
a PARTITION addressed directly:   ERROR: permission denied for table ledger_period_balances_p2026_01
```

The read-path control ADR-0013 §5 built is intact: scoped through the parent, **fails closed** when
unscoped, and a partition addressed directly is refused. Note *why* the last one is refused — **there
is no grant on the partitions**, not because a policy covers them. Policies on a partitioned parent
apply to parent-routed access only; a partition addressed directly carries only its own policies and it
has none. So **the absence of partition grants is load-bearing**, and a later `GRANT … ON ALL TABLES IN
SCHEMA public` would open a direct, unscoped path to every tenant's checkpoint. That belongs in the
ADR's cost column.

### 5.4 Every grant survives, including the belt-and-braces REVOKE — **proven**

```
 ledger_period_balances: openledger_app INSERT / SELECT
 ledger_period_balances: openledger_read SELECT
 ledger_period_balances: openledger_recon SELECT
 (no grants on any partition)

as openledger_app, INSERT through the PARENT into a partition it holds no grant on:
   insert through parent: OK
as openledger_app, UPDATE / DELETE / TRUNCATE on the parent:  permission denied (three times)
as openledger_app, SELECT and UPDATE on a partition directly: permission denied
```

Privileges are checked on the relation named in the query, so parent-routed DML needs nothing on the
partitions — which is what keeps the grant list identical to the baseline's.

### 5.5 The append-only perimeter permits it here, and would refuse it on a journal table — **proven for INHERITS, reasoned for PARTITION OF**

`ledger_period_balances` is **not** in `refuse_journal_ddl`'s `protected` array (`is_protected = f`,
read from `pg_get_functiondef`), and the DDL applies cleanly. The contrast:

```
CREATE TABLE probe_child () INHERITS (ledger_entries);
ERROR:  public.probe_child inherits from posted history: a child carries none of the parent's keys
        or triggers and is visible through it to every report
```

`ck_journal__no_inherit` is a **state assertion over `pg_inherits`**, and a partition creates a
`pg_inherits` row exactly as an inheritance child does. So partitioning any *protected* table —
`ledger_entries`, `ledger_transactions`, `ledger_events`, `ledger_periods`, `ledger_period_closes` — is
refused by the shipped perimeter. Proven for `INHERITS`; reasoned for `PARTITION OF` by the shared
mechanism (the assertion reads `pg_inherits` and neither knows nor parses the grammar — its own comment
says so). That bears directly on the roadmap's *"Partitioning by tenant … Legal on the shipped schema —
`PARTITION BY HASH (tenant_id)` succeeds on `ledger_entries`"*: whatever database that was verified on,
it cannot have had this event trigger installed and enabled. **The roadmap line needs a caveat, or the
event trigger needs a carve-out**; this spike does not settle which, because tenant partitioning is not
its subject.

### 5.6 The book still reconciles, and the rows are in the right partitions — **proven**

```
reconciliation breaks after = 0     (ten checks)

 tenant_id | period_code | currency | rows |             lives_in
 t1        | 2026-01     | USD      |    3 | ledger_period_balances_p2026_01
 t1        | 2026-02     | USD      |    4 | ledger_period_balances_p2026_02
 t2        | FY2026Q1    | USD      |    3 | ledger_period_balances_pfy2026q1
```

### 5.7 What the migration actually has to do — **proven**

```
ALTER TABLE ledger_period_balances PARTITION BY LIST (period_code);
ERROR:  syntax error at or near "PARTITION"

DROP TABLE ledger_period_balances;
ERROR:  cannot drop table ledger_period_balances because other objects depend on it
DETAIL:  view recon_checkpoint_breaks depends on table ledger_period_balances
         view reconciliation depends on view recon_checkpoint_breaks
```

There is **no in-place conversion** — the statement does not exist — and the table cannot be dropped
while its two readers stand. So the migration must: drop `reconciliation`, drop
`recon_checkpoint_breaks`, park the rows, drop the table, create the partitioned table and its
partitions, move the rows back, re-enable RLS with all three policies, re-issue every grant and the
`REVOKE`, restore the table comment, and recreate both views with their `GRANT … TO openledger_recon`.
Every line of it is **migration 00004**, never an edit to the baseline: ADR-0003's freeze is CI-enforced
by `scripts/check-migrations-immutable.sh` with no opt-out.

**And the ordering inside the migration is not cosmetic.** Building the partitioned table *beside* the
old one forces suffixed constraint names, and `ALTER TABLE … RENAME CONSTRAINT` on a partitioned parent
renames **the parent's copy only** — measured: 55 constraint rows, 20 of them left carrying
`fk_period_balances__close_new` on the partitions and `ledger_period_balances_new_tenant_id_not_null` on
every relation, permanently. Parking the rows in a staging table and dropping the old table **first**
costs one extra copy of a table that is derived anyway and keeps the baseline's naming convention
intact. That is what `PROPOSAL.sql` does.

The cheaper alternative available **only because of what this table is**: it is derived and exactly
recomputable from `ledger_entries` at each close's own `computed_at_xid` — which is ADR-0011 §3's whole
argument — so "rebuild by recomputation" is a legal migration strategy where it would not be for a
journal table. Copying preserves history byte for byte and is what a migration should do; the recompute
is the fallback that proves the table is derived. **Which is faster on a large book is a number** and is
in `MEASUREMENT-PLAN.md`.

### 5.8 The schema snapshot shows it as drift — and cannot see the three things that matter — **proven**

What moves, and it is expected and readable:

```
p ledger_period_balances persistence=p rowsecurity=true forcerowsecurity=false options=[]
r ledger_period_balances_p2026_01 ...   (one new line per partition)

CREATE UNIQUE INDEX pk_period_balances ON ONLY public.ledger_period_balances USING btree (...)
CREATE UNIQUE INDEX ledger_period_balances_p2026_01_pkey ON public.ledger_period_balances_p2026_01 ...
```

`relkind` flips `r` → `p`, each partition appears as a new `r` line, and the parent's primary key gains
`ON ONLY`. Fine.

What it cannot see, grepped from the test itself:

```
    relpartbound             in schema_snapshot.rs: ABSENT
    relispartition           in schema_snapshot.rs: ABSENT
    pg_inherits              in schema_snapshot.rs: ABSENT
    pg_partitioned_table     in schema_snapshot.rs: ABSENT
    pg_get_partkeydef        in schema_snapshot.rs: ABSENT
```

None of the nineteen sections records the partition key, a partition's bound, or whether a relation is
attached at all. So a partition attached with the **wrong bound**, the partition **key** changed, or a
partition **detached** are all invisible to the one test ADR-0009 names as the only backstop for the
owner-accident DDL class. Demonstrated with one statement:

```
ALTER TABLE ledger_period_balances DETACH PARTITION ledger_period_balances_p2026_01;

 rows_via_parent | rows_in_detached | checkpoint_drift_breaks | total_breaks
               7 |                3 |                       3 |            3

p ledger_period_balances rowsecurity=true
r ledger_period_balances_p2026_01 rowsecurity=false     <-- the snapshot line is UNCHANGED
```

Three rows vanish from every reader of the checkpoint, and the snapshot's line for the detached table is
byte-identical to the attached one. **The reconciliation sweep does catch it** — `checkpoint_drift = 3`,
`missing_row` — so it is not silent; but the sweep is daily and the snapshot is per-push, and ADR-0009's
charge for this class is the snapshot's. **Migration 00004 must widen the dump**, and `PROPOSAL.sql`
carries the section text.

### 5.9 What partitioning costs, beyond the constraints

- **DDL the app role cannot issue.** The close is an ordinary posting by `openledger_app`, which holds
  no `CREATE` privilege. A period whose partition was never provisioned would make the close **fail**,
  not merely lose the benefit — so the `DEFAULT` partition is not decoration, it is what keeps the close
  working, and provisioning becomes an operator or migration task.
- **`period_code` is a tenant-supplied free-text label.** The baseline's own comment says so:
  *"'2026-02', 'FY2026Q1' — a label, not a key of time."* Under `LIST` the partition set is the **union
  of every tenant's vocabulary**, which the two-tenant book demonstrates: three partitions for two
  tenants' three distinct codes. A hundred tenants with idiosyncratic period codes is a hundred
  vocabularies.
- **`HASH (period_code)` is the alternative and buys something different.** Fixed partition count, no
  DDL per period, no vocabulary problem — and no per-period `DETACH`, and each partition's index still
  grows with every period. It is a smaller-trees change, not a lifecycle change.
- **The mechanism, and what would falsify it — unmeasured.** Partitioning by period does **not** reduce
  the number of rows written or the number of index entries maintained. What it changes is *which* index
  they enter: one fresh, empty, sequentially-filled per-partition primary key per close, instead of
  appending into a shared tree grown by every period before it. If that is where spike 020's ~96% goes,
  the saving **grows with the number of periods already closed and is ~0 on the first close**. That
  prediction is what the timing pass has to falsify, and it is stated here so that it can be.

---

## 6 · What could not be settled without the timing pass

1. **Is the rewritten `balance_sheet_at` actually faster, and by how much?** ADR-0011 §3's 45–49× and
   spike 020's 40–230× were measured on hand-written queries, not on the function, and not with the A14
   guard and the earnings plug included. The plan estimates say the tails are cheap; nothing here says
   the whole function is.
2. **Are the two candidate indexes worth their write cost?** They are 224 kB each on a 30k-entry book
   and they change tail A's plan from a sequential scan to a bitmap index scan by estimate. The cost is
   on the hot path and is not estimable from a plan.
3. **Where is the crossover for `trial_balance_at`'s difference form?** It is more work for a short
   intra-period window and less for a position reading. The crossover is a period-length-versus-
   window-length ratio and it is a number.
4. **Is the bounded reconciliation actually cheaper, and where does the curve cross?** At 12 closes and
   30,024 entries the two estimates are within 2% of each other. The asymptotic argument says the
   bounded form wins as closes grow; 12 is not enough closes to show it.
5. **How much does partitioning save on the close?** §5.9 states the mechanism and the falsifiable
   prediction. Spike 020's ladder (10k / 100k / 1M accounts) plus a periods dimension is what answers
   it.
6. **Does `income_statement_for` need anything at all?** Its cost is O(entries in the window) and nobody
   has measured whether that is a problem at scale. It is not a *checkpoint* question, which is why this
   spike closes it as "no checkpoint" rather than as "fast enough".

---

## 7 · Prior claims named and withdrawn

| claim | where | verdict |
| --- | --- | --- |
| *"a temporary account's checkpoint row is exactly 0 and `retained_earnings` carries the swept earnings"* (A4) | ADR-0011 §3; `migrations/00001_baseline.sql:882-893`; `:1985-1990` | **False on the shipped mechanism** (§1.2) and **unsatisfiable as specified** (§1.3). Becomes true under the identity change (§1.4) |
| *"`computed_at_xid` is held at or above the closing transaction's own `xact_id`"* | ADR-0011 §3 (A4); enforced by `recon_close_breaks` | The enforcement is a **false positive on any non-idle cluster** (§1.1). The correct predicate is the **inverse** — refuse a cursor *above* the close (§3.3) |
| *"they aggregate `ledger_entries` from inception"*, of all three statement functions | ADR-0011 §3; roadmap M5 | **True of `balance_sheet_at` only.** The other two are bounded below by `p_from` (§2.5) |
| *"their inner query plans the same nested loop"*, of the two statement functions | ADR-0011 §4 | **Not observable through `EXPLAIN`** — both are `plpgsql` and plan as a bare `Function Scan` (§2.7). Recorded as unverified, not contradicted |
| *"a committed row's commit position is always retired below the horizon by the time the sweep runs"* | `recon_cursor_breaks`' comment, `migrations/00001_baseline.sql` | **False.** Two false `above_horizon` breaks on an honest book, and `openledger reconcile` exits 1 (§4.1) |
| *"Partitioning by tenant … Legal on the shipped schema — `PARTITION BY HASH (tenant_id)` succeeds on `ledger_entries`"* | roadmap, *Deliberately not now* | Needs a caveat: `ck_journal__no_inherit` refuses a child of any protected table, and a partition is a `pg_inherits` child (§5.5) |

---

## 8 · The acceptance run: `PROPOSAL.sql` applied end to end — **proven**

The proposal is not a sketch. It was applied **in one transaction** to a fresh identity-mode book
(`MODE=identity DB=spike024v ./build-book.sh`, then
`psql --single-transaction -f PROPOSAL.sql`), and the differential was re-run the other way round:
the shipped names now carry the checkpoint form, and the baseline's own bodies — extracted verbatim
from `migrations/00001_baseline.sql` by `sql/90_reference_bodies.sql` and renamed `_ref` — carry the
from-inception form. `out/verify-proposal.txt`:

```
=== 1. THE GATE ===                                ten checks, total_breaks = 0
=== 2. the checkpoint lives in partitions ===      LIST (period_code), 27 rows
=== 3. the AT-CLOSE property ===                   every temporary account 0;
                                                   retained_earnings -400 / -1200 / -2160
=== 4. the differential ===                        balance_sheet_disagreements = 0   (60 points)
                                                   trial_balance_disagreements = 0   (9 windows x 60)
=== 5. the inverted window ===                     refused, SQLSTATE 22023
=== 6. the sweep ===                               close_order_breaks 0;
                                                   level 0, bounded 0
=== 7. the indexes ===                             five shipped, unchanged, plus the two new
```

Three things this run establishes that the earlier ones could not:

- **The proposal applies as a single atomic migration.** It does not, on the first attempt: the
  ordering is forced. `reconciliation` pins `recon_close_breaks` (whose column list changes, so
  `CREATE OR REPLACE` is not available) and `recon_checkpoint_breaks` pins
  `ledger_period_balances` (which has to be dropped). Both errors are quoted in `PROPOSAL.sql`'s
  part 0, and the partitioning had to move **before** every view rather than after — which is why the
  file's parts are 0, 1a, 1b, 2 … rather than 1 … 6.
- **The differential holds against the baseline's real bodies**, not against a paraphrase of them.
- **The `reconciliation` view survives the round trip with its grant.** A dropped view takes its ACL
  with it, and `openledger reconcile` reads that view as `openledger_recon`; part 7 re-issues it.

**What the acceptance run does not cover:** the two indexes are created but nothing measures their
write cost; the partition set is the `DEFAULT` partition alone, because a migration cannot enumerate
future period codes and spelling the per-period ones out is an operator's provisioning job; and the
bounded checkpoint check is created and granted but deliberately **not** wired into
`reconciliation` — see `PROPOSAL.sql` part 4b's adoption note.
