# Spike 014 — What does the write path actually require?

**Status:** closed. Produced [ADR-0013](/decisions/0013-write-path-contract), which records the
isolation-level constraint, the idempotency replay contract, `event_id NOT NULL`, striping as
schema, and the row-level-security policy set. Five of the decision log's then-open design holes
close on it.

**Question.** Five things the write path is *said* to do are not written down anywhere that binds:
it requires `READ COMMITTED` and no ADR says so; `idempotency_hash` is written and read by nothing;
`event_id` is nullable; striping is quoted in throughput figures and has no column; and
[0001](/decisions/0001-rust-and-postgres) asserts "tenant isolation *is* row-level security" against
a schema with zero policies. Which of them are real constraints, what exactly do they cost, and what
is the DDL?

**Ran** 2026-08-27 · PostgreSQL 18.6 (Docker, 16-core laptop, durability on, stock config),
`spike_wse`, loaded from `migrations/00001_baseline.sql` + `schema/chart.sql` and nothing else.
Everything below is reproducible from `spikes/016-write-path-contract/RUN.sh`.
> **Note on reproducing this spike.** Its runs predate the 2026-08-27 integration that folded the
> proposed DDL of ADRs 0009–0013 into `migrations/00001_baseline.sql`
> ([0003](/decisions/0003-migrations)'s editable-until-v0.1 exception), so the overlay files in this
> spike's directory target the *pre-merge* baseline — recover it from git history to re-run them
> verbatim. The merged baseline was re-verified end to end at integration time.

> **The machine was not idle** — load average 2.4–2.9 throughout. Every throughput figure here is a
> *ratio*, and [spike 003](/spikes/003-throughput-ceiling)'s banner applies unchanged: the ratios
> move too. The two findings that carry weight are counts, not rates, and counts are exact.

---

## The answer

**1 · READ COMMITTED is a deployment requirement, and the writer must set it rather than inherit
it.** At eight concurrent writers on one balance row, `REPEATABLE READ` and `SERIALIZABLE` lose
**64–82%** of postings outright, and **90%** at sixteen. **A retry loop written the usual way — catch `40001`, try again —
rescued exactly 0 of 6,363 failures under `REPEATABLE READ` and 0 of 7,476 under `SERIALIZABLE`,
and 0 of 25,536 at sixteen writers.** It cannot: the retry runs in the same transaction, on the same
snapshot, against the same row version. Restarting the *transaction* does work, and turns the write
path into optimistic concurrency at roughly half the throughput — which is
[spike 003](/spikes/003-throughput-ceiling)'s already-refused option.

**2 · The replay contract is two statements in one transaction, and one statement will not do.**
`INSERT … ON CONFLICT DO NOTHING RETURNING`, and — only when that returns nothing — a **separate**
`SELECT` that returns the stored outcome *and* whether the hash matches. Folding both into one
statement with a CTE returns **zero rows** when two callers race, because the CTE's `SELECT` runs on
the snapshot taken before the insert blocked. Under `REPEATABLE READ` the claim itself fails with
`40001`, so the replay path is a second, independent reason the write path needs READ COMMITTED.

**3 · `event_id NOT NULL` is free today and unpayable later**, because the repair the migration would
need is a `DELETE` on an append-only table. With two event-less rows present, `ALTER COLUMN … SET NOT
NULL` is refused, `DELETE` is refused by `refuse_mutation()`, and the only route left is
`DISABLE TRIGGER` — the one hole [0004](/decisions/0004-where-logic-lives) admits to. Nothing in the
tree writes such a row, so the cost is zero now and one disabled guarantee later.

**4 · A stripe is not an account. It is a row in `ledger_account_balances`** — which is what
[0002](/decisions/0002-scaling) said all along ("one logical account is stored as N physical balance
rows") and what the decision log and roadmap both stopped believing. **Put it there and
`uq_accounts__house` does not change at all**: two *different* house accounts of one purpose stay
refused by the index that already refuses them, while 64 stripes of that one account are 64 balance
rows. Not one report changes either — `trial_balance` groups by account id, `balance_sheet` and
`income_statement` by `fs_line`, so stripes roll up for free. Measured on the shipped baseline plus
the proposed columns: **1,066–1,359 → 9,660–10,518 upserts/s, 7.7–9.2×** at 64 stripes and sixteen
writers, over three runs.

**5 · RLS guards reads, every role is subject to it including the writer, and nothing needs
`BYPASSRLS`.** `COPY FROM` really is refused wherever RLS *applies to the current role* — a policy of
`USING (true) WITH CHECK (true)` is refused just the same, because the restriction is not about what
the policy allows. **But `COPY` is not load-bearing here**: on `ledger_entries`,
`INSERT … SELECT FROM unnest(…)` is within **2%** of `COPY` — in both directions — at every batch
size from 25 to 10,000 rows, so the register's "RLS and bulk batching are mutually exclusive" is a true premise with a false
conclusion. That matters, because **`BYPASSRLS` cannot be granted on RDS or Aurora at all.** Two
traps remain: without `security_invoker = true` the three report views bypass every policy — a reader
scoped to `t1` read both tenants out of `trial_balance` — and `FORCE ROW LEVEL SECURITY` takes `COPY`
away from the migration role and the restore path.

---

# The evidence

## 1 · Isolation

### The property, with two sessions and no sleeps

`01_isolation_two_session.sh` runs the balance upsert from [the database page](/database) in two
sessions. A takes the row and holds it; B issues the same statement and blocks; A commits. The
handshake polls `pg_stat_activity` for `state` and `wait_event_type = 'Lock'`, so the ordering is
enforced rather than timed.

| isolation | what session B did | the row afterwards |
| --- | --- | --- |
| `read committed` | `last_seq` **2**, balance −107 | `output 107, last_seq 2` |
| `repeatable read` | `ERROR: could not serialize access due to concurrent update` | `output 100, last_seq 1` |
| `serializable` | `ERROR: could not serialize access due to concurrent update` | `output 100, last_seq 1` |

It **fails closed** — the row is left exactly as A committed it, and `last_seq` still matches the
number of committed writers. Nothing corrupts. The write is simply gone.

### Under contention, and what a retry loop is worth

`02_run.sh` puts eight writers on one balance row, 200 postings each, and varies the retry strategy.
`none` is one attempt. `inline` catches `40001` in a savepoint and retries up to 20 times **inside
the transaction**. `restart` `COMMIT`s between attempts, so each retry gets a new snapshot.

| isolation / retry | postings | committed | lost % | `40001`s | **rescued by retry** | upserts/s |
| --- | --- | --- | --- | --- | --- | --- |
| read committed / none | 1,600 | 1,600 | **0.0** | 0 | 0 | 1,287 |
| read committed / inline | 1,600 | 1,600 | **0.0** | 0 | 0 | 1,261 |
| read committed / restart | 1,600 | 1,600 | **0.0** | 0 | 0 | 1,250 |
| repeatable read / none | 1,600 | 339 | 78.8 | 1,261 | 0 | 698 |
| repeatable read / inline | 1,600 | 1,297 | 18.9 | 6,363 | **0** | 1,026 |
| repeatable read / restart | 1,600 | 1,518 | 5.1 | 6,864 | 691 | 671 |
| serializable / none | 1,600 | 286 | 82.1 | 1,314 | 0 | 689 |
| serializable / inline | 1,600 | 1,244 | 22.3 | 7,476 | **0** | 1,106 |
| serializable / restart | 1,600 | 1,496 | 6.5 | 6,580 | 649 | 767 |

**The zero in the "rescued" column is the finding.** `inline` retried 6,363 times under
`REPEATABLE READ` and 7,476 under `SERIALIZABLE` and did not save a single posting: every one of
those postings burned all 21 attempts and was lost anyway. It cannot do otherwise. A repeatable-read
transaction holds one snapshot for its whole life, the conflicting row version is newer than that
snapshot, and retrying re-reads the identical state. The loop is not slow — it is *impossible*.

Five repetitions at eight writers put `none` between **63.8% and 82.5%** lost and `inline` between
15.3% and 23.6%, with **rescued = 0 every time**. At sixteen writers the same shape sharpens: `none`
loses **90.3%**, `inline` retries **25,074** times and rescues **0**. The rates move by a third
between repetitions on a machine that was never idle; the zero does not move at all.

*(Why `inline` loses less than `none`: it is not saving anything, it is slowing the writers down. 21
futile attempts per lost posting spreads the workers out and lowers the collision rate for the
postings that then succeed on their first try. That is a scheduling artefact, not a mechanism.)*

`restart` is the only loop that works, and it costs what
[spike 003](/spikes/003-throughput-ceiling) already priced: ~1,250 upserts/s at READ COMMITTED
against 671–767 restarting under the stricter levels, with **5.4 attempts per commit** and 5–6.5%
still lost after 21 restarts. Spike 003 measured the same trade from the other side — optimistic
locking at 437/s against pessimistic at 836/s, 11.8 retries per success at c=32 — and concluded
against it. This is that conclusion arriving again by a different road.

### Why READ COMMITTED is *sufficient*, not merely necessary

The write path takes exactly one decision that depends on concurrent state: what the balance row's
next `last_seq` and totals are. `INSERT … ON CONFLICT DO UPDATE` answers it by taking the row lock
and re-reading the **latest committed** version, so the updates to that row form a total order and
each writer's arithmetic lands on the immediately preceding committed state. **For that row, READ
COMMITTED is serial execution.** That is [0002](/decisions/0002-scaling)'s claim — the row lock *is*
the serialization point — and it is why nothing weaker and nothing stronger is wanted.

Everything else on the path is either an append that conflicts with nobody (`ledger_entries`,
`ledger_transactions`, `ledger_events`) or a key. The pattern PostgreSQL's own manual warns about —
*"It is very difficult to enforce business rules regarding data integrity using Read Committed
transactions because the view of the data is shifting with each statement"*, quoted in
[0005](/decisions/0005-event-log-and-write-path) — is reading sibling rows and then deciding. The
writer never does that. The deferred constraint trigger that did is the thing
[0004](/decisions/0004-where-logic-lives) deleted.

**The requirement is on the write path only.** A read-only reporting transaction never issues the
upsert, so it may — and for a multi-statement report should — run at `REPEATABLE READ`.

### So the writer pins it

`09_pin_isolation.sql`: with `default_transaction_isolation = 'serializable'`, a bare `BEGIN` gives
`serializable` and `BEGIN ISOLATION LEVEL READ COMMITTED` gives `read committed`. The deployment
default is overridable per transaction, which is the whole reason this is a decision rather than a
README line. The failure it avoids is `SQLSTATE 40001`, `serialization_failure`.

## 2 · The idempotency replay path

### What is broken today, as a run rather than as a comment

```
=== 0a. the unique index alone: the second attempt FAILS rather than replaying
ERROR:  duplicate key value violates unique constraint "uq_events__idempotency"

=== 0b. ON CONFLICT DO NOTHING swallows a DIFFERENT body under the SAME key
INSERT 0 0
--- the caller got INSERT 0 0 and no way to tell that from a benign replay.
 idempotency_key | stored_payload
-----------------+----------------
 k-naive         | {"amt": 500}
```

The 999,999 body was accepted, discarded and never mentioned.

### The contract

```sql
-- statement A: claim the key. A returned row means this caller is the first
-- writer; it does the work in this same transaction and never runs B.
INSERT INTO ledger_events AS e
       (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
VALUES ($1, $2, $3, $4, $5, $6, $7)
ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
RETURNING e.id;

-- statement B: run ONLY when A returned nothing. Separate statement, so under
-- READ COMMITTED it takes a new snapshot and can see a row a concurrent writer
-- committed while A was blocked on it.
SELECT e.id                     AS event_id,
       t.id                     AS transaction_id,   -- NULL for most operations
       e.recorded_at,
       e.idempotency_hash = $5  AS body_matches
FROM ledger_events e
LEFT JOIN ledger_transactions t
       ON t.tenant_id = e.tenant_id AND t.event_id = e.id
WHERE e.tenant_id = $1 AND e.idempotency_key = $4;
```

`uq_txn__one_per_event` is what makes the `LEFT JOIN` single-valued, so the shape cannot fan out.

**The stored result is the pair `(event_id, transaction_id)`.** The event id is the receipt for every
accepted operation; the transaction id is `NULL` for the majority that write no transaction — an
authorization, a decline, a hold expiry, a limit change
([0005](/decisions/0005-event-log-and-write-path)). A replay returns both, and the caller re-renders
its response from them.

Three cases, run sequentially in `03_idempotency.sql`:

| case | statement A | statement B |
| --- | --- | --- |
| **first write** | returns `01a043e5-…-e735` | not run |
| **benign replay** (same key, same body) | `INSERT 0 0`, no row | `event_id 01a043e5-…-e735`, `transaction_id aaaaaaaa-…-0001`, `body_matches t` |
| **poisoned replay** (same key, 999,999) | `INSERT 0 0`, no row | same ids, **`body_matches f`** |

After three attempts at key `k-1`: **1 event row, 1 transaction.**

`body_matches = f` is the only signal, and turning it into a distinct error is the *writer's* job —
the comparison is a read, and no constraint, key or grant can perform a read
([0004](/decisions/0004-where-logic-lives)). What the database can do is make the wrong answer
unreachable rather than merely wrong: put the hash in the predicate and a caller that forgets to
compare gets **no row** instead of the wrong stored result.

```
=== 4. the fail-closed form: hash in the predicate
   probe   | count            probe      | count
-----------+-------        ----------------+-------
 same body |     1          different body |     0
```

Zero rows is unambiguous there, because statement A has already established that the key exists.

### The race, which is the case a retry loop actually produces

`04_idempotency_concurrent.sh`: A claims the key and holds its transaction open; B issues the same
claim and blocks on A's uncommitted index tuple; A commits.

| variant | session B |
| --- | --- |
| **two statements, READ COMMITTED** | claim returns 0 rows; the follow-up `SELECT` returns A's `event_id` and `body_matches t`. **Correct.** |
| **two statements, REPEATABLE READ** | the *claim itself* fails: `ERROR: could not serialize access due to concurrent update`, then `current transaction is aborted`. **No replay path exists at this isolation level.** |
| **one statement, CTE, READ COMMITTED** | **0 rows.** Neither branch fires. |

The one-statement form is the trap. `ON CONFLICT DO NOTHING` blocks on the conflicting tuple and
resumes after A commits, but the CTE's `SELECT ledger_events` still runs on the snapshot the
*statement* took before it blocked, so it cannot see A's row. The caller gets neither "you are the
first writer" nor "here is the stored result" — a state the contract has no name for.

That is also the second reason the write path needs READ COMMITTED, and it is independent of the
balance upsert: even a ledger with no balance cache at all would need it to have a replay path.

### Prior art, read from the vendor and from source

| | same key + different body | concurrent same key | what is stored | expiry |
| --- | --- | --- | --- | --- |
| **Stripe** | error, `error.type = idempotency_error` | **409**, `idempotency_key_in_use` | **the status code and the response body** | **24 h, silently** |
| **Formance** | **400**, `ErrInvalidIdempotencyInput` | no such state | **the log row**; the response is re-derived | never |
| **IETF draft-07** | **422** `SHOULD` | **409** `SHOULD` | "the result of the previously completed operation" | resource-defined |

**Stripe**, [docs.stripe.com/api/idempotent_requests](https://docs.stripe.com/api/idempotent_requests):
*"Stripe's idempotency works by saving the resulting status code and body of the first request made
for any given idempotency key, regardless of whether it succeeds or fails. Subsequent requests with
the same key return the same result, including 500 errors."* And on the poisoned case: *"The
idempotency layer compares incoming parameters to those of the original request and errors if
they're not the same to prevent accidental misuse."* Replays carry
`Idempotent-Replayed: true` ([error-low-level](https://docs.stripe.com/error-low-level)). Keys are
pruned after 24 hours and *"We generate a new request if a key is reused after the original is
pruned"* — **a reused key past the window is silently treated as brand new**, which is a hazard we do
not inherit because our keys live as long as the log row.

> **One thing not to copy.** Stripe caches the *response*. A response-shape change then never
> reaches a replay, and a 500 replays as a 500 forever. Formance stores the domain event and
> re-renders, which is what our `payload` is already specified to support
> ([0005](/decisions/0005-event-log-and-write-path): *"complete enough to replay from"*).

> **Two things Stripe's own docs do not state**, and this table would be wrong to imply they do: the
> **HTTP status** for the mismatched-body case appears nowhere on stripe.com (the widely-quoted 400
> is from third-party captures, **unverified**), and neither does the message text *"Keys for
> idempotent requests can only be used with the same parameters they were first used with."* The 409
> and the code `idempotency_key_in_use` **are** documented.

**Formance**, read from source at `335bd03c08de46bae6895471702d9656958c64f5` (2026-08-26). Their
idempotency lives entirely on `logs`, not on `transactions`. Three migrations to get the index right
— `5-add-idempotency-key-index` created a **non-unique** one, `7-add-ik-unique-index` had to *delete
the duplicates that had already accumulated* before it could make it unique, and
`8-ik-ledger-unique-index` finally scoped it `(ledger, idempotency_key)` after discovering it was
globally unique across every ledger in the bucket. The hash arrived later still, in
`11-make-stateless`.

Their replay is ours: read the row, compare the hash, return the stored result.
`internal/controller/ledger/log_process.go:221-239` —

```go
if len(log.IdempotencyHash) > 0 {
    if computedHash := ledger.ComputeIdempotencyHash(parameters.Input); log.IdempotencyHash != computedHash {
        return nil, nil, newErrInvalidIdempotencyInputs(log.IdempotencyKey, log.IdempotencyHash, computedHash)
    }
}
```

Note the guard: **rows written before migration 11 have no hash and replay unchecked** — a
deliberate, commented fail-open. `newErrInvalidIdempotencyInputs` maps to HTTP 400 `VALIDATION`;
the *duplicate-key* error maps to 409 `CONFLICT` and never reaches a client, because it is caught
internally and turned into a re-read (`forgeLogRetry`, lines 202-211: *"A log with the IK could have
been inserted in the meantime, read again the database to retrieve it"*). That is the race above,
solved the same way we solve it.

**And the thing worth taking from them:** Formance has no in-flight state and no 409 for a
concurrent duplicate, because the key claim and the work commit in **one database transaction**.
There is no window in which a key is claimed but its result is not yet durable. Stripe needs
`idempotency_key_in_use` because its work is not one transaction; we do not, and should not invent
one.

Their hash is `sha256` over Go's `encoding/json` of the parsed command struct
(`internal/log.go:457-466`) — which couples the fingerprint to **Go struct field names**, since
`AccountMetadata` and `Runtime` carry no json tags. Renaming a field silently invalidates every
stored hash. Ours must hash a canonical byte form the writer owns, which is the `memento` idea
[0005](/decisions/0005-event-log-and-write-path) already defers.

**The IETF draft** (`draft-ietf-httpapi-idempotency-key-header-07`, 15 October 2025) is the only one
of the three that separates the two failures by *what the client should do*:

> "If there is an attempt to reuse an idempotency key with a different request payload, the resource
> SHOULD reply with a HTTP 422 status code" … "If the request is retried, while the original request
> is still being processed, the resource SHOULD reply with an HTTP 409 status code" … "Clients MUST
> correct the requests (with the exception of 409 where no correction is required) before performing
> a retry operation."

422 means *you must change something*; 409 means *wait and send exactly this again*. That is the
distinction a caller can act on, and it costs nothing to honour.

## 3 · `event_id`

`05_event_id_not_null.sql`. The whole first half runs inside a transaction that is rolled back,
because it has to create the rows it is about.

```
=== 1. an event-less transaction inserts without complaint.
INSERT 0 2
 event_less
------------
          2

=== 2. the migration step, with those rows present: refused.
ERROR:  column "event_id" of relation "ledger_transactions" contains null values

=== 3. ...and they cannot be removed, because the journal is append-only.
ERROR:  ledger_transactions is append-only: DELETE on bbbbbbbb-…-0001 refused.
        Correct it with a new row.

=== 4. so the only routes left are the two the project calls holes:
ALTER TABLE ledger_transactions DISABLE TRIGGER ck_txn__append_only;
DELETE 2
ALTER TABLE   -- ENABLE ALWAYS
ALTER TABLE   -- SET NOT NULL
--- it works, and it required turning off the guarantee to get there.
```

**That is the argument for doing it now.** `NOT NULL` is a one-line migration against every database
this schema has ever produced, and becomes a choice between disabling append-only and fabricating
history the moment one event-less transaction commits. It is the same "free now, expensive later"
shape as the tenant-leading keys, with a deadline attached.

Two more things `NOT NULL` buys, both measured after the `ALTER`:

- **`fk_txn__event` becomes total.** It is `MATCH SIMPLE`, so today a `NULL` `event_id` skips the
  check entirely; afterwards a made-up event id is refused — `violates foreign key constraint
  "fk_txn__event"`.
- **`uq_txn__one_per_event` becomes total** and needs no change. Its predicate is
  `WHERE event_id IS NOT NULL`, which every row now satisfies, so no row escapes it. Verified: a
  second transaction from event `k-1` is refused.

The legitimate shapes both still work — one event causing one transaction, and an event causing
**none**, which is most of the lifecycle: 7 events, **5 causing no transaction**.

**Nothing in this repository writes an event-less transaction, or any transaction at all, against
the shipped baseline.** `schema/chart.sql` writes no journal rows. The only trace file,
`spikes/004-chart-of-accounts/golden_trace.sql`, inserts
`ledger_transactions (tenant_id, idempotency_key, idempotency_hash, …)` — **columns that do not exist
on `ledger_transactions`** since the event log took idempotency over. It targets the pre-0005 schema
and cannot load against `migrations/00001_baseline.sql` at all.

## 4 · Striping

### Where the stripe goes

The decision log says `uq_accounts__house` "would currently prevent [a stripe] on the accounts that
need it", and the roadmap says `network_settlement_payable` "cannot have a second row under
`UNIQUE (tenant_id, purpose, currency)`". Both are true **only if a stripe is an account row**, and
that reading contradicts [0002](/decisions/0002-scaling), which says a logical account is stored as N
physical *balance* rows.

Put it where 0002 put it and the index is not in the way:

```
=== 1. uq_accounts__house is UNTOUCHED. Two different house accounts of one
===    purpose are still refused:
ERROR:  duplicate key value violates unique constraint "uq_accounts__house"
DETAIL:  Key (tenant_id, purpose, currency)=(t1, network_settlement_payable, USD) already exists.

=== 2. ...while 64 stripes of THAT ONE account are just 64 balance rows.
 stripe_rows | accounts        rows_in_ledger_accounts
-------------+----------      -------------------------
          64 |        1                              1
```

That is the whole answer to "N stripes coexist while two different house accounts of the same purpose
remain refused": **there is no such thing as two different house accounts of one purpose, and there
never was.** The register's requirement was already the index's behaviour; it only looked
contradictory because the stripe had been imagined one table too high.

### The DDL

```sql
ALTER TABLE ledger_accounts
    ADD COLUMN stripe_count smallint NOT NULL DEFAULT 1
        CONSTRAINT ck_accounts__stripe_count CHECK (stripe_count BETWEEN 1 AND 1024);

ALTER TABLE ledger_account_balances
    ADD COLUMN stripe smallint NOT NULL DEFAULT 0
        CONSTRAINT ck_balances__stripe_non_negative CHECK (stripe >= 0);
ALTER TABLE ledger_account_balances DROP CONSTRAINT pk_balances;
ALTER TABLE ledger_account_balances
    ADD CONSTRAINT pk_balances PRIMARY KEY (tenant_id, account_id, currency, stripe);

ALTER TABLE ledger_entries
    ADD COLUMN stripe smallint NOT NULL DEFAULT 0
        CONSTRAINT ck_entries__stripe_non_negative CHECK (stripe >= 0);
ALTER TABLE ledger_entries DROP CONSTRAINT uq_entries__account_seq;
ALTER TABLE ledger_entries
    ADD CONSTRAINT uq_entries__account_seq UNIQUE (tenant_id, account_id, stripe, account_seq);
ALTER TABLE ledger_entries
    ADD CONSTRAINT fk_entries__stripe FOREIGN KEY (tenant_id, account_id, currency, stripe)
    REFERENCES ledger_account_balances (tenant_id, account_id, currency, stripe);
```

`ledger_entries` needs the column because the counter lives on the stripe row: without it two stripes
both issue `account_seq` 5 for one account and `uq_entries__account_seq` refuses the second —
serialising every writer through a unique index, which is the bottleneck striping exists to remove,
moved one table over.

`fk_entries__stripe` is the same trick as `fk_entries__account` and `fk_entries__txn_effective`: make
the denormalised copy part of a composite key so it cannot name a counter nothing issued. Verified —
an entry claiming stripe 4242 is refused.

**`stripe_count` is a hint to the writer, not an invariant, and that is deliberate.** A reader `SUM`s
the rows that exist; it never enumerates `0..n-1`. So a stripe outside the declared count is
harmless (measured: 65 rows summed correctly), lowering the count from 64 to 8 strands nothing
(same total), and raising it needs no backfill — the next writer to pick a new stripe creates it with
the upsert it was going to run anyway. **There is no DDL at stripe-open time and no online
migration.** Nothing declarative can enforce `stripe < stripe_count` across two tables, and nothing
needs to.

### The reports

Not one of them changes, which is the argument for this placement rather than the other one.
`trial_balance` groups by account id, so a 64-stripe account is **one** row. `balance_sheet` and
`income_statement` group by `fs_line`, one level further up.

| | |
| --- | --- |
| `trial_balance` | 3 rows: `customer_receivable` 33,000, `interchange_revenue` 576, `network_settlement_payable` **32,424** — the sum of 64 stripes plus the opening entry, on one line |
| `balance_sheet` | Receivables 33,000, Payables 32,424, Undistributed earnings 576 |
| accounting equation | assets 33,000, liabilities+equity 33,000, **difference 0** |
| drift check, per stripe | **0 stripes disagree** with the journal recomputed |
| gaplessness, per `(account, stripe)` | **0 stripes with a gap** |

Gaplessness *does* change character: it is now per `(account, stripe)` rather than per account, so an
as-of reconstruction over one account merges N ordered runs instead of walking one. The property is
intact; the walk is wider.

### Does the DDL deliver the mechanism?

`08_run.sh`, sixteen writers on one logical account, affinity stripes (writer *i* owns stripe
*i mod n*), against the shipped baseline plus the columns above:

| stripes | upserts/s | vs unstriped |
| --- | --- | --- |
| 1 | 1,359 | 1.00× |
| 8 | 5,672 | 4.17× |
| **64** | **10,518** | **7.74×** |

Three runs of the same configuration gave unstriped 1,359 / 1,149 / 1,066 and striped-64
10,518 / 9,660 / 9,802 — **7.74×, 8.41×, 9.19×**, with the 8-stripe point at 3.8–4.2× throughout.
Spike 003 measured 7.8–8.0× on its own bench schema; this is the same shape on the real one. **The
ratio is the finding, and it moves by 20% between repetitions on a machine that was never idle.**

The read side is one index range scan either way, over a contiguous key prefix. At the sizes this
ran (a 134-row balance table, entirely cached) the difference is below measurement — pgbench
`-M prepared -c1 -T5`, three repetitions each, gave 0.036/0.037/0.037 ms at one stripe and
0.036/0.038/0.037 ms at 64. Forcing the index makes the cost visible as buffers, which is the claim
that survives a bigger table: **`Index Scan using pk_balances`, 3 buffers at one stripe and 24 at 64,
0.026 ms against 0.072 ms.** No sort, one scan, one leaf entry per stripe.

*(The write bench leaves ~91 heap blocks of dead versions behind one live stripe row and autovacuum
does not come — [spike 009](/spikes/009-where-the-balance-lives)'s finding reproducing itself
unprompted. `VACUUM (FULL, ANALYZE)` before any read measurement.)*

### The suspense sweep

The roadmap lists "the suspense sweep for affinity striping" as unscheduled work, and
[spike 003](/spikes/003-throughput-ceiling) names it: *"the accounting name is a per-writer clearing
account… a periodic sweep consolidates into the real house account."* **Putting the stripe below the
account removes the sweep.** A stripe is not an account: it has no `purpose`, no `fs_line`, no
counterparty, no place on a statement, and nothing to consolidate *into* — it is already inside the
account it belongs to, and every reader already sums it. Spike 004 preferred a tenant affinity key
"because a business key survives a restart and needs no sweep process"; below the account, no
affinity key needs one.

That also settles the tension with spike 004's rule about perimeter accounts — *"split perimeter
accounts on the counterparty's axis, or not at all"*. Splitting an account per tenant introduces an
axis orthogonal to the one an external balance can confirm. A stripe introduces **no axis at all**:
it is invisible above `ledger_account_balances`, so a reconciliation of `network_settlement_payable`
against the network's statement aggregates exactly what it aggregated before. The invariant that
makes this safe is worth stating outright: **a stripe must never appear in a report, a
reconciliation, an API response, or a chart of accounts.**

## 5 · Row-level security

`06_rls.sql`. Five tables, one `FOR SELECT` policy each, granted to a new `openledger_read` role.
`fs_lines` and `account_types` get none — the chart is deployment-global and carries no `tenant_id`,
which the decision log already records as open.

```sql
CREATE POLICY rls_entries__tenant ON ledger_entries
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));
```

Written the one way [spike 004](/spikes/004-chart-of-accounts) measured: the scalar subquery forces a
once-per-statement InitPlan rather than a per-row call of a `STABLE` function, and the two-argument
`current_setting` returns `NULL` when the GUC is unset, so an unscoped session matches nothing.
Confirmed on the plan:

```
 Aggregate
   InitPlan 1
     ->  Result
   ->  Index Only Scan using ix_entries__effective on ledger_entries
         Index Cond: ((tenant_id = (InitPlan 1).col1) AND (account_id = '…'::uuid))
```

| probe | result |
| --- | --- |
| reader with `app.tenant_id = 't1'` | 4 accounts, 2 entries — **t1 only** |
| the same reader asking for `tenant_id = 't2'` | **0 rows.** Refused by absence, not by error |
| reader with the GUC unset | **0 rows.** Fails closed |
| reader through `trial_balance`, `security_invoker = true` | t1 only, 2 rows |
| reader through `trial_balance`, **default** | **t1 *and* t2.** Every policy bypassed |

**The view result is the one to take away.** A view runs with its *owner's* rights unless
`security_invoker = true`, and the owner is the migration role, which no policy applies to. Enable
RLS without that option and the three report views hand every tenant's numbers to a scoped reader
while the base tables behave perfectly. The policies read as deployed and are decoration.

### The write path under RLS

The whole write path — event, transaction, balance upsert, entry — runs as `openledger_app` with
policies enabled and the permissive writer policy applying to it. The upsert still returns
`last_seq 2` and the new balance; the batched form,
`INSERT … SELECT … FROM unnest(ARRAY[…])`, still inserts 5 rows. Nothing about the serialization
point changes.

### `COPY FROM`

The register says PostgreSQL refuses `COPY FROM` on a table with RLS enabled. Two measurements
sharpen that, and the second one changes the answer.

**First: the refusal is keyed on whether RLS *applies to the current role*, not on whether the table
has it enabled, and not on what the policy would allow.**

| role | RLS state | `COPY FROM` |
| --- | --- | --- |
| non-superuser table owner | enabled, not forced | **COPY 2** |
| non-superuser table owner | enabled + `FORCE ROW LEVEL SECURITY` | `ERROR: COPY FROM not supported with row-level security` |
| `openledger_app`, policy `USING (true) WITH CHECK (true)` | enabled | **`ERROR: COPY FROM not supported with row-level security`** |
| `openledger_app` with `BYPASSRLS` | enabled, policies present | **COPY 2** |

The third row kills the obvious workaround. A policy that admits *everything* does not help: it is
not the policy being evaluated and refused, it is `COPY` declining to run where RLS is in scope. The
PostgreSQL 18 manual is explicit —
[sql-copy](https://www.postgresql.org/docs/18/sql-copy.html): *"If row-level security is enabled for
the table, the relevant SELECT policies will apply to COPY table TO statements. Currently, COPY FROM
is not supported for tables with row-level security. Use equivalent INSERT statements instead."* So
the choice is `BYPASSRLS` or giving up `COPY`, with no third arrangement of policies.

> **`openledger` in this repository is a superuser**, and superusers bypass RLS unconditionally — so
> probing any of this as `openledger` measures nothing. The owner rows above use a purpose-made
> `NOSUPERUSER` role. An earlier version of this run did not, reported "FORCE does not block the
> owner's COPY", and was wrong.

`FORCE ROW LEVEL SECURITY` is what [spike 004](/spikes/004-chart-of-accounts) banked as worth having,
and the second row is why we do not take it: it subjects the table owner too, and the table owner is
the migration role and the restore path. What spike 004 actually needed is the *other* half of its
own sentence — **the app role must not own the tables** — and that is true without `FORCE`.

**Second: `COPY` is not load-bearing, so the choice is not a trade at all.** The claim that RLS and
batching are mutually exclusive rests on `COPY` being how a batch is written. Spike 003's best
coalesced batch was 25–100 postings, and `COPY` earns its keep at thousands. Those are different
regimes, and nobody had checked which one we are in. The same rows, written into `ledger_entries`
three ways, five repetitions each, medians:

| batch | `COPY` | `INSERT … SELECT FROM unnest(…)` | `INSERT … VALUES (…), (…)` |
| --- | --- | --- | --- |
| 25 | 2.70 ms | **2.55 ms** (0.95×) | 2.68 ms (0.99×) |
| 100 | 7.47 ms | **7.37 ms** (0.99×) | 7.80 ms (1.04×) |
| 1,000 | 63.56 ms | **62.90 ms** (0.99×) | 68.57 ms (1.08×) |
| 10,000 | 624.35 ms | **613.42 ms** (0.98×) | 673.73 ms (1.08×) |

**`unnest` is indistinguishable from `COPY` and the worst form is 8% behind.** Across three runs
`unnest/COPY` landed between **0.95× and 1.02×** — on both sides of parity, which is what "no
difference" looks like — and `VALUES/COPY` between **0.99× and 1.08×**. The reason is on the table
rather than in the protocol: `ledger_entries` carries three composite foreign keys and a unique
index, so per-row constraint checking dominates and the wire format is noise. Per row the cost falls
from 108 µs at 25 to 62 µs at 10,000 — that is the batching win, and it is identical for all three.

So `COPY` buys nothing measurable on this table, and RLS costs it. **Nothing has to bypass RLS**, which is the whole
of the "needs deciding, not discovering" that [spike 004](/spikes/004-chart-of-accounts) and the
roadmap both left open.

*(Re-measure if `ledger_entries` ever loses a foreign key, and re-measure over a network, where
`COPY`'s streaming protocol has an advantage localhost hides.)*

### `BYPASSRLS` is not available on RDS or Aurora

This is decisive independently of the measurement above. PostgreSQL 18's
[CREATE ROLE](https://www.postgresql.org/docs/18/sql-createrole.html): *"Only superuser roles or
roles with BYPASSRLS can specify BYPASSRLS."* And AWS's own role listing for RDS and Aurora
([RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Roles.View.html))
shows the master user with `Create role, Create DB` and nothing more, while the only role carrying
`Bypass RLS` is `rdsadmin` — which AWS describes as *"used internally by RDS for PostgreSQL"* and
whose privileges *"can't be changed"*.

**A design resting on a `BYPASSRLS` service role is not deployable on RDS or Aurora.** Azure
Flexible Server can grant it on PG16+ and could not before; Google Cloud SQL does not document it
either way, and its master user is `NOSUPERUSER`, so presumably not — **unverified**.

AWS never says "you cannot grant BYPASSRLS" in one sentence; the conclusion is the PostgreSQL rule
applied to AWS's own published role table. It is an inference from two quoted facts, and it is
recorded as one.

### Does `BYPASSRLS` reopen append-only?

No. It is orthogonal to both layers of the defence.

```
=== 4a. the BYPASSRLS writer still has no UPDATE or DELETE on the journal
ERROR:  permission denied for table ledger_entries
ERROR:  permission denied for table ledger_transactions
ERROR:  permission denied for table ledger_events      (TRUNCATE)

=== 4b. ...and even WITH the grant, the append-only triggers still refuse it.
GRANT UPDATE, DELETE ON ledger_entries TO openledger_app;
ERROR:  ledger_entries is append-only: DELETE on 01a043f0-… refused.
        Correct it with a new row.
```

`BYPASSRLS` skips row-level *policies*. It is not a grant and it is not a trigger bypass. The grants
[0004](/decisions/0004-where-logic-lives) §grants describes and the six `ENABLE ALWAYS` triggers both
hold unchanged.

**What it does cost, stated plainly:** the writer sees every tenant. `tenants_visible_to_writer = 2`.
RLS here is a **read-path** control — it protects a reporting connection, an analyst, a BI tool, a
support console — and it does not protect against a compromised writer. Nothing in
[0001](/decisions/0001-rust-and-postgres)'s sentence "tenant isolation *is* row-level security"
survives that unqualified, and it should not be left unqualified.

---

## What this does NOT measure

- **Anything over a network.** localhost throughout, where a round trip costs ~0.05 ms.
  [Spike 003](/spikes/003-throughput-ceiling)'s RDS caveat applies to every rate here.
- **`BYPASSRLS` on a real managed instance.** The RDS conclusion above is drawn from AWS's published
  role table and the PostgreSQL rule, not from an instance. Cloud SQL is **unverified** either way.
  Nothing in the accepted design depends on it, which is the point of measuring `COPY` against
  `unnest` — but if it ever does, this needs an instance.
- **RLS under load.** The plan shape is right (InitPlan, index scan); no throughput number was taken
  with policies enabled.
- **A large balance table.** 134 rows. The striped read's *shape* is measured; its cost at a million
  accounts is not.
- **The `restart` retry at its own best.** 21 attempts, no backoff, no jitter. A tuned restart loop
  under `SERIALIZABLE` would lose less than 5–6.5%; it would still be optimistic concurrency on a
  row every writer touches, which is the thing spike 003 refused.
- **Batching.** Every posting here is its own transaction. The interaction between coalesced
  batching and stripe *selection* is spike 003's finding and is unchanged.

## Reproduce

```sh
cd spikes/016-write-path-contract
./RUN.sh                    # drops and rebuilds spike_wse, runs 00-10 in order
./02_run.sh 16 200          # the isolation matrix at another concurrency
./08_run.sh 16 400          # striping, on the shipped baseline plus the proposed columns
./10_run.sh                 # COPY vs multi-row INSERT vs unnest, on ledger_entries
```

`RUN.sh` recreates the database from `migrations/00001_baseline.sql` and `schema/chart.sql` every
time, so no file here depends on the state another left behind. `06_rls.sql` and `07_striping.sql`
each undo what they applied, because the baseline is not theirs to change.
