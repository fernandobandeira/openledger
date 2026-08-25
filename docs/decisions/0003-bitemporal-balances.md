# 0003 — Balances on two time axes

**Status:** accepted
**Date:** 2026-08-25

## Context

[v1-vision §03](../v1-vision.md#posted-comes-from-the-ledger--no-cache-by-construction) says
balance-as-of is "the same lookup, one more predicate":

```sql
SELECT balance_after FROM ledger_entries
WHERE account_id = :acct AND recorded_at <= :as_of
ORDER BY account_seq DESC LIMIT 1;
```

[Spike 001](../../spikes/001-formance/README.md) found that Formance built exactly this design, hit a
wall, and demoted it — the running balance is now a *projection of* a separate balance table,
behind a feature flag that is off in their own minimal configuration. Not for scale reasons.
For **backdating**.

Reproduced on our own schema. Three entries where insertion order ≠ effective order:

| account_seq | effective | amount | balance_after |
| --- | --- | --- | --- |
| 1 | 2026-01-10 | +100 | 100 |
| 2 | 2026-01-30 | +50 | 150 |
| 3 | 2026-01-20 | +30 | **180** |

Balance as of 2026-01-25: the running-balance lookup returns **180**; the truth is **130**. The
backdated Jan 20 entry has a *higher* `account_seq` than the Jan 30 entry, so `ORDER BY
account_seq DESC LIMIT 1` lands on a `balance_after` that already includes Jan 30.

**The vision doc's query is not wrong — it is answering a different question.** On the
*recorded* axis it is correct, and both queries agree. The gap is that every stated *purpose*
for as-of balances — reproducible lender reporting, "as of June 30", statement cycles — is a
**business-date** question, which is the effective axis. And backdating is not an edge case
here: `effective_at` is the network business date, and late clearing and chargebacks are
inherently backdated.

## What spike 001 did and did not find

Worth stating explicitly, because it reads as a contradiction otherwise: *"Formance demoted their
running balance because of backdating"* and *"we keep a running balance"* look incompatible.

They are not. **Formance kept two running balances, on two axes**, and their own code comments
distinguish them:

| their column | axis | their comment |
| --- | --- | --- |
| `post_commit_volumes` | insertion | *"Those volumes will never change, as those are computed in flight."* |
| `post_commit_effective_volumes` | effective | *"can be updated if a transaction is inserted in the past."* |

**Only the second one cost them anything.** It is the mutable one — the trigger doing an unbounded
`UPDATE ... WHERE effective_date > new.effective_date`, the `fillfactor = 80` tune that exists only
because their journal became UPDATE-heavy, and the six migrations that exist purely to repair
volume data.

**Our `balance_after` is the first one.** It is ordered by `account_seq`, which is assigned on
insertion. A backdated entry receives the *next* sequence number and its own `balance_after`;
nothing already written changes. It never needs an UPDATE, because "what was this account's
balance after this entry was recorded" is a historical fact that a later backdated entry cannot
alter.

Likewise, the 180-vs-130 counterexample below is **not** evidence that `balance_after` is broken.
It is evidence that reading it on the *effective* axis is broken. On the recorded axis the
running-balance lookup and the recomputed aggregate agree exactly.

So the lesson taken from spike 001 is not "running balances are bad." It is **"a running balance
on a mutable axis is bad"** — and the decision below is to have only the immutable one.

## Decision

**Two axes, two mechanisms. Do not try to serve both with one running balance.**

| Question | Mechanism |
| --- | --- |
| Current balance (the auth hot path) | `balance_after`, `ORDER BY account_seq DESC LIMIT 1` — O(1) index lookup, unchanged |
| Balance as recorded at instant T | `balance_after` with `recorded_at <= T` — unchanged, and correct |
| **Balance as of business date T** | **Aggregate on read** over `effective_at <= T` |

`effective_at` is denormalized onto `ledger_entries` so the aggregate is a single-table index
scan on `(account_id, effective_at)` rather than a join. Formance puts `effective_date` on
`moves` for the same reason.

### Why aggregate-on-read rather than a second running balance

Three options were live:

**(a) Forbid backdating** — require `effective_at >=` the account's last effective date. Clean,
and wrong: it breaks on late clearing and chargebacks, which the vision doc already treats as
normal.

**(b) A second `effective_balance_after`, maintained by trigger** — what Formance built. Costs
us immutability, because a backdated insert must `UPDATE` every later row for that account. It
is an unbounded write amplification on the journal table. Their migration 10 sets
`fillfactor = 80` on `moves` *only* because of this, and **six of their migrations exist purely
to repair volume data**.

**(c) Aggregate on read** — chosen. At under 1 TPS a bounded index scan over one account's
entries is not a performance concern; these are thousands of rows, not millions. It preserves
strict immutability, which is the property the whole ledger is built on.

> **Amended under [ADR-0007](./0007-open-source-positioning.md).** The decision stands; the
> second sentence does not. See "The read-path assumption" below.

The bonus is a **free corruption alarm**: `balance_after` and the recorded-axis aggregate must
always agree. Any divergence is a bug, detectable by a cheap periodic check. Formance has no
equivalent, because their running balance is derived rather than independently computed.

## Consequences

- `ledger_entries.effective_at` is denormalized and immutable, with an index on
  `(account_id, effective_at)`.
- Reporting code must **name its axis explicitly**. Formance's read API takes a `pit` plus a
  `useInsertionDate` selector; ours should be equally explicit. An unqualified "as of" in a
  function signature is a bug waiting to be filed as a support ticket.
- The recorded-axis running balance stays the hot path. Nothing about the auth decision changes.
- Roadmap M4 (bitemporal reads) now has a concrete shape and must test the backdating case
  above, not merely the happy path.

## Amendment — the read-path assumption is now unsafe

Option (c) was justified by "at under 1 TPS… thousands of rows, not millions." Both halves are
assumptions the pivot removes, and **[spike 003](../../spikes/003-throughput-ceiling/README.md)
does not rescue either** — it measured the *write* path exclusively. Nothing here has been
measured on the as-of read path.

The row-count assumption is the worse of the two, and it fails in a specific, predictable place.
Spike 003 established that the accounts touched by every transaction are the shared house
accounts. Those are therefore also the accounts that accumulate the **most entries** — by a
margin that grows with total system volume. So the account most likely to be queried
"as of last quarter" for a financial statement is precisely the one whose effective-axis
aggregate scans the largest number of rows. In a general engine with no bound on deployment
size, "thousands of rows, not millions" is not a claim we can make.

**The decision does not change.** Option (b) still costs strict immutability and is still the
design Formance needed six repair migrations for. But the justification is now:
aggregate-on-read is chosen *because immutability is worth more than read latency*, not because
the aggregate is cheap — and its cost is currently unmeasured.

Two mitigations already exist in the design and should be tested rather than assumed:

- **Striping cuts the aggregate too.** [ADR-0007](./0007-open-source-positioning.md) stripes hot
  accounts for write throughput; the same split divides each stripe's entry count, so the
  per-stripe scan shrinks even though the total does not. Whether summing K stripes beats one
  large scan is an empirical question.
- **The append-only property helps.** Spike 003 result 10 found throughput essentially
  size-insensitive (5M entries / 2 GB against 128 MB of cache) because the hot set is bounded by
  account count rather than entry count. That reasoning covers *balance-lookup* reads. It
  explicitly does **not** cover a full-history aggregate, which is the one access pattern that
  must touch cold pages by definition.

**This needs its own spike before M4**: measure the effective-axis aggregate over an account with
millions of entries, striped and unstriped. If it is untenable, the fallback is a periodic
effective-axis checkpoint — a materialized balance at, say, each month end, so an aggregate only
ever scans from the last checkpoint forward. That preserves immutability, which (b) does not.

## Still unresolved — now [ADR-0005](./0005-reproducible-as-of.md)

**`recorded_at` is not monotonic with commit order.** A transaction starting at T1 and
committing at T3 writes `recorded_at = T1`, while one starting at T2 > T1 and committing at
T2.5 writes T2. So an "as of T" report can return different numbers when re-run later — which
defeats the reproducibility the recorded axis exists to provide.

A genuinely reproducible cursor must be **commit-ordered**, not a wall clock. `account_seq` is
per-account, so this needs either a global monotonic entry id or an explicit "as of entry #N".
This ADR does not settle it — [ADR-0005](./0005-reproducible-as-of.md) takes it up, and it
blocks M4.
