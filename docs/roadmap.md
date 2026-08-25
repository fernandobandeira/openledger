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

**Done when:** every invariant in v1-vision §04 has a migration and a test that tries to
violate it and is refused *by Postgres*.

## M2 · The concurrency proof

`account_seq` and `balance_after` mean writes to one account must serialize. Locking the
affected account rows in a deterministic order (sorted by id, to avoid deadlocks) inside the
posting transaction is the boring correct answer — but "boring and correct" needs a test, not
a comment.

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

`balance_after` as of an instant. Trial balance. The accounting equation at an arbitrary
`as_of`.

The trap is not storage, it's boundaries — every `date_trunc`, every `BETWEEN`, every "as of"
that turns an instant into a bucket. Reports pin an **instant**, not a date, or "as of June 30"
re-runs to a different number and reproducibility is gone.

**Done when:** any column of the golden trace can be reconstructed by an as-of query alone,
with no replay.

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

## Deliberately not now

- Sharding, read replicas, caching. The sizing says one Postgres instance. Anyone who opens by
  sharding the ledger has misread the problem.
- The HTTP API. It follows the domain; leading with it inverts the pressure.
- Multi-currency FX. The schema carries `currency` and balances per-currency; conversion is a
  separate problem with its own ADR.
- Statements, disputes, AP/AR, wallet. All real, all after the core holds.
