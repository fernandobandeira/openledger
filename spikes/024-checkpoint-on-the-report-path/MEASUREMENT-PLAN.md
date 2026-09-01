# Spike 024 — the timing pass, precisely specified and NOT RUN

**Nothing in this file has been executed.** Another spike was writing to another database on this
PostgreSQL for the whole of spike 024's design phase, and this project's own banner says two
harnesses on one database invalidate everything: *"the same configuration measured 833 and 482
clearings/s at loadavg ~1.5 and ~6.3, and the ratios moved ~30% too."* That is not a caveat here, it
is a lived fact — the other spike's open transactions pinned the cluster horizon for long enough to
make a close store an **empty checkpoint** and to make `openledger reconcile` report
`cursor_forgery ≠ 0` on a healthy book (FINDINGS §4.1). Both of those were discovered *because* the
machine was busy. Neither is a timing result.

Run this pass only when the machine is quiet, and read every rule below as binding.

---

## Ground rules, inherited and one added

- **One harness, one database, one measurement at a time.** Strictly sequential; never overlap runs.
- **Record the machine's load with every number** — the 1-minute loadavg at the start and end of each
  run, in the result row. Spike 003's banner exists because it did not.
- **Three repetitions per configuration**, median and spread reported. Report **ranges, never single
  runs**.
- **Gate every configuration on correctness.** `SELECT * FROM reconciliation` must report ten checks
  at zero breaks *after* each run. A number from a book that does not reconcile is not a number.
- **Added by this spike: gate every configuration on the CLUSTER HORIZON too.** Before every close,
  poll until `pg_snapshot_xmin(pg_current_snapshot()) > (SELECT max(xact_id) FROM ledger_entries)`.
  A close taken under a pinned horizon stores a checkpoint of nothing and every ratio measured
  against it is meaningless. Record the number of polls it took; a run that needed more than a
  handful was not on a quiet machine and should be discarded.
- **Localhost is not a benchmark.** Every number here is from one localhost PostgreSQL 18. The
  **ratio** is the finding, never the millisecond — and where the ratio is what is claimed, say which
  two configurations it is between.

## The books

Three, because the three questions have different shapes. Each is built by
`build-book.sh`-style seeding, gated, and then closed period by period.

| book | shape | for |
| --- | --- | --- |
| **R** (read) | 1 tenant, 1 currency, **200,000 accounts**, ~2,000,000 entries over 24 monthly periods, all 24 closed. One backdated arrival per period into the two periods below it, so tail B is never empty | Q1, Q2, Q3 |
| **S** (sweep) | 1 tenant, 1 currency, **8,000 accounts**, ~300 entries per period — the same shape spike 020's Q3 used, so the growth curves are directly comparable — closed at **3 / 6 / 9 / 12 / 24 / 48** periods | Q4 |
| **W** (write) | spike 020's ladder: **10,000 / 100,000 / 1,000,000** accounts, 1 currency, closed at period **1, 6, 12 and 24** so the per-close cost can be read against how many periods already exist | Q5, Q6 |

Book **R**'s size is chosen so that the from-inception scan is genuinely expensive: spike 024's
design phase used 30,024 entries, which is far too small to separate the two forms — at 12 closes the
planner's estimates for the two reconciliation forms were within 2% of each other.

---

## Q1 · Does the rewritten `balance_sheet_at` actually pay, and where?

**What it settles.** Whether ADR-0011 §3's 45–49× (one account, hand-written query) and spike 020's
~40–230× (million-entry book, hand-written query) survive being wrapped in the real function — with
the A14 guard and the earnings plug included, and aggregating over every account of a tenant rather
than one. **Nothing in spike 024 measures this**; the design phase only proved the two forms agree.

**Configurations** — on book **R**, at a pinned cursor captured once and reused so the two arms see
the same book:

| arm | function |
| --- | --- |
| `inception` | `balance_sheet_at_ref` (the baseline body, extracted verbatim — `sql/90_reference_bodies.sql`) |
| `checkpoint` | `balance_sheet_at` after `PROPOSAL.sql` |

× six as-of instants, chosen to separate the two effects the ADR's own table separates:

- on a close boundary, **early** in history (period 2 end)
- on a close boundary, **late** (period 24 end)
- **mid-period**, early (period 2, day 15)
- **mid-period**, late (period 24, day 15)
- `'infinity'` — what `recon_equation_breaks` passes
- a boundary **below** the newest close, so tail B is non-empty and the anchor's cursor guard is
  exercised

× 3 repetitions = **36 timed calls per arm**.

**What each number settles.** The boundary/mid-period pair is the honest claim: ADR-0011 §3 says the
cost *"stops depending on the age of the book and starts depending on the length of one period"*, so
the early/late pair at fixed period length is what tests it, and a ratio that shrinks between early
and late refutes it. `'infinity'` is the one the daily sweep actually pays.

**Also record, not timed:** `EXPLAIN (ANALYZE, BUFFERS)` of the *inner* query of each arm under
`auto_explain.log_nested_statements = on`. FINDINGS §2.7 records that both functions plan as a bare
`Function Scan`, so ADR-0011 §4's claim that *"their inner query plans the same nested loop"* is
currently unverified — and `auto_explain` is how it gets verified or withdrawn.

## Q2 · Are the two candidate indexes worth their write cost?

**What it settles.** Whether `ix_entries__tenant_effective` and `ix_entries__tenant_commit` earn
their place on the hot write table. The plan evidence is one-sided: they help the read (tail A goes
from a sequential scan to an index bitmap by estimate; tail B's `effective_at` moves into the Index
Cond) and cost 224 kB each on a 30k-entry book. **The write cost is not estimable from a plan.**

**Configurations.** Spike 022's harness (`spikes/022-batching-and-stripe-selection/RUN.sh`), whose
whole job is clearings/s through the shipped statement, in **four** arms:

| arm | indexes |
| --- | --- |
| `base` | the five shipped indexes on `ledger_entries` |
| `+eff` | plus `ix_entries__tenant_effective` |
| `+commit` | plus `ix_entries__tenant_commit` |
| `both` | plus both |

× the two configurations spike 022 found matter — single-path unstriped, and striped-under-batching
at the writer key — × 3 repetitions.

**What each number settles.** `base` against `both` is the price. `+eff` against `+commit`
separately, because **tail B is already served by PG18's skip scan** (FINDINGS §2.6), so
`ix_entries__tenant_commit` is the one to cut first if the price bites — and this is the arm that
says whether cutting it costs anything on the read side.

**The decision rule, written before the numbers:** if `both` costs more than **5%** of `base`'s
median clearings/s, ship `+eff` alone and let tail B keep its skip scan. If `+eff` alone costs more
than 5%, ship neither and let tail A keep its sequential scan — a defensible outcome, because a read
path that is 20× faster on paper is not worth a measurable dent in the write path this project has
spent two spikes tuning.

## Q3 · Where is `trial_balance_at`'s crossover?

**What it settles.** The difference form is bounded by two period lengths where the shipped body was
unbounded — and it is **more** work for a window that sits well inside one period, because each
prefix carries a tail from its own boundary. Nobody has measured where the two cross.

**Configurations** — book **R**, both arms (`trial_balance_at` vs `trial_balance_at_ref`), × window
shapes expressed as a fraction of a period:

| window | |
| --- | --- |
| `('-infinity', period 24 end)` | the position reading — where the difference form should win by the most |
| `(period 1 start, period 24 end)` | the whole book as a flow |
| one full period, late | the ordinary monthly trial balance |
| **10% of a period**, mid-period | where the difference form should LOSE |
| **1% of a period**, mid-period | where it should lose by the most |

× 3 repetitions. **What it settles:** the window-length-to-period-length ratio at which the two are
equal. If that ratio is above ~1 — i.e. the difference form loses for every sub-period window — then
the honest answer is to keep both forms, or to keep the shipped body and add a separate
`trial_balance_position_at`, and the ADR should say so rather than shipping a pessimization for the
common call.

## Q4 · Is the bounded reconciliation actually cheaper, and where does the curve cross?

**What it settles.** The one number the design phase most wants and least has. Spike 020 measured the
level form growing **1 : 3.2 : 5.8 : 8.2** over 3/6/9/12 closes. The bounded form is
O(entries + stored rows) by construction — proven from the plan: one `Seq Scan` over
`ledger_entries` against a nested loop over C closes — but at 12 closes and 30,024 entries the
planner's **estimates** were a dead heat (7,199 against 7,363), and an estimate is not a
measurement.

**Configurations** — book **S**, timed at **3 / 6 / 9 / 12 / 24 / 48** closes, three arms:

| arm | |
| --- | --- |
| `level` | `recon_checkpoint_breaks` as `PROPOSAL.sql` leaves it |
| `bounded` | `recon_checkpoint_breaks_bounded` |
| `sweep` | `SELECT COALESCE(SUM(breaks),0) FROM reconciliation` — what the operator actually runs |

× 3 repetitions. Report each arm **normalized to its own 3-close value**, so the growth curve is
directly comparable with spike 020's 1 : 3.2 : 5.8 : 8.2.

**What each number settles.** The `level` curve should reproduce spike 020's, which is the
sanity check that the ladder is measuring the same thing. The `bounded` curve should be flat in the
number of closes once the stored-row term is subtracted — and if it is not, the `width_bucket` band
assignment is not doing what the plan says and the design is wrong. The 3-close point is where the
bounded form is expected to *lose*; the crossover is the number that decides whether it ships as a
replacement, as a staged eleventh row in `reconciliation`, or not at all.

**Also record:** the row counts each arm reports under each of the four injected drift classes, at 48
closes. The design phase proved coverage on a 4-close book; the row-count difference (a forged value
producing two bounded rows to the level form's one) should be re-confirmed where C is large, because
a forged *early* level at 48 closes should still produce exactly two rows and not 47.

## Q5 · How much does partitioning the checkpoint save on the close?

**What it settles.** Spike 020's *"it wants partitioning by period before anything else"*, which was
a verdict about where the cost is, not a measurement of the fix.

**The mechanism to falsify, stated in FINDINGS §5.9 and repeated here so the pass can aim at it:**
partitioning by period does not reduce the number of rows written or the number of index entries
maintained. It changes *which* index they enter — one fresh, empty, sequentially-filled per-partition
primary key per close, instead of appending into a shared tree grown by every period before it. **If
that is the mechanism, the saving grows with the number of periods already closed and is ~0 on the
first close.**

**Configurations** — book **W**, four arms × three account counts × four close ordinals:

| arm | |
| --- | --- |
| `unpartitioned` | the baseline table |
| `list` | `PARTITION BY LIST (period_code)`, one partition provisioned per period plus DEFAULT |
| `list-default-only` | `LIST` with **only** the DEFAULT partition — the state a deployment lands in if provisioning is forgotten, and the control that isolates the empty-index effect from the partitioning overhead |
| `hash-16` | `PARTITION BY HASH (period_code)` with 16 partitions |

Timed at close **1, 6, 12 and 24** on the same book, so the ordinal is a real dimension and not four
separate books. × 3 repetitions.

**What each number settles.** `unpartitioned` at close 1 against close 24 measures how much the
shared tree's growth actually costs — the premise. `list` against `unpartitioned` **at each
ordinal** is the fix, and a flat ratio across ordinals *refutes* the mechanism above. `hash-16` is the
cheaper-to-operate alternative: if it captures most of `list`'s saving, the whole per-period
provisioning problem (FINDINGS §5.9, costs 1 and 2) is avoidable and `LIST` should not ship.
`list-default-only` is the negative control that keeps the answer honest.

**Also record, not timed:** `pg_relation_size` and `pg_indexes_size` per arm per ordinal. Spike 020
reported 135 MB for a million rows; whether partitioning changes the total or only its distribution
is a fact, not a timing.

## Q6 · Copy or recompute, for the migration itself?

**What it settles.** Migration 00004 has to move every existing checkpoint row into the partitioned
table. Copying preserves history byte for byte; recomputing from `ledger_entries` at each close's own
`computed_at_xid` is legal here *only* because the table is derived, and is the fallback that proves
it. On a million-account book with 24 closes that is 24 million rows either way, and the two are not
obviously the same cost.

**Configurations** — book **W** at 1,000,000 accounts and 24 closes:

| arm | |
| --- | --- |
| `copy` | `INSERT INTO … SELECT * FROM lpb_stage` |
| `recompute` | one `INSERT … SELECT` per close, bounded by `(xact_id < computed_at_xid OR transaction_id = <that close>)` |

× 3 repetitions, each from a fresh restore of the same book. **Gate both on `recon_checkpoint_breaks`
returning zero afterwards** — and note that `recompute` is the *only* arm where that gate is a real
test rather than a tautology, since `copy` cannot introduce a discrepancy the source did not have.

**What it settles.** If `recompute` is within a small factor of `copy`, the migration can offer it as
the option an operator picks when the old table is suspect — and the ADR gets to say that the
checkpoint's rebuildability is operationally real rather than merely argued.

---

## What this pass cannot settle, and should not pretend to

- **Anything about a network.** Every number here is localhost, where a round trip costs ~0.05 ms.
  The roadmap's largest open caveat is unchanged, and the read path is more sensitive to it than the
  write path is: a statement function is one round trip whatever it costs inside.
- **The A14 guard's red case.** FINDINGS §2.2 owes a negative control — an account type with posted
  entries and no `chart_presentation` row at the requested version, refused by the rewritten guard.
  That is a **correctness** test and belongs in the migration's own test, not in a timing pass; it is
  named here so it is not lost.
- **Whether `income_statement_for` is fast enough.** Its cost is O(entries in the window) and no
  checkpoint can improve on that (FINDINGS §2.4). If it turns out to be slow, that is a different
  spike about a different mechanism, and folding it in here would confuse a bounded scan with an
  unbounded one.
