# 0013 — The write path: READ COMMITTED, a replay contract, and a stripe below the account

**Status:** accepted
**Evidence:** [spike 014](/spikes/014-write-path-contract).

## The decision

**The code that writes to the ledger has a handful of concrete ways it can go wrong once real traffic
hits it, and each rule below stops one of them. All five were assumed along the way but never written
anywhere that binds.**

- **Many writers, one row.** A few accounts get touched by almost every transaction, so under load a
  lot of writes pile onto the same row at once and the database can only take them one at a time. Turn
  the database's safety dial too high and, under that pileup, writers start quietly losing their
  writes — and simply retrying doesn't rescue them. So the writer runs at the one setting where that
  cannot happen, and we call that out as a real deployment requirement rather than a detail.
- **The same request twice.** Networks retry and people double-click, so the same request will
  sometimes arrive again. We must not perform it twice — and we must hand back the *original* answer —
  while a *different* request that happens to reuse the same id is refused loudly instead of quietly
  getting the wrong stored answer.
- **A transaction with no cause.** Every movement of money should trace back to the event that caused
  it, so we make that link mandatory — no orphans — and we do it while the ledger is still empty,
  because nothing could invent the missing cause later.
- **One account too busy to keep up.** When a single account is the bottleneck, we split it into
  several rows underneath so writers spread out, and the reader still sees one balance because it adds
  them up. The split stays invisible above the balance row — no report, reconciliation, API answer or
  chart of accounts ever has to know it is there.
- **A read that quietly crosses tenants.** A reporting connection, an analyst or a BI tool should only
  ever see its own tenant's rows, so reads are fenced by the database itself, and every role is
  subject to the fence — the writer included — so nothing has to remember to filter.

The five rules, the measured evidence behind each, and the DDL that ships them are below.

**1 · The write path runs at `READ COMMITTED`, and the writer sets it rather than inherits it.**
Every write transaction opens with `BEGIN ISOLATION LEVEL READ COMMITTED`. A deployment default is
not consulted, because correctness is never configurable and this is correctness: at eight
concurrent writers on one balance row, `REPEATABLE READ` and `SERIALIZABLE` lose **64–82%** of
postings, and **90%** at sixteen writers. It fails closed — nothing corrupts, the writes are simply gone.

**And the retry loop everyone writes does not help. It cannot.** Catching `40001` and trying again
inside the same transaction rescued **0 of 5,145 failures under `SERIALIZABLE` and 0 of 5,712 under
`REPEATABLE READ`** — zero in every run, at every concurrency, including 0 of 25,074 at sixteen
writers. A repeatable-read transaction holds one snapshot for its whole life; the retry re-reads the
identical state and fails identically. Restarting the whole *transaction* does work, at roughly half
the throughput and 3–14% still lost — which is optimistic concurrency on a row every writer touches,
the thing [spike 003](/spikes/003-throughput-ceiling) already refused at 437/s against 836.

**`READ COMMITTED` is sufficient because the balance row's lock is the serialization point**
([0002](/decisions/0002-scaling)). `INSERT … ON CONFLICT DO UPDATE` takes that lock and re-reads the
latest *committed* version, so updates to that row form a total order and each writer's arithmetic
lands on the immediately preceding committed state. For that row, `READ COMMITTED` **is** serial
execution. Everything else on the path is an append that conflicts with nobody, or a key. The
pattern PostgreSQL's manual warns about — *"It is very difficult to enforce business rules regarding
data integrity using Read Committed transactions because the view of the data is shifting with each
statement"*, quoted in [0005](/decisions/0005-event-log-and-write-path) — is reading sibling rows and
then deciding, and the writer never does that. The deferred constraint trigger that did is what
[0004](/decisions/0004-where-logic-lives) deleted.

**The constraint is on the write path only.** A read-only reporting transaction never issues the
upsert and may run at `REPEATABLE READ`; for a multi-statement report it should.

**2 · The replay contract is two statements in one transaction, and the stored result is
`(event_id, transaction_id)`.**

```sql
-- A. claim the key. A returned row means this caller is the first writer: it does
--    the work in this same transaction and never runs B.
INSERT INTO ledger_events AS e
       (tenant_id, kind, source, idempotency_key, idempotency_hash, payload, effective_at)
VALUES ($1, $2, $3, $4, $5, $6, $7)
ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
RETURNING e.id;

-- B. run ONLY when A returned nothing. A SEPARATE statement, so it takes a new
--    snapshot and can see a row a concurrent writer committed while A blocked on it.
--    The hash is in the WHERE, not a returned column: a same-key/different-body
--    replay returns NO row, and a caller that forgets to compare gets nothing
--    instead of the wrong stored result (see below).
SELECT e.id AS event_id, t.id AS transaction_id, e.recorded_at
FROM ledger_events e
LEFT JOIN ledger_transactions t
       ON t.tenant_id = e.tenant_id AND t.event_id = e.id
WHERE e.tenant_id = $1 AND e.idempotency_key = $4
  AND e.idempotency_hash = $5;
```

| | |
| --- | --- |
| **same key, same body** | replay: return `(event_id, transaction_id)`, `Idempotency-Replayed: true` |
| **same key, different body** | refuse: **HTTP 422**, a distinct error type, and *no* row is written |
| **same key, in flight** | there is no such state — see below |

**The stored result is the event id and the id of the transaction it caused**, and
`transaction_id` is `NULL` for the majority of accepted operations, which write no transaction at
all ([0005](/decisions/0005-event-log-and-write-path)). The caller re-renders its response from
those, as Formance does; it does not cache a response body, as Stripe does. `uq_txn__one_per_event`
is what makes the `LEFT JOIN` single-valued.

**One statement will not do**, and this is the part that is easy to get wrong. Folding A and B into
one `WITH … UNION ALL` returns **zero rows** when two callers race, because the CTE's `SELECT` runs
on the snapshot the statement took before the insert blocked — neither branch fires, and the caller
gets a state the contract has no name for. Reproduced.

**There is no in-flight state and we will not invent one.** Stripe answers a concurrent duplicate
with `409 idempotency_key_in_use` because its work is not one database transaction. Ours is: the key
claim and everything it causes commit together, so the loser of the race simply blocks on the
uncommitted index tuple and finds a durable result the moment it is released. Formance reaches the
same conclusion by the same route.

**422, not 400 or 409**, for the poisoned replay. The IETF draft is the only one of the three sources
that separates the two failures *by what the client must do*: 422 means correct the request, 409
means wait and resend it unchanged. That distinction costs nothing and is the one a caller can act
on.

**And the comparison lives in the writer, not in the database.** It is a read, and no constraint, key
or grant performs a read ([0004](/decisions/0004-where-logic-lives)). What the schema can do is make
the wrong answer unreachable rather than merely wrong: **put the hash in the `WHERE` clause and a
caller that forgets to compare gets no row instead of the wrong stored result.**

**3 · `ledger_transactions.event_id` becomes `NOT NULL`.** One line, and it makes
[0005](/decisions/0005-event-log-and-write-path)'s "every transaction references the event that
caused it" an invariant rather than a convention. It also makes `fk_txn__event` **total** — the key
is `MATCH SIMPLE`, so a `NULL` skips it entirely today — and makes `uq_txn__one_per_event` total,
because every row then satisfies its `WHERE event_id IS NOT NULL` predicate. The index needs no
change.

With one event-less transaction committed, `SET NOT NULL` is refused, the `DELETE` that would fix
it is refused by `refuse_mutation()`, and **the only routes left are `DISABLE TRIGGER` — the one hole
this project admits to — or fabricating the event that caused it**. The migration is free today and
unpayable later, so it had to land while the journal was empty. Nothing in the tree writes such a row: the
chart writes no journal rows at all, and the only trace file targets the pre-0005 schema and cannot
load against the current baseline.

**4 · A stripe is a row in `ledger_account_balances`, not a row in `ledger_accounts` — and
`uq_accounts__house` does not change.** This is what [0002](/decisions/0002-scaling) said all along
("one logical account is stored as N physical balance rows"); the decision log and roadmap stopped
believing it and concluded the index was in the way. It is not. Two *different* house accounts of one
purpose stay refused by the index that already refuses them, while 64 stripes of that one account are
64 balance rows. **There is no such thing as two different house accounts of one purpose, and the
requirement the register stated was already the index's behaviour.**

Three properties follow, and they are why this placement wins:

| | |
| --- | --- |
| **No report changes** | `trial_balance` groups by account id; `balance_sheet` and `income_statement` by `fs_line`. Stripes roll up for free. Verified on a 64-stripe book: one `trial_balance` row, the accounting equation at **0**, the per-stripe drift check clean, no gaps |
| **No sweep** | A stripe has no `purpose`, no `fs_line`, no counterparty, and nothing to consolidate *into*. The roadmap's suspense sweep exists because spike 003 modelled the stripe as a per-writer clearing *account*. Below the account, it is obviated |
| **No stripe-open DDL** | Raising `stripe_count` needs no backfill: the next writer to pick a new stripe creates it with the upsert it was going to run anyway — the plain operator story is in [0002](/decisions/0002-scaling) |

**`stripe_count` is a hint to the writer, not an invariant.** A reader `SUM`s the rows that exist and
never enumerates `0..n-1`, so an out-of-range stripe is harmless, lowering the count strands nothing,
and `stripe < stripe_count` need not be enforced — which is fortunate, because nothing declarative
could enforce it across two tables.

**And the invariant that makes striping safe where per-tenant splitting is not: a stripe must never
appear in a report, a reconciliation, an API response, or a chart of accounts.** [Spike
004](/spikes/004-chart-of-accounts) refuses splitting a perimeter account on any axis but the
counterparty's, because that introduces a partition orthogonal to the only axis an external balance
can confirm. A stripe introduces **no axis at all** — it is invisible above
`ledger_account_balances` — so reconciliation aggregates exactly what it aggregated before.

Measured on the shipped baseline plus the proposed columns, sixteen writers on one logical account
with worker-affinity stripes: **1,066–1,359 upserts/s unstriped, 9,660–10,518 at 64 stripes —
7.7–9.2×.** Spike 003 measured 7.8–8.0× on a bench schema; this is the same shape on the real one.

**5 · Row-level security guards reads. Every role is subject to it, including the writer, and
nothing uses `BYPASSRLS`.** Five tables get one tenant-scoped `FOR SELECT` policy each for a new
`openledger_read` role; the writer gets a permissive `FOR ALL` policy that admits everything. The
chart gets none — it is deployment-global and carries no `tenant_id`.

**The reason the writer is not exempted is that it does not need to be, and on RDS it could not be.**
The register and the roadmap both record RLS and bulk batching as mutually exclusive, because
PostgreSQL refuses `COPY FROM` on a table where RLS applies. The first half is true and sharper than
recorded — a policy of `USING (true) WITH CHECK (true)` is refused just the same, because the
restriction is on RLS being *applied to the role*, not on what the policy would allow. **The second
half does not survive measurement.** On `ledger_entries`, `INSERT … SELECT FROM unnest(…)` is within
**2% of `COPY` in both directions** at every batch size from 25 to 10,000 rows, over three runs, and
a plain multi-row `VALUES` insert is at most 8% behind: the table carries three composite foreign keys and a unique index, so per-row constraint
checking dominates and the wire format is noise. **`COPY` was never the load-bearing part, so giving
it up costs nothing measurable and the exemption is unnecessary.**

Which is as well, because `BYPASSRLS` requires a superuser (or an existing `BYPASSRLS` holder) to
grant, and an RDS or Aurora master user is neither: AWS's own role listing shows `postgres` with
`Create role, Create DB` and nothing else, and the sole holder of `Bypass RLS` is the internal,
unmodifiable `rdsadmin`. **A design resting on a `BYPASSRLS` service role is not deployable on the
RDS/Aurora platform a [network benchmark](/roadmap#if-this-ever-wants-a-production-story) would run
on.**

**Two more things that are not optional.** The three report views need
`WITH (security_invoker = true)`: a view runs with its *owner's* rights by default, and the owner is
the migration role that no policy applies to — without it, a reader scoped to `t1` read both tenants
out of `trial_balance` while the base tables behaved perfectly. And **`FORCE ROW LEVEL SECURITY` is
refused**: it subjects the table owner too, and the table owner is the migration role and the restore
path, which then cannot `COPY` either. What [spike 004](/spikes/004-chart-of-accounts) actually needed
is the other half of its own sentence — *the app role must not own the tables* — and that holds
without `FORCE`.

**None of this touches append-only.** Policies, grants and triggers are three independent layers: the
writer has no `UPDATE`/`DELETE` grant on the journal with or without a policy, and when granted one
the `ENABLE ALWAYS` trigger still refuses the `DELETE`. Verified both ways, including under
`BYPASSRLS`. What RLS here does **not** protect against is a compromised writer, which sees every
tenant — and [0001](/decisions/0001-rust-and-postgres)'s "tenant isolation *is* row-level security"
should not be left standing unqualified.

## The DDL — applied

Every hunk below first ran on `spike_wse` on 2026-08-27 and was then undone; later the same day the
set was folded into `migrations/00001_baseline.sql` under
[0003](/decisions/0003-migrations)'s editable-until-v0.1 exception and re-verified on the merged
schema. Two integration-time notes: the RLS policy set grew from five tables to the **nine**
tenant-keyed tables the merge produced (the period record and the attestation log carry tenant_id
too), with a third, *explicit* `USING (true)` SELECT policy per table for the reconciliation role —
a sweep silently scoped to no tenant would report zero breaks on every book, which is this
project's nightmare shape; and `security_invoker` lands on `trial_balance`, the one statement
surface that stayed a view ([0011](/decisions/0011-period-close-and-report-axes)).

```sql
-- 1. every transaction references the event that caused it (ADR-0005).
--    Refuses if any event-less transaction exists. There is no backfill, and that
--    is the point: nothing could invent the event.
ALTER TABLE ledger_transactions ALTER COLUMN event_id SET NOT NULL;

-- 2. striping. A stripe is a physical partition of one account's balance row.
ALTER TABLE ledger_accounts
    ADD COLUMN stripe_count smallint NOT NULL DEFAULT 1
        CONSTRAINT ck_accounts__stripe_count CHECK (stripe_count BETWEEN 1 AND 1024);

ALTER TABLE ledger_account_balances
    ADD COLUMN stripe smallint NOT NULL DEFAULT 0
        CONSTRAINT ck_balances__stripe_non_negative CHECK (stripe >= 0);
ALTER TABLE ledger_account_balances DROP CONSTRAINT pk_balances;
ALTER TABLE ledger_account_balances
    ADD CONSTRAINT pk_balances PRIMARY KEY (tenant_id, account_id, currency, stripe);

-- the entry records which stripe's counter issued its account_seq. Without it two
-- stripes both issue 5 for one account and uq_entries__account_seq refuses the
-- second -- serialising every writer through a unique index, which is the
-- bottleneck striping exists to remove, moved one table over.
ALTER TABLE ledger_entries
    ADD COLUMN stripe smallint NOT NULL DEFAULT 0
        CONSTRAINT ck_entries__stripe_non_negative CHECK (stripe >= 0);
ALTER TABLE ledger_entries DROP CONSTRAINT uq_entries__account_seq;
ALTER TABLE ledger_entries
    ADD CONSTRAINT uq_entries__account_seq UNIQUE (tenant_id, account_id, stripe, account_seq);
-- ...and the stripe it names must be one that exists. Same trick as
-- fk_entries__account: make the denormalised copy part of a composite key.
ALTER TABLE ledger_entries
    ADD CONSTRAINT fk_entries__stripe FOREIGN KEY (tenant_id, account_id, currency, stripe)
    REFERENCES ledger_account_balances (tenant_id, account_id, currency, stripe);

-- 3. row-level security. The read role is new; the write role exists.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'openledger_read') THEN
        CREATE ROLE openledger_read NOLOGIN;
    END IF;
END $$;
GRANT USAGE ON SCHEMA public TO openledger_read;
GRANT SELECT ON ledger_accounts, ledger_events, ledger_transactions, ledger_entries,
                ledger_account_balances, account_types, fs_lines,
                trial_balance TO openledger_read;
-- balance_sheet_at and income_statement_for are set-returning FUNCTIONS, not views
-- (ADR-0011): SECURITY INVOKER by default and reached by EXECUTE (PUBLIC), so they
-- take neither a SELECT grant nor the ALTER below.

ALTER TABLE ledger_accounts         ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_events           ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_transactions     ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_entries          ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_account_balances ENABLE ROW LEVEL SECURITY;

-- the scalar subquery forces a once-per-statement InitPlan rather than a per-row
-- call of a STABLE function; the TWO-argument current_setting returns NULL when
-- the GUC is unset, and tenant_id = NULL matches nothing, so it FAILS CLOSED.
-- Repeat verbatim for ledger_events, ledger_transactions, ledger_entries and
-- ledger_account_balances.
CREATE POLICY rls_accounts__tenant ON ledger_accounts
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));

-- the writer is SUBJECT to RLS and admitted by it. This is what BYPASSRLS would
-- have given it, minus COPY FROM, which nothing needs.
CREATE POLICY rls_accounts__writer ON ledger_accounts
    FOR ALL TO openledger_app USING (true) WITH CHECK (true);

-- ...and without this the policies above are decoration on every read that goes
-- through the report view. trial_balance is the only report that is a view, so it
-- is the only one that needs this; the two statement functions are SECURITY INVOKER
-- already.
ALTER VIEW trial_balance    SET (security_invoker = true);

-- NOT taken: ALTER TABLE ... FORCE ROW LEVEL SECURITY. It subjects the table
-- owner, which is the migration role and the restore path.
-- NOT taken: ALTER ROLE openledger_app BYPASSRLS. Needs superuser; RDS and Aurora
-- do not have one to give.
```

## What we considered

| | Why not |
| --- | --- |
| **Support `SERIALIZABLE` with a retry loop** | Measured. An in-transaction retry rescues **nothing** — 0 of 25,074 attempts at sixteen writers — and a transaction-restart loop halves throughput and still loses 3–14%. It is optimistic concurrency on the one row every writer touches, refused with numbers by [spike 003](/spikes/003-throughput-ceiling) and refused again here. |
| **Document the isolation requirement and let deployments set it** | That makes an invariant configurable. `BEGIN ISOLATION LEVEL READ COMMITTED` overrides a `serializable` default per transaction, costs one clause, and cannot be forgotten by an operator because no operator is involved. |
| **Assert the isolation level at connection start** | A check that looks for a bad state instead of a constraint that makes it unreachable — the thing the non-negotiables list rules out. It also cannot see a `SET` issued later on the same session. |
| **Idempotency in one statement (`WITH attempt AS (INSERT … DO NOTHING) … UNION ALL SELECT`)** | Returns **zero rows** under the race it exists to handle. The CTE's `SELECT` runs on the pre-block snapshot. One fewer round trip in exchange for a hole. |
| **Cache the response body, as Stripe does** | Then a response-shape change never reaches a replay and a 500 replays as a 500 forever. `payload` is already specified to be *"complete enough to replay from"* ([0005](/decisions/0005-event-log-and-write-path)), so re-deriving is available and truthful. |
| **Return `409` for a concurrent duplicate, as Stripe does** | Stripe needs it because its work is not one database transaction. Ours is, so there is no window in which a key is claimed and its result is not yet durable. Inventing the state would mean inventing the failure. |
| **`400` for the poisoned replay, as Formance does** | 422 and 409 tell the client different things — *change the request* against *resend it unchanged*. Collapsing both onto 400 throws that away for nothing. |
| **Expire idempotency keys after 24 hours, as Stripe does** | Stripe's own docs: *"We generate a new request if a key is reused after the original is pruned."* A key past the window is silently treated as brand new, which converts a retry into a double-post. Our keys live as long as the log row, and the log row is append-only. |
| **A stripe as a `ledger_accounts` row** | Requires weakening `uq_accounts__house`, puts N rows in `trial_balance` for one account, makes every "list my accounts" call filter, and needs the roadmap's suspense sweep to consolidate the stripes back. All of it disappears when the stripe sits one table lower. |
| **Striping customer accounts too** | A single customer account costs 12% ([spike 003](/spikes/003-throughput-ceiling)); the shared row is the whole ceiling. And a customer's balance is a thing people ask about by name, so splitting it buys nothing and costs an identity. |
| **Enforce `stripe < stripe_count`** | Not expressible across two tables, and not wanted: the reader sums the rows that exist, so an out-of-range stripe cannot lose money and a lowered count cannot strand one. |
| **`BYPASSRLS` on the writer** | Works, and is ungrantable on RDS and Aurora — whose master user is `NOSUPERUSER` without it, with the only holder being AWS's internal `rdsadmin`. It also buys only `COPY`, which is worth nothing measurable here. |
| **`FORCE ROW LEVEL SECURITY`** | Subjects the table owner, so the migration role and `pg_restore` lose `COPY` too. The property [spike 004](/spikes/004-chart-of-accounts) wanted from it is *the app role must not own the tables*, which holds without it. |
| **RLS on reads via views only, base tables unguarded** | The default view is the *opposite* of a guard: `security_invoker = false` runs the query as the view owner and bypasses every policy. Measured — a reader scoped to `t1` read both tenants out of `trial_balance`. |

## What it costs

- **The writer sees every tenant.** The permissive writer policy is the honest version of what
  `BYPASSRLS` would have done. RLS here is a **read-path** control: it protects a reporting
  connection, an analyst, a BI tool. It does not protect against a compromised writer, and
  [0001](/decisions/0001-rust-and-postgres)'s flat sentence should be qualified to say so. Tightening
  the writer to `WITH CHECK (tenant_id = (SELECT current_setting('app.tenant_id', true)))` is
  available and would make a cross-tenant write structurally impossible — but it binds a transaction
  to one tenant, which the treasury due-from/due-to pair ([spike 004](/spikes/004-chart-of-accounts))
  would then have to be written to honour. Not decided here.
- **The GUC is the trust boundary, and it is outside the database.** `app.tenant_id` is set by
  whoever holds the connection. `SET LOCAL` per transaction, never `SET ROLE` per tenant — both recent
  RLS plan-cache CVEs came from role switching — and **RDS Proxy may pin the session on `SET`**, which
  would defeat the pattern on AWS's own proxy. Unverified, and it belongs with the deferred
  [RDS benchmark](/roadmap#if-this-ever-wants-a-production-story) beside the
  `BYPASSRLS` finding.
- **Gaplessness becomes per `(account, stripe)`.** The property is intact and the drift check still
  works per stripe, but an as-of reconstruction over one account now merges N ordered runs instead of
  walking one. The walk is wider; the proof is the same.
- **The current-balance read becomes a `SUM`.** One index range scan over a contiguous key prefix
  either way — 3 buffers at one stripe, 24 at 64, no sort. At the sizes measured (a 134-row balance
  table) the difference is below measurement, which means the *shape* is attested and the cost at a
  million accounts is not. The authorization path's one read is the one that pays it
  ([0002](/decisions/0002-scaling)).
- **`fk_entries__stripe` makes a balance row undeletable while entries reference it.** A cache
  rebuild becomes `UPDATE` in place rather than delete-and-reinsert. The app role has no `DELETE` on
  that table anyway, so in practice this costs the owner one habit.
- **Giving up `COPY` is measured at parity and is not free forever.** The gap widens with row count
  and narrows with per-row constraint work; at 10,000 rows `unnest` was still 0.98–1.00× of `COPY` on
  *this* table. Re-measure if `ledger_entries` ever loses a foreign key, and re-measure over a network,
  where `COPY`'s streaming protocol has an advantage localhost hides.
- **A policy is a sixth kind of object and the naming convention has five prefixes.**
  [0007](/decisions/0007-schema-conventions-and-chart) §1 lists `pk_ uq_ ix_ ck_ fk_`; the policies
  above are named `rls_<table>__<what>`, which fits the shape and extends the list. That convention
  needs one more row, and the schema-snapshot test 0007 asks for needs to dump `pg_policy` and
  `reloptions` — a `security_invoker` silently flipped to `false` is a tenant leak that no query
  fails on.
- **The balance table needs its scheduled `VACUUM` more, not less.** Striping multiplies the number
  of hot rows, and [spike 009](/spikes/009-where-the-balance-lives)'s finding reproduced itself here
  unprompted: the write bench left ~91 heap blocks of dead versions behind one live stripe row and
  autovacuum never came.
- **The contract binds the writer, not the schema.** The five schema decisions are in
  `migrations/00001_baseline.sql` (above), but the replay contract is a contract the writer honours
  — the same gap [0005](/decisions/0005-event-log-and-write-path) records about balance, one level
  along. What this ADR buys is that the shapes are decided and measured rather than assumed, and
  that `event_id NOT NULL` has a deadline attached to it.
- **The hash is not specified here.** [0005](/decisions/0005-event-log-and-write-path) defers the
  `payload`/`memento` split, and the fingerprint must be computed over a canonical byte form the
  writer owns. Formance's is `sha256` over Go's `encoding/json` of the parsed command struct, which
  couples every stored hash to Go field names — renaming a field silently invalidates all of them.
  Do not copy that.
