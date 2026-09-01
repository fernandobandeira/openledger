# Spike 022 — the harness specification

**The question.** On the *shipped* schema and the *shipped* writer's statement, what should the
stripe-selection key be, and does cross-request batching compose with it?

Spike 003 answered both, but on a bench schema (`spikes/003-throughput-ceiling/bench_schema.sql`)
driven by a Go harness calling a per-leg `post_entry()` function over six round trips. The shipped
writer is a single-call CTE pipeline (`crates/ledger/postgres/src/repository.rs`,
`CLAIM_AND_APPEND`) with in-request coalescing and three round trips. **This binary's own
throughput has never been measured** (roadmap, M3). Everything below runs against
`migrations/00001_baseline.sql` + `00002` + `00003` applied by the compiled `openledger migrate`,
plus `schema/chart.sql`.

Three specific claims are up for confirmation or refutation:

1. **Spike 004's refinement — "the affinity key should be the tenant, not the worker" — may be
   obsolete and may be wrong.** Obsolete because its stated reason was that a business key survives
   a restart and needs no sweep process, and ADR-0013 §4 removed the sweep entirely by placing the
   stripe below the account. Possibly wrong because spike 003's own whale finding predicts that a
   tenant-keyed stripe maps a dominant tenant onto **one** row of the shared house account — which
   is exactly the 1.07× collapse that killed per-tenant house accounts.
2. **Spike 003's "batching and random striping cancel."** Its mechanism is that a batch of 25 lands
   on ~25 different stripes, so there is nothing left to coalesce. If the stripe is chosen per
   *batch* rather than per *posting*, the cancellation cannot occur by construction. Measure it.
3. **Cross-request batching needs per-member failure isolation.** Today a refusal is diagnosed
   after the statement and answered by rolling back the whole database transaction. In a batch that
   destroys every innocent member. Section D measures the proposed in-statement admissibility gate
   against the batch-abort-and-retry-singly fallback.

---

## Ground rules, taken from spike 003's own methodology caveats

- **Record the machine's load with every number.** Spike 003's banner exists because it did not:
  the same configuration measured 833 and 482 clearings/s at loadavg ~1.5 and ~6.3, and the
  *ratios* moved ~30% too. Every result row carries the 1-minute loadavg at the start and end of
  the run.
- **One harness, one database, one measurement at a time.** Spike 003: "Two harnesses on one
  database invalidate everything." The runner is strictly sequential and never overlaps runs.
- **Report ranges, not single runs.** Every configuration runs three repetitions; report the
  median and the spread.
- **Gate every configuration on correctness.** After each run: `SELECT * FROM reconciliation` must
  report ten checks at zero breaks. A throughput number from a book that does not reconcile is not
  a number.

## The workload

Spike 003's clearing — one account that spreads, two that contend — **expressed as this writer can
actually express it**:

```
Posting(source = interchange_revenue, destination = customer_receivable,   9)
Posting(source = fee_revenue,         destination = customer_receivable, 491)
```

**Correction, and it matters for every absolute number.** An earlier version of this section wrote
the workload as spike 003's three legs — `DR customer_receivable 500 / CR interchange_revenue 9 /
CR fee_revenue 491` — and the first harness hand-built exactly that. **The shipped API cannot
express three legs.** `expand_postings` (`crates/ledger/src/postings.rs`) emits exactly two legs per
`source → destination` posting, so a leg count is always **even**. Spike 003's clearing is therefore
**2 postings and 4 legs coalescing to 3 deltas**, with `customer_receivable` taking two debit legs
and consuming two `account_seq` values per clearing.

Two consequences. The harness's original clearing wrote **3 entry rows where the shipped writer
writes 4** — spike 003's own confounded-comparison error reproduced, where an arm looked faster
partly because it did less work. And because both legs on the receivable coalesce into one delta,
the three-leg version left **every walk-back offset at zero**: `offsets_back_from_last_seq`, which
ADR-0013 specifies and `postings.rs` unit-tests in isolation, was never exercised against a database
until this correction landed. Fixing the workload dropped V0 from 778.7 to **~671 clearings/s**,
which is the honest baseline.

Comparability with spike 003 is therefore of *shape*, not of unit: same contention structure, one
more entry row per clearing, and a real SHA-256 and payload rendering per post that spike 003's Go
harness never did.

**Substitution, and why.** Spike 003's hot account was `network_settlement_payable`. That type is
`is_perimeter = true`, so `chart_lint.perimeter_unattested` fires for it on every book until the
attestation feed exists (unowned, roadmap M7) — which would put one of the ten reconciliation
checks permanently non-zero and destroy the correctness gate above. `fee_revenue` is a non-perimeter
house type with the same shape: one shared row every clearing must update. The account *type* has
no bearing on write throughput — same table, same constraints, same lock — and the substitution is
recorded here so nobody reads the numbers as `network_settlement_payable`'s.

The two-leg fixture the e2e suite uses is deliberately not reused: **two accounts cannot produce a
deadlock at all** (the planner emits the legs in account order for free — roadmap M2), and section E
exists to produce one.

## The variants

### Stripe selection

Four modes. All four compute the stripe **inside the statement** from `ledger_accounts.stripe_count`,
so selection costs no extra round trip and the writer stays at three:

| mode | expression | what it models |
| --- | --- | --- |
| `none` | `0` | today's writer — the literal it binds now |
| `random` | `(floor(random() * a.stripe_count))::smallint` | spike 003's random selection, the one that cancels |
| `tenant` | `(abs(hashtext($1)) % a.stripe_count)::smallint` | spike 004's refinement |
| `worker` | `($affinity::int % a.stripe_count)::smallint` | spike 003's affinity striping, keyed on the connection |

**The stripe must be materialized in its own CTE before it is used.** `random()` is `VOLATILE`, so
an expression repeated in both the `SELECT` list and the `ORDER BY` may evaluate to two different
values — a row inserted at one stripe and sorted as another, which silently breaks the lock
ordering. Compute it once:

```sql
striped AS (
    SELECT d.account_id, d.currency, d.input, d.output, d.legs,
           a.owner_type, a.owner_id_key, a.purpose, a.category, a.normal_balance,
           <STRIPE_EXPR> AS stripe
    FROM delta d
    JOIN ledger_accounts a
      ON a.tenant_id = $1 AND a.id = d.account_id AND a.currency = d.currency
),
balance AS (
    INSERT INTO ledger_account_balances
           (tenant_id, account_id, currency, stripe, owner_type, owner_id_key,
            purpose, category, normal_balance, input, output, last_seq)
    SELECT $1, s.account_id, s.currency, s.stripe, s.owner_type, s.owner_id_key,
           s.purpose, s.category, s.normal_balance, s.input, s.output, s.legs
    FROM striped s
    ORDER BY s.account_id, s.currency, s.stripe          -- the lock order
    ON CONFLICT (tenant_id, account_id, currency, stripe) DO UPDATE
    SET input = ledger_account_balances.input + EXCLUDED.input,
        output = ledger_account_balances.output + EXCLUDED.output,
        last_seq = ledger_account_balances.last_seq + EXCLUDED.last_seq,
        updated_at = now()
    RETURNING account_id, currency, stripe, last_seq
)
```

`entry` then takes its `stripe` column from `balance`'s returned row rather than the literal `0`,
joining on `(account_id, currency)` as it does today. `fk_entries__stripe` is what makes a mismatch
here a refused write rather than silent drift.

#### Selection placement — a second axis, and the one that may matter more

**Where** the stripe is chosen relative to the coalesce is not a detail; under batching it decides
whether the antagonism can occur at all. The `striped` CTE above sits *after* `delta`, and that
placement gives one stripe per account per batch **even under `random`** — which would make section
B report a null result caused by this SQL rather than by the world. So both placements are built:

| placement | where | what it does to a batch |
| --- | --- | --- |
| `per-member` | stripe chosen at `member_delta` grain, **before** the cross-member coalesce, which then groups by `(account_id, currency, stripe)` | reproduces spike 003 faithfully: 25 members under `random` scatter across ~25 stripes with nothing left to coalesce. Under `worker`/`tenant` the expression is constant across the batch, so the grouping collapses back to one stripe per account on its own |
| `per-batch` | stripe chosen **after** the coalesce, as shown above | the whole batch lands on one stripe per account, whatever the mode |

Both are correct against the schema: gaplessness is per `(account, currency, stripe)`,
`recon_balance_breaks` groups at exactly that grain and tolerates a stripe appearing lazily
mid-history (its `FULL JOIN` is per stripe, so a fresh stripe's cache row and journal group agree at
`entry_count = max_seq = N`), and `fk_entries__stripe` holds either way.

**The hypothesis this tests matters more than the affinity key.** `per-batch` selection may remove
the batching/striping antagonism with **no affinity key at all**, because the batch is already the
coalescing unit. If it holds, the expected ranking is `worker` ≥ `random per-batch` ≫
`random per-member`, and ADR-0002's rule 3 — "batching and *randomly* chosen stripes cancel each
other" — turns out to be a statement about **when** the stripe is chosen, not about randomness.

**Correction: it matters far less than the affinity key, and the ranking's `≥` did the deciding.**
Measured, per-batch placement is worth **+7.6%** for `random` and nothing at all for `worker` — a
real effect and a small one. The affinity key is worth **4.31× against no striping**, and on the
whale workload the worker key beats the tenant key **2.8×**. The predicted ranking held exactly
(`worker` 2,020 ≥ `random per-batch` 1,964 ≫ `random per-member` 1,825), but the hypothesis this
section stated — that per-batch placement would *remove the need for* an affinity key — is
**refuted**: per-batch random still loses to worker with batching, and loses far more decisively
without it (2,503 against 2,687). Rule 3 is a statement about **which key**, and only marginally
about when. The key is what the answer turns on.

At B = 1 the two placements are identical by construction, which is the harness's own self-check.

### Batching

Batch size B ∈ {1, 10, 25, 100} members per statement, per database transaction. B = 1 is today's
writer and must reproduce it exactly.

The batched statement generalizes `CLAIM_AND_APPEND` with a **member ordinal**: the arrays gain a
member index, `claimed` inserts B events in one `INSERT … ON CONFLICT DO NOTHING`, and each
dependent CTE carries the ordinal. Two things change shape and they are the findings this section
exists to produce:

**1 · Admissibility becomes a per-member gate inside the statement.** A member naming an account
that does not exist must contribute *nothing* rather than poison the coalesced upsert that other
members share:

```sql
member_delta AS (
    SELECT ord, account_id, currency,
           coalesce(sum(amount_minor) FILTER (WHERE direction = 'debit'), 0)::bigint  AS input,
           coalesce(sum(amount_minor) FILTER (WHERE direction = 'credit'), 0)::bigint AS output,
           count(*) AS legs
    FROM member_leg GROUP BY ord, account_id, currency
),
admissible AS (
    SELECT md.ord
    FROM member_delta md
    LEFT JOIN ledger_accounts a
           ON a.tenant_id = $1 AND a.id = md.account_id AND a.currency = md.currency
    GROUP BY md.ord
    HAVING count(*) FILTER (WHERE a.id IS NULL) = 0
),
proceeding AS (      -- claimed its key AND admissible
    SELECT c.id AS event_id, m.ord
    FROM claimed c
    JOIN member m ON m.idempotency_key = c.idempotency_key
    JOIN admissible ad ON ad.ord = m.ord
),
delta AS (           -- coalesce ACROSS proceeding members
    SELECT md.account_id, md.currency,
           sum(md.input) AS input, sum(md.output) AS output, sum(md.legs) AS legs
    FROM member_delta md JOIN proceeding p ON p.ord = md.ord
    GROUP BY md.account_id, md.currency
)
```

**2 · The walk-back arithmetic moves from Rust into the statement.** `offsets_back_from_last_seq`
(`crates/ledger/src/postings.rs`) counts each leg's later siblings in Rust. Across a batch that is
no longer computable client-side: which members proceed is only known server-side, after the claim
and the admissibility gate, and a dropped member would leave holes in a Rust-computed offset. So
the batched path numbers with a window function over the proceeding legs:

```sql
count(*)     OVER (PARTITION BY account_id, currency)
- row_number() OVER (PARTITION BY account_id, currency ORDER BY ord, leg_ord)
```

This is exactly the shape `mirror_leg` already uses for the server-derived reversal, which is the
precedent. Measure whether it costs anything against the Rust-computed offsets at B = 1.

Partition it on `(tenant, account, currency, stripe)` — the counter's own grain, since `pk_balances`
carries the stripe. Note that `mirror_leg` partitions on `(account_id, currency)` alone and is sound
only because one transaction contributes to at most one stripe per account; per-member selection is
the first thing that could break that invariant, so it wants stating rather than inheriting.

**3 · The gate sits above the claim.** `admissible` depends only on `member_leg`/`member_delta`, so
it is available before `claimed` — and it has to be, because a member whose event row commits with
no transaction has its idempotency key permanently burned, and its retry is answered as a replay
with `transaction_id: null` rather than being refused afresh. Gating only the downstream CTEs
launders a refusal into an indistinguishable success. **None of the ten reconciliation checks reads
`ledger_events`**, so the oracle cannot see this: the harness asserts the transaction count against
the book directly instead.

#### What the batched path deliberately does not do

It hardcodes `'posted'::ledger_txn_status` and binds neither `resolves_id` nor `reverses_id`, so
**it cannot express a pending, resolving or reversing member at all** — where the shipped writer
takes all four kinds on one endpoint. This is a scope decision for ADR-0018 to make explicitly, not
a gap to discover later, and it has a consequence worth stating: the measured batching speedup is an
upper bound a real batched writer carrying the supersede gate and the mirror derivation cannot
reach.

---

## The measurements

### A · Selection × stripes, unbatched

`{none, random, tenant, worker}` × `stripe_count {1, 8, 64}` × concurrency `{8, 16, 32}`, B = 1.

Establishes this binary's own baseline — the number the roadmap says does not exist.

**Correction: there is no "7.7–9.2×" for this section to reach, and an earlier version of this
paragraph invented one.** It said the section would test "whether the stripe reaches the 7.7–9.2×
ADR-0013 measured on the bench." That inverts the ADR and changes its unit. ADR-0013's actual words:
*"Measured **on the shipped baseline plus the proposed columns**, sixteen writers on **one logical
account** with worker-affinity stripes: 1,066–1,359 **upserts/s** unstriped, 9,660–10,518 at 64
stripes — 7.7–9.2×. Spike 003 measured 7.8–8.0× **on a bench schema**; this is the same shape **on
the real one**."*

So 7.7–9.2× is the *non*-bench figure, and it is **upserts/s against one logical account** — not
clearings/s through a writer that also hashes a payload, claims a key, inserts an event, a
transaction and four entries, and touches a per-company account that was never contended. A
three-account clearing where one leg spreads cannot reach that ratio, by Amdahl alone. Reporting
"striping only delivered 4×, so ADR-0013 overstated it" would be an artifact of comparing
incommensurable units, and this section must not do it.

### B · The cancellation matrix

`{none, random, tenant, worker}` × `{per-member, per-batch}` × `stripe_count {1, 64}` ×
`B {1, 25}` at c = 32, plus `B {10, 100}` for the two modes that survive.

The core table. Spike 003's prediction, restated for this writer: `random × per-member × 64 × B=25`
is *worse* than either lever alone; `worker × 64 × B=25` is better than both. The new question is
whether `random × per-batch × 64 × B=25` also composes — which would move the finding from
"randomness cancels" to "choosing too early cancels".

**Correction: "`worker × 64 × B=25` is better than both" is false, and the prediction's frame was
wrong.** Measured, `worker × 64 × B=25` reaches **2,020** against `worker × 64 × B=1`'s **4,182** —
so it is not better than the striping lever alone, it is **less than half of it**. Nor is
`random × per-member × 64 × B=25` (1,825) worse than either lever alone in the way predicted; it is
worse than *no batching* (4,265 for `random × per-batch × 64 × B=1`) and better than *no striping*
(1,427). What both halves miss is that at this section's uniform 32-tenant workload **batching itself
is the loss**, in every mode and both placements: B=25 is 2–2.8× slower than B=1 across the whole
matrix. Striping under batching does still compose — 1.42× — so the cancellation does not reproduce;
it is simply that the batching axis this table varies is negative here, which the prediction assumed
it could not be. The mechanism that generalizes: batching trades lock count for lock hold time, and
pays only where members overlap.

### C · The whale

32 tenants, one generating 90% of traffic, at `stripe_count = 64`, c = 32, B ∈ {1, 25}, for
`tenant` and `worker` selection.

The claim under test: tenant-keyed selection collapses toward 1.0× under skew for the same reason
per-tenant house accounts did (spike 003: 948 → 936 at whale = 0.9), while worker-keyed selection
does not. This is the measurement that decides the affinity key.

### D · Failure isolation, and the two costs batching adds

1. **Poison pill.** A batch of 25 where one member names an account that does not exist. With the
   admissibility gate: 24 commit, 1 is refused by name, and the book reconciles. Without it
   (batch-abort-and-retry-singly): measure the cost of the abort plus 25 individual retries.
   Both paths must leave ten zeros.
2. **Head-of-line blocking.** Hold an uncommitted `ledger_events` claim on key K in a second
   session, then run a batch containing K. `INSERT … ON CONFLICT DO NOTHING` waits on the
   uncommitted index tuple, so the 24 innocent members — possibly of other tenants — wait with it.
   Measure the stall. This one is a cost to state, not a bug to fix: it is the price of one
   statement.

### E · Deadlocks, and making the `ORDER BY` load-bearing

The roadmap's standing complaint: "removing or inverting the statement's `ORDER BY` survives the
entire suite today." This section's deliverable is the configuration in which it *does not* — the
evidence M2's concurrency proof is built on. Report deadlocks per 1,000 statements as well as raw
counts, and suppress `clearings_per_s` entirely in any deadlocking configuration: a deadlock loses a
whole batch with no retry, and each victim waits out `deadlock_timeout`, so the rate there is
meaningless.

**Correction: "half the writers present their legs in reverse order" is not one hazard, it is
three — and on the batched path it is not expressible at all.** An earlier version of this section
specified a single `--reverse-half` flag. On the batched path that flag was **inert**: a caller's
leg order reaches SQL only as a per-leg ordinal feeding the *sequence numbering*, while the balance
insert's row order comes from an aggregate's group-key set, which is identical however the legs
arrived. The coalesce destroys member identity before the insert. Deadlocks measured under that flag
were real but were being credited to a mechanism that could not have caused them.

That fact is itself the finding, so the three arms are now distinguished, and every result line
carries which one it ran and whether it is a model:

| arm | mechanism | a model? |
| --- | --- | --- |
| `caller-legs`, single path | the real M2 hazard: two writers take the same rows in opposite order | no |
| `account-subsets`, batched path | concurrent batches draw different account subsets, so their aggregate output orders differ | no |
| `descending-model`, batched path | the statement itself is run with an explicit `DESC` — maximal adversity, manufactured | **yes** |

`--lock-order-hazard caller-legs` combined with `--batch > 1` is **refused**, with the reason stated
in the error: on the batched path a caller cannot influence lock order, and that is the finding
rather than a limitation to work around.

**Both order sources** (roadmap M2) still have to be covered: the planned path takes its delta order
from the bound arrays, the mirror path from a `GROUP BY` over the target's entries. The batched
statement carries no reversals (§F), so the mirror arm runs on the **single** path — otherwise half
of M2's deliverable stays untested, and it is the half whose order comes from a `GROUP BY`.

### F · Latency, at an offered rate the batches do not fill

Closed-loop measurement always fills its batches, so every figure in A–E is a **ceiling**. A batch
window is a *latency* knob, and A–E measure no latency at all.

Open-loop: fixed arrival rate with Poisson inter-arrivals, a real accumulator dispatching on
`--window-ms` **or** `--batch` members whichever comes first, reporting p50/p95/p99 end-to-end,
achieved rate, and the fill the window actually collected. Rates include **20 and 50 TPS** —
ADR-0002's own derived average and peak — and rates approaching the measured ceiling.

Why this section exists: at 50 TPS offered with B=25 and a 25 ms window, the smoke run measured a
true fill of **2.21**. Two members, not twenty-five. An ADR that sets a window default from A–E
alone would be sizing a latency knob with throughput data.

*(**Correction:** 2.21 is the smoke run's, and it is the figure the ADR quoted for a day. The
committed section F median at that cell is **2.26** — same conclusion, different number. Quote the
committed one; the smoke run's results file is not kept.)*

## Deliverables

- `harness/` — a self-contained Rust crate, **not** a workspace member (spike code is throwaway and
  its dependencies never leak into the root manifest — see the spikes index).
- `RUN.sh` — the sequential runner, one configuration at a time, loadavg recorded per run.
- `transcript.txt` — raw output, kept.
- `results-<run-uuid>.jsonl` — one line per configuration; `./RUN.sh reduce <file>` is the reducer
  that turns them into medians, spread and the per-pass drift check. **Two runs, not one:** the
  closed-loop matrix (227 configurations, four passes) and the open-loop dispatch ladder (75, three).

*(**Correction:** this list named a `NOTES.md` — "the findings, leading with the answer" — which was
never written. It has no home: the findings live in the site write-up below, which is the
deliverable this project ships, and a second copy in the spike directory would be a second thing to
keep true. The line is deleted rather than satisfied. The `results-*.jsonl` files, which the list
omitted and which are what every published figure is checked against, take its place.)*

The site write-up is `site/content/spikes/018-batching-and-stripe-selection.md`; the spike
directories carry their own numbering, and this is dir 022 / site 018.
