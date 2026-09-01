# 0023 — An account has a statement, and it names its axis rather than choosing one

**Status:** accepted (ruled 2026-09-01). It **completes the reversal
[0021](/decisions/0021-accounts-over-http) started** of [0019](/decisions/0019-read-path)'s blanket
refusal of listings — for entries *of one account*. A **global** transaction listing stays refused.
**Evidence:** the schema's own two axis indexes, and `uq_entries__account_seq`'s grain.

## The decision

**`GET /v1/accounts/{account_id}/entries` ships: one account's entries, in order, at a cursor.**
Until now the only way to see a transaction was to already know its id. A ledger whose entries cannot
be listed per account is not inspectable — you can ask what an account is *worth* and never what
happened to it.

**[0019](/decisions/0019-read-path) refused a listing because it "must choose between the recorded
axis and the effective axis". This one does not choose: it takes the axis as a parameter** — which is
not a new idea here, it is exactly what [0019](/decisions/0019-read-path) itself ruled for the trial
balance, *"one endpoint serves both time axes, by parameter and never by a mode flag"*. The objection
was never that a listing is unorderable; it was that a listing which picks an axis silently is
confidently wrong. Naming it removes the objection rather than dodging it.

**The two orderings are the two indexes the schema already carries**, each built for exactly this
question:

| `axis` | ordered by | index |
| --- | --- | --- |
| `recorded` | `(xact_id, id)` | `ix_entries__asof_commit (tenant_id, account_id, xact_id)` |
| `effective` | `(effective_at, xact_id, id)` | `ix_entries__effective (tenant_id, account_id, effective_at, xact_id)` |

The entry `id` breaks ties, so each is a **total** order and keyset pagination on it is exact. Both
are filtered by the commit cursor like every other read, and the effective axis additionally takes a
half-open range.

**`account_seq` is deliberately *not* the page key, and the reason is a trap worth recording.** It
reads like the obvious choice — a per-account counter, gapless, already unique. But
`uq_entries__account_seq` is `(tenant_id, account_id, **stripe**, account_seq)`: the counter is per
*stripe*, because a single per-account counter would serialise every writer through one unique index,
*"the bottleneck striping exists to remove, moved one table over"*
([0013](/decisions/0013-write-path-contract)). So on a striped account `account_seq` is not a total
order, and paging by it would interleave two counters and silently drop or repeat rows. It is
returned on each entry — it is what a drift check walks — but it does not order the page.

**A global transaction listing remains refused**, and this decision narrows rather than removes that.
Across accounts there is no ordering the caller can be assumed to want, and the axis question
compounds with a second one — which of a transaction's legs places it. Per account, both questions
have one answer each. **If a global listing is ever wanted, it needs its own decision**, not this
one's precedent.

## What we considered

| | Why not |
| --- | --- |
| **`account_seq` as the page key** | Per *(account, stripe)*, not per account. Silently wrong on a striped account, which is the one place it matters. |
| **A mode flag (`?recorded=true`)** | [0019](/decisions/0019-read-path) already refused this shape for the trial balance. An axis is a parameter with two named values, not a boolean. |
| **Defaulting the axis** | Whichever we picked would be the one a caller failed to think about. The axis is required. |
| **Offset pagination** | Shifts under concurrent inserts on the recorded axis; the keyset is exact and the indexes are already the right shape. |
| **Returning whole transactions rather than entries** | An account's statement is the legs that touched *it*; a transaction's other legs belong to other accounts. `transaction_id` is on every row, and the transaction read already exists for the rest. |
| **A global transaction listing, while here** | Two open ordering questions instead of one, and no caller has asked. Kept refused. |

## What it costs

- **A fourth listing-shaped surface**, and each is permanent under
  [0014](/decisions/0014-http-api)'s machine-checked table.
- **The effective axis can return an entry the recorded axis has not reached yet**, and vice versa —
  that is what two axes *mean*, and a caller paging one while writes land on the other will see them
  in different places. It is the same property [0006](/decisions/0006-time-and-as-of) records; the
  statement makes it visible rather than introducing it.
- **No bound parameter may ever be NULL, and that is measured rather than preferred.** The keyset's
  predicates must stay `column op $n::type`, which the planner keeps as an INDEX COND. Both
  `COALESCE($n, …)` and `$n IS NULL OR …` are index conds only while the plan is a **custom** one: on
  400,000 entries the `COALESCE` form, planned generically, dropped the bound to a `Filter` and a deep
  page removed **299,999 rows by filter (62 ms)** where the bound form reads six buffers (0.2 ms). So
  the first page binds the *floor of the order* — `'0'` for `xid8`, whose counting starts at 3, and
  the nil UUID, which `uuidv7()` never issues. **A keyset that degrades to an offset on the sixth
  execution of a prepared statement is an offset.**

  This is the same mechanism [0019](/decisions/0019-read-path) records for `balance_sheet_at`, biting
  the other way: there the **generic** plan is the fast one and a pooled reader has a warm-up, here
  the generic plan is the dangerous one. PostgreSQL's custom-to-generic switch at the sixth execution
  is a property this codebase now has to reason about in both directions, and neither instance was
  visible without an `EXPLAIN` under `force_generic_plan`.
- **Page size is chosen, not measured**, like the account listing's before it.
- **This is the third decision in a day to add routes**, all three from building a client. That is the
  adoption surface being exercised for the first time, and it should be expected to settle.
