# 0011 — What the database enforces, and what it cannot

**Status:** accepted
**Date:** 2026-08-26

## Context

Between [0009](./0009-chart-and-completeness.md) and this ADR, the schema grew about a dozen
guards. Every one of them was added because an adversarial reviewer produced a counterexample: a
state the design claimed was impossible, reached in SQL, with every existing check green.

None of them was recorded here. The front page of this log claims to hold *"everything we've
decided,"* and a repeated finding was that it did not — the most consequential correctness
mechanisms in the project existed only as trigger definitions. This ADR is the record.

The pattern in the counterexamples is worth stating first, because it is more useful than the list:

> **A column with a `DEFAULT` is not a constraint.** `effective_at` was made honest by putting it
> inside a composite key. `recorded_at`, `account_seq`, `xact_id` and `uuidv7()` ids all had
> defaults and nothing else, and every one of them turned out to be forgeable by an INSERT.

## Decisions

### The journal is sealed at commit

`ledger_transactions.xact_id` records the database transaction that created the row, and
`ck_entries__sealed` refuses an entry whose transaction was created by a *different, already
committed* one.

Without it, append-only protected the **entry** and not the **journal**: the app role, holding
nothing but its ordinary `INSERT` grant, added a balanced, correctly-dated, correctly-sequenced
pair of legs to a transaction committed and reported months earlier. February revenue went from
500.00 to 1,166.00 with the drift view, the accounting equation and the balance sheet all green,
because every constraint in the schema was satisfied.

`ck_txn__immutable` completes it: a transaction row cannot be deleted, and cannot be updated
outside `metadata` and `external_ref`. That closed two more escapes — deleting a transaction's
legs *and* the transaction row together (which erased 50,000 of revenue past the min-entries
guard), and re-opening a sealed transaction with a one-line `UPDATE` of `xact_id`.

### `recorded_at` is assigned, never accepted

A `BEFORE INSERT` trigger stamps `now()` on entries, transactions and events, discarding whatever
the caller supplied.

The insertion axis is what every "reproducible as of any date, forever" claim rests on, and it was
client-supplied and unconstrained. Three consequences, all reproduced: an already-issued
recorded-axis report could be rewritten months later by a transaction *claiming* to predate it; one
transaction's two legs could carry different recording times, so a recorded-axis report of a
perfectly balanced journal came back **unbalanced**; and, arranged more carefully, a **green report
that was 50% wrong**.

**What this does not fix**, and it matters: `now()` is transaction-*start* time, so `recorded_at`
is still not monotonic with commit order. [0005](./0005-reproducible-as-of.md) is the outstanding
work, and until it lands `balance_after` cannot answer a recorded-axis as-of question — the
aggregate can. Both axes are now asserted in [`tests/bitemporal.sql`](../../tests/bitemporal.sql).

### `account_seq` is assigned from the journal

`assign_entry_seq` is a `BEFORE INSERT` trigger: it sets `NEW.account_seq` to `MAX + 1` over that
account's existing entries. A client-supplied value is **discarded**, not refused.

This sentence used to end "under the row lock the balance upsert already holds", which was a
**caller convention stated as a property of the mechanism**. Nothing obliged a caller to touch
`ledger_account_balances` first, and a reviewer ran 6 workers x 20 balanced postings that did not:
100 of 120 died on `uq_entries__account_seq` with a `23505`, indistinguishable from a genuine
idempotency conflict and retried by no serialization-failure loop. The trigger now takes that lock
itself — it upserts the `(account, currency)` cache row and locks it before reading `MAX` — so the
serialization is something the database provides rather than something the caller is trusted to
have done.

It took two attempts. Uniqueness and positivity were not enough — an app-role INSERT could leave a
48-wide gap and later *fill* it with a backdated, balanced, same-account round trip, taking gross
turnover from 100 to 100,000,000 with the journal and the cache written together, so all three
copies agreed and the alarm stayed silent.

The first fix *validated* the incoming sequence against `ledger_account_balances.last_seq` — and
that was the same mistake one level down, because **the app role is granted `UPDATE` on that
table**. The counter was not issued, it was *asked*: rewind `last_seq` into a reserved gap in one
transaction, back-fill it in another, put the counter back. It also did nothing at all for a
brand-new account, where no cache row exists yet and bigint-max was accepted, permanently bricking
the account. Assignment closes all three.

That is the general limit of the drift view, and it is worth naming: **`ledger_balance_drift`
detects disagreement, never fabrication.** Sequencing therefore has to be enforced where it is
issued, not reconciled afterwards.

The alarm's scope also grew, for the same reason — it now compares per-row running balances (not
just the last one), the cached net balance, `input` and `output` *individually*, and `last_seq`.
Each of those was a state that had been reachable while the view stayed empty.

### `ENABLE ALWAYS` on every trigger, and on the foreign keys

`session_replication_role = 'replica'` is the logical-replication apply path and what
`pg_restore --disable-triggers` sets. Under it, a trigger in the default `ENABLE ORIGIN` state does
not fire.

This was applied to one trigger, then to all of them, and finally — after a reviewer pointed out
that referential integrity *is* implemented as triggers — to the internal FK triggers as well.
Before that last step a transaction spanning two tenants, with both legs carrying a currency their
account does not hold, dated 27 years before their own transaction, committed cleanly on the
replication path. **A subscriber must enforce what its publisher enforces, or replication is a
laundering channel for corrupt rows.**

### One convention per hold group

`card_hold_groups.total_convention` is fixed by the first message that moves the authorized
subtotal, and a group may not mix deltas with cumulative totals.

This is **the honest limit of the order-tolerance claim** [0010](./0010-authorization-holds.md)
headlines, and it deserves to be stated plainly rather than buried: mixing them is *irreconcilable*,
not merely awkward. `{authorization +100.00 as a delta, incremental 120.00 as a total}` yields
120.00 in one arrival order and 220.00 in the other, because a total arriving before the delta it
restates carries no information saying it already includes it. No derivation can fix that. Only
refusing the mix can.

### Expiry is reversible, and the alarm measures against a snapshot

An expired hold re-opens on any increase-side message — including an `expiry_reversal`, and
including a cumulative restatement whose delta is *zero*, because the restatement itself is the
liveness signal. A late clearing does not resurrect it.

`expire_hold_group` snapshots `expired_authorized` and `expired_total`, and the drift alarm flags
exposure that grew past either. Timestamps could not do this job: `assigned_at > expired_at`
compares two `now()` values, so any writer whose transaction opened before the release timer fired
was invisible.

### The chart cannot contradict itself

An account type's category must agree with its statement line's `statement` and `side`
(`ck_types__matches_fs_line`), and `fs_lines.side` must belong to its statement. Pointing a
`revenue` type at a cost-of-revenue line put 6,000 of revenue on the expense side of the income
statement — the exact harm 0009 is about — with every check green. A balance-sheet line carrying
side `debit` was counted on *neither* side of `balance_sheet_balances` and simply vanished: 90% of
a sheet missing, reporting balanced.

## What the database still cannot enforce

Recorded here because the alternative is implying it can.

- **`GRANT ALL` re-grants everything, including `TRUNCATE`.** A `REVOKE` is a point-in-time change
  to a privilege, not a standing prohibition. Append-only comes from the narrow `GRANT` and from
  never widening it; the `REVOKE` lines make the intent legible in review and nothing more.
- **Table inheritance disarms every constraint.** A child of `ledger_entries` inherits CHECKs and
  nothing else — no FKs, no unique indexes, no triggers — while remaining visible through the
  parent to every view. It needs `CREATE` on the schema, so it is an operator path, not an app one.
- **Gaplessness is enforced at issue, not verified at rest.** `assign_entry_seq` makes a gap
  unreachable through an INSERT; nothing scans the journal for one that arrived another way.
- **The chart is not versioned.** Changing which statement line an account reports under is blocked
  outright while accounts exist, which is a stopgap: IAS 1.41 *requires* reclassifying comparatives.
- **There is no period close and no period lock**, so a backdated entry can still restate a
  reported period. See [0009](./0009-chart-and-completeness.md).
