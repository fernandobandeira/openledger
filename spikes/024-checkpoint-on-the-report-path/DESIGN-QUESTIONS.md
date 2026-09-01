# The questions this spike has to settle

Written **before** the answers, and kept beside the evidence for the reason spike 022 keeps its
own: the questions are what the ADR has to answer, and a document that quietly acquires the
answers it was shaped by teaches nobody what was actually in doubt.

Three known-open items, all three *proven to exist* by [spike 020](../020-close-cost-at-scale/)
and none of them designed. Each question below names the decision it blocks and the evidence that
would settle it — and says up front whether that evidence is a correctness experiment (runnable
now) or a number (**not** runnable now: another spike holds this machine, and this project's own
banner says two harnesses on one database invalidate everything).

---

## Item 1 · The statements never read the checkpoint

Spike 020 proved the negative from `pg_get_functiondef`: `balance_sheet_at`,
`income_statement_for` and `trial_balance_at` never name `ledger_period_balances`. ADR-0011 §3
specifies the read that would — "checkpoint + two tails" — and measured it at 45–49× at a close
boundary on one account, ~40–230× at scale. Nothing takes it.

### Q1.1 — Which of the three functions can take the treatment at all?

**Blocks:** the shape of migration 00004's function bodies, and how much of ADR-0011 §3's claim
survives contact with the shipped signatures.

The three signatures are not the same kind of object:

| | signature | kind |
| --- | --- | --- |
| `trial_balance_at` | `(tenant, from, to, cursor)` | a **flow** over a half-open range — per-account gross debits and credits |
| `income_statement_for` | `(tenant, from, to, cursor, chart_version)` | a **flow**, explicitly (ADR-0011 §4: "a **flow**, so a half-open range") |
| `balance_sheet_at` | `(tenant, as_of, cursor, chart_version)` | a **position** — one instant (ADR-0011 §4: "a **position**, so one instant") |

A cumulative checkpoint is a *position*. Only `balance_sheet_at` asks for one. For the two flows
the checkpoint can only enter as a **difference of two positions**, prefix(to) − prefix(from),
which is a different query with a different cost. So the question is not "wire the checkpoint into
the three functions"; it is which of the three the arithmetic even admits.

And a sharper sub-question for the income statement specifically: **the accounts it reports are
exactly the accounts the close zeroes.** ADR-0011 §2: what closes is revenue and expense, into
`retained_earnings`; §3 (A4): the checkpoint is the **at-close** position, closing entries
*included*, so a temporary account's checkpoint row is *exactly 0*. If that is right, the
checkpoint stores nothing but zeros for every line the income statement prints, and the flow can
only be recovered by adding back the closing entries the statement is specified to exclude
(`NOT EXISTS` against `ledger_period_closes`). Settle it by reading the shipped body and by
measuring the stored rows on a closed book.

**Evidence that settles it:** the function bodies (already read), plus a book with several closes
where the checkpoint rows for revenue and expense accounts are dumped directly. Correctness work,
runnable now.

### Q1.2 — Is "they scan `ledger_entries` from inception" true of all three?

**Blocks:** whether ADR-0011 §3's and the roadmap's M5 sentence need withdrawing or only
narrowing.

Both documents say it of all three. But `trial_balance_at` and `income_statement_for` carry
`effective_at >= p_from` — they are bounded *below* by a caller-supplied instant, so their cost is
O(entries in the window) and there is no from-inception scan to remove. Only `balance_sheet_at`
(and its earnings plug, and its A14 guard) has no lower bound. If that reading holds, the claim as
written is true of one function out of three and the other two are mislabelled — which changes
what M5 is actually for.

**Evidence:** the bodies, and `EXPLAIN` on each showing what the range predicate does to the scan.
Runnable now (plan shape, not timing).

### Q1.3 — What exactly are the two tails, and does the tenant-wide statement have an index for them?

**Blocks:** whether migration 00004 needs new indexes on `ledger_entries`, which is a
write-path cost and therefore not free.

ADR-0011 §3 names the tails and cites a plan: `Index Scan using ix_entries__asof_commit`,
`Index Cond: … xact_id >= … AND xact_id < pg_snapshot_xmin(…)`. That measurement was **one
account** — 400,000 entries on one account. The statement functions aggregate over **every account
of a tenant**. Both existing indexes put `account_id` in second position:

```
ix_entries__asof_commit  (tenant_id, account_id, xact_id)
ix_entries__effective    (tenant_id, account_id, effective_at, xact_id)
```

A tenant-wide range on `effective_at` or on `xact_id` does not have a leading-column path through
either. So either PostgreSQL 18's btree skip scan rescues it over a high-cardinality
`account_id`, or the rewritten bodies want `(tenant_id, effective_at, xact_id)` and
`(tenant_id, xact_id, effective_at)` — two new indexes on the hot write table, which ADR-0013 does
not get to wave through.

**Evidence:** `EXPLAIN` of each tail on a real book, and the index list. Plan shape now; whether
the index is *worth* its write cost is a number, and goes in the measurement plan.

### Q1.4 — Does the rewritten form agree with the from-inception form, to the minor unit, on a book that contains everything?

**Blocks:** everything. A faster wrong answer is not an optimization.

The book has to contain, at minimum: no closes at all; one close; several closes; a posting
backdated into an already-closed period; a pending transaction; a resolution; a reversal of a
posted transaction; a voided pending; more than one currency; and an as-of instant that falls
*exactly* on a close boundary as well as one mid-period. Every one of those is a way the two forms
could differ:

- **pending** — the checkpoint is posted-only, and so is the aggregate. But status never mutates
  (ADR-0016), so a transaction pending at close time is pending forever. If that holds, the two
  forms cannot disagree here; if it does not, the checkpoint is unsound and the whole item dies.
- **resolution** — a *new* posted transaction with its own `xact_id`, effective wherever the caller
  said. If it is effective below a close boundary and committed above the close cursor, it is tail
  B, which is the case the tail exists for.
- **reversal of a posted transaction** — a mirror with flipped directions and (by the soft
  convention) the *target's* `effective_at`, so a reversal of a pre-close posting is *also* tail B.
- **the void** — a posted, zero-entry marker. It contributes nothing to either form. The question
  is whether it contributes nothing to *both*.
- **multiple currencies** — the close is per `(tenant, currency)`, so "the latest close at or
  before the as-of point" must be chosen per currency. A form that picks one boundary for the whole
  tenant is wrong the moment USD is closed through March and EUR only through January.
- **on the boundary** — `ends_at = p_asof` must make tail A empty and the checkpoint exact, which
  is only true because both bounds are half-open. Off by one microsecond either way is a wrong
  balance sheet.

**Evidence:** a differential harness — both forms, every as-of point, every currency, compared to
the minor unit, on a book that reconciles at ten zeros first. Correctness work, runnable now, and
the core of this spike.

### Q1.5 — What does the rewritten read path now *depend* on that today's does not?

**Blocks:** an honest cost line in the ADR, and possibly a change to the sweep.

Today's statements depend on `ledger_entries` and nothing else. The rewritten ones depend on
`ledger_period_balances` being **complete** — one row per account that had posted entries below
the boundary. A close that skipped an account produces a *silently low* balance sheet, where today
it could not. `recon_checkpoint_breaks` is the only thing standing between that and a wrong
statement, and it deliberately treats a missing row with zero recomputed values as clean (A11).
So: is a missing row with *non-zero* values caught, and is that enough?

**Evidence:** delete a checkpoint row for an account with a real position and see whether the
sweep reports it and whether the rewritten statement goes wrong. Runnable now, and it is an
adversarial test rather than a happy-path one.

### Q1.6 — Does the A14 guard get the same treatment, or does it defeat the whole exercise?

**Blocks:** whether the rewrite is worth doing at all.

`balance_sheet_at` is `plpgsql` for two reasons, and the second — A14, "refuse a chart version
that does not present every account type with posted entries as at this instant" — runs its own
`EXISTS` over `ledger_entries` **with no lower bound**. Wiring the checkpoint into the aggregate
and leaving the guard scanning from inception leaves the function exactly as slow as it was. So the
guard needs an equivalent form over checkpoint-plus-tails, and the equivalence has to be argued:
`ck_entries__amount_positive` says `amount_minor > 0`, so an account with any posted entry below
the boundary has `input + output > 0` in its checkpoint row — which is what makes "had entries"
answerable from the checkpoint at all.

**Evidence:** the constraint, plus a negative control — an account type with posted entries and no
`chart_presentation` row must still raise under the rewritten guard.

---

## Item 2 · `recon_checkpoint_breaks` is O(entries × closes)

Measured: 1 : 3.2 : 5.8 : 8.2 over 3 / 6 / 9 / 12 closes. The mechanism is in the view — it joins
each close to *every* entry with `effective_at < that close's ends_at`, so close *k* re-aggregates
the whole prefix up to period *k*.

### Q2.1 — Is there a bounded form that compares something real?

**Blocks:** whether M5 can bound the sweep or has to accept its cost.

ADR-0010's standard is explicit and it is the constraint on any answer here: *"A reconciliation is
a statement with its reconciling items named, not a subtraction"*, and *"a check that returns
nothing because it was never run is indistinguishable from one that passed"* — the TRUNCATE scar.
That rules out the obvious cheap answer, which is to check only the closes that have changed since
last time: a watermarked check that skips closes is exactly the failure mode the summary view
exists to prevent.

The candidate this spike will design instead: the checkpoint is **cumulative** (the recompute has
no lower bound on `effective_at`), so consecutive checkpoints differ by exactly one period's own
arrivals, and the *difference* of two stored levels can be compared against the *difference* of the
two recomputed sets. If each entry then falls into at most a bounded number of per-close bands, the
whole check is one pass over `ledger_entries` instead of C passes.

### Q2.2 — Does the bounded form need an invariant the schema does not state?

**Blocks:** whether Q2.1's answer is sound, or sound-looking.

The delta argument assumes the closes of a `(tenant, currency)` are **monotone on both axes** —
that ordering them by `ends_at` also orders them by `computed_at_xid`. Nothing in the schema says
so. `pk_closes` is `(tenant_id, period_code, currency)`; nothing stops February being closed
*after* March, and if it is, February's cursor is *higher* than March's, the level sets stop
nesting, and the delta is not a difference of nested sets. The level-comparison form does not care;
the delta form does.

If that is right, the bounded form ships **with the check that states the invariant**, and the
coverage argument becomes: order-break ⟹ reported as its own break class; order clean ⟹ delta
agreement is provably equivalent to level agreement.

**Evidence:** construct an out-of-order close in a scratch database and see whether it is legal,
whether the delta form goes wrong on it, and whether an order check catches it. Runnable now.

### Q2.3 — Does the bounded form catch every drift class the current one catches?

**Blocks:** shipping it at all. *A cheaper check that misses a drift class is a regression, not an
optimization.*

The current view names three reasons: `missing_row`, `spurious_row`, `value_drift`. Each has to be
reproduced against the bounded form: forge a checkpoint value, insert a spurious row, delete a real
one, and confirm the bounded form still breaks — and confirm the clean-book negative control still
reports zero, because a check that never fires is the failure ADR-0010 opens with.

There is also a coverage question in the *other* direction: the delta form compares one more thing
than the level form (each close's *own* period arrivals rather than its cumulative prefix), so a
single forged row should surface as **two** breaks. That is more sensitive, not less — but it
changes the row count an operator sees, which is part of the interface.

**Evidence:** each drift class injected by hand, both views run side by side, both outputs
captured. Runnable now.

### Q2.4 — Is the bounded form actually cheaper?

**Blocks:** nothing about correctness, and it is the one question here that needs a number.
Asymptotically O(entries + closes) beats O(entries × closes); the constant is a different matter,
and the band-assignment join may itself be O(entries × closes) in comparisons even when it is one
pass in I/O. **Not measurable in this phase.** It goes in `MEASUREMENT-PLAN.md` with the exact
ladder — 3 / 6 / 9 / 12 closes, the same shape spike 020 used, so the growth curves are directly
comparable.

---

## Item 3 · Partitioning `ledger_period_balances` by period

Spike 020's finding: closing 1,000,000 accounts took ~49 s and wrote 1,000,003 rows / 135 MB, and
**~96% of that is the checkpoint write** — one row per account plus primary-key and foreign-key
maintenance — against ~4% aggregation. Its verdict: what it wants "before anything else" is
partitioning `ledger_period_balances` by period.

### Q3.1 — What is the partitioning key, and does it survive the tenant-leading primary key?

**Blocks:** the DDL.

Every table in this schema carries `(tenant_id, …)` as its primary key by decision (M1: "the one
irreversible decision on the list, and it was free"). A partition key must be a subset of every
unique constraint on the table, and `pk_period_balances` is
`(tenant_id, period_code, currency, account_id)` — so `period_code` is legal as a key, and so is
`(tenant_id, period_code)`. Which one, and what does each buy? `LIST (period_code)` gives
`DETACH`-a-period and an empty index per close; `HASH (period_code)` gives N smaller trees and no
partition management at all. They are not the same proposal and spike 020's measurement does not
by itself pick between them.

And a cost the roadmap does not mention: `period_code` is a **tenant-supplied free-text label**
(`'2026-02'`, `'FY2026Q1'` — the baseline's own comment says "a label, not a key of time"). Under
`LIST`, the partition set is the union of every tenant's code vocabulary, and a tenant inventing a
new code needs a partition to exist before the close can write into it. The close is an ordinary
posting by the **app role**, which has no DDL privilege at all.

### Q3.2 — Do the two foreign keys, the three RLS policies and the grants survive?

**Blocks:** the DDL, and whether the ADR-0013 read-path control survives a change made for write
throughput.

Four specific things to verify, not reason about:

- `fk_period_balances__close` and `fk_period_balances__account` are both *outgoing* FKs from the
  table being partitioned. Supported since PostgreSQL 12 — verify, on this server, carrying the
  composite columns they actually carry.
- `rls_period_balances__tenant` / `__writer` / `__recon`. Policies on a partitioned parent apply to
  parent-routed queries; a partition accessed **directly** carries only its own policies, and it
  has none. So the question is not "do they survive" but "what is now reachable that was not" —
  and whether a scoped `openledger_read` session is still scoped.
- the grants: `GRANT SELECT, INSERT ON ledger_period_balances TO openledger_app`, `SELECT` to
  `openledger_read` and `openledger_recon`, and the belt-and-braces
  `REVOKE UPDATE, DELETE, TRUNCATE … FROM openledger_app`. Privileges are checked on the relation
  named in the query, so parent-routed DML should need nothing on the partitions — verify, including
  the REVOKE.
- the append-only perimeter: `ledger_period_balances` is deliberately *not* in the append-only
  trigger set and *not* in `refuse_journal_ddl`'s `protected` array (checked). So the event triggers
  should permit this. The contrast is worth recording, because `ck_journal__no_inherit` is a **state
  assertion over `pg_inherits`** — which means partitioning any *protected* table is refused, and the
  roadmap's "Partitioning by tenant … Legal on the shipped schema" line is about tables that are.

### Q3.3 — Would the schema-snapshot test show it as expected drift, and is what it shows enough?

**Blocks:** whether migration 00004 also has to widen the snapshot's charge.

The dump's `relations` section selects `relkind IN ('r','p','v','m','S')`, so the parent flips
`r` → `p` and every partition appears as a new `r` line: expected drift, visible, fine. The
question is what it *cannot* see. `pg_inherits`, `pg_class.relpartbound`,
`pg_class.relispartition` and `pg_partitioned_table` appear in none of the nineteen sections. If
that holds, then a partition attached with the wrong bound, a partition detached, or the partition
key itself changed are all invisible to the one test ADR-0009 names as the only backstop for the
owner-accident DDL class — and `ALTER TABLE … DETACH PARTITION` is one statement that silently
removes rows from every report that reads the checkpoint.

### Q3.4 — What does the migration actually have to do?

**Blocks:** the shape of migration 00004, and how it is deployed.

There is **no in-place `ALTER TABLE` conversion** to a partitioned table — the roadmap already
says so for tenant partitioning. So the migration creates a new partitioned table, moves the rows,
and swaps names. Two things make that more than a rename here: `recon_checkpoint_breaks` reads the
table and `reconciliation` reads that view, so both must be dropped and recreated with their
grants; and ADR-0003's freeze (`scripts/check-migrations-immutable.sh`, no opt-out) means every
line of it is a **new numbered migration — 00004**, never an edit to the baseline.

There is also a cheaper option available *only* because of what this table is: it is derived and
exactly recomputable at each close's own `computed_at_xid`, which is the whole argument of ADR-0011
§3. So "rebuild by recomputation" is a legal migration strategy where it would not be for a journal
table. Whether it is the *better* one is a question about how long the rebuild takes on a large
book — a number, deferred.

### Q3.5 — How much does partitioning by period actually save on the close?

**Blocks:** whether item 3 is worth its cost at all — and it is a **number**, so this spike does
not answer it.

The mechanism to test is specific, and stating it is this phase's job: partitioning by period does
not reduce the number of rows written or the number of index entries maintained. What it changes is
*which* index they go into — one fresh, empty, sequentially-filled per-partition primary key per
close, instead of appending into a shared tree that has grown with every period before it. If that
is where the ~96% goes, the saving grows with the number of periods already closed and is ~0 on the
first close. **That prediction is exactly what the timing pass has to falsify**, and a design that
cannot say what would falsify it is not a design.
