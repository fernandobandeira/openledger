# 0013 — The write primitive is a posting, not an entry

**Status:** accepted
**Answers the question [0012](./0012-where-logic-lives.md) left open:** if the balance invariant is
not a trigger, what is it?

## The decision

**The Go write API accepts postings. A posting names a source account, a destination account, an
amount and a currency — so it cannot express one leg.** A transaction is a list of postings. The
writer expands each into two `ledger_entries` rows, one debit and one credit, and there is no code
path that writes an entry on its own.

An unbalanced transaction is therefore **unconstructible**, not refused.

**That claim is not free in Go, and as written it was false.** [Spike 010](../../spikes/010-go-or-rust/README.md)
built the type with four unexported fields and one validating constructor, then fabricated it from
another package anyway: `ledger.Posting{}` compiles, `var p ledger.Posting` compiles, and
`make([]ledger.Posting, 2)` compiles — **an empty composite literal is legal outside the package even
when every field is unexported**, and Go's zero value fills the rest. The fabricated postings reached
the write path and were stopped by `ck_balances__currency_iso`, *a database CHECK* — the mechanism
this ADR exists to say we are not relying on. Rust refuses all three at compile time (`cannot
construct … due to private fields`; `the trait bound Posting: Default is not satisfied`), which is
what "unconstructible" means without qualification.

In Go the claim becomes true only with a **validating unwrap at the top of the writer** — every
posting re-checked for a non-zero currency, distinct accounts and a positive amount before expansion,
so a zero-valued struct cannot pass. That is cheap, and it is not written yet. Until it is, this ADR
describes an intent rather than a guarantee.

`ledger_entries` keeps its present shape — independent rows carrying a `direction`, with
`account_seq` and `balance_after`. That is deliberate, and it is what Formance does too: `Posting` in
the type, two `moves` rows in storage. The row is a leg; the *primitive you can call* is a pair.

## Why

A check lives in one handler and the next handler has to remember it. A type is remembered by the
compiler, for every caller in the language, forever, with no coordination. Spikes
[001](../../spikes/001-formance/README.md) and
[009](../../spikes/009-how-other-ledgers-enforce/README.md) show that is what the field actually
relies on:

- **Formance** ships **zero `GRANT` and zero `REVOKE` in its entire repository** — they are not
  betting on one writer either. Their guarantee is `Posting{Source, Destination, Amount, Asset}`, and
  `Postings.Validate()` contains **no balance check at all**, because there is nothing left to check.
  Measured against their applied schema: a single unbalanced row inserted straight into `moves`
  commits silently, 500 USD leaving `world` and arriving nowhere. The type is the whole defence.
- **TigerBeetle** puts both account ids on one `Transfer` row. Same idea, one level lower.
- **pgledger** puts it in the *table*: `pgledger_transfers (from_account_id, to_account_id, amount,
  CHECK (amount > 0 AND from_account_id != to_account_id))`, with the per-account legs generated,
  never authored. The strongest version of "make the illegal state unrepresentable" in the survey.
- **Beancount, hledger and `ledger`** make the point most elegantly: you may **elide the amount on
  exactly one posting**, and it is inferred from the requirement that the transaction balance. The
  invariant is not a validation bolted onto the model — it is the thing that *completes* it.

And the negative result, which is what makes this a decision rather than a preference: **no
established open-source ledger enforces debits-equal-credits in the database.** Not one of the nine
systems surveyed — six of them SQL or ORM-backed. Modern Treasury asserts it at the API with a 422;
Fragment makes it a schema-compile-time error; everyone else checks it in application code or makes
it structural. Formance *did* once enforce a different invariant with a
`CREATE CONSTRAINT TRIGGER … DEFERRABLE INITIALLY DEFERRED` — and **deleted it in migration 15 in
favour of a partial unique index.**

## Alternatives

- **Keep the deferred constraint trigger.** It worked, and it was the thing
  [0011](./0011-what-the-database-enforces.md) was proudest of. But PostgreSQL's own manual opens its
  consistency chapter with *"It is very difficult to enforce business rules regarding data integrity
  using Read Committed transactions because the view of the data is shifting with each statement"* —
  and a constraint trigger that reads sibling rows to decide whether to raise is exactly that
  pattern. Ours was safe only because it read rows in its own transaction; the sequence-assignment
  trigger next to it was *not*, and became sound only once it took the balance row's lock itself. We
  found that by counterexample.
- **Check it at the API boundary**, as Modern Treasury does. That is a check, not a shape.
- **Fragment's approach** — declare entry *templates* in a schema and validate the accounting
  equation when the schema compiles, so callers pass parameters and never lines. Genuinely stronger,
  and it presumes a template language we do not have. Revisit if a posting-rules DSL lands.

## What it costs

**The decomposition of a transaction into pairs is not unique.** "Debit A 100, credit B 60, credit C
40" is expressible as `A→B 60, A→C 40`, and so is every other balanced set — but where the pairing
carries no meaning, we are inventing one and then storing it as though it did. TigerBeetle's answer
is to route through a **control account** and chain the transfers so they succeed or fail together;
they recommend doing that first and optimising later. Ours should say which account plays that role
before the first multi-leg posting is written.

**Cross-currency is two postings through a clearing account**, and the rate lives nowhere. pgledger
refuses a cross-currency transfer outright and its own example shows the consequence: the FX rate is
implicit in the difference between two amounts and is not stored. We should store it.

**None of this binds direct DML.** A posting type is a guarantee about Go, and says nothing about a
psql session, a backfill, `pg_restore --disable-triggers`, or the replication apply path. That is
what the two triggers in [`schema/schema.sql`](../../schema/schema.sql) are for, and why
[0012](./0012-where-logic-lives.md) keeps them: they are the outer layer, and they bind accidents,
not intent.

**And nothing enforces balance today.** `ck_entries__balances` is gone and the Go does not exist.
Between those two facts, `ledger_entries` stores independent rows with a `direction`, so an
unbalanced transaction is fully expressible right now. Every system in the survey that made this move
shipped the enforcing path first; we did not, and this ADR exists partly to say so out loud.
