# 0015 — Five crates plus a test crate, and the boundary is machine-enforced

**Status:** accepted.
**Evidence:** the tree — the root `Cargo.toml`, `deny.toml`, `clippy.toml`, the crate manifests —
and CI, which runs every check named here on every push (`.github/workflows/test.yml`).

## The decision

**The workspace is five library/binary crates plus one test-only crate, hexagonal by dependency
direction — and the boundary is machine-enforced, not conventional.** The single-crate binary this
repository started as could hold the same layering as a module layout and a code-review habit;
what it could not do is *refuse* a violation, because an in-crate module cannot be forbidden a
dependency. Splitting the crates is what gives the enforcement tooling a grain to grip.

| crate | job |
| --- | --- |
| **`ledger`** | The domain, the ports and the writer service: posting types, validation, the canonical idempotency hash, the pure posting math, the one-method `Ledger` trait, the outbound `Repository` port, and the `LedgerService` that orchestrates the use-case over it (hash, claim-or-replay, coalesce, upsert in id order, number, append, commit). **Zero sqlx — grep-provable**: no sqlx in its manifest, no sqlx type in its code, and `deny.toml` fails the build if that ever changes. |
| **`ledger-postgres`** | The adapter, a **nested member** at `crates/ledger/postgres` — its own manifest and its own deny.toml allowance, never a module; only the directory nests, the name stays flat. It implements the `Repository` port **where the SQL lives**: one trait method per SQL statement, all of the crate's SQL in one file with no forwarding layer between the port and the statements, and `begin`, which SETS `READ COMMITTED` rather than inheriting it. The orchestration that used to sit beside the SQL is `LedgerService`, in `ledger`. |
| **`db`** | Connections and migrations. A `Database` newtype that does **not** re-export `PgPool` — a re-export would hand every consumer the sqlx dialect back and make the ratchet decorative. Pool hardening lives here as this crate's decision, not the caller's: `after_connect` sets `statement_timeout = '30s'`, `lock_timeout = '10s'`, `idle_in_transaction_session_timeout = '60s'`; acquire times out at 15 s; the pool is `connect_lazy`, so startup's failure point is a readable message rather than a construction error. Also `migrate` ([0003](/decisions/0003-migrations) in code) and `verify_schema_is_current` — the **lock-free schema gate `serve` runs before listening**: plain SELECTs against `_sqlx_migrations`, refusing an unmigrated or behind database with the remedy in the message. Lock-free is the point, not an optimization — [0003](/decisions/0003-migrations)'s *"the ledger process never migrates"* only holds if serving never contends with a migrator, and this gate is the half of that split the serving process enforces. |
| **`api`** | The HTTP surface ([0014](/decisions/0014-http-api)): axum + utoipa, generic over the port — it consumes `ledger::Ledger` and never names the adapter or the pool. Its router state is a named `AppState` struct holding that one port, so a second port lands additively — reads will get their own port when the first read endpoint arrives. |
| **`openledger`** | The binary: clap's derive, the exit codes, and the **composition root** — the one place `PgRepository` is wired into `LedgerService`, and the service into the router as its `Ledger`. No sqlx, dev-dependencies included. |
| **`e2e`** | Test-only, and deliberately its own crate: it exists so the suite's capabilities — sqlx to read the oracle, reqwest to be a real caller, testcontainers for the no-`DATABASE_URL` fallback — are **allowed here, visibly and scoped**, in `deny.toml`'s map, instead of leaking onto a shipping crate. |

**The enforcement layer is five named mechanisms, and each one turns a convention into a failed
build.**

- **`deny.toml`'s capability-ownership bans are the ratchet.** Each entry names a capability crate
  and the only workspace crates allowed to speak it: `sqlx` → `db`, `ledger-postgres`, `e2e` (the
  domain crate deliberately absent — forbidding it sqlx outright is what the map exists for);
  `axum` → `api` (plus `tonic`, below); `utoipa` → `api`; `clap` → `openledger`; `reqwest` → `e2e`;
  `testcontainers` → `e2e` and its own modules crate — and the workspace's own edge crates are in
  the map too: `ledger-postgres` → `openledger` and `db` → `ledger-postgres`, `openledger`, which
  is what closes the api → adapter edge by machine rather than by review convention. A new crate
  reaching for any of these fails
  `cargo deny check`, so **a new wrapper is argued in review, never just appended** — the manifest
  edit and the policy edit are the same diff.
- **The advisories policy is strict, with its bookkeeping written before it is needed.**
  Vulnerable, unmaintained, unsound and yanked are all denied, over the whole graph
  **dev-dependencies included** — the e2e suite's tree runs on every contributor machine and in CI,
  which is exactly where a compromised crate wants to be. The ignore list is empty, and the
  convention for it is written down *now*: any future ignore must state the crate, the transitive
  path, and the removal condition, and a removed ignore stays as a tombstone comment. This policy
  is what refused `utoipa-axum` on day one ([0014](/decisions/0014-http-api)).
- **`clippy.toml` disallows the ambient clocks.** `SystemTime::now` and `Instant::now` are
  `disallowed-methods`: a ledger's time is the database's (`recorded_at`) or the caller's
  (`effective_at`), per [0006](/decisions/0006-time-and-as-of), and nothing in this codebase gets to
  invent a third clock ad hoc. The one legitimate use — the migrator's operator-facing lock budget
  and elapsed report — carries `#[expect(clippy::disallowed_methods)]` with its reason at each of
  the three call sites in `crates/db/src/migrate.rs`.
- **Suppressions are `#[expect]`, never `#[allow]`** — workspace-wide, beside the denied
  `unwrap`/`expect`/`panic` lints from [0001](/decisions/0001-rust-and-postgres): a suppression that
  stops suppressing must warn itself out, where an `#[allow]` outlives its reason silently.
- **`scripts/check-migrations-immutable.sh`** guards the migration set in CI — modified, renamed or
  deleted migrations fail, duplicate version prefixes fail, and a bad base ref refuses rather than
  passes vacuously. The reasoning is [0003](/decisions/0003-migrations)'s and is not restated here;
  what this ADR adds is that it sits in the same layer as the ratchet: a rule the machine holds so
  review does not have to.

**The port-error decoupling arrived from an unexpected direction.** `WriteError::Storage` carried
`sqlx::Error` while the adapter lived in the same crate, with a comment deferring the opaque wrapper
*"until a second adapter needs one."* The second consumer arrived — **as an enforcement requirement,
not an adapter**: the deny ratchet only means anything if the `ledger` crate names no sqlx type
anywhere, so the variant is now `Storage(Box<dyn std::error::Error + Send + Sync>)` and the Postgres
error type stays inside `crates/ledger/postgres`, boxed at exactly one function. What
[0004](/decisions/0004-where-logic-lives) decided still stands unbroken: the SQL in the adapter is
the product's reasoning about PostgreSQL, not an interchangeable backend, and no storage-agnostic
interface is pretended — the port is the ledger's contract, one method wide.

## What we considered

| | Why not |
| --- | --- |
| **Stay one crate** | The layering exists either way; the *refusal* does not. `cargo deny` bans resolve per crate, so a single crate can never be forbidden sqlx in its domain module — the boundary would remain a review habit, which is the "one service owns the writes" shape of guarantee [0004](/decisions/0004-where-logic-lives) already rejected one level down. |
| **Adapter co-located with the domain** (yesterday's shape) | ADR-0004's original reasoning — PostgreSQL is half the product — argued for co-location, and it is superseded by the ratchet argument: the ban is only meaningful if the crate holding the domain can be forbidden sqlx outright. The crate-level doc in `crates/ledger/src/lib.rs` records the supersession. |
| **A separate `ports` crate** | A sixth manifest to hold one trait and one enum. The port lives in the domain crate it constrains; nothing consumes the trait without the types it mentions, so the split buys a boundary nothing crosses. |
| **The e2e suite as the binary crate's `tests/`** | It would get `CARGO_BIN_EXE_openledger` for free — cargo sets it only for the package that defines the binary — but the suite's capabilities (sqlx, reqwest, testcontainers) would land on the shipping binary's manifest as dev-dependencies, invisible to the capability map's grain. The trade taken: the suite resolves the binary from its own `current_exe` location instead (the same resolution `assert_cmd` uses), and `make test` and CI build the binary explicitly first. |
| **Mock the port and test the API against a fake** | The database is the product. A mock verifies the mapping against an imagined writer; the suite's whole design is a real binary, a real PostgreSQL, and `SELECT * FROM reconciliation` as the oracle — the checks that exist because imagining is how ledgers drift. |
| **`cargo-hakari` / a workspace-hack crate** | Its value is eliminating feature-unification rebuild thrash between build contexts, and measured on 2026-08-28 there is none to eliminate: cycling `cargo build` ↔ `cargo test --workspace` ↔ `cargo check` ↔ `--workspace` ↔ clippy recompiles **zero** third-party dependencies warm. The costs are concrete here: a generated crate on every manifest, a CI freshness job, and a `workspace-hack` wrapper on every capability ban — hakari names sqlx, axum and clap directly by design — diluting the map this ADR exists to keep readable. Re-adopt if that same cycle ever measures nonzero, if `cargo build -p` workflows come to dominate a much larger workspace, or if CI dependency rebuilds start costing real wall-clock; and mind hakari's platform list, which can silently shift dep features on other architectures — a hazard to the byte-deterministic `openapi.json`. |

## What it costs

- **Six manifests where there was one**, each with its own comment burden, plus `Cargo.lock` churn
  whenever the workspace graph moves — a bump in one crate re-litigates the skip list's duplicate
  pairs, and `deny.toml` says so beside each skip.
- **The capability map must be maintained to stay true.** It is a list of claims about the graph,
  and the graph moves under it: a dependency reorganising its internals can add or drop a direct
  parent and the map must follow. The compensation is the failure direction — a stale map fails the
  build loudly rather than rotting silently.
- **`tonic` sits in the axum wrapper list, and it is not ours.** bollard's buildkit gRPC stack —
  dev-only, under testcontainers — serves its streams over axum, and a wrapper entry must name every
  direct parent in the graph, workspace or not. It grants no workspace crate anything; it is noise
  the map's precision forces us to carry, documented inline so nobody reads it as a capability.
- **The behind-schema and checksum branches of the serve gate are held by surgical fixtures, not
  real history.** `startup.rs` now proves all three refusals — never migrated, *behind this binary*,
  checksum mismatch — but the last two are staged by editing `_sqlx_migrations` on a scratch
  database (a deleted version row; a doctored checksum), because an honest fixture means a migration
  the database lacks, and slipping a test-only migration into `migrations/` and removing it later is
  itself the edit `check-migrations-immutable.sh` exists to refuse. The surgery touches only sqlx's
  bookkeeping table, never the schema or `migrations/`; the day migration `00002` exists, a
  mid-upgrade fixture becomes real history and can replace it.
