# 0001 — Rust on one PostgreSQL 18, with sqlx and no ORM

**Status:** accepted
**Evidence:** [spike 003](/spikes/003-throughput-ceiling) for the database,
[spike 010](/spikes/010-go-or-rust) for the language.

## The decision

**Rust, on a single PostgreSQL 18 instance, with `sqlx` and no ORM.** We write the SQL; `sqlx`
checks every query against a live database at compile time and gives back typed rows. The ledger's
procedural logic lives in Rust; Postgres holds the shape ([0004](/decisions/0004-where-logic-lives)).

## Why

**Rust, because two of this project's guarantees were written down before they were true, and only
a type system catches that.** Spike 010 built `post_transaction`, the authorization hot path and
the seven-variant `auth_event_kind` machine twice, against the real schema, then wrote this
project's own bugs into both. Rust's compiler caught **5 of 5** with no tooling. Go's compiler and
`go vet` caught **0 of 5**. Two of the five were guarantees an accepted ADR had already claimed:

- **"An unbalanced transaction is unconstructible."** With four unexported fields and one validating
  constructor, `ledger.Posting{}` still compiles from another package — an empty composite literal
  is legal outside the package even when every field is private, and Go's zero value fills the rest.
  The fabricated postings reached the write path and were stopped by a **database CHECK**, which is
  the mechanism [0004](/decisions/0004-where-logic-lives) exists to say we are not relying on. Rust has no
  zero value and no implicit `Default`: `cannot construct Posting with struct literal syntax due to
  private fields`. The claim is free here and cost a hand-written unwrap there.
- **"A silently-zero balance is worse than a crash."** An earlier data-access ADR said that, rejected
  go-jet over it, and then recommended `pgx.RowToStructByNameLax` four bullets later — which is the
  same trap. 50.00 of real headroom, `posted_minor` dropped from a `SELECT` in a refactor, scanned as
  `0` with `err == nil`, and a **200.00 authorization approved**. Build clean, vet clean.

Three more that matter for a ledger. A `match` missing `expiry_reversal` is `error[E0004]`, with no
linter, no configuration and no third-party binary — where Go's `switch` needs `nishanths/exhaustive`,
which last released **2023-11-11** and no longer installs under Go 1.26. **A `Result` cannot be
dropped**: `let posted = posted_balance(...)` will not type-check into an `i64`, so every one of the
~40 database calls on the hot path must name its error path, where Go's `posted, _ :=` is one
character and `go vet` is silent. And a **nullable column is `Option<i64>`**, so the arithmetic
simply does not compile — Go dereferences the nil and panics. *The panic is the good case; it is
loud and it aborts the transaction. The silent zero is the one that reconciles.*

**PostgreSQL, because the headroom is measured, not assumed.** Spike 003 recorded **~800 clearings/s
unsharded and 6,970–7,897 striped at 64**, durability on, one 16-core machine — **16–40×** the volume the
reference product needs. At the top of the ladder the curve "plateaus **because the machine ran out of
cores rather than because of a lock**. The ceiling moved from the design to the hardware."

**`sqlx`, because it checks the query against the database, not against a file.** A checked-in DDL
file that has drifted from production is checked against confidently and wrongly; `sqlx` introspects
the real thing. `ALTER TABLE credit_lines ALTER COLUMN limit_minor TYPE numeric`, no code touched:

```
Rust:  error: SQLx feature `bigdecimal` required for type NUMERIC of column #1 ("limit_minor")
Go:    go build exit=0 -- and it RAN, coercing numeric into int64 and printing a number
```

**No ORM, because the hot queries are hand-tuned artifacts meant to be read as SQL** — by us and
plausibly by an auditor. The authorization decision is one transaction using `FOR UPDATE`, a filtered
aggregate and `ON CONFLICT … DO NOTHING`; a balance is an index lookup on `(account_id, account_seq
DESC)`. Diesel was tried against the real schema and produced **0 of 5 views and 0 `joinable!`
entries**, because every foreign key here is composite — the entire reporting layer
[0007](/decisions/0007-schema-conventions-and-chart) builds its completeness argument on is invisible to it.

**Formance reached the same "no procedural logic in the database" position, expensively.** Their v1
put the ledger *in* PL/pgSQL; migration 37 drops 27 stored functions and moves it into Go
([spike 001](/spikes/001-formance)). Note what they **kept**: the constraints. It is
procedural logic they reversed, not database-enforced correctness.

## Alternatives

| | Why not |
| --- | --- |
| **Go** | The prior decision, and it lost on the evidence it was re-examined against — 0 of 5. It also won one round cleanly, and that round is now a cost of this decision rather than a footnote: see below. Its original case rested partly on Temporal SDK quality, a premise [0008](/decisions/0008-authorization-holds) removed. |
| **Diesel** | 0 of 5 views, 0 `joinable!` on composite foreign keys. A DSL that cannot see the reports is worse than no DSL. |
| **Kotlin/JVM** | Sealed classes give exhaustive state machines, which was the strongest single argument against Go — and Rust gives the same thing without the stack weight. |
| **TypeScript** | Default numeric type is a float. Every boundary would need `bigint` discipline forever. |
| **TigerBeetle** | See [0002](/decisions/0002-scaling#why-not-tigerbeetle). |

## What it costs

- **The one round Go won, and it is a real hole.** `sqlc` regenerates the enum from the schema, so
  `ALTER TYPE auth_event_kind ADD VALUE 'financial_authorization'` propagates into the type and the
  linter then forces you to visit every `match`. **Rust has no codegen step, so the hand-written enum
  does not grow and `cargo build` stays clean while the database has a value the code has never
  heard of.** The mitigation is a test that reads `pg_enum` and asserts it equals the Rust enum,
  variant for variant; it is not written. Without it, this decision trades a compile error for a
  runtime one — `sqlx` *does* refuse the unknown value at decode rather than accepting it silently,
  so it fails loudly, but it fails in production rather than in CI.
- **`#[sqlx(default)]` is this stack's `Lax`, and it is banned on money fields.** It reproduces the
  silent zero exactly. The difference from Go is that it is opt-in per field, written at the money
  column, and visible in review rather than being one whole-struct switch — which is a difference in
  blast radius, not in kind.
- **198 crates against Go's 17 modules**, for a project whose stated value is *small team, boring
  tech*. That is 198 to audit, pin and upgrade. Cold build 17.8 s vs 5.5 s; incremental is a wash at
  1.2 s vs 0.4 s. **The claim that the ratio worsens at scale is an extrapolation, not a measurement.**
- **`sqlx`'s compile-time checking is viral and needs a committed `.sqlx/`.** Compiling a dependency
  that uses `query!` will try to introspect *your* database. CI needs either a live schema or
  `SQLX_OFFLINE=true` with the query cache in version control.
- **The async story has two loose ends.** `dyn`-compatible async traits are an accepted 2026 Project
  Goal, not shipped, and Return Type Notation is still nightly — so `Send` bounds on async traits go
  through the `trait-variant` crate. The runtime is a tokio monoculture: `async-std` is sunset in
  favour of `smol`, and **`smol` has not released since 2.0.2 on 2024-09-07**.
- **The contributor pool is smaller.** Stack Overflow 2025 (n=49,009; there is no 2026 survey) puts
  Go at 16.40% against Rust's 14.84%, widening among professionals. Rust wins *admiration* 72.41% to
  56.46% — **a retention signal among people who already cleared the learning curve, not a hiring
  pool.** This cuts against [the open-source goal in `vision.md`](/vision) and is the
  clearest thing this decision gives up.
- **Tenant isolation is meant to be row-level security and is not built.** `tenant_id` leading every
  key is the prerequisite and it exists; the policies do not.
- Correctness pressure moves into Rust, SQL, migrations and tests rather than into a framework.
