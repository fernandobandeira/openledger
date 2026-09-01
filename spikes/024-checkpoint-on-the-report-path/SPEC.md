# Spike 024 — the harness specification

**The question.** ADR-0011 §3 specifies an as-of read as "checkpoint + two tails" and measures it at
45–49× at a close boundary; [spike 020](../020-close-cost-at-scale/) proved from
`pg_get_functiondef` that no statement function reads the checkpoint, that
`recon_checkpoint_breaks` is O(entries × closes), and that ~96% of a close's cost is the checkpoint
*write*. This spike designs the three fixes and proves the correctness of each. **It measures no
milliseconds**: another spike is writing to another database on this same PostgreSQL, and this
project's own banner says two harnesses on one database invalidate everything.

Everything runs against `migrations/00001_baseline.sql` + `00002` + `00003` applied by the compiled
`openledger migrate`, plus `schema/chart.sql`, in scratch databases this spike creates and drops.
The `openledger` database is never touched and `make reset` is never run.

---

## Ground rules, and one this spike had to add

- **Gate every book on correctness.** After building any book, `SELECT * FROM reconciliation` must
  return ten rows at zero breaks. A finding from a book that does not reconcile is not a finding.
  Two exceptions, both deliberate and both labelled where they appear: an *adversarial* cell whose
  whole point is to make a check go red, and the identity-mode book, which reconciles only once the
  matching recompute is applied — which is itself the finding.
- **Plain `EXPLAIN`, never `EXPLAIN ANALYZE`.** A plan is not a measurement; a plan is what tells you
  whether an index path exists at all. Every cost quoted from a plan is labelled as the planner's
  *estimate*.
- **The cluster horizon is not ours.** `pg_snapshot_xmin` is per *cluster*, and the other spike's
  write transactions move it. Every close in this spike is preceded by a poll — *wait until
  everything we have written is below the horizon* — because a close taken under a pinned horizon
  stores a checkpoint of **nothing**, and the first run of `run-cursor-arms.sh` measured exactly
  that. The poll is a correctness precondition, not a timing device.

## The book

Built by `build-book.sh`. **Every write except the close goes through the compiled binary over
HTTP** (`openledger serve`, `POST /v1/transactions`), because pending → posted, the void, and the
server-derived reversal mirror are *writer* semantics and re-implementing them in a SQL fixture
would be testing the fixture. The close is the one operation the wire cannot express — there is no
`kind` in `TransactionBody` and `fk_closes__txn_kind` demands `kind = 'period_close'` — so it stays
SQL, exactly as spike 020 left it (`sql/00_helpers.sql`, `spike_close` / `spike_close_mode`).

Two tenants, two currencies, four monthly periods, and one of every case that can make the two forms
of the same statement disagree:

| | |
| --- | --- |
| `bk` | the closed book: USD closed through **2026-03**, EUR closed only through **2026-01**, 2026-04 left open |
| `nc` | the *same* postings and **no close at all**. The "no closes" arm cannot be a phase of `bk`: once `bk` is closed its pre-close state is not reachable again |

The postings, in commit order, per tenant per currency:

| label | what it is | why it is here |
| --- | --- | --- |
| A1 | capital, effective 2026-01-05 | an equity position to make the balance sheet foot |
| A2 | revenue, 2026-01-10 | a temporary account the close will sweep |
| A3 | expense, 2026-01-12 | the other sign of temporary account, and C4's reversal target |
| A4 | **pending**, 2026-01-15 | a hold that is never resolved — excluded from both forms forever, because status never mutates (ADR-0016) |
| A5 | **pending**, 2026-01-16 | C2's resolution target |
| A6 | **pending**, 2026-01-17 | C3's void target |
| — | **cursor P0 captured here**, before any close exists | the reproducibility case: an issued report re-run after the book has moved |
| — | close `bk/2026-01` in **USD and EUR** | |
| C1 | revenue, 2026-02-10 | ordinary tail-A traffic |
| C2 | **resolution** of A5, effective **2026-01-20** | pending → posted as a NEW transaction, *backdated into a closed period* — tail B |
| C3 | **void** of A6 | a posted, zero-entry marker. Contributes nothing to either form; the question is whether it contributes nothing to *both* |
| C4 | **reversal** of A3, a posted target | the mirror is derived server-side and takes the target's own `effective_at`, so it too lands in closed January — tail B |
| — | **cursor P1 captured here** | |
| — | close `bk/2026-02` in **USD only** | so the two currencies have different boundaries and a per-*tenant* boundary is wrong |
| E1 | revenue, 2026-03-05 | |
| E2 | ordinary posting effective **2026-01-10**, arriving after **two** closes | tail B against two different close cursors |
| — | close `bk/2026-03` in USD | |
| G1 | revenue, 2026-04-10 | the open period — tail A with no close above it |
| G2 | posting effective **2026-02-05**, after all three closes | tail B into the middle period |
| G3 | expense, 2026-04-12 | |
| — | **cursor P2 captured here** | |

Result: 24 posted and 6 pending ordinary transactions per tenant, 4 closing transactions, 18
`close_disclosures` rows, **ten reconciliation checks at zero breaks** (`out/gate.txt`,
`out/book.txt`).

**Non-perimeter account types only.** `operating_cash` and `fbo_cash` are `is_perimeter`, so
`chart_lint.perimeter_unattested` fires for them on every book until the attestation feed exists
(unowned, roadmap M7) — which would leave one of the ten checks permanently non-zero and destroy the
gate. The asset side is therefore `customer_receivable`. Same substitution spike 022 made, recorded
for the same reason. `due_from_treasury` / `due_to_tenants` are avoided too: they are the chart's one
mirror pair, so `recon_scope_breaks` only has a population if they are used.

## The experiments

### A · The three arms of `computed_at_xid` — `run-cursor-arms.sh`

Added after an adversarial audit found that the three predicates bounding `computed_at_xid` cannot
all mean what the schema says. The same close under the three values a one-transaction close can
bind, each run twice — once with the horizon caught up, once with an **older writer holding an
uncommitted posting across the close and committing after it**, which is the interleaving
ADR-0011 §1 built the entire cursor argument on. Six cells, each reporting: `computed_at_xid`
against the closing transaction's own `xact_id`; whether the stored checkpoint is the **at-close**
position (temporary accounts at exactly 0, a `retained_earnings` row present); `recon_close_breaks`;
`recon_checkpoint_breaks`; and whether a checkpoint-plus-tails **reader** agrees with the
from-inception aggregate account by account.

The concurrent writer posts through `pic → recv_1` rather than through a temporary account on
purpose: the close upserts the balance-cache row of every account it sweeps, so a holder sitting on
`fee_revenue`'s row makes the close **block** instead of proceeding. Measured, and an operational
note rather than the experiment.

### B · The differential — `sql/20_candidates.sql`, `sql/25_candidates_identity.sql`, `sql/30_agreement.sql`

The candidate bodies are installed *beside* the shipped ones under `_ckpt` names, so both forms run
on the same book in the same snapshot. `bs_disagreements` and `tb_disagreements` are **FULL JOIN**s,
not subtractions: a line present in one form and absent from the other is a disagreement, and
`WHERE a - b <> 0` cannot see it.

The grid is 2 tenants × 3 cursors (P0, P1, P2) × 10 as-of instants = **60 balance-sheet points**,
and the trial balance adds 9 windows per cell. The instants are chosen to include *before
everything*, *mid-period*, *exactly on each of the three close boundaries*, *mid the unclosed
period*, *past every entry*, and **`infinity`** — the value `recon_equation_breaks` passes.

Run twice: once on the `xmin_strict` book (the close as spike 020 implements it) and once on the
`identity` book (the close as this spike proposes it), with the reader matched to each.

### C · The bounded reconciliation — `sql/50_bounded_recon.sql`, `55_drift_classes.sql`, `56_span_is_load_bearing.sql`

The bounded form assigns each entry the index of the **first close whose checkpoint contains it** —
one `width_bucket` binary search per axis, one pass over `ledger_entries` — and compares the
*difference* of consecutive stored levels against the sum of the entries assigned to that index,
plus a **presence** check over the stored rows alone.

Five drift cells, each mutating the checkpoint inside a transaction and rolling back: the clean-book
negative control, a value forged by one minor unit, a spurious row, a missing row at a *middle*
close where the account moved, and — the adversarial one — a missing **trailing** row for an account
that did *not* move in that period, which is the case a pure difference comparison cannot see.
`56_span_is_load_bearing.sql` builds the bounded form *without* its presence half and re-runs that
one cell, so "the guard matters" is a measurement rather than a claim.

### D · Out-of-order closes — `run-out-of-order.sh`

February closed *after* March, which nothing in the schema forbids. Reports whether the shipped
sweep calls it legal, whether the bounded form goes wrong on it, whether `close_disclosures`' wide
carve-out stops being dead, and whether the *reader* still agrees.

### E · The adversarial cells — `run-adversary.sh`, `sql/60_adversary.sql`

Three, all rolled back: `recon_cursor_breaks` against an honest committed entry under an older open
transaction (run from a **read-only** session holding no xid of its own, because an earlier version
of this cell posted inside the measuring transaction and flagged its own uncommitted rows);
`computed_at_xid` forged to 2^62 and to 1; and the grant surface of `computed_at_xid` against
`ledger_entries.xact_id`.

### F · The empty close — `run-empty-close.sh`

Found by the correctness gate while building the partitioning book, and kept because it is a defect
in its own right. A period in which no revenue or expense moved.

### G · Partitioning — `run-partitioning.sh`, `sql/70_partition_ddl.sql`, `75`, `76`

The candidate DDL applied by hand in a scratch database, then: the partition key and bounds from the
catalog; both foreign keys tested against a real violation *through the parent*; the three RLS
policies tested with a scoped reader, an unscoped reader and a partition addressed directly; the
grants tested by inserting through the parent as `openledger_app` and by attempting
`UPDATE`/`DELETE`/`TRUNCATE`; the append-only and event-trigger perimeter; the reconciliation gate
after the change; what the schema-snapshot dump would and would not show; and one
`ALTER TABLE … DETACH PARTITION`.

### H · Plans — `run-plans.sh`, `sql/80_bulk_seed.sql`, `sql/85_plans.sql`

A larger book — 203 accounts, 30,024 entries, 12 monthly closes, 2,424 checkpoint rows — seeded in
bulk under `session_replication_role = replica` (the append-only and event triggers are
`ENABLE ALWAYS` and still fire), gated on `reconciliation` at ten zeros both before and after the
twelve closes. Then **plain `EXPLAIN` only** for: each tail tenant-wide, with and without
`enable_seqscan`; the single-account form ADR-0011 §3 actually measured; the same tails after
creating the two candidate indexes; the index sizes; and both reconciliation forms.

### I · The acceptance run — `sql/90_reference_bodies.sql`, `91_grid.sql`, `95_verify_proposal.sql`

`PROPOSAL.sql` applied **in one transaction** to a fresh identity-mode book, and then the differential
re-run the other way round: the shipped names carry the checkpoint form, and the baseline's own
bodies — extracted verbatim from `migrations/00001_baseline.sql` and renamed `_ref` — carry the
from-inception form. This is the only run that tests the migration as it would actually land,
including its internal ordering.

## What this spike deliberately does not do

- **No timing.** `MEASUREMENT-PLAN.md` specifies the pass that has not been run.
- **No migration.** Nothing under `migrations/`, `crates/`, `schema/` or `site/content/` is touched.
  `PROPOSAL.sql` is the migration-ready text for a human to turn into `00004`.
- **No harness crate.** Every experiment is `psql` plus bash, which is the simplest thing that
  produces the evidence.
