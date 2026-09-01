# 0020 — The checkpoint is read by one function, the close is admitted by identity, and the snapshot cannot see a DETACH

**Status:** accepted (ruled 2026-09-01). It **amends [0011](/decisions/0011-period-close-and-report-axes) §3**,
whose at-close sentence is not merely unbuilt but *unsatisfiable as specified*, and **amends
[0007](/decisions/0007-schema-conventions-and-chart) §2**, whose snapshot test cannot see a partition
detached.
**Evidence:** [spike 020](/spikes/020-checkpoint-on-the-report-path); the close's cost at scale is
[spike 016](/spikes/016-close-cost-at-scale)'s.

## The decision

**`ledger_period_balances` gets a reader on the report path, and it is one function — not three.**
[0011](/decisions/0011-period-close-and-report-axes) §3 and the roadmap both said the statement
functions "aggregate `ledger_entries` from inception". **That is true of `balance_sheet_at` only**, and
the correction matters because it re-sizes the milestone: `trial_balance_at` and
`income_statement_for` each carry `effective_at >= p_from`, so a caller asking for one month scans one
month. `balance_sheet_at` has no lower bound *by nature* — a position is cumulative — and it is the
one the sweep calls at `'infinity'` for every tenant, so wiring it pays twice.

**`income_statement_for` is refused the checkpoint outright**, and the reason is structural rather
than budgetary: it is a **flow**, the accounts it reports are exactly the ones a close zeroes, and it
is already window-bounded. `trial_balance_at` can only take it as `prefix(to) − prefix(from)`, and the
first version of that was **wrong on an inverted window** — it returned negative gross debits where
the shipped body correctly returns nothing — so it is refused too, pending the crossover measurement.

**The reader is checkpoint plus two tails, and three things [0011](/decisions/0011-period-close-and-report-axes) §3
left out are load-bearing.** Zero disagreements against the from-inception form at **all 60
(tenant, cursor, as-of) points** — a book with no closes, one, and three; a backdated posting; a
resolution backdated into a closed period; a reversal; a voided pending; an unresolved pending; two
currencies closed to *different* depths; as-of exactly on each boundary; mid-period; and `infinity` —
then again on a 30,000-entry, twelve-close book. What the ADR's paragraph omits:

1. **The boundary is chosen per currency**, because a close is per `(tenant, currency)` and two
   currencies are routinely closed to different depths.
2. **The anchor is guarded on the closing transaction's own `xact_id`**, or a close *restates an
   already-issued statement upward*.
3. **Tail B must exclude the close's own transaction**, or the closing legs are counted twice —
   measured at **1,000 against a true 500**.

**At-close and a reproducible cursor are mutually exclusive in one transaction. This is proven, and
it is why §3's A4 sentence is not a bug to fix but a specification to replace.** Six cells, three
candidate cursor values by two horizon states:

| what the close stores | on an idle cluster | with one other writer open |
| --- | --- | --- |
| `pg_current_xact_id()` (equality) | at-close holds | **`cursor_precedes_close` fires on a correct close** |
| `report_cursor()` (`pg_snapshot_xmin`) | below its own xid | below its own xid — and it **silently loses a real posting**: 10,570 read as 10,500 |

`xid8` has no successor operator, so there is no third value to reach for. **The audit's proposed fix
— relaxing the recompute to `e.xact_id <= c.computed_at_xid` — was tested and refused**: it holds only
where equality holds, which is precisely the arm that is not reproducible. What works is to stop
bounding the close by its cursor at all and **admit it by transaction identity**
(`OR e.transaction_id = c.transaction_id`). The checkpoint is then the at-close position under **both**
horizon states, and the reader agrees with the from-inception form under both. Both conventions
produce the *same statement*; what changes is what a human reading the stored row is told, and until
now they were told something false.

**The bounded reconciliation check ships with a new invariant, because it needs one.**
`recon_checkpoint_breaks` is O(entries × closes) today — it re-aggregates the whole prefix once per
close, measured growing 1 : 3.2 : 5.8 : 8.2 over 3/6/9/12 closes. `width_bucket` band assignment
turns that into **one pass over `ledger_entries`**, confirmed from the plan, and catches all four
drift classes on both books with the clean-book control at zero. Two things came out of building it:

- **The difference comparison alone loses a class.** A deleted trailing row for an account that did
  not move in the final band is reported by the level form and **not** by a bounded form that
  compares only deltas. The presence half of the check is what restores it, so the bounded view keeps
  both.
- **Out-of-order closes are legal today** — the shipped sweep reports zero breaks on them — and they
  make the bounded form report **false** breaks. So this decision adds `recon_close_order` as its
  own reason. That same invariant is what makes the at-close claim true, and what makes
  `close_disclosures`' carve-out dead: 18/18/0 rows in order, 0/2/2 out of order.

**Partitioning `ledger_period_balances` is legal, designed, and deliberately not decided here.**
`LIST (period_code)` under an unchanged tenant-leading primary key: both foreign keys survive **and
still refuse**, all three RLS policies survive with a scoped reader scoped and an unscoped one at zero
rows, every grant survives with parent-routed `INSERT` working while `UPDATE`/`DELETE`/`TRUNCATE` stay
refused, and the sweep is at ten zeros afterwards. What it costs is written down: **there is no
in-place `ALTER`** (proven — a syntax error), the table cannot be dropped while its two views stand,
`period_code` is a tenant-supplied label so the partition set is the union of every tenant's
vocabulary, **the app role cannot create a partition** — hence a `DEFAULT` partition, or the close
stops working — and the migration must drop the old table *first* or 20 of 55 constraint rows are
permanently misnamed. Whether it is worth doing waits on the measurement pass, with the mechanism
stated so it can be falsified: the saving should be ~0 on the first close and grow with the number of
closes.

**And the snapshot test cannot see a partition detached.** `[0007](/decisions/0007-schema-conventions-and-chart) §2`'s
dump records `relkind`, so *converting* a table to partitioned is visible as `r` → `p`, and each
partition appears as its own relation line. **The partition key, the partition bounds, and whether a
child is attached are all absent**: `relpartbound`, `relispartition`, `pg_inherits`,
`pg_partitioned_table` and `pg_get_partkeydef` are dumped nowhere. So one `DETACH PARTITION` removes
rows from every reader — the reports, the reconciliation views, the sweep — **with the snapshot
byte-identical**, because a detached child is still an `r` relation of the same name in the same
schema. That is exactly the owner-accident class [0009](/decisions/0009-append-only-perimeter) widened
the charge for, and it is uncovered. The three catalogs go into the dump **in the same migration that
first partitions anything**, and they go in whether or not partitioning is adopted — the hole exists
today for any table.

**Four defects found while looking for something else, all going into the same migration.**

| | |
| --- | --- |
| **`recon_cursor_breaks` bounds by `xmin` where it means `xmax`** | An honest book gets two `above_horizon` breaks and **`openledger reconcile` exits 1**. A one-word fix, and [spike 021](/spikes/021-reporting-layer-defects) reproduced it independently — twice, once by accident, when a neighbouring database held the horizon |
| **A period with no revenue or expense cannot be closed** | The close writes an entryless transaction and `recon_transaction_breaks` flags it `no_entries`. It wants the same shape of narrow carve-out migration 00003 gave the void |
| **`computed_at_xid` is bounded from below only** | Forged to `2^62` it is green in `recon_close_breaks` and silences `close_disclosures` for that period entirely — and it sits under a **table-wide** `INSERT` grant, unlike `xact_id`, which is withheld by a column-level one for the identical reason |
| **The close blocks behind any open writer** | It upserts the balance cache of every account it sweeps, so one uncommitted posting on one of those rows holds the whole close |

## What we considered

| | Why not |
| --- | --- |
| **Wiring all three statement functions to the checkpoint** (0011 §3's framing, and the roadmap's) | Two of the three are already window-bounded, and the flow statement reports exactly the accounts a close zeroes. The milestone is one function. |
| **`trial_balance_at` as `prefix(to) − prefix(from)`** | Correct on a normal window and **wrong on an inverted one** — negative gross debits where the shipped body returns nothing. Refused pending a crossover measurement; the shipped body is not slow enough to justify the risk. |
| **Relaxing the recompute to `xact_id <= computed_at_xid`** (the audit's proposal) | Tested and refused: it holds only on the arm where equality holds, which is the arm that is not reproducible under a concurrent writer. |
| **Requiring `computed_at_xid > x.xact_id`** | Forces the close into two transactions and contradicts the settled framing that the checkpoint is one `INSERT … SELECT` in a transaction already running. |
| **A bounded check comparing only band deltas** | Loses a drift class — a deleted trailing row for an unmoved account. The presence comparison is not redundant. |
| **`PARTITION BY HASH (tenant_id)` on the journal tables** (the roadmap's "deliberately not now" note) | Needs a caveat rather than a refusal: `ck_journal__no_inherit` refuses a child of any protected table, so the roadmap's claim that hash partitioning "succeeds on `ledger_entries`" is not true as written on the shipped schema. |
| **Adopting partitioning now** | The close's cost is ~96% checkpoint *write*, which is the argument for it — but no timing pass has run, and the mechanism predicts ~0 saving on a first close. A written decision rule beats a hunch. |

## What it costs

- **Two candidate indexes, and tail A is the one that needs them.** Tail B is already served by
  PostgreSQL 18's skip scan; tail A is not — the planner prefers a sequential scan. The two indexes
  are 224 kB each on a 30,000-entry book, about **7% more index bytes**, and they are on the write
  path. The decision rule is written and not yet applied: **more than 5% off clearings/s and they do
  not ship.**
- **Six questions are unmeasured**, in the spike's `MEASUREMENT-PLAN.md`: whether the rewritten
  function is actually faster, whether the indexes earn their write cost, `trial_balance_at`'s
  crossover, whether the bounded sweep is cheaper — **at twelve closes the two plan estimates are a
  dead heat**, which is why the ladder runs to 48 — how much partitioning saves the close, and
  copy-versus-recompute for the migration itself.
- **The A14 refusal's red case was never constructed.** Every account type is presented at every
  chart version on every book this spike built, so the guard that makes a statement refuse an
  unpresented type has not been seen to fire. Named as a correctness debt, not as a passing test.
- **A `DEFAULT` partition is load-bearing if partitioning is adopted**, because the app role cannot
  create a partition and `period_code` is a tenant-supplied label. That is a permanent operational
  obligation — a partition per period per vocabulary, created by someone with more than the app
  role's grants — traded against the close's write cost.
- **`PROPOSAL.sql`'s part ordering is forced, not chosen.** The spike documents the two errors that
  force it. A migration written from it in a different order does not apply.
