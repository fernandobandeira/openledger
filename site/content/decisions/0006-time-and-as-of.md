# 0006 — Two time axes, two mechanisms, and "as of" means a commit-ordered cursor

**Status:** accepted — but its as-of *mechanism* is refuted and replaced by [0011](/decisions/0011-period-close-and-report-axes) (the `xid8` cursor, below); the cursor is decided and in the schema, and roadmap M5 is **unblocked**.
**Evidence:** [spike 001](/spikes/001-formance),
[spike 003](/spikes/003-throughput-ceiling).

## The decision

**Every entry carries two dates, and they routinely disagree: when the thing happened, and when we
found out about it.** The business date it belongs to — a card network's clock, say, not our webhook's
— is its **effective** date (`effective_at`); the moment we learned of it and wrote it down is its
**recorded** date (`recorded_at`, ordered within an account by a counter, `account_seq`). An entry we
record today that is effective last week is **backdated**, and that is not an edge case: late card
clearings and chargebacks arrive out of order as a matter of routine.

**Because of that, "what is the balance now" and "what was the balance as of June 30" are different
questions, and a single stored running total can only answer one of them.** A **running balance** is a
total kept continuously up to date as entries land; but if an entry dated June arrives in August, a
total that was correct in recording order is now wrong for the question "as of June 30". So we keep both
dates explicitly rather than pick one.

**We store no running balance at all.** The **current** balance — the common case, "what is it right
now" — is a single cached number per account (`ledger_account_balances`, read by primary key). Any
**"as of" balance** — the balance as it stood at some past point — is *computed* on demand by adding up
the entries on whichever date axis the question asked about. And "as of" is pinned not to a wall-clock
time (which cannot reliably say which write landed first) but to a **commit-ordered cursor**: a marker
a report saves next to itself and re-runs against forever, so the same report always returns the same
answer. Why we keep no stored running total is in the evidence below.

**Two axes, two mechanisms — and no running balance serving either.**

| Question | Mechanism |
| --- | --- |
| Current balance (the hot path) | `ledger_account_balances` — a `SUM` over the account's **stripe** rows *(this read "one row per account, read by primary key". The primary key is `(tenant_id, account_id, currency, stripe)`, so a striped account holds several rows and a naive single-row read under-reports the balance — the same correction the roadmap applied to the card walkthrough and the database page, made live by [0018](/decisions/0018-batching-and-stripe-selection))* |
| Balance as *recorded* at instant T | aggregate filtered by the commit cursor `xact_id < :cursor`, on `ix_entries__asof_commit` — [0011](/decisions/0011-period-close-and-report-axes) proved `recorded_at` cannot order commits and re-pointed the index at `xact_id` |
| **Balance as of business date T** | **aggregate over `effective_at < T`**, denormalized onto `ledger_entries` so it is a single-table index scan, not a join *(this read `effective_at <= T`. The shipped `balance_sheet_at` filters `effective_at < p_asof`, half-open to match the period model — [0011](/decisions/0011-period-close-and-report-axes) §A3 — and `BETWEEN`'s inclusive form was measured dropping an entry effective at `…23:59:59.999999`. A caller who followed this row's old bound got the position at the **start** of its business date and silently lost a day at every period boundary, so `p_asof` takes a period's `ends_at`, never a business date)* |

**An as-of query names the column it filters, and a resource has one such column** — naming the axis on
the *parameter* is not enough. The cursor is `pg_snapshot_xmin(pg_current_snapshot())`, the lowest
transaction id still running (everything below it has finished and can never grow), read directly
against an `xact_id xid8` column on every journal row and filtered `xact_id < :cursor`. That mechanism
is [0011](/decisions/0011-period-close-and-report-axes)'s; the gap-free watermark this ADR first
specified for the cursor is refuted, and the deep-dive at the end of this ADR carries why.

## The evidence

Three entries into one account, the third one backdated — and a stored running balance already
disagrees with the truth for a date in the middle:

| account_seq | effective | amount | running balance |
| --- | --- | --- | --- |
| 1 | Jan 10 | +100 | 100 |
| 2 | Jan 30 | +50 | 150 |
| 3 | Jan 20 | +30 | **180** |

As of Jan 25 by running-balance lookup: **180**. The truth: **130**. The Jan 20 entry has a *higher*
sequence number than Jan 30's, so `ORDER BY account_seq DESC LIMIT 1` lands on a balance including Jan
30 — and every as-of balance anyone asks for ("as of June 30") is a business-date question.

**That last clause is the whole finding**, and it is why the column is gone rather than merely
restricted. Backfilling is not an edge case in this domain: a clearing carries the network's business
date, so entries arrive out of effective order as a matter of routine. A number that is only correct
on the axis nobody asks about is not a fast path, it is a trap with an index on it.

**This is why `balance_after` is gone.** An earlier version of the mechanism table stored
`balance_after`, a running balance on every entry; [spike 009](/spikes/009-where-the-balance-lives)
removed it, and the axis argument above is what killed it — a point-in-time answer on the recorded axis
answers a question nobody asks. Two independent reasons stand behind the removal:

- **Axis (the fundamental one).** The table above: a stored running balance is right only on the
  recorded axis, and every as-of question is effective-date, which backfills. This holds even for a
  single-stripe account, so it is what drops the column on its own.
- **Striping (the trigger, and a real independent reason).** Under [0002](/decisions/0002-scaling) an
  account is N stripes, each with its own `account_seq` counter, so a per-entry `balance_after` would be
  a **per-stripe partial** — not the account's balance, and incoherent as an account-level number.
  Striping is what first forced the question; the axis argument is the one that would drop the column
  even without it.

[Spike 009](/spikes/009-where-the-balance-lives) carries the prior art, the cost, and what replaces the
drift check — the per-account row already answers "now", and the recomputed sum over `ledger_entries`
gives the *independent* check a `balance_after` computed in the same transaction never could.

**Each read must be ordered by the axis it asks about.** A recorded-axis read written as
"current-balance lookup plus `recorded_at <= T`" plans on `account_seq` and filters — **~36,000 rows
removed by filter** against zero for the right one. That first motivated `ix_entries__asof_recorded`; [0011](/decisions/0011-period-close-and-report-axes) then proved `recorded_at` cannot order commits and re-pointed the index at the `xid8` cursor as `ix_entries__asof_commit`.

**The business date is copied onto the entry, and a key holds the copy honest — not the writer.**
The effective-axis aggregate is a single-table index scan only because `effective_at` is denormalised
from the transaction onto `ledger_entries`, and nothing held that copy to its source: a transaction
dated 2026-06-15 accepted a thousand entries dated 1999-01-01, which is the column every
business-date report in the system reads. `fk_entries__txn_effective` makes the copy part of a
composite foreign key onto `uq_txn__id_effective`, so an entry whose business date disagrees with its
transaction's is unwritable rather than merely wrong — the same trick as the currency copy in
`fk_entries__account`. It is the guard here that needs a test: dropping it loads cleanly, where
dropping the unique index it points at makes the schema fail to load outright. That test is
[0007](/decisions/0007-schema-conventions-and-chart)'s schema snapshot.

**Why not a second running balance on the effective axis?** A backdated insert `UPDATE`s every later
row for that account — unbounded write amplification on the one table whose value is immutability.
Spike 001 copied Formance's trigger pair verbatim, inserting N moves into one account in
effective-date order and fully backdated:

| moves | in insertion order | fully backdated |
| --- | --- | --- |
| 200 | — | 679 ms |
| 400 | — | 5,162 ms |
| 1,000 | **114 ms** | **84,342 ms** |

**740× on a thousand rows, and worse than quadratic** — 200→400 is 7.6×, 400→1,000 is 16× — because
each `UPDATE` rewrites a larger set until the HOT-update budget from `fillfactor = 80` runs out. That
fill factor is migration 10; 19, 20 and 28 repair data. Their own best point-in-time path ignores the
column: `/volumes?pit=` re-aggregates from `moves`, and only `/aggregate/balances?pit=` reads
`post_commit_effective_volumes`. **None of it argues against our running balance.** They kept **two**,
their comments separating them: `post_commit_volumes` (insertion axis) *"will never change"*;
`post_commit_effective_volumes` (effective axis) *"can be updated if a transaction is inserted in the
past"*. Only the **mutable** one cost anything: **a running balance on a mutable axis is bad**.

**`recorded_at` is not reproducible.** It is `now()` — *transaction start* time, not commit order:

| Transaction | starts | commits | writes `recorded_at` |
| --- | --- | --- | --- |
| A | T1 | **T3** | T1 |
| B | T2 (> T1) | T2.5 | T2 |

A report "as of T2.6" run at T2.7 sees B but not A, uncommitted; re-run at T4 it sees both.
**Different answer**, and time zones have nothing to do with *this* failure: it needs two concurrent
writers and
one slow transaction — a reporting run overlapping a batched posting run, an ordinary Tuesday.
**Reproduced** on ordinary INSERT grants — one recorded-axis report either side of one commit gave
revenue **110,000.00 then 160,000.00**, `balanced` both times, drift empty.

**The closest prior art has the same hole and knows it.** Formance's `transaction_date()` seeds
`statement_timestamp()` into a session temp table — intra-transaction consistency, nothing about
commit order. Their per-ledger sequence exists *"instead of a sequence of the table as we want to have
contiguous ids"* and carries, three times, the note that *we can still have "holes" on ids since a sql
transaction can be reverted after a usage of the sequence* — a gapless order attempted, its failure
written beside it, while their `logs (ledger, id)` key *is* the cursor this ADR wants. The naming rule
is theirs too: they *do* name the axis (`pit` plus a `useInsertionDate` selector) and `pit` still
resolves to **six columns across seven endpoints**, spelled three ways, undocumented in their OpenAPI.

## What we considered

| | Why not |
| --- | --- |
| **One running balance for both axes** | Wrong by construction — the first table above. |
| **A second running balance on the effective axis** | 740× on backdated insert, measured on their code. |
| **Keeping the recorded-axis running balance for the hot path** | Reversed by [spike 009](/spikes/009-where-the-balance-lives): it is correct on an axis nobody queries, it was not the independent drift check it looked like, and the per-account row answers "now" anyway. |
| **Forbid backdating** | Breaks on late clearing and chargebacks, which are the normal case. |
| **`recorded_at <= :as_of`** | Not reproducible — the table above. Do not build M5 on it. |
| **A bare `bigserial` as the cursor** | Sequence values are handed out at *insert* time, so the same interleaving leaves gaps that fill in afterwards; `max(seq)` is not yet gap-free. Hence a watermark. |
| **Serialize all ledger writes** behind one commit-ordered lock | Trivially correct, and measured expensive: spike 003's single-contended-row case, roughly **10× unbatched and 2.3× batched** ([0002](/decisions/0002-scaling)). Worse than it looks, because the lock is **global** — every lever 0002 rests on reduces contention on *account* rows, and none touch a lock taken by every writer. **The concurrency-4 plateau is the specific danger**: throughput *declines* past four concurrent writers, so answering a slow ledger by adding workers makes it slower. |
| **Push "as of entry #N" to the caller** | Honest, and fine internally, but a credit agreement says "as of June 30", not "as of entry 4,183,992". Something still has to map a date to a cursor. |

## What it costs

| | |
| --- | --- |
| **The effective-axis aggregate is linear and currently unbounded** | Roughly 0.10 µs per entry in range, and **105.91 ms** for a 1M-entry account (one-off run, no harness in repo). We traded Formance's unbounded `UPDATE` for an unbounded `SCAN`, but ours is on the read path and mutates nothing. |
| **It must be bounded, and accounting already knows how: period close** | Discharged by [0011](/decisions/0011-period-close-and-report-axes): `ledger_period_balances` materializes each account's balance at each close, at a stored cursor, so a business-date query becomes *"prior close + tail"* — measured 45–49× at a close boundary, 8–9× mid-period, neither decaying with history. A backdated entry into a closed period is **accepted, not locked out**, lands above the stored cursor, and is enumerated by `close_disclosures` — the analogue of the restatement disclosure accounting practice requires. |
| **The striped read cost is unmeasured** | The accounts every transaction touches are the shared ones, also the accounts accumulating the most entries, so the account most likely to be queried "as of last quarter" has the largest scan, summed across N stripes ([0002](/decisions/0002-scaling)). **Spike before M5.** |
| **The recorded axis is not yet trustworthy** | `recorded_at` should be assigned by the writer; today it is a bare `DEFAULT` and forgeable — verified, an `INSERT` supplying `1999-01-01` was accepted. **A column with a `DEFAULT` is not a constraint** ([0004](/decisions/0004-where-logic-lives)). |
| **The query layer's shapes exist as SQL; a Rust read path over them is roadmap M5** | *The effective-axis February close as known on 1 March* **is** expressible: [0011](/decisions/0011-period-close-and-report-axes) turned `balance_sheet` and `income_statement` into the `balance_sheet_at`/`income_statement_for` functions taking an effective range (or instant) and a commit cursor, and `recon_equation_breaks` takes one instant and one cursor. The Rust read path over those functions is roadmap M5, not part of the SQL layer. |
| **The drift check is the only check** | `ledger_account_balances` and the recomputed sum over `ledger_entries` must always agree; a cheap periodic check finds divergence, and should recompute rather than only alarm, as Modern Treasury does. Recomputing from the append-only entries is what makes it independent — a comparison against `balance_after` would not have been, because the writer computed both from the same locked row in the same transaction. |
| **Reporting code must name its axis, and the cursor lags the newest writes** | M5 must test the backdating case above. The lag is the longest in-flight transaction — the price of write concurrency — and it composes with [0005](/decisions/0005-event-log-and-write-path)'s deferred hash chain, which needs a total order. |

## The as-of cursor is decided, and [0011](/decisions/0011-period-close-and-report-axes) replaced the mechanism

**The failure this ADR measured is real; the fix it first specified is not.** The watermark above —
a gapless sequence on `ledger_events` with `W = min(seq) - 1` over events whose xid ≥
`pg_snapshot_xmin` — takes its minimum over rows the reporter can *see*. On the interleaving where
writer A starts first and commits last, A's xid sits *below* an already-issued watermark and its
rows appear afterwards — reproduced in [spike 012](/spikes/012-period-close) §3, alongside this
ADR's own 45% instability. The mechanism is now `xact_id xid8` on every journal row and a cursor of
`pg_snapshot_xmin(pg_current_snapshot())`, applied in the baseline; **M5 is unblocked**. This ADR
got the horizon right and projected it onto the wrong substrate. The risks below stand as *costs*
of the surviving mechanism, with 0011's measurements:

1. That `pg_snapshot_xmin(pg_current_snapshot())` gives a usable watermark under our write pattern.
   The risk is a **batched posting run**, not the one-shot timers of the card rail's [authorization-holds decision](/card/decisions/0001-authorization-holds).
2. Its lag under such a run: one transaction open for minutes pins every report behind it.
3. ~~That the watermark advances past aborted transactions automatically.~~ **Verified** on PostgreSQL
   18.6: a session took xid8 5325039 and held it open, a concurrent snapshot read `5325039:5325039:`
   with xmin pinned at that id, and on `ROLLBACK` the next read `5325040:5325040:`. xmin tracks what
   is still *running*, and an aborted transaction is not, so it stops pinning the horizon unaided. The
   same transcript demonstrates risk 2, and on RDS the holders are not only our writers — `pg_dump`,
   an idle-in-transaction session, a logical replication slot, `hot_standby_feedback` from a replica,
   and any prepared transaction all pin xmin, so a report trailing the oldest can trail by hours.
