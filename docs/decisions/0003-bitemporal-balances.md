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

## Still unresolved — now [ADR-0005](./0005-reproducible-as-of.md)

**`recorded_at` is not monotonic with commit order.** A transaction starting at T1 and
committing at T3 writes `recorded_at = T1`, while one starting at T2 > T1 and committing at
T2.5 writes T2. So an "as of T" report can return different numbers when re-run later — which
defeats the reproducibility the recorded axis exists to provide.

A genuinely reproducible cursor must be **commit-ordered**, not a wall clock. `account_seq` is
per-account, so this needs either a global monotonic entry id or an explicit "as of entry #N".
This ADR does not settle it — [ADR-0005](./0005-reproducible-as-of.md) takes it up, and it
blocks M4.
