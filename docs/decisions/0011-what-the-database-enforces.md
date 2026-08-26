# 0011 — A column with a DEFAULT is not a constraint

**Status:** **superseded in part by [0012](./0012-where-logic-lives.md)** — the findings stand, the
conclusion does not
**Date:** 2026-08-26

## The decision

This ADR records what a PL/pgSQL implementation could and could not be made to guarantee. **The
mechanisms described here no longer exist** — [0012](./0012-where-logic-lives.md) deleted the
deferred balance trigger, the sequence and `xact_id` assignment triggers, the correction-target
guard, the inheritance event trigger, both ledger-side drift views and roughly fifteen named objects
besides. What ships today is eleven tables, five views, ten foreign keys, eight triggers over two
functions, and no policies.

The finding that survives it all, and the reason the file is kept:

> **A column with a `DEFAULT` is not a constraint.** `effective_at` was made honest by putting it
> inside a composite key. `recorded_at`, `account_seq`, `xact_id` and `uuidv7()` ids all had defaults
> and nothing else, and every one of them turned out forgeable by an `INSERT`.

Each entry below was added because an adversarial reviewer produced a counterexample: a state the
design claimed was impossible, reached in SQL, with every existing check green.

## Why — the counterexamples

| What had to be enforced | What was reached without it |
| --- | --- |
| **The journal sealed at commit.** `xact_id` recorded the creating database transaction; `ck_entries__sealed` refused an entry whose transaction was created by a *different, already committed* one. | Append-only protected the **entry**, not the **journal**: the app role, holding nothing but its ordinary `INSERT` grant, added a balanced, correctly-dated, correctly-sequenced pair of legs to a transaction committed and reported months earlier — February revenue 500.00 → **1,166.00**, with the drift view, the equation and the balance sheet all green. Deleting a transaction's legs *and* its row together erased 50,000 of revenue past the min-entries guard; a one-line `UPDATE` of `xact_id` re-opened a sealed transaction. |
| **`recorded_at` assigned, never accepted** — and assignment was still not enough. | Client-supplied insertion times let an already-issued recorded-axis report be rewritten months later, let one transaction's two legs carry different recording times (a balanced journal reporting **unbalanced**), and produced a green report that was 50% wrong. Assigning `now()` shrank the window without closing it: `now()` is transaction-*start* time, so a writer that begins before a report and commits after it inserts rows claiming to predate it — same query, same as-of, either side of one `COMMIT`, revenue 110,000.00 → **160,000.00**, balanced both times, zero drift. **A timestamp cannot order commits**; [0005](./0005-reproducible-as-of.md) is the outstanding work. |
| **`account_seq` *issued*, not validated.** | Uniqueness and positivity were not enough: an `INSERT` left a 48-wide gap and later filled it with a backdated, balanced, same-account round trip — gross turnover 100 → **100,000,000**, all three copies of the balance agreeing. Validating the incoming value against the balance cache was the same mistake one level down, because the app role holds `UPDATE` on that table: the counter was not issued, it was *asked*. **A drift view detects disagreement, never fabrication.** |
| **`TRUNCATE` refused.** | `TRUNCATE ledger_entries, ledger_account_balances` left eleven transactions standing with zero entries, every currency `balanced = t`, drift at zero rows, the equation satisfied. Nothing was wrong with any report; there was nothing left to disagree with — **silence read as assent.** The deferred `ck_txn__has_entries` could not speak: it fires at the commit of a statement that *touched* a transaction, and `TRUNCATE` is not one. The schema comment beside the `REVOKE`s said *"Nothing in SQL can stop that."* A reviewer disproved it in four lines. **A "cannot" is a claim like any other.** |
| **Immutability on the event log**, not just assignment. | `ledger_events` stamped `recorded_at` on insert and let an `UPDATE` rewrite it afterwards — and `idempotency_hash` with it, the column whose entire job is *same key, different body, refuse*. Rewrite the hash and the next replay of that key returns the wrong stored result. |
| **An account's owner frozen.** `purpose`, `currency` and `tenant_id` were frozen by unique indexes and composite foreign keys; the owner was not. | One `UPDATE` moved 110,000 of receivable from a named company to `owner_id NULL`: every balance identical, trial balance balanced, drift silent — because no report reads the owner. A receivable owed by nobody is not a receivable, and there is no entry to reverse. |
| **A correction pointing at something it can correct.** `resolves_id` and `reverses_id` had foreign keys, so the target had to *exist*. | Nothing required the target to be in a state the correction means anything against. A posted transaction "resolved" by another posted one, and a pending one "reversed", took revenue to **−49,223** with drift at 0 and the equation balanced. The referential integrity was real; the semantic linkage was assumed. |
| **`ENABLE ALWAYS` on triggers — including the foreign keys' own.** | `session_replication_role = 'replica'` (the logical-replication apply path, and what `pg_restore --disable-triggers` sets) skips triggers left in the default `ENABLE ORIGIN` state, **and foreign keys are implemented as triggers**. Before the FK triggers were swept too, a transaction spanning two tenants, both legs in a currency their account does not hold, dated 27 years before its own transaction, committed cleanly on that path. *(Not true of the shipped schema — all 40 internal FK triggers are `ENABLE ORIGIN` again; the sweep went with the PL/pgSQL. In [Still open](./README.md).)* |
| **A chart that cannot contradict itself.** | Pointing a `revenue` type at a cost-of-revenue line put 6,000 of revenue on the expense side of the income statement — the harm [0009](./0009-chart-and-completeness.md) is about — with every check green. A balance-sheet line carrying side `debit` was counted on *neither* side and vanished: 90% of a sheet missing, reporting balanced. Now a composite foreign key rather than a trigger, which is strictly better ([0012](./0012-where-logic-lives.md)). |
| **One convention per hold group; expiry measured against a snapshot.** | Mixing deltas with cumulative totals is *irreconcilable*, not merely awkward. And `assigned_at > expired_at` compares two `now()` values, so any writer whose transaction opened before the release timer fired was invisible. Both are [0010](./0010-authorization-holds.md)'s, and both survive in the shipped schema. |

**A finding is a claim, too.** One escape recorded here — plant a transaction carrying a *future*
`xact_id`, wait for the global counter to reach it, then append legs — was written into this ADR and
into a migration on a reviewer's report alone, and it does not reproduce: the forged value seals the
transaction against its own legs at plant time, and a leg-less transaction cannot commit. Adopting an
adversary's demonstration without re-running it is the sourcing failure nobody watches for.

## Alternatives

- **Validate rather than assign.** Tried for `account_seq` against the balance cache, and it failed
  for a reason that generalises: the app role could write the thing being validated against, and a
  brand-new account had no cache row at all, so bigint-max was accepted and the account was
  permanently bricked. Assignment closes all three holes.
- **`REVOKE` instead of a trigger.** A `REVOKE` is a point-in-time change to a privilege, not a
  standing prohibition; one `GRANT ALL` undoes it. What survives in [0012](./0012-where-logic-lives.md)
  is both — the grant binds the application role, the trigger binds a backfill script or a human at a
  psql prompt.
- **Defend against every writer** — this ADR's own conclusion, and the part
  [0012](./0012-where-logic-lives.md) supersedes. Twenty-seven triggers were the measurement of how
  much ledger had leaked into the schema, not of how much safety was bought.

## What it costs — what the database still cannot enforce

Recorded because the alternative is implying it can.

- **`REVOKE CREATE ON SCHEMA public FROM PUBLIC` is a no-op here.** Since PostgreSQL 15, PUBLIC has no
  `CREATE` on `public` to revoke. The line is load-bearing only on PG ≤ 14 and this project's floor is
  18; kept as documentation of intent, and nobody should count it as a defence.
- **`GRANT ALL` re-grants everything**, and a superuser can set `session_replication_role` or drop the
  triggers outright. At that point the defence is backups and audit, not the schema.
- **Table inheritance disarms every constraint — open again.** `CHECK`s are inherited; foreign keys,
  unique indexes and triggers are not. A child of `ledger_entries` plus one `INSERT … SELECT * FROM
  ONLY` took an income statement from 900 to 1,800, and the child remains visible through the parent
  to every view. The event trigger that closed it went with the PL/pgSQL; `pg_event_trigger` is empty.
- **Gaplessness is enforced at issue, not verified at rest.** Nothing scans the journal for a gap that
  arrived some other way.
- **The chart is not versioned**, and changing an account's statement line is blocked outright while
  accounts exist — a stopgap, since IAS 1.41 *requires* reclassifying comparatives.
- **There is no period close and no period lock**, so a backdated entry can still restate a reported
  period. See [0009](./0009-chart-and-completeness.md).
