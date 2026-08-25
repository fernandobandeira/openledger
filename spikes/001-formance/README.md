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

Our [v1 vision](../../docs/v1-vision.md) asserts a lot of design without showing the failures that
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
   This is [milestone 2 of our roadmap](../../docs/roadmap.md) and the most likely place to get it
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

Anything that contradicts [v1-vision.md](../../docs/v1-vision.md) gets an ADR, not a silent edit to
the vision doc.

## Findings

Read at `formancehq/ledger` **`25f8708bba638c1951a5a2180d0dafbb566474be`** (2026-08-18, HEAD of
`main`): all 54 migrations in `internal/storage/bucket/migrations/`, the storage layer, the
write path, plus docs and issue tracker.

Their migration history is unusually legible — names like `27-fix-invalid-pcv`,
`28-fix-pcv-missing-asset`, `29-fix-invalid-metadata-on-reverts`. The failure history is in the
repo, which is exactly what this spike was for.

### Q1, the headline: they built our design, hit a wall, and demoted it

- **v1** stored `moves.post_commit_volumes` as the only balance — computed in plpgsql from the
  previous move. That is our `balance_after`, one for one.
- **Migration 11 (`make-stateless`)** added `accounts_volumes`, a separate current-balance table
  keyed `(ledger, account, asset)`, backfilled it, and made the running-balance columns
  **nullable**.
- The write order then **inverted**: the balance table is updated first, and each move's running
  balance is derived from the returned totals. The running balance became a *projection of* the
  balance table rather than its source.
- It is now behind feature flags (`MOVES_HISTORY`, `MOVES_HISTORY_POST_COMMIT_EFFECTIVE_VOLUMES`),
  off in their `MinimalFeatureSet`, and off in their own stress test.

**The reason is backdating, not scale.** They keep two running balances on two time axes, and
the effective-axis one is *not* immutable — a trigger does an unbounded
`UPDATE ... WHERE effective_date > new.effective_date` across every later row for that account.
Migration 10 is `alter table moves set (fillfactor = 80)`: a fillfactor tune exists only because
their journal table is UPDATE-heavy. **Six migrations exist purely to repair volume data.**

Their own docs: *"Even by freezing the ledger at a date T, effective volumes can move, because
you can insert transactions before that date."*

### Verified against our own schema

The claim that this is a live gap in our design was worth checking rather than accepting, so it
was reproduced on our schema. Three entries, insertion order ≠ effective order:

| account_seq | effective | amount | balance_after |
| --- | --- | --- | --- |
| 1 | 2026-01-10 | +100 | 100 |
| 2 | 2026-01-30 | +50 | 150 |
| 3 | 2026-01-20 | +30 | **180** |

Balance as of **2026-01-25**:
- running-balance lookup (`effective_at <= T ORDER BY account_seq DESC LIMIT 1`) → **180**
- ground truth (aggregate over `effective_at <= T`) → **130**

It silently includes the Jan 30 entry, because that row has a *lower* `account_seq` than the
backdated Jan 20 one. On the **recorded** axis both queries agree.

**Precise conclusion — narrower than the raw finding.** The vision doc's as-of query is written
against `recorded_at`, and on that axis it is *correct*. The gap is that the doc's stated
*purpose* for as-of queries — reproducible lender reporting, "as of June 30", statement cycles —
is a **business-date** question, and on the effective axis `balance_after` is unusable the moment
anything is backdated. In this domain backdating is guaranteed: `effective_at` is the network
business date, and late clearing and chargebacks are inherently backdated.

Resolved in [ADR-0003](../../docs/decisions/0003-bitemporal-balances.md).

### COPY — adopted into the schema

Applied to [`spikes/002-sqlc-vs-jet/schema.sql`](../002-sqlc-vs-jet/schema.sql) and
verified by [`invariants.sql`](../002-sqlc-vs-jet/invariants.sql):

1. **Tenant-scope the idempotency key.** Their sequence is a cautionary tale: migration 5 shipped
   a *non-unique* index, migration 7 had to de-duplicate production rows before adding
   `unique (idempotency_key)`, migration 8 re-scoped it to `unique (ledger, idempotency_key)`.
   Ours was globally unique — migration 7's mistake. Now `(tenant_id, idempotency_key)`.
   ⚠️ **With `NULLS NOT DISTINCT`** — without it the index does not constrain house-scoped rows
   at all, the same `NULL != NULL` trap the vision doc calls out for house accounts. Our first
   version had this bug and T7 caught it.
2. **Store a hash of the request body next to the key.** Same key + same hash → replay the stored
   result. Same key + *different* hash → reject. Ours stored the key only; without the hash a
   caller bug silently returns the wrong stored result. Added `idempotency_hash bytea NOT NULL`.
3. **Guard double-reversal declaratively.** They use `UPDATE ... WHERE reverted_at IS NULL` and
   check the row count — unavailable to us, since we refuse to mutate. `UNIQUE (reverses_id)
   WHERE NOT NULL` and the same for `resolves_id` give the identical property. Nothing previously
   stopped two concurrent reversals of one transaction. Verified by T9.
4. **Denormalize `effective_at` onto `ledger_entries`** so the effective-axis aggregate is a
   single-table index scan rather than a join. Formance puts `effective_date` on `moves` for
   exactly this reason.

### COPY — for M1/M2, not yet applied

5. **Get the balance and the next sequence number from one atomic upsert.** Their
   `INSERT ... ON CONFLICT ... DO UPDATE SET input = input + excluded.input RETURNING input, output`
   makes the row lock itself the serialization point — no `SELECT max()`, no advisory lock, no
   retry loop. Note our `UNIQUE (account_id, account_seq)` *creates* a concurrency problem they
   do not have (their `moves.seq` is a plain global bigserial, which cannot collide). Extending
   their upsert with `last_seq = last_seq + 1 RETURNING balance, last_seq` is strictly better
   than both our sketch and theirs. **This is the answer to roadmap M2.**
6. **Insert the zero-balance row before locking it.** You cannot `FOR UPDATE` a row that does not
   exist, so two writers race on an account's *first* entry. They do a
   `WITH ins AS (INSERT ... ON CONFLICT DO NOTHING)` then `FOR UPDATE`. We have this hole today.
7. **Deterministic lock ordering, everywhere.** Sorted by `(account, asset)` on both read and
   write paths, and the same table order in every operation. This was a real deadlock fix for
   them (PR #767, backported). Cheap; do it from day one.
8. **Ship a test with every data-repair migration** — `up_tests_before.sql` seeds the broken
   state, `up_tests_after.sql` asserts the repair. Plus a test that restores a production dump and
   runs the whole chain. For an append-only ledger where a bad backfill is unrecoverable, this is
   the highest-leverage practice in their repo.
9. **Backfill technique on append-only tables (Q6).** They have no grant restrictions at all — the
   app role has full DML — so they never faced our constraint, and the real answer to "how do you
   backfill with no UPDATE grant" is *run migrations as a different role*. Techniques worth
   taking: batched `DO $$ ... commit; end loop $$` backfills; the zero-downtime NOT NULL dance
   (`ADD CONSTRAINT ... NOT VALID` → `VALIDATE CONSTRAINT` → `SET NOT NULL` → `DROP CONSTRAINT`);
   `ADD PRIMARY KEY USING INDEX` to promote an existing index without a rebuild.
10. **Name the time axis in the API.** Their read endpoints take `pit` plus an explicit
    `useInsertionDate` selector. Naming the axis is what stops "as of" ambiguity becoming a
    support incident.

### DELIBERATELY DIVERGE

1. **Keep `category` + `normal_balance` as typed columns.** Formance has **no accounting
   semantics at all** — balance is `input - output`, so a liability reads negative, and their
   "chart of accounts" is an address *naming grammar* whose rules type is literally
   `struct{}`. They cannot produce a trial balance without an external mapping layer. We have a
   lender who wants collateral reporting. They offer no counter-evidence to our decision not to
   derive `normal_balance` from `category`, because they never modelled either.
2. **Keep `status` / `resolves_id`.** They have no pending/authorization/hold concept — users
   model a hold by moving money to a hold *account*. Auth → clearing → settlement, with the
   amount difference as the norm, is our core domain. Corollary worth copying though: because
   they have no partial state they have **no partial reversal** — corrections are ordinary new
   transactions. That is the right model; keep our `status`, adopt their conclusion.
3. **Do not put ledger logic in plpgsql.** Migration 37 is the demolition of their v1: it drops
   ~26 stored functions including `handle_log()`, `insert_transaction()`, `insert_move()`. The
   trigger-cascade design was ripped out and moved into Go. We have one writer and no second
   consumer needing the DB to enforce the cascade. Keep logic in Go; the DB does constraints and
   locks.
4. **Do not build a feature-flag system.** Theirs exists to serve every customer's cost tradeoff.
   It has a nasty failure mode — issue #1416: a PIT query silently returns `{}` when a
   historization flag is off. Configurable historization means as-of queries that are *wrong*
   rather than loud. Hardcode.
5. **Skip everything built for scale**: async log hashing and `logs_blocks`, buckets and
   `_system.ledgers`, per-ledger dynamic triggers, connection-pool backoff handling, the gin
   indexes on address arrays, `moves` fillfactor tuning (only needed because they UPDATE moves —
   we will not), Numscript and its VM, and the whole `internal/replication` tree.
6. **Bound the deadlock retry loop.** Theirs retries `ErrDeadlockDetected` with an unbounded
   `continue`, no backoff. At our volume a livelock is a page, not a metric.
7. **Colon-delimited string addresses.** They encode taxonomy in `assets:cash:usd` with jsonb
   segment arrays and gin indexes, which is why they needed a SQL-injection fix in the address
   filter as recently as this year. Our typed `owner_type`/`owner_id`/`purpose` columns are
   better for a fixed product.

### Correction to a common assumption (Q4)

**Formance enforces balancing structurally, not with any constraint.** Their primitive is
`Posting{Source, Destination, Asset, Amount}` — a balanced pair by construction. There is no
CHECK, no trigger; the only balance assertion in the schema is a one-off `ASSERT` during a
migration backfill. The "debits always equal credits" line is marketing, not a runtime guarantee.

Our entries are independent rows with a `direction`, so we *can* express an unbalanced
transaction and therefore *must* enforce it. Take both layers: make the write API accept balanced
pairs only (make the illegal state unrepresentable — the actual Formance lesson), **and** keep
the deferred constraint trigger as a backstop. At our volume the trigger is free and it converts
a class of silent corruption into a failed insert.

### OPEN — promoted to work

- **Effective-axis balances** → [ADR-0003](../../docs/decisions/0003-bitemporal-balances.md).
- **`recorded_at <= T` is not reproducible under concurrency.** `recorded_at` is not monotonic
  with *commit* order: a transaction starting at T1 and committing at T3 writes `recorded_at=T1`,
  while one starting at T2 > T1 and committing at T2.5 writes T2. The same "as of T" report run
  later can differ. For a lender-facing *reproducible* balance the cursor must be a
  **commit-ordered sequence, not a wall clock**. Our `account_seq` is per-account, so this needs
  a global monotonic entry id, or an explicit "as of entry #N". **The vision doc's claim that
  as-of is "the same lookup, one more predicate" does not survive concurrent writers.**
- **We have no event log, and probably need one.** Their `logs` table is the real source of
  truth; everything else is a projection, and they rebuild a ledger by replaying it. Our
  idempotency key lives on `ledger_transactions`, so we can only dedupe things that *produce* a
  transaction — a declined authorization, a limit change, an account opening have no home and
  cannot be made idempotent. **This is the one table from their schema we are genuinely missing.**
- **Tamper evidence is nearly free at our volume.** Their `logs.hash` chains each row to the
  previous, which under SYNC takes an advisory lock and serializes every write — the reason their
  ASYNC block-hashing exists. At under 1 TPS that serialization is free and the lender value is
  real. Take the per-row chain; never build the blocks.
- **Metadata mutability defeats reproducibility.** They maintain metadata *revision* tables
  precisely because a mutable jsonb blob cannot answer "what did we believe at time T". Our
  `metadata jsonb` is mutable with no history. If any of it feeds collateral reporting, it needs
  history — cheapest path is to make metadata changes *be* log entries.
- **Benchmark the hot account.** Their docs warn that locks are per (account, asset) and high
  concurrency on one source account serializes. Our credit-line account is touched by every
  transaction. Their design target is 1K writes/sec, but issue #1363 documents a real user hitting
  a knee at **~8–12 TPS** on a single ledger. Our 20–50 TPS peak is not automatically safe.
- **Every table needs a PK / replica identity from day one.** Migration 45 is
  `fix-missing-primary-keys` — they shipped releases with no PK on `transactions`, `accounts`, or
  `logs`. Logical replication and CDC require one. Related trap: dropping a column silently drops
  its indexes.
- **`NOT VALID` constraints must actually get validated.** Their migration 19 adds one and nothing
  ever validates it, so it constrains new rows only. If we use that technique, a follow-up
  migration must run `VALIDATE CONSTRAINT` or we are lying to ourselves about our invariants.


---

## Addendum — table design pass

A second pass answering "what about the design of tables". Method matters here: all 54 bucket
migrations were applied **to a real Postgres in order** and the result `pg_dump`ed, so the DDL
below is the actual end state at HEAD rather than a reading of the migration files. Index claims
come from `pg_indexes` / `pg_constraint` and `EXPLAIN (ANALYZE, BUFFERS)` over 400k seeded rows.

Three findings that only that method surfaces:

1. **`moves` has no index supporting a running-balance lookup.** Migration 0 had
   `(accounts_seq, asset, seq)`. Migration 37 dropped the `accounts_seq` column, Postgres
   silently dropped the indexes with it, and nothing recreated them on `accounts_address`.
   **Their point-in-time balance read is a scan-and-sort of the account's whole history** —
   measured at 809 buffers with `Sort Key: asset, seq DESC`.
2. **Zero foreign keys in the entire bucket schema.** Not one.
3. **All four CHECK constraints are `NOT VALID` and none was ever validated.** They constrain
   new rows only.

The pattern behind most of their schema debt is a single mechanism: **dropping a column silently
drops its indexes and constraints, and nothing in their process caught it.** Four separate
regressions trace to migrations 37 and 46 alone. That is what
[ADR-0006's snapshot test](../../docs/decisions/0006-schema-conventions.md) exists to prevent.

### Verified against our schema, and the result was not what the headline implied

The 809 → 4 buffer improvement is real *for them*, because their composite index is missing.
**Ours already has the right index**, so the only thing left to gain was the heap fetch. Measured
on our schema, 400k rows:

| Index | Plan | Heap Fetches | Size |
| --- | --- | --- | --- |
| `(account_id, account_seq DESC)` | Index Scan | — | 16 MB |
| `... INCLUDE (balance_after)` | Index **Only** Scan | 0 (settled) | 19 MB |
| `... INCLUDE (balance_after)` | Index Only Scan | **1 (fresh row)** | 19 MB |

The third row is the one that matters. Index-only scans need the visibility map bit, which is
set by vacuum — so on a **freshly inserted row, which is exactly what the auth hot path reads**,
the heap fetch happens anyway. `INCLUDE` is justified by as-of reporting over settled history,
not by the hot path. Adopted with that rationale recorded in the schema, per
[ADR-0006 §6](../../docs/decisions/0006-schema-conventions.md).

The mirror image is why their covering index on `accounts_volumes` is a mistake: it duplicates
the PK's key columns on an **UPDATE-heavy** table, paying two index writes per posting to save a
heap fetch the visibility map will mostly deny it.

### `logs` — the DDL we are designing ADR-0004 from

```sql
CREATE TABLE logs (
    ledger           varchar NOT NULL,
    id               numeric NOT NULL,     -- per-ledger sequence
    type             log_type NOT NULL,
    hash             bytea,
    date             timestamp without time zone NOT NULL DEFAULT transaction_date(),
    data             jsonb   NOT NULL,     -- full payload, for replay and reads
    idempotency_key  varchar(255),
    memento          bytea,                -- canonical hash input (migration 23)
    idempotency_hash bytea,
    schema_version   text
);
ALTER TABLE logs ADD CONSTRAINT logs_ledger PRIMARY KEY (ledger, id);
CREATE UNIQUE INDEX logs_idempotency_key ON logs (ledger, idempotency_key);
```

**The `data` / `memento` split is the best idea in their schema.** `data` is the full payload for
replay. `memento` is a *separate canonical byte form used only as hash input*, and it
deliberately excludes derived fields — their comment: *"We don't want those fields to be part of
the hash as they are not part of the decision-making process."*

The chain therefore covers **the decision, not the derived state**, which means recomputing a
balance never invalidates tamper evidence. Get this wrong and every backfill breaks the chain.
Folded into [ADR-0004](../../docs/decisions/0004-event-log.md).

The hash input also pins `"id":0` and `"hash":null` so the digest is position-independent. The
predecessor lookup rides the PK as a backward index scan and is cheap — but it must see a stable
predecessor, which is why every write takes `pg_advisory_xact_lock(ledger_id)` and serializes.

### On our open ordering question — they have no answer

Directly relevant to [ADR-0005](../../docs/decisions/0005-reproducible-as-of.md), and worth stating
plainly: **Formance has no commit-ordered total order anywhere in their schema.**

- `transaction_date()` seeds from `statement_timestamp()` — start-ordered. It guarantees
  intra-transaction consistency (all rows of one operation share a timestamp) and nothing more.
- `bigserial` does not help either: `nextval` is also called at statement time, so `seq` is
  start-ordered too.
- Their per-ledger sequences carry an explicit comment that they accept gaps: *"we can still
  have 'holes' on ids since a sql transaction can be reverted after a usage of the sequence."*

So `WHERE recorded_at <= T` is not reproducible for them either, and they do nothing about it.
This raises confidence that ADR-0005 is a real problem rather than an over-reading, and lowers
confidence that a clever solution exists — **the agent's own recommendation was our option (c):
make "as of" mean "as of entry id N" and hand the lender an id, not a timestamp.**

### Column-type choices — what cost them

| Choice | Outcome |
| --- | --- |
| `numeric` for ids (`transactions.id`, `logs.id`) | Cross-type comparisons against `bigint` columns made an index unusable in a trigger; migration 44 (`fix-seq-scan-in-plpgsql`) exists solely to add a `::bigint` cast. They cannot fix the root cause — narrowing now needs a table lock. |
| `postings varchar` holding JSON | The canonical record of money movement is a string. Four shadow jsonb columns and three GIN indexes exist to make it queryable. Repeated in `exporters.config`. |
| `timestamp` (no zone) everywhere | UTC held by convention, not constraint. Migration 33 is `fix-invalid-date-format`. |
| `numeric` for `amount` | Correct for *them* — arbitrary-precision multi-asset. Not for us; `bigint` minor units are cheaper and comparable. |
| `volumes` composite type `(inputs, outputs)` | Genuinely elegant — the pair moves atomically. Simpler as two `bigint` columns for us. |
| `input`/`output` kept separate, not one signed balance | **Worth stealing.** Makes the upsert commutative and additive in both directions, gives gross turnover free, and no row needs to know the sign convention. |

### Naming and conventions

Tables plural snake_case, no prefixes; cross-table references named `<plural_table>_<column>`
(`accounts_address`, `transactions_id`) — unusual but unambiguous about the target, worth
adopting. Constraints named clearly.

**Indexes are named inconsistently and it cost them.** `accounts_ledger` and `logs_ledger` are
composite PKs, not indexes on `ledger`. `accounts_metadata_idx` is on `accounts`, not
`accounts_metadata` — and that name is exactly why a missing index on a hot write path went
unnoticed for thirty migrations. `_idx` / `_index` / no-suffix / `2`-suffixes all coexist.
Column names drift badly too: `date`, `timestamp`, `insertion_date`, `inserted_at`, `added_at`,
`addedat`, `created_at` all appear, several meaning the same thing.

→ [ADR-0006 §1](../../docs/decisions/0006-schema-conventions.md).

### Their unfixed bugs, as a checklist of what to avoid

1. `moves` lost its running-balance index to a column drop (migration 37).
2. `accounts_metadata` has no btree index — every metadata write sequentially scans the whole
   revision history. The transactions side was fixed; this side never was.
3. No unique constraint on `(ledger, id, revision)` in either metadata table. Revision
   uniqueness rests on an unsynchronised `max()+1` inside a trigger; two concurrent updates
   produce duplicates.
4. Four `NOT VALID` CHECK constraints, none validated.
5. Zero foreign keys.
6. Redundant indexes on the hottest tables — `moves_account_address` is a strict prefix of
   `moves_range_dates`; `moves_ledger` and `moves_asset` are near-zero cardinality.
7. `address_array` is orphaned: nullable, no default, its populating trigger dropped in migration
   46, yet it still carries a GIN index *and* an expression index. Population depends entirely on
   Go remembering.
8. `logs_blocks` shipped with PK `(previous)` alone, so two ledgers in one bucket collided on
   block 0 (fixed in migration 53). **Our `tenant_id` must be in every natural key.**
9. Go struct tags contradict the schema — `varchar(256)` vs `varchar(255)`, `timestamptz` vs
   `timestamp`, `unique` declared where no index exists.
