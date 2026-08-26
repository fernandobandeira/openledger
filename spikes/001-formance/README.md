# Spike 001 — Learn from Formance

**The question.** Formance Ledger is an open-source double-entry ledger run against real money in
production, with its schema, migration history and issue tracker all public. Which of our design
assertions does their experience confirm, and which does it contradict?

**Status:** closed. Produced [ADR-0003](../../docs/decisions/0003-bitemporal-balances.md),
[0004](../../docs/decisions/0004-event-log.md),
[0005](../../docs/decisions/0005-reproducible-as-of.md),
[0006](../../docs/decisions/0006-schema-conventions.md).
**Explicit non-goal:** adopting Formance. Prior art, not a dependency decision.

---

## The answer

**They built our design, hit a wall, and demoted it — but only half of it, and it's the half we
don't have.**

We carry a *running balance* (`balance_after`) on every entry: the account's balance immediately
after that entry, so reading the current balance is one index lookup instead of summing history.
Formance did the same, then migration 11 made it a *projection* of a separate balance table and
put it behind a feature flag that's off in their own minimal configuration.

**The reason was backdating, not scale** — and this is the distinction that matters:

| their column | time axis | their own comment |
| --- | --- | --- |
| `post_commit_volumes` | insertion order | *"Those volumes will never change, as those are computed in flight."* |
| `post_commit_effective_volumes` | business date | *"can be updated if a transaction is inserted in the past."* |

*Backdating* means an entry arriving today that is economically dated last week — routine in
payments, because a clearing carries the network's business date. On the **effective** axis a
backdated entry invalidates every later running balance, so their trigger runs an unbounded
`UPDATE … WHERE effective_date > new.effective_date`. Migration 10 sets `fillfactor = 80` on the journal. The fill factor is verified at the pinned
commit; the REASON is OUR INFERENCE -- `notes.yaml` reads only "Define fill factor of moves table"
-- and we infer it is because the table became UPDATE-heavy. Six migrations touch volume/pcv
aggregation
afterwards — **three of them repairing data** (19, 20, 28), two replacing functions, and one
(`27-fix-invalid-pcv`) a no-op stub. An earlier version of this line said all six "exist solely to
repair volume data"; fetched at the pinned commit, that is not what they do.

**Our `balance_after` is their immutable one.** It is ordered by `account_seq`, assigned on
insertion, so a backdated entry gets the *next* sequence number and its own balance; nothing
already written changes. The lesson is not "running balances are bad" — it is **"a running
balance on a mutable axis is bad"**, and we keep only the immutable one.

## What it cost us

We verified the failure mode on our own schema rather than accepting it. Three entries, insertion
order ≠ effective order:

| account_seq | effective | amount | balance_after |
| --- | --- | --- | --- |
| 1 | 2026-01-10 | +100 | 100 |
| 2 | 2026-01-30 | +50 | 150 |
| 3 | 2026-01-20 | +30 | **180** |

Balance as of 2026-01-25: the running-balance lookup returns **180**, ground truth is **130**. It
silently includes the Jan 30 entry, because the backdated row has a *higher* `account_seq`.

**On the recorded axis both queries agree.** So the vision doc's as-of query is correct as
written — the gap is that its stated *purpose* (reproducible lender reporting, "as of June 30")
is a business-date question, and on that axis `balance_after` is unusable the moment anything is
backdated. Resolved in [ADR-0003](../../docs/decisions/0003-bitemporal-balances.md): keep the
running balance for the recorded axis, aggregate on read for the effective axis.

---

# The evidence

Read at `formancehq/ledger` **`25f8708bba638c1951a5a2180d0dafbb566474be`** (2026-08-18, HEAD of
`main`): all 54 migrations, the storage layer, the write path, docs and issue tracker. Their
migration names are unusually legible — `27-fix-invalid-pcv`, `28-fix-pcv-missing-asset`,
`29-fix-invalid-metadata-on-reverts`. The failure history is in the repo.

For the table-design pass, all 54 migrations were applied to a real Postgres in order and the
result `pg_dump`ed, so the DDL below is the actual end state rather than a reading of the
migration files.

## COPY — already applied to the schema

Applied to [`spikes/002-sqlc-vs-jet/schema.sql`](../002-sqlc-vs-jet/schema.sql) and verified by
[`invariants.sql`](../002-sqlc-vs-jet/invariants.sql):

1. **Tenant-scope the idempotency key.** Their sequence is a cautionary tale: migration 5 shipped a
   *non-unique* index, migration 7 had to de-duplicate production rows before adding
   `unique (idempotency_key)`, migration 8 re-scoped it to `unique (ledger, idempotency_key)`. Ours
   was globally unique — migration 7's mistake. Now `(tenant_id, idempotency_key)`, **with
   `NULLS NOT DISTINCT`**: without that clause the index doesn't constrain house-scoped rows at
   all, the same `NULL != NULL` trap the vision doc calls out for house accounts. Our first version
   had this bug and the invariant test caught it.
2. **Store a hash of the request body next to the key.** Same key + same hash → replay the stored
   result; same key + *different* hash → reject. Without the hash a caller bug silently returns the
   wrong stored result.
3. **Guard double-reversal declaratively.** They use `UPDATE … WHERE reverted_at IS NULL` and check
   the row count — unavailable to us, since we never mutate. `UNIQUE (reverses_id) WHERE NOT NULL`
   and the same for `resolves_id` give the identical property. Nothing previously stopped two
   concurrent reversals.
4. **Denormalize `effective_at` onto entries** so the effective-axis aggregate is a single-table
   index scan rather than a join. Formance puts `effective_date` on `moves` for the same reason.

## COPY — for M1/M2, not yet applied

5. **Get the balance and the next sequence number from one atomic upsert.**
   `INSERT … ON CONFLICT … DO UPDATE SET input = input + excluded.input RETURNING input, output`
   makes the row lock itself the serialization point — no `SELECT max()`, no advisory lock, no
   retry loop. Note our `UNIQUE (account_id, account_seq)` *creates* a concurrency problem they
   don't have (their `moves.seq` is a plain global bigserial, which can't collide). Extending their
   upsert with `last_seq = last_seq + 1 RETURNING balance, last_seq` beats both. **This is the
   answer to roadmap M2.**
6. **Insert the zero-balance row before locking it.** You can't `FOR UPDATE` a row that doesn't
   exist, so two writers race on an account's *first* entry. We have this hole today.
7. **Deterministic lock ordering, everywhere.** Sorted by `(account, asset)` on both read and write
   paths. A real deadlock fix for them (PR #767, backported). Cheap; do it from day one.
8. **Ship a test with every data-repair migration** — `up_tests_before.sql` seeds the broken state,
   `up_tests_after.sql` asserts the repair, plus a test restoring a production dump and running the
   whole chain. For an append-only ledger where a bad backfill is unrecoverable, this is the
   highest-leverage practice in their repo.
9. **Backfill technique on append-only tables.** They have no grant restrictions, so they never
   faced our "app role has no UPDATE" constraint — the real answer is *run migrations as a
   different role*. Techniques worth taking: batched `DO $$ … commit; end loop $$`; the
   zero-downtime NOT NULL dance (`ADD CONSTRAINT … NOT VALID` → `VALIDATE CONSTRAINT` →
   `SET NOT NULL` → `DROP CONSTRAINT`); `ADD PRIMARY KEY USING INDEX` to promote an existing index
   without a rebuild.
10. **Name the time axis in the API.** Their read endpoints take `pit` plus an explicit
    `useInsertionDate` selector. Naming the axis is what stops "as of" ambiguity becoming a support
    incident.

## DELIBERATELY DIVERGE

1. **Keep `category` + `normal_balance` as typed columns.** Formance has **no accounting semantics
   at all** — balance is `input - output`, so a liability reads negative, and their "chart of
   accounts" is an address *naming grammar* whose rules type is literally `struct{}`. They cannot
   produce a trial balance without an external mapping layer. They offer no counter-evidence to our
   design because they never modelled either.
2. **Keep `status` / `resolves_id`.** They have no pending/authorization/hold concept — users model
   a hold by moving money to a hold *account*. Auth → clearing → settlement, with the amount
   difference as the norm, is our core domain. Corollary worth copying: because they have no partial
   state they have **no partial reversal** — corrections are ordinary new transactions. Right model;
   keep our `status`, adopt their conclusion.
3. **Do not put ledger logic in plpgsql.** Migration 37 is the demolition of their v1: it drops **27**
   stored functions including `handle_log()`, `insert_transaction()`, `insert_move()`. The
   trigger-cascade design was ripped out and moved into Go. Keep logic in Go; the DB does
   constraints and locks.
4. **Do not build a feature-flag system.** Theirs serves every customer's cost tradeoff, and has a
   nasty failure mode — issue #1416: a point-in-time query silently returns `{}` when a
   historization flag is off. **Configurable historization means as-of queries that are *wrong*
   rather than loud.** Hardcode.
5. **Skip everything built for scale**: async log hashing and `logs_blocks`, buckets and
   `_system.ledgers`, per-ledger dynamic triggers, connection-pool backoff, gin indexes on address
   arrays, `moves` fillfactor tuning, Numscript and its VM, the whole `internal/replication` tree.
6. **Bound the deadlock retry loop.** Theirs retries with an unbounded `continue` and no backoff. At
   our volume a livelock is a page, not a metric.
7. **Colon-delimited string addresses.** They encode taxonomy in `assets:cash:usd` with jsonb
   segment arrays and gin indexes — which is why they needed a SQL-injection fix in the address
   filter this year. Our typed `owner_type`/`owner_id`/`purpose` columns are better for a fixed
   product.

## Correction to a common assumption

**Formance enforces balancing structurally, not with any constraint.** Their primitive is
`Posting{Source, Destination, Asset, Amount}` — a balanced pair by construction. There is no CHECK,
no trigger; the only balance assertion in the schema is a one-off `ASSERT` during a migration
backfill. The "debits always equal credits" line is marketing, not a runtime guarantee.

Our entries are independent rows with a `direction`, so we *can* express an unbalanced transaction
and therefore *must* enforce it. Take both layers: make the write API accept balanced pairs only
(make the illegal state unrepresentable — the actual Formance lesson), **and** keep the deferred
constraint trigger as a backstop.

## Table design

Three findings only the apply-and-dump method surfaces:

1. **`moves` has no index supporting a running-balance lookup.** Migration 0 had
   `(accounts_seq, asset, seq)`. Migration 37 dropped the `accounts_seq` column, Postgres silently
   dropped the indexes with it, and nothing recreated them. **Their point-in-time balance read is a
   scan-and-sort of the account's whole history** — measured at 809 buffers with
   `Sort Key: asset, seq DESC`.
2. **Zero foreign keys in the entire bucket schema.** Not one.
3. **Five of their nine CHECK constraints are `NOT VALID` and were never validated.** An earlier
   version of this line said "all four ... none was ever validated", which is wrong twice: there
   are nine, and **four of them WERE validated**, in migration 40, using precisely the
   `ADD ... NOT VALID -> VALIDATE CONSTRAINT -> SET NOT NULL -> DROP CONSTRAINT` dance this file
   recommends stealing sixty lines above. The five that were not constrain new
   rows only.

The pattern behind most of their schema debt is one mechanism: **dropping a column silently drops
its indexes and constraints, and nothing in their process caught it.** Four separate regressions
trace to migrations 37 and 46 alone. That is what
[ADR-0006's snapshot test](../../docs/decisions/0006-schema-conventions.md) exists to prevent.

### Verified against our schema — and the headline didn't transfer

The 809 → 4 buffer improvement is real *for them*, because their composite index is missing. **Ours
already has the right index**, so the only thing left to gain was the heap fetch:

| Index | Plan | Heap Fetches | Size |
| --- | --- | --- | --- |
| `(account_id, account_seq DESC)` | Index Scan | — | 16 MB |
| `… INCLUDE (balance_after)` | Index **Only** Scan | 0 (settled rows) | 19 MB |
| `… INCLUDE (balance_after)` | Index Only Scan | **1 (fresh row)** | 19 MB |

The third row is the one that matters. Index-only scans need the visibility-map bit, set by vacuum
— so on a **freshly inserted row, which is exactly what the auth hot path reads**, the heap fetch
happens anyway. `INCLUDE` is justified by as-of reporting over settled history, not by the hot
path. Adopted with that rationale recorded in the schema.

The mirror image is why their covering index on `accounts_volumes` is a mistake: it duplicates the
PK's key columns on an **UPDATE-heavy** table, paying two index writes per posting to save a heap
fetch the visibility map will mostly deny.

### `logs` — the DDL behind ADR-0004

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
replay; `memento` is a *separate canonical byte form used only as hash input*, deliberately
excluding derived fields — their comment: *"We don't want those fields to be part of the hash as
they are not part of the decision-making process."* The tamper-evidence chain therefore covers
**the decision, not the derived state**, so recomputing a balance never invalidates it. Get this
wrong and every backfill breaks the chain. Folded into
[ADR-0004](../../docs/decisions/0004-event-log.md).

The hash input also pins `"id":0` and `"hash":null` so the digest is position-independent. The
predecessor lookup rides the PK as a backward index scan and is cheap — but it must see a stable
predecessor, which is why every write takes `pg_advisory_xact_lock(ledger_id)` and serializes.

### On our open ordering question — they have no answer

Directly relevant to [ADR-0005](../../docs/decisions/0005-reproducible-as-of.md): **Formance has no
commit-ordered total order anywhere in their schema.**

- `transaction_date()` seeds from `statement_timestamp()` — *start*-ordered. It guarantees
  intra-transaction consistency and nothing more.
- `bigserial` doesn't help either: `nextval` is also called at statement time.
- Their per-ledger sequences carry an explicit comment accepting gaps: *"we can still have 'holes'
  on ids since a sql transaction can be reverted after a usage of the sequence."*

So `WHERE recorded_at <= T` is not reproducible for them either, and they do nothing about it. That
raises confidence ADR-0005 is a real problem and lowers confidence a clever solution exists — the
recommendation was our option (c): make "as of" mean "as of entry id N" and hand the lender an id,
not a timestamp.

### Column types — what cost them

| Choice | Outcome |
| --- | --- |
| `numeric` for ids | Cross-type comparisons against `bigint` made an index unusable in a trigger; migration 44 (`fix-seq-scan-in-plpgsql`) exists solely to add a `::bigint` cast. They can't fix the root cause — narrowing now needs a table lock. |
| `postings varchar` holding JSON | The canonical record of money movement is a string. Four shadow jsonb columns and three GIN indexes exist to make it queryable. Repeated in `exporters.config`. |
| `timestamp` (no zone) everywhere | UTC held by convention, not constraint. Migration 33 is `fix-invalid-date-format`. |
| `numeric` for `amount` | Correct for *them* — arbitrary-precision multi-asset. Not for us; `bigint` minor units are cheaper and comparable. |
| `input`/`output` kept separate, not one signed balance | **Worth stealing.** Makes the upsert commutative and additive in both directions, gives gross turnover free, and no row needs to know the sign convention. |

### Naming cost them a hot-path index

Tables plural snake_case; cross-table references named `<plural_table>_<column>`
(`accounts_address`, `transactions_id`) — unusual but unambiguous, worth adopting.

**Indexes are named inconsistently and it hurt.** `accounts_ledger` and `logs_ledger` are composite
PKs, not indexes on `ledger`. `accounts_metadata_idx` is on `accounts`, not `accounts_metadata` —
and that name is exactly why a missing index on a hot write path went unnoticed for thirty
migrations. Column names drift badly too: `date`, `timestamp`, `insertion_date`, `inserted_at`,
`added_at`, `addedat`, `created_at` all appear, several meaning the same thing.
→ [ADR-0006 §1](../../docs/decisions/0006-schema-conventions.md).

### Their unfixed bugs, as a checklist of what to avoid

1. `moves` lost its running-balance index to a column drop (migration 37).
2. `accounts_metadata` has no btree index — every metadata write sequentially scans the whole
   revision history. The transactions side was fixed; this side never was.
3. No unique constraint on `(ledger, id, revision)` in either metadata table. Revision uniqueness
   rests on an unsynchronised `max()+1` inside a trigger; two concurrent updates produce duplicates.
4. Five `NOT VALID` CHECK constraints never validated, out of nine (four others were validated in migration 40).
5. Zero foreign keys.
6. Redundant indexes on the hottest tables — `moves_account_address` is a strict prefix of
   `moves_range_dates`; `moves_ledger` and `moves_asset` are near-zero cardinality.
7. `address_array` is orphaned: nullable, no default, its populating trigger dropped in migration
   46, yet it still carries a GIN index *and* an expression index. Population depends entirely on Go
   remembering.
8. `logs_blocks` shipped with PK `(previous)` alone, so two ledgers in one bucket collided on block
   0 (fixed in migration 53). **Our `tenant_id` must be in every natural key.**
9. Go struct tags contradict the schema — `varchar(256)` vs `varchar(255)`, `timestamptz` vs
   `timestamp`, `unique` declared where no index exists.

## OPEN — promoted to work

- **`recorded_at <= T` is not reproducible under concurrency.** `recorded_at` is not monotonic with
  *commit* order: a transaction starting at T1 and committing at T3 writes `recorded_at=T1`, while
  one starting at T2 > T1 and committing at T2.5 writes T2. The same "as of T" report run later can
  differ. A reproducible cursor must be **commit-ordered, not a wall clock**. →
  [ADR-0005](../../docs/decisions/0005-reproducible-as-of.md).
- **We have no event log, and probably need one.** Their `logs` table is the real source of truth;
  everything else is a projection. Our idempotency key lives on `ledger_transactions`, so we can only
  dedupe things that *produce* a transaction — a declined authorization, a limit change, an account
  opening have no home and cannot be made idempotent. **The one table from their schema we are
  genuinely missing.** → [ADR-0004](../../docs/decisions/0004-event-log.md).
- **Metadata mutability defeats reproducibility.** They maintain metadata *revision* tables
  precisely because a mutable jsonb blob cannot answer "what did we believe at time T". Ours is
  mutable with no history. If any of it feeds collateral reporting it needs history — cheapest path
  is to make metadata changes *be* log entries.
- **Benchmark the hot account.** Their docs warn locks are per (account, asset) and high concurrency
  on one source account serializes. They are *said* to target 1K writes/sec -- **unverified**, no
  URL was ever recorded and an authenticated code search across their org returns zero hits for the
  phrase, as `spikes/003` records. Issue #1363 documents
  a knee at **~8-12 TPS** -- but the issue is titled "Concurrent-write throughput regression v2.4.5 -> v2.4.7" and reports it AS A REGRESSION, the same binary being far faster serially. Reading it as an inherent single-ledger ceiling drops the load-bearing qualifier. →
  [spike 003](../003-throughput-ceiling/README.md).
- **Every table needs a PK / replica identity from day one.** Migration 45 is
  `fix-missing-primary-keys` — they shipped releases with no PK on `transactions`, `accounts` or
  `logs`. Logical replication and CDC require one.
- **`NOT VALID` constraints must actually get validated**, or we are lying to ourselves about our
  invariants.
