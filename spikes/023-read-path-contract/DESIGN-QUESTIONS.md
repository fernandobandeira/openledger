# The design questions the read path has to answer before it is built

**Written before the answers**, on 2026-09-01, against the shipped tree at `870d245`. M5 is the last
unbuilt Phase 1 milestone and the only one where the SQL already exists and **nothing in Rust has
ever called it**: `report_cursor()`, `trial_balance_at`, `income_statement_for` and
`balance_sheet_at` are in `migrations/00001_baseline.sql` (lines 1045–1318) and the `trial_balance`
view above them; the HTTP surface is exactly one route (`crates/api/src/lib.rs:74`); and
`openledger_read` — the RLS-scoped read role the whole tenant fence hangs off — is referenced only
by e2e fixtures. **No service code has ever connected as it.**

So this is not a spike about whether the reports are right. ADR-0011 measured that. It is a spike
about the **contract a Rust read path must honour** to reach them without breaking the two things
the write path already bought: tenant isolation that fails closed, and an issued report that keeps
saying the same thing.

Nine questions. Each names the decision it blocks and the evidence that would settle it. Where a
question sits against something already written down, the ADR and the sentence are named, because
that is where a refutation would land.

---

## 1 · Tenant scoping on a pooled connection — `SET`, `SET LOCAL`, or `set_config`?

**The decision it blocks:** whether the read path *requires* a transaction, and what that costs.

The RLS policies are, nine times over (`migrations/00001_baseline.sql:2601–2628`):

```sql
CREATE POLICY rls_entries__tenant ON ledger_entries
    FOR SELECT TO openledger_read
    USING (tenant_id = (SELECT current_setting('app.tenant_id', true)));
```

The baseline's own comment claims the fail-closed property: *"the TWO-argument current_setting
returns NULL when the GUC is unset — `tenant_id = NULL` matches nothing, so an unscoped session
FAILS CLOSED."* ADR-0013's cost list picks the form: *"`SET LOCAL` per transaction, never `SET ROLE`
per tenant."*

Neither sentence has been executed by service code, and the failure mode they guard against is
specific and cheap to reproduce: **a GUC set session-wide on a connection that is then returned to a
pool and handed to the next request for a different tenant.** The read path's pool is the serving
process's (`crates/db/src/lib.rs`), and sqlx does not promise to reset session state on release.

What would settle it:

- The leak, demonstrated. One pooled connection, `SET app.tenant_id = 't1'` on checkout A, a read on
  checkout B that sets nothing, and the row count B sees.
- `SET LOCAL` and `set_config(..., is_local => true)` demonstrated *not* to leak — and the trap
  underneath that: **`LOCAL` scope is the current transaction, and outside an explicit transaction
  every statement is its own transaction.** If `set_config(local)` in autocommit is gone by the next
  statement, the read path has no choice about the transaction.
- The fail-closed claim **verified rather than assumed**: unset GUC ⇒ `current_setting` NULL ⇒ zero
  rows, on the base tables and through `trial_balance` and the statement functions.
- One thing neither ADR says: `SET` takes no bind parameter, and `tenant_id` is caller-supplied
  `text` from a request body (ADR-0017: *"data scoping, not an auth claim"*). Whether the chosen form
  can be **parameterised** is therefore a correctness question, not an ergonomics one.

## 2 · Assuming the read role — shared pool, or its own?

**The decision it blocks:** where the read path's connections come from, and whether
`POOL_CONNECTIONS` moves.

`reconcile.rs` gets this right by not sharing anything: it opens its own `PgConnection` and issues
`SET ROLE openledger_recon` once, because the role is `NOLOGIN` and the login behind `DATABASE_URL`
only holds membership. The serving process has no such luxury — it has one pool of
`POOL_CONNECTIONS = 38`, and `crates/db/src/lib.rs` sizes it as dispatchers plus
`CONNECTIONS_ABOVE_THE_WRITERS = 6`, whose doc comment already claims the six are headroom keeping
the startup schema gate *"and any future reader"* from waiting behind a full pool of writers.
**This is the reader that comment was written for**, so the claim is now testable rather than
prospective.

The hazard is symmetric with Q1 and worse in consequence: a `SET ROLE openledger_read` that survives
a pool checkout hands the *writer* a role with no `INSERT` grant, and the reverse hands a reporting
query the writer's admit-all policy — a silent cross-tenant read.

What would settle it:

- The hazard, both directions, on a real pool: a `SET ROLE` leaking forward into a write, and a
  connection never scoped reading across tenants.
- Whether `SET LOCAL ROLE` inside a transaction is sufficient, and whether it composes with the
  `app.tenant_id` GUC — order of operations included, since a `SET LOCAL` issued *after* the role
  change runs under the new role's privileges.
- Whether it survives an error and a rollback inside the transaction.
- **The plan-cache question ADR-0013 raises and does not resolve.** Its cost list: *"both recent RLS
  plan-cache CVEs came from role switching."* sqlx prepares and caches statements per connection,
  keyed by SQL text. A statement prepared while the session was one role and executed while it is
  another is exactly the shape those CVEs describe. Reproduce it or refute it.
- What all of the above means for the two constants. Either the six are enough — in which case say
  what "enough" means in reports-in-flight — or they are not, and the number moves in the same
  change as the first read endpoint.

## 3 · Cursor reproducibility — the core M5 acceptance property

**The decision it blocks:** whether the read path may expose a cursor at all, and whether "re-run an
issued report" is a promise the API can make.

The roadmap's M5 done-when begins: *"an as-of query at instant T returns the same answer when re-run
under concurrent writes."* ADR-0006's watermark was **refuted** (spike 012: a row appeared below a
watermark already issued); ADR-0011 replaced it with `xact_id xid8` pinned at
`pg_snapshot_xmin(pg_current_snapshot())`, and `report_cursor()` in the baseline is that one line.

The mechanism has been proven on isolated tables. It has **not** been proven end to end through the
three shipped functions, and there is a specific reason to look: a function applies its cursor to the
branches its author remembered. ADR-0011 §3 already had to admit that these functions *"never
reference `ledger_period_balances`"* — proven from `pg_get_functiondef`, not from the source file.
The same instrument should be pointed at the cursor predicate.

What would settle it:

- A report run, its `pinned_cursor` captured, concurrent posting, the same cursor re-run, diffed
  byte for byte. Posting through the **compiled binary over HTTP** where possible — a read-path spike
  that writes with hand-built SQL is measuring a schema, not a system.
- The ADR-0006 breaker constructed deliberately: **a transaction that starts before the cursor is
  taken and commits after it.** What `xact_id < cursor` does with it, with the transaction's own
  `xact_id` and the cursor printed side by side rather than inferred.
- **Every branch of every aggregation, read out of `pg_get_functiondef`**, and each one classified:
  pinned by the cursor, pinnable and not pinned, or **unpinnable because the table it reads carries
  no `xact_id` at all.** The third class is the interesting one, and it is not hypothetical — the
  `scopes` CTE in both statement functions reads `ledger_accounts`, and `ledger_accounts` has no
  `xact_id` column. If a branch of an issued statement can move under a fixed cursor, the reader
  gets to know which one.
- The chart version: both statement functions default it to `max(version)` over `chart_versions`.
  A default evaluated at run time is a second unpinned axis, and ADR-0011 §4's own reason for
  returning `chart_version` as a column was *"so a reader can tell a fresh report from one pinned
  behind a stale horizon."*

## 4 · Backdating, on both axes

**The decision it blocks:** whether one endpoint can serve both axes, or each axis needs its own.

The second clause of M5's done-when: *"the backdating case (insertion order ≠ effective order) is
correct on both axes."* ADR-0006's worked table is three entries into one account with the third
backdated, where a stored running balance reads 180 against a truth of 130.

The subtlety worth naming before measuring: **there is no shipped recorded-axis function.**
ADR-0006's mechanism table says the recorded-axis read is *"aggregate filtered by the commit cursor
`xact_id < :cursor`"* — which is the same `p_cursor` parameter the effective-axis functions already
take. So the two axes may be one function with two parameter shapes, and if they are, the endpoint
surface in Q6 has to say so out loud rather than inventing two resources.

What would settle it: post entries whose `effective_at` precedes an already-posted one, then show
each axis's answer correct *and* reproducible — the second half being the one that catches an axis
served by an unpinned branch.

## 5 · Result size, and the 30-second statement timeout

**The decision it blocks:** pagination, a read-path timeout of its own, or both.

`trial_balance_at` returns one row per (account, currency) and the statements return one row per
`fs_line`, so the *result* is small and bounded by the chart. The **scan** is not: ADR-0011 §3 and
the roadmap both record that the three functions never read `ledger_period_balances`, so they
aggregate `ledger_entries` from inception. The serving pool sets `statement_timeout = '30s'`
(`crates/db/src/lib.rs`, `SESSION_TIMEOUTS`), chosen for a writer whose statements are
single-millisecond appends.

What would settle it: an indicative measurement of an inception scan at growing book sizes, enough
to say at what order of magnitude it approaches the 30 s budget, with the 1-minute loadavg recorded
beside every number and the plain statement that another agent may have been loading this machine —
so the numbers are **shape, not benchmark**. And then a ruling on the three candidate answers:
pagination (which the result size does not obviously need), a longer timeout for reads (which trades
an outage for a queue), or the checkpoint wiring M5 already owns.

## 6 · The endpoint surface

**The decision it blocks:** ADR-0014's *"the API is the adoption surface"*, applied to reads.

Six candidates, each of which has to justify itself:

- **An account's current balance.** Per ADR-0018 and the roadmap's own correction, this is a `SUM`
  over the account's stripe rows — *"a naive single-row read under-reports the balance"* — and it is
  the one read with a latency deadline rather than a throughput target.
- **A balance as of a business date.** The effective axis, which is the axis every real as-of
  question is asked on (ADR-0006).
- **The trial balance**, pinned.
- **The balance sheet** and **the income statement**, which are the two that `RAISE` and therefore
  the two that need an error grammar.
- **Reading back a transaction the caller posted.** A write-only API is hard to adopt; scope creep
  is worse. This one has to be argued to a verdict, not listed.

Each needs a path, a method, its parameters and its error cases — and the surface has to name what
it deliberately leaves out, because ADR-0014's route table is machine-checked against the committed
spec in both directions and a route that exists is a route that is documented forever.

## 7 · Where the read path lives in the hexagon

**The decision it blocks:** a second method on `Ledger`, or a second inbound port.

`crates/ledger/src/port.rs` is one trait with one method, and its doc says the quiet part out loud:
*"One consumer-facing capability — post a transaction — so one method; anything else the API grows
must earn its place here first."* `crates/api/src/lib.rs`'s `AppState` was already written for this
day: *"A struct rather than the bare port so the next port — reads will get their own when the first
read endpoint arrives — lands as one more field."*

`deny.toml`'s capability ratchet forbids `sqlx` in `crates/ledger`, and the `Repository` port's rule
is one trait method per SQL statement.

What would settle it: reading `deny.toml` and `port.rs` and stating whether the answer needs the
ratchet relaxed. **If it does, that is a finding**, not a footnote — ADR-0015 calls the boundary
*"machine-enforced, not conventional"*, and a read path that needs an exception is the first thing to
test that claim.

## 8 · The error grammar for reads

**The decision it blocks:** which HTTP statuses the read endpoints declare, per ADR-0014's
*"each endpoint documents only the errors it can actually return."*

The write path's grammar is fixed: 422 for the poisoned replay, no invented 409, and error `type`s
that *"name their subject first and their condition second"*. Reads have to extend it, and the
functions already have opinions: `balance_sheet_at` and `income_statement_for` both
`RAISE EXCEPTION ... USING ERRCODE = '23514'` on a missing or nonexistent chart version, and again
on an in-scope account type the chosen version does not present.

Five inputs need an answer: an unknown account, an unknown tenant, a nonexistent chart version, a
malformed cursor, and an empty book.

And one distinction that may not be available at all: **"no rows because the book is empty" against
"no rows because RLS scoped you out."** Both are the fail-closed path working correctly. If the API
cannot tell them apart, that is a design consequence to state in the ADR, not a bug to fix in the
handler — ADR-0017 already accepts that `tenant_id` in the body asserts nothing about the caller.

## 9 · Isolation for a report

**The decision it blocks:** whether the read path opens `REPEATABLE READ READ ONLY`, plain
`READ COMMITTED`, or nothing at all.

`reconcile` runs `REPEATABLE READ READ ONLY`, and its own comment is unusually honest about why the
isolation buys nothing *today*: *"the sweep is a single statement, and a single statement is one
snapshot at every isolation level."* ADR-0010's reason is the multi-statement future; ADR-0013 §1
says a read-only reporting transaction *"may run at `REPEATABLE READ`; for a multi-statement report
it should."*

A single cursor-pinned report function may need neither, because the cursor is doing the job the
snapshot would do. The question is whether that holds for the branches the cursor does **not** pin
(Q3), and whether a multi-statement read — a balance sheet plus `close_disclosures`, say — changes
the answer.

What would settle it: the reasoning, stated against Q3's branch classification, plus the cost
`reconcile` already documents — ADR-0010's cost list: one snapshot for the whole sweep means one
`backend_xmin` for the whole sweep, which *"pins [ADR-0006]'s as-of watermark, which is defined off
`pg_snapshot_xmin`."* **A long report transaction holds back the cursor of every report issued after
it, including its own successors.** That is a self-inflicted wound worth pricing before choosing an
isolation level for a read path.
