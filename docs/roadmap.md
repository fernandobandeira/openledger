# Roadmap

Ordered by what unblocks what, not by size. No estimates — see
[ADR-0001](./decisions/0001-go-and-postgres.md) for why the risk here is correctness, not
throughput, and correctness doesn't estimate well.

**Scope for now: the ledger only.** The card rail is what makes it a product, but the ledger is
what makes it correct, and the vision doc's own argument is that they are the same table
serving different masters. Build the table first.

---

## M0 · The golden trace as a fixture

The most useful artifact in [v1-vision.md](./v1-vision.md#06--lifecycle-one-500-purchase-row-by-row)
is the balance table: 12 accounts × 11 columns, plus three branch cases, with the accounting
equation checking out at every column. Someone already wrote our acceptance test.

Encode it as data — accounts, opening balances, the eight steps with their entries, the
expected balance at each column, and the `held`/`available` rows — before writing the engine
that satisfies it. Then correctness pressure exists from the first commit instead of arriving
in month two, after the API shape has already made some of it awkward.

**Done when:** the fixture parses, the accounting equation is asserted at every column by the
fixture's own self-check, and the engine doesn't exist yet.

## M1 · Schema and invariants

Starts from [`spikes/002-sqlc-vs-jet/schema.sql`](../spikes/002-sqlc-vs-jet/schema.sql), which
already applies cleanly with nine invariants verified as enforced by Postgres, and already
carries the [spike 001](./spikes/001-formance.md) corrections (tenant-scoped idempotency with
`NULLS NOT DISTINCT`, request-body hash, double-reversal guards, denormalized `effective_at`).

`ledger_accounts`, `ledger_transactions`, `ledger_entries`. Nothing else. No API, no Go beyond
what runs migrations.

- Balanced-per-currency enforced by the database, not by application code.
- Append-only enforced by `REVOKE UPDATE, DELETE` from the app role — which means two roles,
  and migrations that run as the other one.
- `idempotency_key UNIQUE` on transactions; the key is scoped to the **event**, not the purchase.
- Both `UNIQUE` constraints on accounts, including the partial one for `owner_type = 'house'`
  (`NULL != NULL` in Postgres, so the general constraint would happily allow a second
  `interchange_revenue`).
- `amount_minor bigint CHECK (> 0)` — direction carries the sign, never the amount.

Now also includes **`ledger_events`** — see [ADR-0004](./decisions/0004-event-log.md). It is the
idempotency spine for the majority of the lifecycle that writes no ledger transaction at all
(authorizations, declines, hold expiry, reversals, statement close, repayment initiation, limit
changes). Today those cannot be made idempotent, because idempotency is a column on a table they
never touch.

**Done when:** every invariant in v1-vision §04 has a migration and a test that tries to
violate it and is refused *by Postgres*.

## M2 · The concurrency proof

`account_seq` and `balance_after` mean writes to one account must serialize.

[Spike 001](./spikes/001-formance.md) supplies the mechanism: a per-(account, currency) balance
row, updated by a single atomic upsert that returns **both** the new balance and the next
sequence number —

```sql
INSERT INTO ledger_account_balances (...) VALUES (...)
ON CONFLICT (account_id, currency) DO UPDATE
   SET balance  = ledger_account_balances.balance + excluded.balance,
       last_seq = ledger_account_balances.last_seq + 1
RETURNING balance, last_seq;
```

The row lock *is* the serialization point — no `SELECT max()`, no advisory lock, no retry loop.
Note our `UNIQUE (account_id, account_seq)` **creates** a concurrency problem Formance does not
have (their sequence is a plain global bigserial, which cannot collide), and this upsert is what
pays for it.

Two traps to handle, both from their bug history:

- **Insert the zero-balance row before locking it.** You cannot `FOR UPDATE` a row that does not
  exist, so two writers race on an account's *first* entry.
- **Deterministic lock ordering** — sort accounts by id in every operation, on both read and
  write paths. This was a real deadlock fix for them.

Get this wrong and two entries claim seq 7, or a `balance_after` is computed from a value
another transaction is about to invalidate. It is the single most likely place in this codebase
to be subtly, silently wrong.

**Done when:** N concurrent posters against overlapping account sets produce a gapless,
duplicate-free sequence per account, and every `balance_after` equals the recomputation from
scratch. Run it enough times to trust it.

## M3 · The posting engine

The narrow API the rest of the system talks to: given a balanced set of entries and an
idempotency key, post them atomically or return the stored result. Pending → posted as a new
transaction with `resolves_id`, never an UPDATE.

**Done when:** M0's golden trace replays end to end, and every column matches the table.

## M4 · Bitemporal reads

Shaped by [ADR-0003](./decisions/0003-bitemporal-balances.md): **two axes, two mechanisms.**
Current and recorded-axis balances come from `balance_after`; business-date balances are an
aggregate over `effective_at`. Every reporting function names its axis explicitly.

Blocked on an open question ADR-0003 does not settle: `recorded_at` is not monotonic with commit
order, so a reproducible cursor must be commit-ordered rather than a wall clock. Decide that
first — it needs its own ADR.

**Done when:** any column of the golden trace can be reconstructed by an as-of query alone, with
no replay — *and* the backdating case from ADR-0003 (insertion order ≠ effective order) returns
the correct number on both axes.

## M5 · The auth hot path

`credit_lines`, `spend_controls`, `card_holds`. The transaction from v1-vision §03, against a
fake processor. Read-only with respect to the ledger — an authorization writes no entry.

Includes the edge cases that decide whether you've built this before: over-capture clamping,
forced posts, negative available credit as a **legal state**, and duplicate auths returning the
**stored** decision rather than re-evaluating against a limit that may have moved.

## M6 · Durable timers

Temporal enters here and not before — hold expiry and the ACH return window are the first two
things that genuinely need it. Activities must be idempotent, which M3 already gives us.

---

## Newly known work, not yet scheduled

From [spike 001](./spikes/001-formance.md), in rough priority order:

- **Per-row hash chaining** for tamper evidence. Nearly free at our volume; never build their
  block-hashing layer. Deferred in [ADR-0004](./decisions/0004-event-log.md) because it needs a
  total order — decide it with [ADR-0005](./decisions/0005-reproducible-as-of.md).
- **Metadata history**, if any metadata feeds collateral reporting. Cheapest path is to make
  metadata changes *be* log entries rather than adding revision tables.
- **Benchmark the hot account.** Every transaction touches the credit-line account. Their design
  target is 1K writes/sec, but a real user hit a knee at ~8–12 TPS on a single ledger. Our 20–50
  TPS peak is not automatically safe.
- **Primary key / replica identity on every table** from day one, if lender reporting will ever
  be fed by CDC.

## Deliberately not now

- Sharding, read replicas, caching. The sizing says one Postgres instance. Anyone who opens by
  sharding the ledger has misread the problem.
- The HTTP API. It follows the domain; leading with it inverts the pressure.
- Multi-currency FX. The schema carries `currency` and balances per-currency; conversion is a
  separate problem with its own ADR.
- Statements, disputes, AP/AR, wallet. All real, all after the core holds.
