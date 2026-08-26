# Spike 010 — Go or Rust for the ledger service

**Status:** closed. Produced [ADR-0001](../../docs/decisions/0001-rust-and-postgres.md), and three
corrections to ADRs that were already accepted.

**Question.** [0001](../../docs/decisions/0001-rust-and-postgres.md) chose Go, partly on Temporal SDK
quality — a premise [0008](../../docs/decisions/0008-authorization-holds.md) removed when it chose River.
Meanwhile [0005](../../docs/decisions/0005-event-log-and-write-path.md) moved the balance invariant *into the
type system*. Both changes put weight on the type system that Go was never chosen for. So: is Go
still right?

**Method.** `post_transaction`, the authorization hot path, and the seven-variant
`auth_event_kind` machine, implemented twice against the real `schema/schema.sql` + `chart.sql`.
Then this project's own bugs written into both, on purpose, to see which compiler stops you.

**Ran** 2026-08-26 · Go 1.26.5 · rustc 1.97.1 · PostgreSQL 18.6 · pgx v5.10.0 · sqlc v1.31.1 ·
sqlx 0.9.0 · goose v3.27.3 · river v0.45.0 · graphile_worker 0.13.5 · refinery 0.9.2 ·
`nishanths/exhaustive` v0.12.0.

---

## The answer

**Rust.** It won the type-system crux **5 of 5** with no tooling at all, where Go's compiler and
`go vet` caught **0 of 5** and the `exhaustive` linter caught 2 — and two of those five were
guarantees two then-accepted ADRs had already claimed in writing and did not have.

The spike's own first recommendation was *stay on Go*, on the strength of Q4. That recommendation
did not survive checking Q4 properly: the finding is not "Rust lacks a try-lock migrator", it is
that **only one Rust migrator locks at all**, and the deployment model the migrations ADR already chose — a
single-runner pre-deploy job — is the one where that matters least. Fifteen verified lines close it.
The record of the Go case is kept below in full, because the reasons it nearly won are the things
Rust now has to be watched for.

**The condition that flips it:** a second silent-money defect reaching a balance. The first one is
already here, in §3 below.

---

## Three findings against documents that were already accepted

These are the reason this spike was worth running, and none of them is about Rust.

### 1. [0001](../../docs/decisions/0001-rust-and-postgres.md) recommended the trap it rejected go-jet for

The data-access ADR that then stood rejected go-jet because it "can silently scan a money column as
zero with no error", then four
bullets later recommends `pgx.RowToStructByNameLax` as the escalation path for dynamic queries.
`Lax` **is** that trap. Company with a 1,000.00 limit and 950.00 posted — 50.00 of headroom. Drop
`posted_minor` from the SELECT list in a refactor, keep the field on the struct:

```
truth: limit=100000 posted=95000 held=0 -> available=5000, a 20000 auth MUST decline

B-1b Lax    / posted_minor DROPPED   err=<nil>
     scanned={LimitMinor:100000 PostedMinor:0 HeldMinor:0} approved=true available=100000
     >>> APPROVED 20000 against 5000 of real headroom. err was nil.

B-1c Strict / posted_minor DROPPED   err=cannot find field posted_minor in returned row
```

`go build` exit 0, `go vet` exit 0. The sentence was struck before that ADR was folded into
[0001](../../docs/decisions/0001-rust-and-postgres.md), which now carries the finding.
**`Lax` is one switch that makes every money field on a struct silently zeroable.**

### 2. [0005](../../docs/decisions/0005-event-log-and-write-path.md)'s headline claim was false in Go

The write-path ADR, now [0005](../../docs/decisions/0005-event-log-and-write-path.md): *"An
unbalanced transaction is therefore **unconstructible**, not refused."* The type was built exactly as
it describes — four unexported fields, one validating constructor. From an outside package:

```
=== go build exit=0   === go vet exit=0
go  var zero ledger.Posting  -> compiles, {source:[0...0] destination:[0...0] amount:0 currency:}
go  ledger.Posting{}         -> compiles, {source:[0...0] destination:[0...0] amount:0 currency:}
go  make([]ledger.Posting, 2)-> compiles, len=2
go  PostTransaction(zero postings) -> err=post: bump balance: ERROR: new row for relation
    "ledger_account_balances" violates check constraint "ck_balances__currency_iso"
```

**An empty composite literal is legal outside the package even when every field is unexported**, and
the zero value fills the rest. The fabricated postings reached the write path and were stopped by a
**database CHECK** — the mechanism that ADR exists to say we are not relying on. Rust refuses all three:

```
fab1: error: cannot construct `posting::Posting` with struct literal syntax due to private fields
fab2: error[E0277]: the trait bound `posting::Posting: Default` is not satisfied
fab3: error[E0277]: the trait bound `posting::Posting: Default` is not satisfied
```

In Go the claim needs a validating unwrap at the top of the writer. It is cheap; it is not written.

### 3. The auth hot path is not implementable against the committed schema

The board's §03 reads `credit_lines`. `schema/schema.sql` does not define it, nor `spend_controls`,
nor `card_holds`. The spike had to add a minimal `credit_lines` to make the hot path runnable. A
repo gap, not a language finding.

---

## Q1 — the omitted case

Same logic, same omission of `expiry_reversal`. Rust:

```
error[E0004]: non-exhaustive patterns: `AuthEventKind::ExpiryReversal` not covered
```

Go builds, vets clean, and returns the zero value with `err == nil` — the flag silently uncleared.

**Trying hard to make Go win.** `nishanths/exhaustive` is the mitigation the Go ADR gestured at. It
**does not install** under Go 1.26 (`go install …@latest` fails: the tool pins
`golang.org/x/tools v0.15.0`, which no longer compiles — `invalid array length -delta * delta`).
Last release **v0.12.0, 2023-11-11**. Built via a shim module forcing `x/tools v0.49.0`, it works
and earns its keep — it catches the switch with *and* without a `default:` clause:

```
$ exhaustive ./...
main.go:26:2: missing cases in switch of type main.AuthEventKind: main.KindExpiryReversal
exit=3
```

**But two ordinary Go shapes are invisible to it** — `go build`, `go vet` and `exhaustive` all
silent on an `if/else` chain falling through to `return 0, nil`, and on a `map[Kind]int64` lookup
returning the zero value for a missing key. Rust's `if/else` is equally unchecked; the difference is
that in Rust the idiomatic form is `match` and `match` is checked by the compiler with no
configuration, while in Go the idiomatic form is `switch` and it is checked only by an optional
third-party binary that has not shipped in nearly three years.

**When the enum grows, Go wins a round.** `ALTER TYPE auth_event_kind ADD VALUE
'financial_authorization'` (a real gap — [0008](../../docs/decisions/0008-authorization-holds.md)
names Lithic's `FINANCIAL_AUTHORIZATION`): `sqlc
generate` propagates it into the type and `exhaustive` then forces you to visit the switch. Rust has
no codegen, so the hand-written enum does not grow and `cargo build` stays clean.

**When the value actually arrives, Go loses it back.** sqlc's enum is `type AuthEventKind string` —
an open set:

```
go  UNKNOWN variant decoded SILENTLY as "financial_authorization", err=nil
go  AuthEventKind("not_a_kind_at_all") compiles and is a valid value of the type
rs  UNKNOWN variant REFUSED at decode: invalid value "financial_authorization" for enum AuthEventKind
```

**One good result neither language earned.** The first attempt to *insert* such a row was refused:
`ck_auth_events__sign` is a **whitelist over kinds**, so a new enum value can carry no delta at all —
positive, negative or zero. Stronger than its comment claimed.

## Q2 — sqlc vs sqlx vs Diesel

The difference is not *whether* but **what each checks against**: sqlc checks the query against a
checked-in DDL file, sqlx against the live database. After `ALTER TABLE credit_lines ALTER COLUMN
limit_minor TYPE numeric`, with no code touched and `sqlc generate` not re-run — the realistic case:

```
Go:   go build exit=0, and it RAN:  LockCreditLine OK: limit=100000   <-- pgx coerced numeric to int64
      (the failure only surfaces once a value stops being integral: 100000.55 -> runtime scan error)
Rust: error: SQLx feature `bigdecimal` required for type NUMERIC of column #1 ("limit_minor")
      cargo build exit=101
```

Re-run `sqlc generate` and it *does* catch it (`mismatched types pgtype.Numeric and int64`). **So
sqlc's check is as strong as sqlx's, one step later, and only if the DDL file tracks production.**
That last clause is CI's job. Same shape for a dropped column.

Two sqlc landmines confirmed live, one understated by the data-access ADR: **`overrides` apply to
`NOT NULL` columns only**, so the generated struct carries `ID uuid.UUID` beside `EventID
pgtype.UUID`. It
says a miss is silent; it is also *partial*, which is harder to spot.

**Diesel is out.** `diesel print-schema` against the real schema produced **0 of 5 views** and **0
`joinable!` entries**, because every foreign key here is composite. The reporting layer
[0007](../../docs/decisions/0007-schema-conventions-and-chart.md) builds
its completeness argument on is invisible to it.

## Q3 — durable jobs: the expected disqualifier, which was not one

Rust has transactional enqueue. `graphile_worker` 0.13.5 (MIT, on sqlx 0.9.0 — no skew), same test
as River v0.45.0, against a real `ledger_write` table:

```
                            graphile_worker            River
A. enqueue in tx, ROLLBACK  ledger_write=0 jobs=0      ledger_write=0 river_job=0    both PASS
B. enqueue in tx, COMMIT    ledger_write=1 jobs=1      ledger_write=1 river_job=1    both PASS
C. 7-day absolute run_at    run_at=2026-09-02 …        scheduled_at=2026-09-02 …
D. idempotent by key        1 row after 3 enqueues     1 row after 3 enqueues
```

Symmetric. Two frictions on the Rust side: **`underway` 0.2.0 pins sqlx `^0.8.2`** and fails against
0.9.0 with `multiple different versions of crate sqlx_postgres in the dependency graph`; and sqlx's
compile-time checking is **viral** — compiling a dependency that uses `query!` tries to introspect
*your* database (`relation "underway.task" does not exist`, 24 errors) until you set `SQLX_OFFLINE`.

`sqlx::copy_in_raw` works — 100,000 rows in 0.03 s — so spike 003's 4.4× `CopyFrom` path survives a
port. No sqlx equivalent of `pgx.Batch` pipelining was found; **untested.**

## Q4 — migrations, where Rust loses

[0003](../../docs/decisions/0003-migrations.md)'s criterion, reproduced: 2,000,000 rows,
127 MB, one migration containing `CREATE INDEX CONCURRENTLY`, three concurrent migrators.

```
2026-08-26 17:43:01.066 UTC [831046] ERROR:  deadlock detected
DETAIL:  Process 831046 waits for ExclusiveLock on advisory lock […]; blocked by process 831045.
	Process 831045 waits for ShareLock on virtual transaction 13/65162; blocked by 831044.
	Process 831044 waits for ExclusiveLock on advisory lock […]; blocked by process 831046.
	Process 831044: SELECT pg_advisory_lock($1)
	Process 831045: CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_t_v ON t (v)
```

| tool | 3 migrators × 3 trials |
| --- | --- |
| **sqlx 0.9.0**, default locking | **2 of 3 failed, every trial** |
| **goose 3.27.3** + `WithSessionLocker` | **0 of 3, every trial** |
| **sqlx 0.9.0** + `set_locking(false)` + hand-rolled `pg_try_advisory_lock` poll | **0 of 3, every trial** |
| **refinery 0.9.2** | `CREATE INDEX CONCURRENTLY cannot run inside a transaction block` — cannot run it at all |

**No Rust migrator polls a try-lock** — but that framing understates it and points at the wrong
thing. Read against the published sources of every Rust migrator on crates.io:

| crate | version | cross-process lock | can it run `CREATE INDEX CONCURRENTLY`? |
| --- | --- | --- | --- |
| `sqlx` | 0.9.0 | **blocking `pg_advisory_lock`** | yes, `-- no-transaction` |
| `diesel_migrations` | 2.3.2 | **none** | yes, `run_in_transaction = false` |
| `sea-orm-migration` | 2.0.2 | **none** | yes, `use_transaction() -> Option<bool>` |
| `geni` | 1.3.3 | **none** | yes, `transaction: no` in line 1 |
| `movine` | 0.11.4 | **none** | no — `batch_execute` inside a transaction |
| `migrant` | 0.14.0 | **none** | — |
| `schemamama` | 0.3.0 | **none** | — |
| `refinery` | 0.9.2 | **none** | **no** — `cannot run inside a transaction block` |

`grep -rn "pg_advisory\|advisory" --include=*.rs` over the whole Diesel git repository returns
**nothing**. So the accurate finding is: **exactly one Rust migrator attempts cross-process
coordination at all, and it is the one that does it the wrong way.** The rest have no lock to be
wrong. That is not "Rust's tooling is behind on one detail" — it is a different default. Go's goose
and Atlas both poll a try-lock; the Rust ecosystem largely does not attempt the problem.

**How much this should weigh is less than it first appears.** [0003](../../docs/decisions/0003-migrations.md)
already chose to run migrations as a **dedicated pre-deploy job, not from application startup** —
which is a single runner by construction. The three-concurrent-migrators test models the topology
[0003](../../docs/decisions/0003-migrations.md) rejected. The lock is a guard against a botched
deploy (a retried Job overlapping a pod that
lost its lease, a node failure mid-run), not a load-bearing mechanism in the chosen design. It is
still wanted, which is why goose has one.

`sqlx` with `set_locking(false)` and a hand-rolled `pg_try_advisory_lock` poll was **verified
0-of-3 failures across every trial** — fifteen lines, and it is the only Rust configuration that
coordinates correctly. We maintain goose's algorithm; we do not reimplement goose.

## Q5 — the cost of Rust

| | Rust | Go |
| --- | --- | --- |
| cold build | **17.8 s** | **5.5 s** |
| incremental, one line | 1.2 s | 0.4 s |
| fast type check | 0.3 s (`cargo check`) | 0.9 s (`go vet`) |
| dependency graph | **198 crates** | **17 modules** |

3.2× cold, negligible incremental, on ~420-line programs. **The claim that the ratio worsens at
scale is an extrapolation, not a measurement.** For a project whose stated value is *"small team,
boring tech"*, 198-vs-17 is the number that weighs more.

**Money is not a differentiator.** Every money column here is `bigint`; both languages map it to a
native 64-bit integer with a compile error on mismatch. Rust's newtype is a modest extra.

**Async is settled enough.** AFIT/RPITIT stabilized in Rust 1.75 (2023-12-28). `dyn` compatibility is
an accepted 2026 Project Goal, not shipped; RTN is still nightly, so `Send` bounds on async traits
need `trait-variant`. The runtime story is a tokio monoculture with a dead tail — `async-std` is
sunset in favour of `smol`, and **`smol` has not released since 2.0.2 on 2024-09-07**.

**Hiring, weakly.** Stack Overflow 2025 (n=49,009; there is no 2026 survey): Go 16.40% vs Rust
14.84%, widening among professionals. Rust wins *admiration* 72.41% vs 56.46% — **a retention signal
among people who already cleared the learning curve, not a hiring pool.** UK IT Jobs Watch, 6 months
to 2026-08-26: Go 470 postings at £80k median, Rust 285 at £90k — one aggregator, one country, and
"Go" is a noisy search token. Do not let these harden into facts.

## What this spike could not verify

- **Compile-time scaling.** All timings are on ~420-line programs.
- **`pgx.Batch` pipelining in Rust.** No equivalent found; not benchmarked.
- **`NUMERIC` money.** Never exercised — every money column here is `bigint`. The `rust_decimal`
  (caps at 2⁹⁶−1, scale ≤ 28, fails on decode) and `bigdecimal` (runtime `22P03` on encode) facts
  come from reading sqlx's source, not from running them.
- **`underway`, `pg_task`, `sqlxmq` transactional enqueue.** Only `graphile_worker` was run.
  underway's sqlx version skew *is* verified; the rest is source-reading.
- **The 300 ms p99 auth target.** Never load-tested. Single-shot wall times were 5.5 ms (Go) and
  9.1 ms (Rust) including connection setup. **That is not a p99 and must not be quoted as one.**
- **sqlx's blocking-lock deadlock has no upstream bug report.** Searched `transact-rs/sqlx`
  (redirected from `launchbadge/sqlx`) and found nothing. Reproduced here; nobody appears to have
  written it down.

## Files

`bugs/A-omitted-case/` · `bugs/A2-decode/` · `bugs/B-silent-zero/` · `bugs/C-unconstructible/`,
each with a `go/` and an `rs/` side. The two full implementations, the migration harness and the job
harnesses were scratch and are not kept — [0004](../../docs/decisions/0004-where-logic-lives.md) is
the standing reason a spike does not graduate into the repository.
