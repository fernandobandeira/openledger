# Spike 020 — Can the report path read the period-close checkpoint, and what has to change first?

**Status:** closed. Produced [ADR-0020](/decisions/0020-checkpoint-on-the-report-path). **One
statement function of the three can take the checkpoint and one is refused it structurally; the
close's own transaction has to be admitted by *identity*, because an at-close checkpoint and a
reproducible cursor are mutually exclusive for the two values a one-transaction close can bind; and
the O(entries × closes) drift check can be bounded to one pass over the journal at the price of an
invariant the schema does not state.** **This spike ran no timings at all** — every cost on this page
is either a planner's *estimate*, a byte count, or another spike's measurement, and each one says
which.
*(Directory `spikes/024-checkpoint-on-the-report-path/`; the spike directories carry their own
numbering.)*

**Question.** [Spike 016](/spikes/016-close-cost-at-scale) left three things proven to exist and none
of them designed: the shipped statement functions **never read `ledger_period_balances`** (proven from
`pg_get_functiondef`), `recon_checkpoint_breaks` is **O(entries × closes)**, and **~96%** of a close's
cost is the checkpoint *write*, which wants the table partitioned by period. Can the checkpoint
actually be wired into the shipped statement functions, does the rewritten form give the same answer
to the minor unit, can the drift check be bounded without losing a drift class, and is partitioning
legal on this schema? The deliverables are in the repository at
`spikes/024-checkpoint-on-the-report-path/`: `DESIGN-QUESTIONS.md` written **before** the answers,
`SPEC.md` (the book, the gate and the shape of each experiment), `FINDINGS.md` with every claim
labelled **proven** or **unmeasured / reasoned**, `MEASUREMENT-PLAN.md` specifying the timing pass
that **has not been run**, `PROPOSAL.sql` as migration-ready text applied end to end in one
transaction, six `run-*.sh` scripts, `sql/`, and `out/`, where every quoted number is grep-able.

[ADR-0020](/decisions/0020-checkpoint-on-the-report-path) carries the rulings. **This page carries the
measurements and the method**, and does not repeat the decision. PostgreSQL 18.6 on
`x86_64-pc-linux-musl`, localhost port 5433, in scratch databases this spike creates and drops; the
`openledger` database was never touched.

---

## Method — a design phase that deliberately measured no time

- **No milliseconds anywhere, and the reason is not modesty.** Another spike was writing to another
  database on this same PostgreSQL throughout, and this project's own banner says two harnesses on one
  database invalidate everything: *"the same configuration measured 833 and 482 clearings/s at loadavg
  ~1.5 and ~6.3, and the ratios moved ~30% too."* So `MEASUREMENT-PLAN.md` specifies six timed
  questions, three books and a decision rule written before the numbers — and nothing in it has been
  executed. Where this page quotes a growth ratio, it is [spike 016](/spikes/016-close-cost-at-scale)'s
  and says so.
- **Plain `EXPLAIN`, never `EXPLAIN ANALYZE`.** A plan is not a measurement; a plan is what tells you
  whether an index path exists at all. Every cost quoted from a plan is labelled as the planner's
  estimate.
- **Every book gated on `SELECT * FROM reconciliation` at ten zeros**, with two deliberate exceptions,
  both labelled where they appear: an adversarial cell whose whole point is to make a check go red, and
  the identity-convention book, which reconciles only once the matching recompute is applied — **which
  is itself the finding.**
- **The cluster horizon is not ours, and every close is preceded by a poll.** `report_cursor()` is
  `pg_snapshot_xmin(pg_current_snapshot())`, which is the *cluster's*, so a close taken under a pinned
  horizon stores a checkpoint of **nothing**. The first run of `run-cursor-arms.sh` measured exactly
  that while the neighbouring spike held the horizon at 15797: empty stored checkpoints and **6 total
  breaks on a correct book.** The poll is a correctness precondition, not a timing device.
- **Every write except the close goes through the compiled binary over HTTP** (`openledger serve`,
  `POST /v1/transactions`), because pending → posted, the void and the server-derived reversal mirror
  are *writer* semantics and re-implementing them in a SQL fixture would test the fixture. The close is
  the one operation the wire cannot express — there is no `kind` in `TransactionBody` and
  `fk_closes__txn_kind` demands `kind = 'period_close'` — so it stays SQL.
- **The candidate bodies are installed *beside* the shipped ones** under `_ckpt` names, so both forms
  run on the same book in the same snapshot, and the differentials are **`FULL JOIN`s rather than
  subtractions**: a line present in one form and absent from the other is a disagreement, and
  `WHERE a - b <> 0` cannot see it.

**The book**, built by `build-book.sh`: two tenants, two currencies, four monthly periods. `bk` is the
closed book — USD closed through **2026-03**, EUR through **2026-01**, 2026-04 left open — and `nc`
carries the *same* postings with **no close at all**, as its own tenant rather than as a phase, because
once `bk` is closed its pre-close state is not reachable again. It contains one of everything that can
make the two forms disagree: a pending transaction never resolved, a resolution backdated into a closed
period, a reversal of a posted transaction whose server-derived mirror takes the target's own
`effective_at` and therefore also lands in closed January, a voided pending, an ordinary posting
arriving after **two** closes, and a posting backdated into the middle period after all three. Three
cursors are captured — **P0 before any close exists**, P1 after the January close and its backdated
arrivals, P2 at the end. Result: 24 posted and 6 pending ordinary transactions per tenant, 4 closing
transactions, 18 `close_disclosures` rows (`out/book.txt`). Non-perimeter account types only, because
`chart_lint.perimeter_unattested` fires for every `is_perimeter` account until the attestation feed
exists (roadmap M7) and would leave one of the ten checks permanently red, destroying the gate — the
same substitution [spike 018](/spikes/018-batching-and-stripe-selection) made, for the same reason.

*(This spike's own `run-cursor-arms.sh` database is the neighbour that appears by name in
[spike 019](/spikes/019-read-path-contract) and [spike 021](/spikes/021-reporting-layer-defects) as the
backend holding their horizon back. The interference was mutual and is recorded on all three pages.)*

---

## A · What a one-transaction close can actually store — three arms, six cells

`./run-cursor-arms.sh` → `out/cursor-arms.txt`. Added after an adversarial audit found that the three
predicates bounding `computed_at_xid` cannot all mean what the schema says. **Three candidate cursor
values × two horizon states**, the second being an older writer holding an uncommitted posting *across*
the close and committing after it — the interleaving [ADR-0011](/decisions/0011-period-close-and-report-axes)
§1 built the entire cursor argument on.

| arm | `computed_at_xid` vs the close's own `xact_id` | stored checkpoint | `close_typing` | `checkpoint_drift` | reader vs from-inception |
| --- | --- | --- | --- | --- | --- |
| `xmin_strict` (`report_cursor()`), horizon caught up | 16000 = 16000, **equal** | `fee_revenue = -500`, **no `retained_earnings` row** → **pre-close** | 0 | 0 | **0 disagreements** |
| `xmin_strict`, older writer commits after the close | 16024 **<** 16025 | pre-close | **1** | 0 | 0 disagreements |
| `own_xid` (`pg_current_xact_id()`), horizon caught up | 16058 = 16058, equal **by construction** | `fee_revenue = 0`, `retained_earnings = -500` → **at-close** | 0 | **2** | **2 disagreements** |
| `own_xid`, older writer | 16083 = 16083, equal by construction | at-close | 0 | **4** | **4 disagreements** |
| **`identity`**, horizon caught up | 16108 = 16108 | **at-close** | 0 | 2 *(shipped view; see below)* | **0 disagreements** |
| **`identity`**, older writer | 16132 **<** 16134 | **at-close** | **1** | 2 *(shipped view)* | **0 disagreements** |

**Equality is what the shipped close stores, and only on an idle cluster.** `spike_close` binds
`pg_snapshot_xmin(pg_current_snapshot())` before acquiring an xid, and on an idle cluster the
snapshot's xmin *is* the next xid to be assigned — the one this transaction is about to take. So
`computed_at_xid` comes out exactly equal to the closing transaction's own `xact_id`: all four closes on
the main book report `equal = t` (`out/checkpoint-content-asspecified.txt`). `recon_close_breaks` admits
equality (its break condition is `c.computed_at_xid < x.xact_id`), so **the shipped check is green
today for a reason that has nothing to do with the property it is named for.** Put one other write
transaction on the cluster and equality is gone — 16024 < 16025 — and `cursor_precedes_close` fires on a
close whose checkpoint reconciles cleanly and whose reader agrees with the journal to the minor unit.
**It is a false positive on any cluster that is not idle.**

**The shipped checkpoint is the PRE-close position, and three artifacts say otherwise.** On the main
book, `bk/2026-01/USD`:

```
 period_code |       purpose       | input | output | dr_pos
 2026-01     | fee_revenue         |     0 |    500 |   -500
 2026-01     | credit_loss_expense |   100 |      0 |    100
 (no retained_earnings row at all)
```

`fee_revenue` is **−500**, not 0. The closing entries carry the closing transaction's own `xact_id`,
which under equality equals `computed_at_xid`, and the recompute's bound is **strict** — so they are
excluded from both the stored row and the recompute. Self-consistent, and the opposite of what
`migrations/00001_baseline.sql:882-893`, `:1985-1990` and ADR-0011 §3 all say. **The prose is wrong, not
the arithmetic**, and `close_disclosures`' `NOT EXISTS` carve-out is the tell: it is only needed
*because* the closing entries sit at or above `computed_at_xid`.

**At-close and a reproducible cursor are mutually exclusive — proven for the two reachable values,
reasoned for the impossibility.** That labelling is `FINDINGS.md`'s own and is worth keeping exactly.
What is **proven** is the `own_xid` arm: it does store an at-close checkpoint, and it **loses a real
posting**. With the older writer holding an uncommitted posting of 70 across the close:

```
       purpose       | inception_dr | reader_dr | inception_cr | reader_cr
 customer_receivable |        10570 |     10500 |            0 |         0
 paid_in_capital     |            0 |         0 |        10070 |     10000
 retained_earnings   |            0 |         0 |          500 |      1000
 fee_revenue         |          500 |      1000 |          500 |       500
```

The held entry's `xact_id` is *below* `computed_at_xid` (it was assigned earlier), so it is not in tail
B; and it was invisible to the close's own `INSERT … SELECT`, so it is not in the checkpoint either.
**A silent, permanent understatement of a real position** — `10570` read as `10500`. It is detectable —
`recon_checkpoint_breaks` reports 4 rows — but the statement is already wrong. What is **reasoned** is
that there is no third value to reach for: `pg_snapshot_xmin` is `<=` the caller's own xid whenever the
caller holds one, so a cursor *above* the closing transaction's own entries is not reachable from
inside the transaction that writes them; `pg_snapshot_xmax` is `latestCompletedXid + 1` and admits
in-flight transactions that commit later, which is the `max(xact_id) + 1` failure ADR-0011 §1 already
refutes; and **`xid8` has no successor operator**, so `own_xid + 1` is not expressible without a text or
numeric round trip. **A4 as written is unsatisfiable.**

**The fix is to name the transaction, not to loosen the inequality.** The audit's cheapest proposal —
`e.xact_id <= c.computed_at_xid` in the recompute — was **tested and refused**: `<=` means "include the
close's own entries" *only when* `computed_at_xid` equals the closing transaction's own xid, which is
the `own_xid` arm, which is the arm that is not reproducible. On a busy cluster the two values differ
(16132 against 16134, measured), `<=` admits nothing extra, and the stored row silently reverts to
pre-close while the prose still says at-close. The close's own transaction is **already named** in
`ledger_period_closes.transaction_id`, under `fk_closes__txn`, `fk_closes__txn_kind` and
`uq_closes__txn`, so it does not need to be reachable through the cursor at all:

```sql
e.xact_id < c.computed_at_xid OR e.transaction_id = c.transaction_id
```

Under that rule the checkpoint is at-close under **both** horizon states and the reader agrees with the
from-inception aggregate in both. On the main book rebuilt this way, every temporary account is exactly
0 at every close and `retained_earnings` carries **−400, −1200, −2160** across the three
(`out/checkpoint-content-identity.txt`). **That is A4's sentence, true for the first time.**

**Both conventions produce the *same statement*.** The 60-point grid returns zero disagreements on both
books, and the worked balance sheet at 2026-04-01 is byte-identical between them — receivables 12,290 /
equity 10,000 / retained earnings 2,160 / undistributed 130, in both currencies. **What differs is what
a human reading `ledger_period_balances` directly is told**: a pre-closing trial balance under a comment
promising a post-closing one. That is the whole cost of getting it wrong, and it has a real audience —
the checkpoint is the one derived table an adopter can read without writing Rust.

**Two conditions come with identity admission, and neither is optional.** The checkpoint's
`INSERT … SELECT` must run **after** the closing entries exist, or there is nothing for identity to
admit. And the close's arithmetic and `recon_checkpoint_breaks`' recompute **must land in the same
migration**, because an at-close checkpoint under the shipped strict recompute reports drift on *every*
close: the identity book's gate reads `checkpoint_drift = 12` and the harness stops on it
(`out/book-identity.txt`, `out/gate.txt`), falling to **0** once both sides move — which is what the
acceptance run's own gate shows (`out/verify-proposal.txt`, ten checks at zero).

## B · The statements, rewritten

**`balance_sheet_at` takes the treatment, and the rewritten form agrees everywhere.** 60 points on the
`xmin_strict` book and 60 on the `identity` book, each comparing 20 statement lines by amount, caption,
side and sort order through a `FULL JOIN`:

```
=== 2. the same, as one number. MUST be 0 ===
 total_balance_sheet_disagreements
                                 0
=== 3. every disagreeing line, if any ===
(0 rows)
```

The grid is 2 tenants × 3 cursors × 10 as-of instants, and the instants are chosen to cover *before
everything*, *mid-period*, *exactly on each of the three close boundaries*, *mid the unclosed period*,
*past every entry*, and **`infinity`** — the value `recon_equation_breaks` passes. Re-verified on the
30,000-entry / 203-account / 12-close book (30,024 entries once the closing legs land): **0
disagreements at four instants**, balance sheet and trial balance both.

**Three things in the rewritten body are not in ADR-0011 §3, and each was necessary.** *The boundary is
chosen per **currency***, because `pk_closes` is `(tenant_id, period_code, currency)` and USD closed
through March with EUR through January is an ordinary state — it is the state the book is built in, on
purpose — so a boundary chosen per *tenant* reads the wrong checkpoint for one of them. *The anchor is
guarded on the **closing transaction's own `xact_id`**, not on `computed_at_xid`*: a checkpoint computed
at C is the set `{xact_id < C}`, and a report pinned at P < C must not see rows between P and C; under
the identity convention the last thing to become visible is the closing transaction itself. Without
that guard, a close that happened *after* a statement was issued **restates that statement upward** —
the exact property the cursor exists to prevent, and the P0 column of the grid is what tests it,
because P0 was captured before any close existed and the rewritten form still agrees at all ten
instants. And *tail B must exclude the close's own transaction*: drop that clause and the closing legs
are counted twice — measured in the `own_xid` arm above as `fee_revenue` reading **1,000 against a true
500**.

With **no close at all** the form degrades to today's behaviour with no special case: the boundary is
`-infinity` (and `ck_entries__effective_finite` forbids an entry there), so tail B is empty, tail A is
everything, and the checkpoint term joins nothing. Tenant `nc` is the proof.

**The A14 guard takes the same treatment — proven for the positive case, and a red proof is owed.**
`balance_sheet_at` is `plpgsql` for two reasons and the second, A14, runs its own `EXISTS` over
`ledger_entries` with **no lower bound**; wiring the aggregate and leaving the guard scanning from
inception leaves the function exactly as slow as it was. The equivalent form asks the same question of
the checkpoint population gated on `debits + credits > 0`, which is exact because
`ck_entries__amount_positive` is `CHECK (amount_minor > 0)`: an account with any posted entry below the
boundary has a non-zero *gross* checkpoint row, and a dormant account for which the close wrote 0/0 is
correctly not treated as having entries. The rewritten function is called 120 times across the two
books and raises in none of them. **The negative control was not run** — an account type with posted
entries and no `chart_presentation` row at the requested version — because the chart is seeded whole by
`schema/chart.sql` and constructing a partially-presented version needs rows this spike did not build.
The equivalence argument is the reasoning; **the red proof is owed** and belongs in the migration's own
test. *(It is reachable: [spike 021](/spikes/021-reporting-layer-defects) built exactly that state and
found the raise takes out the whole reconciliation summary.)*

**`trial_balance_at` takes it too, as a difference of two positions, and that is proven.**
`trial_balance_at` is a **flow** over `[p_from, p_to)`, so the checkpoint can only enter as
`prefix(to) − prefix(from)` — exact because `prefix()` sums *gross* debits and credits over
`{eff < x, xact_id < cursor, posted}` and that set is monotone in x. **Zero disagreements across 9
windows × 60 cells on both books.**

**The first version of the difference form was wrong, and this spike's own grid caught it, and the fix
makes the contract stronger.** With `p_from > p_to` — an inverted window — the shipped body returns
**no rows** (`eff >= from AND eff < to` is empty) while the difference form returned **negative** gross
debits and credits:

```
              account_id              | currency | shipped_dr | cand_dr | shipped_cr | cand_cr
 0ae3f014-ccec-53d6-68be-369e6e633da4 | EUR      |            |       0 |            |  -10000
 198e4c3f-2fa9-9871-7f17-f3406a745aeb | USD      |            |    -300 |            |       0
```

Six such rows. Nothing in the shipped signature refuses an inverted window and nothing would have
noticed, **because a negative gross debit is not a value any caller checks.** So `PROPOSAL.sql` refuses
it outright (`SQLSTATE 22023`, verified in the acceptance run), which makes the rewritten function's
contract *stronger* than the one it replaces; clamping silently was rejected on
[ADR-0010](/decisions/0010-reconciliation)'s grounds, that a caller who passes an inverted window has a
bug and a report answering it with zeros hides the bug behind a plausible number. **A fixed defect is
not a cost of the fix.** The real costs are two, and both are stated in the proposal: each prefix
carries a tail from its own boundary, so the work is roughly
`(to − boundary_to) + (from − boundary_from)` rather than `(to − from)` — **more** work than the shipped
body for a window well inside one period, and bounded by two period lengths only for a window whose
lower bound is deep in history — and **the function stops being `LANGUAGE sql`**, so it loses the
inlining ADR-0011 §4 relies on and plans as a `Function Scan`. Which side of that trade a caller is on
is a number, and it is in `MEASUREMENT-PLAN.md`.

**`income_statement_for` cannot take it, and the reason is structural.** Three reasons, the third
decisive. It is a **flow** — ADR-0011 §4 says so in as many words — so a cumulative checkpoint could
only enter as the same difference form. **The accounts it reports are exactly the accounts the close
zeroes**, so under the canonical at-close convention every revenue and expense checkpoint row is
exactly 0 (measured, §A) and `prefix(to) − prefix(from)` between two boundaries is `0 − 0 = 0`; the flow
is recoverable only by adding back the closing entries the statement is specified to *exclude*. And
**there is nothing from-inception to remove**: its `dp` CTE already carries
`e.effective_at >= p_from AND e.effective_at < p_to`, so its cost is O(entries in the window) and the
checkpoint cannot beat a range scan of the range it was asked about. **`income_statement_for` needs no
checkpoint and gets none** — the answer either way, said plainly.

**The two tails: one is served today, one is not — proven from plans, unmeasured as to worth.**
`./run-plans.sh` → `out/plans.txt`, on the 203-account / 30,024-entry / 12-close book. Plain `EXPLAIN`;
every number is the planner's **estimate**.

| term, tenant-wide | default plan | forced index | with the candidate index |
| --- | --- | --- | --- |
| tail A — `effective_at` in `[boundary, as_of)` | **Seq Scan**, est. 1243.60 | Bitmap Index Scan on `ix_entries__effective`, est. **946.65** | Bitmap Index Scan on `ix_entries__tenant_effective`, est. **45.44** |
| tail B — `effective_at < boundary`, `xact_id >= C` | **Index Scan on `ix_entries__asof_commit`**, est. 730.09, with `effective_at` in **Filter** | — | Index Scan on `ix_entries__tenant_commit`, est. **224.62**, `effective_at` moves **into** the Index Cond |

So **PostgreSQL 18's btree skip scan does rescue tail B** — `ix_entries__asof_commit` is chosen without
help even though `account_id` sits between `tenant_id` and `xact_id` — and ADR-0011 §3's cited plan
therefore holds tenant-wide as well as single-account, which is more than the ADR's own measurement
established: the single-account form it actually measured plans at est. **8.32**. Tail A is **not**
served; the planner prefers a sequential scan and forcing the existing index costs ~21× the
leading-column alternative by estimate, **at 203 accounts** — and the skip factor gets worse with
account count, which is the direction any real book moves. The two candidate indexes are **224 kB each**
against a 3,944 kB heap and 6,448 kB of indexes in total — about **7% more index bytes** for both — and
each is *smaller* than `ix_entries__effective` (992 kB) because it drops `account_id`. **Whether that is
worth its write-path cost is a number**, and [ADR-0013](/decisions/0013-write-path-contract) does not
get to wave through two new indexes on the hot table on an estimate.

**And the statement functions are opaque to `EXPLAIN`, which undermines a claim in ADR-0011 §4.**

```
EXPLAIN SELECT * FROM balance_sheet_at_ckpt('big', '2027-01-01 00:00+00', report_cursor());
 Function Scan on balance_sheet_at_ckpt  (cost=0.26..10.26 rows=1000 width=184)
```

Identical for the shipped `balance_sheet_at`. Both are `plpgsql`, so `EXPLAIN` shows a `Function Scan`
and nothing about the inner query. ADR-0011 §4 states *"their inner query plans the same nested
loop"* — **that is not observable this way and cannot have been verified this way.** It is checkable
with `auto_explain.log_nested_statements`, which this spike did not enable. Recorded as unverified
rather than contradicted.

## C · The bounded reconciliation

**The bounded form, and why it is bounded.** The checkpoint is **cumulative** — the recompute has no
lower bound on `effective_at` — so consecutive checkpoints differ by exactly one close's own arrivals.
Instead of recomputing C levels, assign each entry the index of the **first close whose checkpoint
contains it**:

```sql
LEAST(
  NULLIF(GREATEST(width_bucket(e.effective_at, <ends ascending>)      + 1,
                  width_bucket(e.xact_id,      <cursors, same order>) + 1),
         n + 1),
  <the index of the close whose transaction this entry belongs to>   -- identity term
)
```

`width_bucket(anyelement, anyarray)` is a binary search, so the assignment is **O(log C) per entry**
rather than O(C); `xid8` has a default btree opclass (`xid8_ops`, `opcdefault = t`, read from
`pg_opclass`) so it works on the cursor axis too; and `LEAST` ignores NULLs in PostgreSQL, so the
identity term can only pull an index earlier and is inert for an ordinary entry. Then compare the
*difference* of consecutive stored levels against the sum of the entries at that index. The entries side
is exactly one pass (`out/bounded-plan.txt`):

```
->  Seq Scan on ledger_entries e  (cost=0.00..793.24 rows=30024 width=68)
```

against the level form's bitmap scan inside a nested loop over 12 closes emitting 40,037 rows into a
`HashAggregate` (est. 7011.24). **The honest bound is O(entries + stored rows), not O(entries)** — the
presence half inspects every stored checkpoint row and that is the floor, because you cannot check N
stored rows in fewer than N, and stored rows = accounts × closes is the size of the table being checked.

**Two honesty notes on the same evidence.** A first draft of the view was **8× worse** than this and
the plan said so: referencing the two close-index views plainly re-planned them at every reference —
seven `WindowAgg` nodes — for a whole-view estimate of **60,100**, dominated by that rather than by the
single entries pass; materializing them (a dozen rows) brought it to **6,987**. And at 12 closes on
30,024 entries the two whole-view estimates are a **dead heat**: level **7,199.08**, bounded
**7,363.12**. That is not a refutation of the asymptotic claim — 12 closes on 30k entries is exactly
where O(E×C) has not yet hurt — but it is the honest state of the evidence, and it is why the ladder in
`MEASUREMENT-PLAN.md` runs to 48 closes and not 12. **The growth ratio the bounded form is meant to
flatten, `1 : 3.2 : 5.8 : 8.2` over 3 / 6 / 9 / 12 closes, is
[spike 016](/spikes/016-close-cost-at-scale)'s and not this spike's**, normalized to its own 3-close
value on the book shape this spike's measurement plan reproduces for comparison — 8,000 accounts, ~300
entries per period. **Nothing on this page times either form.**

**The difference comparison alone LOSES a drift class, and the presence half restores it.** Five cells,
each mutating the checkpoint inside a transaction and rolling back, run on both books
(`out/drift-classes-both.txt`):

| cell | level form | bounded form | bounded reasons |
| --- | --- | --- | --- |
| **clean book (negative control)** | **0** | **0** | — |
| value forged by +1 on a middle close | 1 | **2** | `spurious_row, value_drift` |
| spurious row, 4,242 on an unused account | 1 | **2** | `spurious_row, value_drift` |
| missing row, middle close, account moved | 1 | **3** | `missing_row, row_span, value_drift` |
| **missing row, trailing close, account did NOT move** | 1 | **1** | **`row_span`** |

*(The third label on the fourth row is `value_drift` on the `xmin_strict` book and `spurious_row` on the
identity book; the counts — 1 against 3 — are the same on both.)* And the falsification of "the presence
half matters" (`out/span-load-bearing.txt`):

```
 level_form | bounded_with_span | bounded_without_span
          1 |                 1 |                    0
```

**Every drift class the level form catches, the bounded form catches** — and the last row is the whole
reason the presence half exists. A trailing checkpoint row deleted for an account that had no arrivals
in that period produces a stored difference of 0 against recomputed arrivals of 0: a pure difference
comparison has *nothing to disagree about*, while the level form sees a missing row against a non-zero
recomputed level. Without the span check the bounded form reports **0** where the level form reports
1 — **a cheaper check that misses a drift class, which is a regression, not an optimization.** With it,
1 and 1. Key-set equivalence on the clean book is exact on both books: zero rows on either side of the
`level_only` / `bounded_only` comparison.

**Two interface changes an operator will see, and they must be documented rather than discovered.** A
single forged value produces **two rows, not one** — the difference at close *k* and at close *k+1*
both disagree, which is more sensitive rather than less, at a different row count. And **the `reason`
labels are less precise**: a forged value shows as `spurious_row, value_drift` where the level form says
`value_drift`, because the second affected difference has no arrivals row to pair with. The break is
real and the account and period are right; the word is misleading. A fourth reason (`delta_drift`)
would fix it and is left to the ADR.

**The bounded form needs an invariant the schema does not state, and out-of-order closes are legal
today.** `./run-out-of-order.sh` → `out/out-of-order.txt`. February closed **after** March, which
nothing forbids: `pk_closes` is `(tenant_id, period_code, currency)` and `ex_periods__no_overlap` orders
the *periods*, not the closes over them.

```
 period_code |        ends_at         | computed_at_xid | close_txn_xid
 2026-01     | 2026-02-01 00:00:00+00 |           16512 |         16512
 2026-02     | 2026-03-01 00:00:00+00 |           16511 |         16511

shipped sweep total breaks = 0
```

Ten checks, zero breaks — **legal.** And then: the **level** form reports **0** breaks, because each
checkpoint is individually recomputable at its own cursor and nothing is wrong with either row; the
**bounded** form reports **2** `value_drift` breaks, which are **false positives**, because the stored
levels no longer nest and their difference is therefore not a difference of nested sets; the **reader**
reports **0 disagreements at all four as-of instants**, so out-of-order closing is a problem for the
*check* and not for the *statement*; and the at-close claim degrades, because January's checkpoint
carries `retained_earnings = -500` and February's `-1200` — February swept before January existed.

So the bounded form ships **with the check that states the invariant**, and the coverage argument
becomes: order broken ⟹ reported as its own class; order clean ⟹ the difference comparison is
equivalent to the level comparison. `recon_close_order` catches this book with two reasons at once:

```
 period_code | computed_at_xid | txn_xact_id | prev_cursor | prev_txn_xact_id |           reason
 2026-02     |           16511 |       16511 |       16512 |            16512 | cursor_not_monotone
 2026-02     |           16511 |       16511 |       16512 |            16512 | previous_close_above_cursor
```

`previous_close_above_cursor` is the one that matters most, and it is **not** only the bounded form's
requirement: it is the condition that makes the at-close claim true for *every* close, because if close
*k*'s cursor does not clear close *k−1*'s own transaction, close *k*'s checkpoint silently omits the
previous sweep. It is satisfiable in any healthy deployment — the horizon advances between two monthly
closes — and where it is not, ADR-0011 already accepts that *"a close cannot complete while xmin is
pinned below it"*. So the close should **refuse to run** while the horizon has not cleared the previous
close: a precondition check, not a trigger.

**And `close_disclosures`' wide carve-out is dead exactly when that invariant is green — proven both
ways.** On the identity book, removing the wide `NOT EXISTS` changes no row (`18 | 18 | 0`), and the
population that would make it live — *another* close's entries falling below this close's boundary and
above its cursor — is empty. On the **out-of-order** book the same query says `0 | 2 | 2`, naming
2026-02 against 2026-01: January's own closing legs are effective below February's boundary and above
February's cursor, so without the carve-out they would be disclosed as backdated arrivals. **The
removal is safe exactly when `recon_close_order` is green**, and the ADR should say that rather than
describe the carve-out as redundant.

**`computed_at_xid` is bounded from below only, and it sits under a table-wide grant.**
`./run-adversary.sh` → `out/adversary.txt`. Forged upward to 2^62, all inside a rolled-back
transaction: `recon_close_breaks` **0 — green**; `close_disclosures` for that period **0 — the
disclosure feed for that period is silenced entirely**; `recon_checkpoint_breaks` 4, labelled
**`value_drift`**; the proposed `recon_close_order` **2**, `cursor_above_close` and
`cursor_above_horizon`. The audit predicted the drift would surface "only later"; on this book it
surfaces immediately, because backdated arrivals above the true cursor already exist and the inflated
recompute picks them up — **but on a book with no arrivals above the true cursor it would not surface at
all**, and either way it is labelled a value discrepancy when the cause is a forged cursor. Precise
statement: detected on this book, mislabelled, and **undetectable in general.** *(Forged downward to 1,
`FINDINGS.md` §3.5 records `recon_close_breaks` 1 — caught — `recon_checkpoint_breaks` 8 and the
proposed check 2. That is the one cell whose capture in `out/adversary.txt` ends mid-run, so those three
counts rest on the findings document rather than on a kept capture.)*

The grant surface is confirmed from the catalog:

```
       relname        |     attname     | app_can_insert
 ledger_entries       | xact_id         | f
 ledger_period_closes | computed_at_xid | t
```

`ledger_entries` carries a **column-list** `INSERT` grant that omits `xact_id` (ten columns granted,
read from `pg_attribute.attacl`); `ledger_period_closes` carries a **table-wide**
`GRANT SELECT, INSERT` (`migrations/00001_baseline.sql:2518-2519`), so the app role can supply any
`computed_at_xid` it likes. But note what a column-list grant *cannot* do here: **the close must write
`computed_at_xid`, so the column cannot be withheld from the writer. The fix is the upper-bound check,
not the grant** — and that is the difference from the journal case, where the writer never needs to
supply `xact_id` at all. The correct upper bound is **`pg_snapshot_xmin`, not `pg_snapshot_xmax`** —
tighter than the audit suggested, and for a reason: `computed_at_xid` is a *captured* xmin and the
cluster xmin is non-decreasing, so any honestly captured value is `<=` the current xmin, while `xmax`
would admit a cursor above the current horizon, which is exactly the forgery `recon_cursor_breaks`
refuses for an entry. **Reasoned, not measured**: the forged-2^62 cell shows the check firing, not that
the bound is the tightest sound one.

## D · Partitioning `ledger_period_balances` by period

`./run-partitioning.sh` → `out/partitioning.txt`. The candidate DDL applied by hand in a scratch
database with two tenants on **different period-code vocabularies** (`2026-01`, `2026-02` and
`FY2026Q1`) on purpose.

**`PARTITION BY LIST (period_code)` is legal under the tenant-leading primary key**, and the primary key
is **unchanged**: `pk_period_balances` is still `PRIMARY KEY (tenant_id, period_code, currency,
account_id)`. A partition key must be a *subset* of every unique constraint, not a prefix of it — and
`period_code` is in the key because the period needed it, not because anyone was planning this. **The
tenant-leading convention costs nothing here.**

**Both foreign keys survive, on the parent and on all four partitions, and both still refuse**, through
the parent:

```
ERROR:  insert or update on table "ledger_period_balances_p2026_01" violates foreign key constraint "fk_period_balances__account"
ERROR:  insert or update on table "ledger_period_balances_pdefault" violates foreign key constraint "fk_period_balances__close"
```

Both are *outgoing* foreign keys from the partitioned table, supported since PostgreSQL 12; nothing
references `ledger_period_balances`, so the harder case does not arise. The catalog shows **55
constraint rows** across parent and partitions after the change, every one carrying its baseline name.

**All three RLS policies survive and the reader is still scoped** — and the reason the last line is
refused is the one worth writing down:

```
 rls_period_balances__recon  | r | openledger_recon | true
 rls_period_balances__tenant | r | openledger_read  | (tenant_id = (SELECT current_setting('app.tenant_id', true)))
 rls_period_balances__writer | * | openledger_app   | true

as openledger_read scoped to t1:  t1 | 7
as openledger_read scoped to t2:  t2 | 3
with NO app.tenant_id set:        rows_when_unscoped | 0
a PARTITION addressed directly:   ERROR: permission denied for table ledger_period_balances_p2026_01
```

The read-path control ADR-0013 §5 built is intact: scoped through the parent, **fails closed** when
unscoped, and a partition addressed directly is refused — **because there is no grant on the
partitions, not because a policy covers them.** Policies on a partitioned parent apply to parent-routed
access only; a partition addressed directly carries its own policies and it has none. So **the absence
of partition grants is load-bearing**, and a later `GRANT … ON ALL TABLES IN SCHEMA public` would open a
direct, unscoped path to every tenant's checkpoint. That belongs in the ADR's cost column, and it does.

**Every grant survives, including the belt-and-braces `REVOKE`.** Twelve grant lines on the parent, none
on any partition; `openledger_app` inserting **through the parent** into a partition it holds no grant on
succeeds, while `UPDATE`, `DELETE` and `TRUNCATE` on the parent are refused three times and `SELECT` and
`UPDATE` on a partition directly are refused as well — so the parent `REVOKE` has no hole underneath it.
Privileges are checked on the relation named in the query, which is what keeps the grant list identical
to the baseline's.

**The append-only perimeter permits it here and would refuse it on a journal table.**
`ledger_period_balances` is **not** in `refuse_journal_ddl`'s `protected` array (`is_protected = f`, read
from `pg_get_functiondef`) and the DDL applies cleanly. The contrast:

```
CREATE TABLE probe_child () INHERITS (ledger_entries);
ERROR:  public.probe_child inherits from posted history: a child carries none of the parent's keys
        or triggers and is visible through it to every report
```

`ck_journal__no_inherit` is a **state assertion over `pg_inherits`**, and a partition creates a
`pg_inherits` row exactly as an inheritance child does — so partitioning any *protected* table
(`ledger_entries`, `ledger_transactions`, `ledger_events`, `ledger_periods`,
`ledger_period_closes`) is refused by the shipped perimeter. **Proven for `INHERITS`, reasoned for
`PARTITION OF`** by the shared mechanism, since the assertion reads `pg_inherits` and neither knows nor
parses the grammar. That bears directly on the roadmap's *"Partitioning by tenant … Legal on the shipped
schema — `PARTITION BY HASH (tenant_id)` succeeds on `ledger_entries`"*: whatever database that was
verified on, it cannot have had this event trigger installed and enabled. **The roadmap line needs a
caveat, or the event trigger needs a carve-out**; this spike does not settle which, because tenant
partitioning is not its subject.

**The book still reconciles afterwards** — ten checks, zero breaks — and the rows land in the right
partitions, `t1/2026-01` in `…_p2026_01`, `t1/2026-02` in `…_p2026_02`, `t2/FY2026Q1` in
`…_pfy2026q1`.

**What the migration actually has to do, and the ordering is not cosmetic.**

```
ALTER TABLE ledger_period_balances PARTITION BY LIST (period_code);
ERROR:  syntax error at or near "PARTITION"

DROP TABLE ledger_period_balances;
ERROR:  cannot drop table ledger_period_balances because other objects depend on it
DETAIL:  view recon_checkpoint_breaks depends on table ledger_period_balances
         view reconciliation depends on view recon_checkpoint_breaks
```

**There is no in-place conversion — the statement does not exist** — and the table cannot be dropped
while its two readers stand. So the migration must drop `reconciliation`, drop
`recon_checkpoint_breaks`, park the rows, drop the table, create the partitioned table and its
partitions, move the rows back, re-enable RLS with all three policies, re-issue every grant and the
`REVOKE`, restore the table comment, and recreate both views with their `GRANT … TO openledger_recon`.
Every line of it is **migration 00004**, never an edit to the baseline:
[ADR-0003](/decisions/0003-migrations)'s freeze is CI-enforced by
`scripts/check-migrations-immutable.sh` with no opt-out. And building the partitioned table *beside*
the old one forces suffixed constraint names, while `ALTER TABLE … RENAME CONSTRAINT` on a partitioned
parent renames **the parent's copy only** — `FINDINGS.md` §5.7 records 20 of the 55 constraint rows left
carrying `fk_period_balances__close_new` and `ledger_period_balances_new_tenant_id_not_null`,
permanently. Parking the rows in a staging table and dropping the old table **first** costs one extra
copy of a table that is derived anyway and keeps the naming convention intact; that is what
`PROPOSAL.sql` does, and it is the approach whose clean 55 rows are in the capture above. The cheaper
alternative available **only because of what this table is** — it is derived and exactly recomputable
from `ledger_entries` at each close's own `computed_at_xid`, which is ADR-0011 §3's whole argument — is
"rebuild by recomputation", a legal strategy here where it would not be for a journal table. **Which is
faster on a large book is a number** and is in `MEASUREMENT-PLAN.md`.

**What partitioning costs beyond the constraints.** The close is an ordinary posting by
`openledger_app`, which holds **no `CREATE` privilege**, so a period whose partition was never
provisioned would make the close **fail** rather than merely lose the benefit — the `DEFAULT` partition
is not decoration, it is what keeps the close working, and provisioning becomes an operator or
migration task. And `period_code` is a **tenant-supplied free-text label** — the baseline's own comment
says *"'2026-02', 'FY2026Q1' — a label, not a key of time"* — so under `LIST` the partition set is the
**union of every tenant's vocabulary**, which the two-tenant book demonstrates: three partitions for two
tenants' three distinct codes, and a hundred tenants with idiosyncratic period codes is a hundred
vocabularies. **`HASH (period_code)` is the alternative and buys something different**: a fixed
partition count, no DDL per period and **no vocabulary problem** — and also no per-period `DETACH`, with
each partition's index still growing with every period. It is a smaller-trees change, not a lifecycle
change, and if it captures most of `LIST`'s saving then `LIST` should not ship. Finally, **the mechanism
is stated so that it can be falsified**, because it is unmeasured: partitioning by period does not
reduce the number of rows written or index entries maintained, it changes *which* index they enter — one
fresh, empty, sequentially-filled per-partition primary key per close instead of appending into a
shared tree grown by every period before it. **If that is where spike 016's ~96% goes, the saving grows
with the number of periods already closed and is ~0 on the first close.**

## E · The snapshot gap, at exactly the strength it was measured

What moves under the change is expected and readable: `relkind` flips `r` → `p`, each partition appears
as a new `r` line, and the parent's primary key gains `ON ONLY`. What the dump **cannot** see was
grepped from the test itself:

```
    relpartbound             in schema_snapshot.rs: ABSENT
    relispartition           in schema_snapshot.rs: ABSENT
    pg_inherits              in schema_snapshot.rs: ABSENT
    pg_partitioned_table     in schema_snapshot.rs: ABSENT
    pg_get_partkeydef        in schema_snapshot.rs: ABSENT
```

**None of the nineteen sections records the partition key, a partition's bound, or whether a relation is
attached at all.** So a partition attached with the **wrong bound**, the partition **key** changed, or a
partition **detached** are invisible to the one test [ADR-0009](/decisions/0009-append-only-perimeter)
names as the only backstop for the owner-accident DDL class. Demonstrated with one statement:

```
ALTER TABLE ledger_period_balances DETACH PARTITION ledger_period_balances_p2026_01;

 rows_via_parent | rows_in_detached | checkpoint_drift_breaks | total_breaks
               7 |                3 |                       3 |            3

p ledger_period_balances rowsecurity=true
r ledger_period_balances_p2026_01 rowsecurity=false     <-- the snapshot line is UNCHANGED
```

Three of ten stored rows vanish from every reader of the checkpoint — the reports, the reconciliation
views, the sweep — and **the snapshot's line for the detached table is byte-identical to the attached
one**, because a detached child is still an `r` relation of the same name in the same schema. **The
reconciliation sweep does catch it** (`checkpoint_drift = 3`, `missing_row`), so it is not silent; but
the sweep is daily and the snapshot is per-push, and ADR-0009's charge for this class is the
snapshot's. Migration 00004 must widen the dump, and `PROPOSAL.sql` carries the section text — which
also catches the roadmap's eventual tenant partitioning for free, and reads `(none)` on a schema with no
partitions.

**Two limits on that sentence, both of them the ADR's own.** What was *measured* byte-identical is the
**relations section** and the index lines beside it; whether the whole nineteen-section dump stays
identical across a `DETACH` hinges on PostgreSQL 18 orphaning cloned foreign keys rather than dropping
them, and **nothing here tested that**. And the hole is **not** universal:
[ADR-0020](/decisions/0020-checkpoint-on-the-report-path) notes that the dump has a triggers section and
that `DETACH` drops triggers cloned from the parent, so the **nine trigger-bearing tables would still
show drift** — which is precisely why this matters for `ledger_period_balances`, which carries none, and
not for them.

## F · Four defects found by the correctness gate, which was looking for something else

**1 · `recon_cursor_breaks` reports `above_horizon` for honest entries, and `openledger reconcile`
exits 1 on a healthy book.** A holder acquires an xid with `pg_current_xact_id()` and writes nothing; a
second session commits one ordinary posting; a third runs the sweep **exactly as `openledger reconcile`
does** — `BEGIN TRANSACTION READ ONLY`, holding no xid of its own:

```
 xmin_pinned_by_the_holder | xmax  | newest_committed_entry_xid
                     16164 | 16166 |                      16165

 shipped_above_horizon_breaks | xmax_bounded_breaks | sweep_would_exit_1
                            2 |                   0 |                  1
```

`recon_cursor_breaks` bounds an entry's `xact_id` by `pg_snapshot_xmin`, whose comment asserts *"a
committed row's commit position is always retired below the horizon by the time the sweep runs"* — false
whenever any transaction older than the entry is still running, which on a busy database is most recent
entries. **The fix is one word**: `pg_snapshot_xmax` is `latestCompletedXid + 1`, so no *committed* xid
can reach it, and the same book at the same instant reports 0. An earlier version of this cell posted
*inside* the measuring transaction and reported 2 under both bounds — a snapshot's xmax equals the
observer's own xid, so the observer was flagging itself; the sweep holds no xid, which is why the
corrected cell is the one that answers the question. **Not hypothetical, and not only reachable by
construction**: the first run of `run-cursor-arms.sh` observed 6 total breaks on a correct book while a
neighbouring spike held the cluster horizon, and [spike 021](/spikes/021-reporting-layer-defects)
reproduced the same defect independently — twice, once by accident.

**2 · A period with no revenue or expense cannot be closed without breaking the sweep.** A book with a
capital injection and nothing else — a real balance sheet, no temporary-account movement:

```
before the close:  breaks = 0

after closing a period with nothing to sweep:
       check_name        | breaks
 unbalanced_transactions |      1

            transaction_id            |     kind     | status | leg_count |   reason
 01a05d7f-8c38-7f07-9429-846797e79a9e | period_close | posted |         0 | no_entries

openledger reconcile would exit 1
```

The close sweeps one posting per temporary account with a non-zero balance, so a period with nothing to
sweep writes a `period_close` transaction with **zero entries** — and `recon_transaction_breaks` flags
every entryless transaction as `no_entries`, the [ADR-0004](/decisions/0004-where-logic-lives)
`TRUNCATE` scar's class. Migration 00003 carved out the **void** and nothing else. The close is
otherwise entirely well-formed: the `ledger_period_closes` row is there, `computed_at_xid` is right, and
the checkpoint has its two rows. The narrow carve-out closes it on the same book (`breaks = 0`):
`x.kind = 'period_close' AND EXISTS (a ledger_period_closes row naming it)` — a key lookup, exactly the
device ADR-0011 §2 chose for the income statement's exclusion, and tight, because `fk_closes__txn_kind`
already forces the kind and `uq_closes__txn` makes the naming one-to-one.

**3 · `cursor_precedes_close` is a false positive on any cluster that is not idle** — §A's second cell,
and the shipped check's green today is an artifact of an idle cluster rather than evidence of the
property it is named for.

**4 · `computed_at_xid` is unbounded above under a table-wide `INSERT` grant** — §C's adversarial cell,
where a forged cursor is green in `recon_close_breaks` and silences that period's disclosure feed
entirely.

*(`FINDINGS.md` §0 lists those four. [ADR-0020](/decisions/0020-checkpoint-on-the-report-path) also
lists four and swaps the third for a fifth fact this spike measured incidentally: **the close upserts
the balance-cache row of every temporary account it sweeps, so any open writer holding one of those rows
blocks the close.** The first version of `run-cursor-arms.sh` hung on exactly that, and the concurrent
writer was moved off `fee_revenue` for the experiment. Five distinct facts between the two lists; this
page states all five.)*

---

## What this spike refutes, withdraws or corrects

Collected because this project treats a withdrawn claim as a first-class result. `FINDINGS.md` §7 names
six, each with the file and the sentence.

1. **ADR-0011 §3's A4 sentence, and the same sentence in the shipped comments at
   `migrations/00001_baseline.sql:882-893` and `:1985-1990`:** *"a temporary account's checkpoint row is
   exactly 0 and `retained_earnings` carries the swept earnings."* **False on the shipped mechanism**
   (the stored row is the pre-close position, measured) **and unsatisfiable as specified** (proven for
   the two reachable cursor values, reasoned for the impossibility). It becomes true under the identity
   change — the first time the sentence has described the artifact.
2. **ADR-0011 §3's mechanism clause,** *"`computed_at_xid` is held at or above the closing transaction's
   own `xact_id`"*, enforced by `recon_close_breaks`. The enforcement is a **false positive on any
   non-idle cluster**, and the correct predicate is the **inverse** — refuse a cursor *above* the close,
   which is what `recon_close_order` does.
3. **ADR-0011 §3 and roadmap [M5](/roadmap#m5--bitemporal-reads):** *"`balance_sheet_at`,
   `income_statement_for` and `trial_balance_at` never reference `ledger_period_balances` (proven from
   `pg_get_functiondef`), so they **aggregate `ledger_entries` from inception**."* The first half is
   correct and is [spike 016](/spikes/016-close-cost-at-scale)'s finding. **The second half is true of
   `balance_sheet_at` only** — `income_statement_for` and `trial_balance_at` both carry
   `e.effective_at >= p_from`, a caller-supplied lower bound, so neither scans from inception unless the
   caller passes `-infinity`. Read from the shipped bodies at `migrations/00001_baseline.sql:1052`,
   `:1090` and `:1194`. **This is the claim on
   [spike 016's page](/spikes/016-close-cost-at-scale) that this spike supersedes**, and it is corrected
   in place there. The correction matters because it re-sizes M5: the from-inception scan to be removed
   is `balance_sheet_at`'s position aggregate, its earnings plug and its A14 guard — three scans in one
   function — plus `recon_equation_breaks`, which calls that function at `('infinity', report_cursor())`
   per tenant on **every reconciliation sweep**. It is not three functions that need fixing; it is one
   function that the sweep calls.
4. **ADR-0011 §4,** *"their inner query plans the same nested loop"*, of the two statement functions.
   **Not observable through `EXPLAIN`** — both are `plpgsql` and plan as a bare `Function Scan`.
   Recorded as **unverified, not contradicted**; `auto_explain.log_nested_statements` is how it gets
   verified or withdrawn.
5. **`recon_cursor_breaks`' own comment in `migrations/00001_baseline.sql`:** *"a committed row's commit
   position is always retired below the horizon by the time the sweep runs."* **False** — two
   `above_horizon` breaks on an honest book, and the shipped sweep exits 1.
6. **The roadmap's *Deliberately not now* note:** *"Partitioning by tenant … Legal on the shipped
   schema — `PARTITION BY HASH (tenant_id)` succeeds on `ledger_entries`."* Needs a caveat rather than a
   refusal: `ck_journal__no_inherit` refuses a child of any protected table and a partition is a
   `pg_inherits` child.

## The acceptance run — `PROPOSAL.sql` applied end to end

The proposal is not a sketch. It was applied **in one transaction** to a fresh identity-convention book
and the differential re-run **the other way round**: the shipped names now carry the checkpoint form,
and the baseline's own bodies — extracted verbatim from `migrations/00001_baseline.sql` and renamed
`_ref` — carry the from-inception form (`out/verify-proposal.txt`).

```
=== 1. THE GATE ===                                ten checks, total_breaks = 0
=== 2. the checkpoint lives in partitions ===      LIST (period_code), 27 rows
=== 3. the AT-CLOSE property ===                   every temporary account 0;
                                                   retained_earnings -400 / -1200 / -2160
=== 4. the differential ===                        balance_sheet_disagreements = 0   (60 points)
                                                   trial_balance_disagreements = 0   (9 windows x 60)
=== 5. the inverted window ===                     refused, SQLSTATE 22023
=== 6. the sweep ===                               close_order_breaks 0; level 0, bounded 0
=== 7. the indexes ===                             five shipped, unchanged, plus the two new
```

Three things this run establishes that the earlier ones could not. **The proposal applies as a single
atomic migration — and it does not, on the first attempt: the ordering is forced.** `reconciliation`
pins `recon_close_breaks`, whose column list changes so `CREATE OR REPLACE` is not available, and
`recon_checkpoint_breaks` pins `ledger_period_balances`, which has to be dropped; both errors are quoted
in `PROPOSAL.sql`'s part 0, and the partitioning had to move **before** every view rather than after,
which is why the file's parts are numbered 0, 1a, 1b, 2 … rather than 1 … 6. **The differential holds
against the baseline's real bodies**, not against a paraphrase of them. And **the `reconciliation` view
survives the round trip with its grant**, because a dropped view takes its ACL with it and
`openledger reconcile` reads that view as `openledger_recon`.

**What the acceptance run does not cover**, stated where it is easy to overlook: the two indexes are
created and **nothing measures their write cost**; the partition set is the `DEFAULT` partition alone,
because a migration cannot enumerate future period codes and spelling the per-period ones out is an
operator's provisioning job; and the bounded checkpoint check is created and granted but deliberately
**not** wired into `reconciliation`, because it reports a different row count and is sound only while
the order check is green — swapping it in on faith is exactly the move ADR-0010 warns about.

## What could not be settled without the timing pass

`MEASUREMENT-PLAN.md` specifies six questions, three books, three repetitions per configuration with
ranges rather than single runs, a loadavg recorded on every row, a horizon poll before every close, and
a decision rule written **before** the numbers. **None of it has been executed.**

1. **Is the rewritten `balance_sheet_at` actually faster, and by how much?** ADR-0011 §3's 45–49× and
   spike 016's ~40–230× were measured on hand-written queries, not on the function, and without the A14
   guard and the earnings plug included. The plan estimates say the tails are cheap; **nothing here says
   the whole function is.**
2. **Are the two candidate indexes worth their write cost?** 224 kB each on a 30k-entry book, and they
   move tail A from a sequential scan to a bitmap index scan by estimate. The cost is on the hot write
   path and is not estimable from a plan. The rule is two-staged — if both together cost more than 5% of
   the baseline's clearings/s, ship the effective-axis index alone and let tail B keep its skip scan; if
   that one alone still costs more than 5%, ship neither.
3. **Where is `trial_balance_at`'s crossover?** More work for a short intra-period window, less for a
   position reading. The crossover is a window-length-to-period-length ratio, and if it is above ~1 the
   honest answer is to keep both forms rather than ship a pessimization for the common call.
4. **Is the bounded reconciliation actually cheaper, and where does the curve cross?** At 12 closes and
   30,024 entries the two plan estimates are within 2% of each other. The asymptotic argument says the
   bounded form wins as closes grow; **12 is not enough closes to show it**, which is why the ladder runs
   to 48.
5. **How much does partitioning save on the close?** The mechanism and its falsifiable prediction are
   above. Spike 016's ladder — 10,000 / 100,000 / 1,000,000 accounts — plus a periods dimension is what
   answers it, with `HASH` and a `DEFAULT`-partition-only control as the arms that keep the answer
   honest.
6. **Does `income_statement_for` need anything at all?** Its cost is O(entries in the window) and nobody
   has measured whether that is a problem at scale. It is **not a checkpoint question**, which is why
   this spike closes it as *"no checkpoint"* rather than as *"fast enough"*.

Two correctness debts are named in the same place so they are not lost with the timings: **the A14
guard's red case**, which belongs in the migration's own test rather than in a timing pass, and
**nothing measured over a network** — every observation here is one localhost PostgreSQL, which the
roadmap already calls the project's largest open caveat.
