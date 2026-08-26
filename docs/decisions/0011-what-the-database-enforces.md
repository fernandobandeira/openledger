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
aggregate can — **which was wrong, and is now corrected in the migration too.** `now()` is
transaction-*start* time, so a writer that begins before a report and commits after it inserts rows
that claim to predate the report. Demonstrated with nothing but the app role's INSERT grants: the
same query, the same as-of, the same axis, run either side of one `COMMIT`, moved revenue from
110,000.00 to 160,000.00 — balanced both times, zero drift. Assigning `now()` shrank the window
from "any instant the caller invents" to "the duration of the writer's transaction", which the
writer still chooses. **A timestamp cannot order commits.** Neither `balance_after` nor the
aggregate answers a recorded-axis as-of question reproducibly until
[0005](./0005-reproducible-as-of.md) lands, and `xact_id` is already stored for it. Both axes are
asserted in [`tests/bitemporal.sql`](../../tests/bitemporal.sql) — as *separation*, which holds; not
as reproducibility under concurrent writes, which does not.

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

### The journal cannot be emptied

`TRUNCATE ledger_entries, ledger_account_balances` left eleven transactions standing with zero
entries, all three currencies reporting `balanced = t`, drift at zero rows, and the accounting
equation satisfied. Nothing was wrong with any report; there was simply nothing left to disagree
with. **Silence read as assent** — the same shape as an empty report that "found no problems".

`ck_txn__has_entries` could not speak, and this is worth being precise about, because it looks
like the guard that should have: it is a DEFERRED constraint trigger, so it fires at the commit of
a statement that *touched* a transaction. `TRUNCATE` is not such a statement. The transactions were
never touched; their entries just stopped existing.

Two things changed. `BEFORE TRUNCATE ... FOR EACH STATEMENT` triggers, `ENABLE ALWAYS`, on
`ledger_entries`, `ledger_transactions`, `ledger_events` and `ledger_accounts` — verified to hold
against `GRANT ALL`, `SET ROLE openledger_app`, `CASCADE`, and `session_replication_role =
'replica'`. And `ledger_transaction_drift`, a standing cross-check of the two journal tables
against each other, because the two of them agreeing with a *third* thing is not the same as
agreeing with each other.

The comment beside the `REVOKE`s said, in as many words, *"Nothing in SQL can stop that."* A
reviewer disproved it in four lines. **A "cannot" in this repository is a claim like any other**,
and this one had been sitting there being believed.

### An event log with no immutability guard

`ledger_events` was the one table with an assign-on-insert trigger and nothing to stop an UPDATE
afterwards, so `recorded_at` was assigned and then rewritable — and so was `idempotency_hash`, the
column whose entire job is *same key, different body, refuse*. Rewrite the hash and the next replay
of that key returns the wrong stored result. The same guard now covers `card_auth_events`.

### An account's owner is part of what its history means

`purpose`, `currency` and `tenant_id` were frozen — by the unique indexes and the composite foreign
keys entries carry. **Who the account belongs to was not.** One UPDATE moved 110,000 of receivable
from a named company to `owner_id NULL`: every balance identical, the trial balance still balanced,
`ledger_balance_drift` silent. None of them read the owner. A receivable owed by nobody is not a
receivable, and there is no journal entry to reverse, because nothing was posted.

`metadata` stays mutable: it is annotation. `purpose` deliberately stays with 0002's entry-aware
guard rather than being frozen here too — duplicating it would shadow the better message and leave
the richer guard permanently unreachable.

### A correction must point at something it can correct

`resolves_id` and `reverses_id` each had a foreign key, so the target had to **exist**. Nothing
required it to be in a state the correction means anything against. A posted transaction
"resolved" by another posted one, and a pending one "reversed", took revenue to **−49,223** with
drift at 0 and the equation balanced — because both halves were internally consistent journal
entries. The referential integrity was real; the semantic linkage was assumed.

This is decidable at INSERT because a transaction's status can never change: `ck_txn__immutable`
refuses every UPDATE, and pending → posted is a *new row* pointing back through `resolves_id`.

### `xact_id` is assigned, never accepted — the thesis, applied to itself

This ADR's one-line summary is *a column with a `DEFAULT` is not a constraint*. It was written after
`recorded_at`, `account_seq` and `xact_id` each turned out forgeable by an INSERT. Two of those three
were then fixed with an assignment trigger. **The third was not** — and it is the one the schema
calls "the seal's whole basis".

A `DEFAULT` fires only when the client omits the column, and `GRANT INSERT ON ledger_transactions`
covers every column, so `xact_id` was **accepted** rather than assigned. `ck_txn__xact_id` now
assigns it, exactly as `assign_recorded_at` does. The `DEFAULT` stays so the column is never null
under a bulk load with triggers off; it is not the mechanism.

**And a claim that came with it is struck.** A reviewer reported a live escape: plant a transaction
carrying a *future* `xact_id`, wait for the global counter to reach it, then append legs while the
live xid matches, so `assert_entry_seals` reads equal and opens — 555.00 of revenue added to a
closed period with every report agreeing. It was written into this ADR and into the migration on
that report alone, and **it does not work.** Checked against the pre-fix schema: the forged value
seals the transaction against *its own* legs at plant time (`is already committed; its entries are
sealed`), and a leg-less transaction cannot commit because `ck_txn__has_entries` fires at COMMIT. A
second reviewer, asked to verify the same claim independently, also failed to reproduce it and said
so rather than assuming.

That is the sourcing rule of [the decision log](./README.md#on-sourcing) applied to a *finding*
rather than to a citation, and it was violated in the direction nobody watches for: not by inventing
a number, but by adopting an adversary's demonstration without re-running it. **A finding is a
claim.** The fix stands on the principle this ADR is named for — a column whose integrity rests on a
`DEFAULT` is not defended, and leaving the seal's own basis as the single exception to a rule
`recorded_at` and `account_seq` both follow was an inconsistency waiting for a use.

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

- **`REVOKE CREATE ON SCHEMA public FROM PUBLIC` is a no-op here.** Since PostgreSQL 15, PUBLIC has
  no `CREATE` on `public` to revoke — verified on a database that never ran these migrations. The
  line is load-bearing only on PG ≤ 14, and this project's floor is 18. Kept as documentation of
  intent, recorded here so nobody counts it as a defence.
- **`GRANT ALL` re-grants everything.** A `REVOKE` is a point-in-time change to a privilege, not a
  standing prohibition, so the narrow `GRANT` is a matter of discipline. This entry used to end
  "including `TRUNCATE`", and to say that nothing in SQL could stop that — see the new section
  above, which is what happens when a reviewer takes a "cannot" literally.
- **`session_replication_role` can still be set by a superuser to something no trigger sees.**
  Every internal trigger here is `ENABLE ALWAYS`, which covers the replica path, but nothing covers
  a superuser who drops the triggers outright. At that point the defence is backups and audit, not
  the schema.
- **Table inheritance disarms every constraint.** A child of `ledger_entries` inherits CHECKs and
  nothing else — no FKs, no unique indexes, no triggers — while remaining visible through the
  parent to every view. It needs `CREATE` on the schema, so it is an operator path, not an app one.
- **Gaplessness is enforced at issue, not verified at rest.** `assign_entry_seq` makes a gap
  unreachable through an INSERT; nothing scans the journal for one that arrived another way.
- **The chart is not versioned.** Changing which statement line an account reports under is blocked
  outright while accounts exist, which is a stopgap: IAS 1.41 *requires* reclassifying comparatives.
- **There is no period close and no period lock**, so a backdated entry can still restate a
  reported period. See [0009](./0009-chart-and-completeness.md).
