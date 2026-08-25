# Spike 001 — Learn from Formance

**Question:** Formance Ledger is an open-source, production double-entry ledger solving a
problem adjacent to ours. What did they get right that we should copy, and where do their
constraints differ enough that copying would be wrong?

**Timebox:** one focused session. Read, don't build.
**Blocks:** nothing. Runs in parallel with the schema work.
**Explicit non-goal:** adopting Formance. This is a source of prior art, not a dependency
decision. If it turns into an adoption evaluation, that is a *different* spike with a
different question.

## Why it's worth the time

Our [v1 vision](../v1-vision.md) asserts a lot of design without showing the failures that
produced it. Formance has been run against real money in production, and its schema, its
migration history, and its issue tracker are all public. That is a cheap way to find out which
of our assertions are load-bearing and which are taste.

Their sources list already cites TigerBeetle, Modern Treasury, and Square's books post —
Formance is the one of that class whose **actual implementation** is readable.

## Questions to answer, in priority order

1. **Balance reads.** We carry `balance_after` on every entry, with `account_seq` monotonic per
   account (v1-vision §03). That requires serializing writes per account. What does Formance do
   — running balance, a moves/balances table, or aggregate-on-read? If they moved *away* from a
   running balance, find out why; that is the single highest-value thing this spike can return.
2. **Per-account sequence assignment.** However they order entries within an account, how do
   they avoid two writers claiming the same sequence, and what does it cost under contention?
   This is [milestone 2 of our roadmap](../roadmap.md) and the most likely place to get it
   subtly wrong.
3. **Idempotency.** We key on the *event*, not the purchase, so pending → posted is a new row
   rather than an UPDATE. Does theirs agree? What happens on a retry with the same key but a
   *different* body — reject, or return the stored result?
4. **Transaction atomicity + balance assertions.** How do they enforce that a transaction
   balances, and per-currency? Constraint, trigger, or application code?
5. **Reversals.** We have `reverses_id` and never mutate. Confirm they never mutate either, and
   see how they model a partial reversal.
6. **Migrations on an append-only table.** The interesting operational question nobody writes
   down: how do you add a column, or backfill, on a table where the app role has no `UPDATE`?
7. **What they have that we don't have a name for yet.** Read the schema cold and list every
   table we have no equivalent of. Then decide, per table, whether we're missing something or
   they're solving a problem we don't have.

## Where our constraints genuinely differ

Note these before reading, so the differences don't get mistaken for mistakes:

- Formance is a **general-purpose** ledger. We are a **single-product** ledger that happens to
  serve four masters. We can hardcode what they must make configurable.
- We have a lender. Collateral reporting and reproducible as-of balances are first-class for
  us in a way they need not be for them.
- We have a card auth hot path with a ~1s deadline. Their latency profile is different.
- We are explicitly under 1 TPS. Anything they do for scale is something we should *not* copy.

## Evidence that would settle it

A written finding in this file, structured as:

- **Copy** — with a pointer to the specific file/table and what it does better than our sketch.
- **Deliberately diverge** — with the constraint that justifies the divergence.
- **Open** — things their design implies we haven't thought about, promoted to roadmap items
  or new spikes.

Anything that contradicts [v1-vision.md](../v1-vision.md) gets an ADR, not a silent edit to
the vision doc.

## Findings

*(empty — spike not yet run)*
