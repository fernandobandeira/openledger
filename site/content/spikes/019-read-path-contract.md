# Spike 019 — What must a Rust read path honour to reach the shipped report functions?

**Status:** closed. Produced [ADR-0019](/decisions/0019-read-path). **The fence is a property of
`current_user`, not of the connection or the GUC — so a read needs its own login; the cursor pins a
report's amounts and not its row set; and the same report costs 11.0 s, 4.2 s or 2.7 s depending only
on how the cursor reaches the planner.**
*(Directory `spikes/023-read-path-contract/`; the spike directories carry their own numbering.)*

**Question.** M5 is the last unbuilt Phase 1 milestone and the only one where the SQL is applied and
**nothing in Rust has ever called it**. `report_cursor()`, `trial_balance_at`,
`income_statement_for` and `balance_sheet_at` have been in `migrations/00001_baseline.sql` since the
baseline; the HTTP surface is one route; and `openledger_read` — the role the whole read-side tenant
fence hangs off — is referenced only by e2e fixtures, so **no service code has ever connected as
it.** What contract must a Rust read path honour to reach those functions without losing tenant
isolation or report reproducibility? The deliverables are in the repository at
`spikes/023-read-path-contract/`: `DESIGN-QUESTIONS.md` written before the answers, `SPEC.md`,
`FINDINGS.md` with every claim labelled **proven** / **measured** / **unmeasured, reasoned**,
`RECOMMENDATION.md` as numbered rulings, `RUN-q3.sh` / `RUN-q5.sh` / `RUN-q8.sh` / `RUN-q9.sh`,
`sql/`, a self-contained `harness/`, and `out/`, where every quoted number is grep-able.

[ADR-0019](/decisions/0019-read-path) carries the rulings. **This page carries the measurements and
the method**, and does not repeat the decision. Localhost, PostgreSQL 18.6, with another agent's
spike running against the same cluster throughout and the 1-minute loadavg between **2.32 and 4.22**
during the cost measurements — **shape, not a benchmark.**

---

## The three findings that changed the design

**1 · A login that is a member of both `openledger_app` and `openledger_read` reads every tenant, with
every policy, grant and comment in the schema exactly as written.** Two purpose-built logins, the same
script:

| | `spike023_reader` (member of `openledger_read`) | `spike023_dual` (member of `openledger_app` **and** `openledger_read`) |
| --- | --- | --- |
| no GUC at all | **0 entries** | **6 entries, tenants t1,t2** |
| `set_config('app.tenant_id','t1',true)`, inherited membership, no `SET ROLE` | 4 entries, t1 | **6 entries, tenants t1,t2** |
| the same behind `SET LOCAL ROLE openledger_read` | 4 entries, t1 | 4 entries, t1 |

A row-security policy applies to any `current_user` that `pg_has_role(current_user, polrole, 'USAGE')`
reaches, and multiple permissive policies are **OR'd**. The baseline declares three per tenant-keyed
table — the reader's `tenant_id = current_setting(…)`, the writer's `USING (true)`, the sweep's
`USING (true)` — so a login that inherits `openledger_app` gets `tenant_id = current_setting(…) OR
true` and `app.tenant_id` becomes decoration. **The shipped tree has never been able to observe
this**, because it has one `DATABASE_URL`, it is the owner's, and the owner is not subject to RLS at
all. This contradicts nothing in [ADR-0013](/decisions/0013-write-path-contract) — its §5 is about
roles and the roles are right. What it establishes is that *"share the writer's pool"* and *"read as
the read role"* are not independent choices.

**2 · The cursor pins a report's amounts and does not pin its row set.** Read out of
`pg_get_functiondef` rather than the source file, every amount in all three statements comes from a
`p_cursor`-filtered branch — seven such branches, including `balance_sheet_at`'s A14 guard, its `pos`
term and its un-closed-earnings plug. The lines, however, are enumerated from `ledger_accounts`,
`chart_versions`, `chart_presentation`, `fs_lines`, `account_types` and `ledger_period_closes`, and
the catalog confirms the shape of the problem:

```
tables carrying xact_id: ledger_entries, ledger_events, ledger_transactions
tables the reports read that carry NO xact_id: account_types, chart_presentation,
    chart_versions, fs_lines, ledger_accounts, ledger_period_closes
```

**Six tables, no `xact_id` column at all.** One new EUR `fee_revenue` account, nothing posted to it,
at a fixed cursor: the balance sheet gained **ten rows** and the income statement **four**, with every
amount on every pre-existing row byte-identical.

**3 · The same `balance_sheet_at` call on the same data costs 11.0 s, 4.2 s or 2.7 s, and the
*generic* plan is the fast one.** Same function, same cursor, three ways of reaching the planner:

| how the query reaches the planner | median | shared buffers |
| --- | --- | --- |
| the function, **custom** plan — calls 1–5 on a connection | **11,046–11,079 ms** | 47.3 M |
| the function, **generic** plan — call 6 onward | **4,138–4,200 ms** | 7.44 M |
| the same body inlined with the cursor as a **literal** | **2,731–2,767 ms** | 2.49 M |
| `SET plan_cache_mode = force_custom_plan` | 11,061–11,207 ms | 47.3 M |

A 4.0× spread on identical SQL over identical data, and the direction is the opposite of the usual
advice. PL/pgSQL builds a custom plan for a statement's first five executions on a connection and
then considers a generic one, so **a pooled read path has a warm-up and the sixth report on each
connection is the first fast one** — while `force_custom_plan`, the knob an operator reaches for when
a generic plan misbehaves, pins the 11 s plan permanently.

---

## Method

- **A real database, and not the shared one.** `CREATE DATABASE spike023` on the project's own
  instance (PostgreSQL 18-alpine, port 5433), schema applied by the **compiled binary** — three
  migrations in 174 ms — and the chart seeded from `schema/chart.sql`. Nothing outside
  `spikes/023-read-path-contract/` was modified: no migration, no crate, no doc.
- **Writes through the compiled binary over HTTP wherever that reaches**, because a read-path spike
  that writes with hand-built SQL is measuring a schema rather than a system. Two exceptions, both
  stated at their use: the [ADR-0006](/decisions/0006-time-and-as-of) breaker needs a transaction
  held open across a cursor capture, which the HTTP writer cannot do because it commits before it
  answers; and the million-entry book cannot be posted one HTTP call at a time in the time available.
- **Two login roles the shipped tree does not have**, created by hand and dropped by teardown, because
  the owner is not bound by RLS at all (`FORCE ROW LEVEL SECURITY` is deliberately unset) and
  therefore cannot answer the question a deployment faces.
- **Every experiment gated on `SELECT * FROM reconciliation` at ten zeros** — and the gate is honest
  about when it held. It is satisfied at the **end** of the run (`book reconciled — 10 checks, 0
  breaks, 28970 ms`, on 1.11 M entries), because during the run a neighbouring database held the
  cluster horizon back. Nine of ten checks were at zero throughout, and every one of the 10,016
  `cursor_forgery` breaks was `reason = above_horizon` with `xact_id = txn_xact_id` — no forgery, and
  nothing wrong with the book.
- **Five passes per cost cell, median quoted, full range printed**, with `EXPLAIN (ANALYZE, TIMING
  OFF, BUFFERS)` rather than `\timing`, so psql's round trip is excluded and the buffer counts come
  along.
- **One rule added after [spike 018](/spikes/018-batching-and-stripe-selection)**: every number quoted
  in `FINDINGS.md` is grep-able in a kept file under `out/`. Nothing is quoted from a smoke run.
- **The endpoint surface and the hexagon placement are labelled *reasoned*, not measured**, and are
  argued against the tree — the route table, `AppState`, both ports, the composition root, `deny.toml`
  and `clippy.toml`.

---

## A · The tenant fence on a pooled connection

**The baseline's fail-closed claim is true, and nothing had executed it.** As `openledger_read` with
`app.tenant_id` never set: zero entries on the base tables, through the `security_invoker` view, and
through both `SECURITY INVOKER` statement functions (`trial_balance_at`, `balance_sheet_at` and
`income_statement_for` all at 0 rows).

**A session `SET` leaks across a pool checkout.** On a real `sqlx::PgPool` configured the way
`crates/db` configures the serving process's, with `max_connections(1)` so that "the connection the
next request gets" is deterministic:

```
checkout 1: SET app.tenant_id = 't1', then read     entries=4 guc=t1 tenants=t1
checkout 2: sets NOTHING, reads as if for t2        entries=4 guc=t1 tenants=t1
```

**sqlx 0.9 issues no reset on release.** Checkout 2 inherited t1's scope and read t1's rows while
believing itself unscoped: the next request does not have to be malicious or even buggy, only to trust
the pool. `SET LOCAL` and `set_config(…, true)` inside `BEGIN … READ ONLY` do not leak — 4 entries
inside the transaction, **0** on the same connection after `COMMIT` and 0 on the next checkout.

**`SET` takes no bind parameter and `set_config` does, and that is a correctness finding rather than
an ergonomic one.**

```
SET app.tenant_id = $1     REFUSED: syntax error at or near "$1"
set_config($1, is_local => true) in a transaction     applied=t2 entries=2 tenants=t2
…and with a hostile tenant_id as the bind
     applied="t2'; SET ROLE openledger_app; --" entries=0 current_user=openledger_read
```

`tenant_id` is caller-supplied `text` from a request body
([ADR-0017](/decisions/0017-no-authentication) is explicit that it is *"data scoping, not an auth
claim"*), so the only form of the statement that can carry it is the one that carries it as **data**.
The hostile value was stored verbatim as the GUC, matched no tenant, and left `current_user`
untouched.

**`is_local => true` with no explicit transaction is a silent no-op, and that is what makes the
transaction mandatory.** `LOCAL` scope is the current transaction and in autocommit each statement is
its own transaction, so the setting is discarded before the read it was meant to scope: `applied=t1`,
next statement `guc=`, read `entries=0`. The failure direction is benign — an empty book, not another
tenant's rows — but a read path built this way returns an empty book for every request forever, and
the fence never fires because nothing ever gets past it. The cost of the transaction is two extra
round trips per read, ~0.2 ms on localhost and ~1.5 ms at [ADR-0002](/decisions/0002-scaling)'s
~0.5 ms round trip: noise against a report, and not noise against a per-account balance read whose own
work is 0.09 ms.

**The single-round-trip alternative is refused on principle rather than on measurement.**
`WITH s AS (SELECT set_config('app.tenant_id', $1, true)) SELECT …` has no documented evaluation order
between a non-data-modifying CTE and the outer query, and a tenant fence resting on an unspecified
evaluation order is not a fence. It was attempted; the attempt ran as the owner, who is not subject to
RLS, so it establishes nothing either way — **which is itself the reason to refuse the shape rather
than trust an observation of it.**

**After `RESET` the GUC is `''`, not NULL, and what fails closed there is a `CHECK` constraint.**

```
fresh connection, never SET       current_setting => None
after SET then RESET              current_setting => Some("")
can a tenant be named ''?         REFUSED: violates check constraint "ck_accounts__tenant_non_empty"
```

The baseline's comment names exactly one mechanism — the two-argument `current_setting` returning NULL
for a GUC that was never set. That covers a connection never scoped. It does not cover a connection
scoped and then reset, which is the state a pool with an `after_release` hook would leave; there
`tenant_id = ''` is a real comparison, and what saves it is
`ck_*__tenant_non_empty CHECK (btrim(tenant_id) <> '')` on all nine tenant-keyed tables, refused above
even for the owner, who bypasses both RLS and grants. **A future migration that relaxed those checks
would open a cross-tenant read on reset connections, and no comment in the RLS section would warn
about it.**

## B · The read role, and what the policy union costs

**`SET LOCAL ROLE` is sufficient, composes with the GUC and survives an error.** Inside the read's own
transaction, `SET LOCAL ROLE openledger_read` followed by `set_config('app.tenant_id','t1',true)` — the
GUC set *after* the role change, therefore under the read role's privileges, which works because
`app.` is a placeholder namespace and so `USERSET`. After `COMMIT` the connection is the login again;
after a division by zero and a `ROLLBACK` it is the login again with the GUC back to `<NULL>`.

**A session `SET ROLE` survives a checkout and disarms the writer**, in the direction that costs
money and fails closed: checkout 1 sets the role, and checkout 2's posting runs as
`openledger_read` and is refused `permission denied for table ledger_accounts` — a 500 on a posting,
not a silent write to the wrong place.

**A read pool with `SET ROLE openledger_read` in `after_connect` works, and its role is escapable.**
There is no per-request role statement to forget and a connection never scoped reads nothing; but
`RESET ROLE` on a read-pool connection returns `current_user=openledger`. That is acceptable for a
pool whose SQL the read path writes and unacceptable as a security boundary against arbitrary SQL,
which the read path is not. The boundary without that hole is a separate **login** whose only
membership is `openledger_read`, whose `RESET ROLE` lands on a role with no grants and no writer
policy.

**The RLS plan-cache hazard does not reproduce, and that withdraws a worry.** One connection, one SQL
text, sqlx's per-connection prepared-statement cache, four executions across a role change *and* two
GUC values, starting from the worst case — the first plan prepared as the **owner**, for whom RLS does
not apply at all, so the cached plan carries no RLS qual whatsoever:

```
1st execution: OWNER, no GUC                    entries=1110024 tenants=big100k,big10k,big1m,t1,t2
2nd execution: same text, reader scoped to t1    entries=22 tenants=t1
3rd execution: same text, GUC moved to t2        entries=2 tenants=t2
4th execution: same text, back to the OWNER      entries=1110024 tenants=…
```

Every execution correct for the role and scope in force, on PostgreSQL 18.6 with sqlx 0.9.

**The pool arithmetic is reasoned, not measured, and the deciding reason is not capacity.** Against
`DISPATCHERS = 32`, `POOL_CONNECTIONS = 38`, `ACQUIRE_TIMEOUT = 15 s` and this spike's measured report
costs: a report holds its connection for the whole of its transaction, and `balance_sheet_at` on a
million-entry book holds it for **4–11 s**. Six concurrent reports exhaust the six headroom
connections, and the seventh competes with 32 dispatchers that are full by design and loses its
acquire at 15 s — a read path taking the write path's connections and then failing anyway. But the
reason the read path must not share is the policy union above: sharing the pool means sharing the
*login*. A read pool can also carry its own `statement_timeout` (a pool whose `after_connect` sets
`90s` reports `90s`) and `openledger_read` can raise it per transaction itself (`SET LOCAL
statement_timeout = '120s'` reports `2min`), so the timeout alone requires no second pool.

## C · The cursor, confirmed end to end on the shipped functions

The interleaving is [ADR-0006](/decisions/0006-time-and-as-of)'s, constructed deliberately: adversary
A opens a transaction and posts by hand (`xact_id 15783`) without committing; B posts through the
compiled binary over HTTP and commits (`xact_id 15784`). **A started first, holds the lower id, and
commits last.**

```
report_cursor() = pg_snapshot_xmin:      15760
max(xact_id)+1  (the refuted watermark): 15785
  A below the pg_snapshot_xmin cursor?   f
  A below max(xact_id)+1?                t
```

All three reports rendered at each cursor, A committed, all three re-rendered:

```
--- pg_snapshot_xmin cursor 15760, before vs after A's commit ---
IDENTICAL — the cursor holds under a transaction that spanned it
--- the refuted watermark 15785, before vs after A's commit ---
DIFFERENT — a row appeared below a watermark already issued
```

The watermark's diff is **131,000 → 230,000** on `receivables`, `current_year_earnings` and `revenue`,
and 131,000 → 230,000 on the trial balance. [Spike 012](/spikes/012-period-close) proved this class on
isolated tables; **it is now proven on `trial_balance_at`, `balance_sheet_at` and
`income_statement_for` as shipped.** The negative control is a cursor explicitly above every committed
write — 18,000 at the pinned cursor against 230,000 at 15785 — so the pinned cursor is withholding
rather than merely agreeing with itself.

**One branch is unfiltered and is nonetheless sound, and it is worth recording so nobody "fixes"
it.** The join `ledger_transactions x … AND x.status = 'posted'` carries `xact_id` and is not filtered
by it: `fk_entries__transaction` means an entry cannot exist before its transaction, so an entry below
the cursor has a transaction below the cursor, and `status` is immutable under `ck_txn__append_only`
(`ENABLE ALWAYS`) plus `REVOKE UPDATE … FROM openledger_app`. **The safety is a key and a trigger, not
a predicate.**

**The chart version is a second unpinned axis, and naming it only half closes it.**

```
default resolves to version 3
explicit v1 vs default: 1 vs 3
appending a line to the FROZEN version 1: ERROR ... below the current maximum 3 ... frozen history
appending a line to the CURRENT version 3, at a FIXED cursor: rows 10 -> 11
```

`refuse_stale_chart_version()` freezes history and not the present, so a statement pinned at the
*current* version gained a line at a fixed cursor.

**The horizon lags by the cluster, and it happened here, unbidden.** A session belonging to another
agent's spike, in a **different database on the same cluster**, held `report_cursor()` at 15760 for the
whole Q3 run:

```
 pid  |   datname    |        state        | backend_xmin
 6042 | spike024arms | idle in transaction |
 6045 | spike024arms | active              |        15760

 cursor_now | entries_total | entries_a_report_would_see | entries_above_the_horizon
      15760 |            12 |                          8 |                         4
```

A third of the book was above the horizon at that moment and half of it (8 of 16) later in the run.
[ADR-0011](/decisions/0011-period-close-and-report-axes) and
[ADR-0010](/decisions/0010-reconciliation) both predict this in prose; it is now reproduced by
accident, by a third party, on this project's own development cluster, within one working session.
**The read path cannot treat "the cursor is roughly now" as an assumption**, and an endpoint that
returns `pinned_cursor` is returning the only thing that lets a caller notice.

## D · Two legal cursor values, and one absent one, that make a report lie

No function is `STRICT` (`proisstrict = false` on all five) and `EXECUTE` is `PUBLIC` (`proacl` NULL
on all five). A NULL cursor therefore reaches the SQL and filters every entry — but **the statements
enumerate their lines from the chart**, so the shape of the answer survives and only the numbers go to
zero:

```
balance_sheet_at('t1','infinity', NULL, 3)
  rows=20   assets=0   liab_eq_earn=0   rows_with_null_pinned_cursor=20
recon_equation_breaks(NULL,'infinity')
  equation_breaks=0
income_statement_for('t1', -inf, inf, NULL, 3)   4 rows, all 0
trial_balance_at('t1', -inf, inf, NULL)          0 rows
```

**The accounting equation holds trivially and the highest-leverage reconciliation check in the system
reports zero breaks on a fabrication.** `trial_balance_at` is the exception precisely because it
enumerates from the *entries*, so it returns nothing instead of returning a lie. A NULL `p_asof` gives
10 rows at 0 and a NULL effective range gives 4 rows at 0.

And a supplied cursor can be worse than an absent one:

| cursor | result |
| --- | --- |
| `'not-a-cursor'` | `ERROR 22P02: invalid input syntax for type xid8` — the good case |
| `'0'` | 20 rows, total **0** — the same fabrication as NULL |
| `'18446744073709551615'` (xid8 max) | 20 rows, total **884,000** — the whole book, unpinned |
| **`'-1'`** | **20 rows, total 884,000** — because `'-1'::xid8 = '18446744073709551615'::xid8` is `t` |

`-1` is the natural sentinel for "no cursor" in any signed integer and it silently wraps to the
maximum. The report it produces carries **today's correct numbers** and a `pinned_cursor` that will
still be above every transaction id forever, so it is an *unpinned* report that looks fine and re-runs
identically until the book changes, then changes with it. **That is harder to catch than the all-zero
case**, and the database cannot refuse either: both are legal `xid8`. The one tell in the NULL case is
that `pinned_cursor` comes back NULL on all 20 rows — detectable at the outermost layer of a
five-layer stack whose innermost layer has `EXECUTE` to `PUBLIC`.

This is the same defect class the baseline already documents and guards for the chart version, at its
A13 comment: *"the old COALESCE never touched `chart_versions`, so `income_statement_for(..., 999)`
returned a fabricated, all-zero, perfectly balanced statement citing a version nobody created."*
Guarded for the chart version; **unguarded for the cursor, the as-of instant and the effective
range.**

## E · Both axes, on one function

ADR-0006's own worked table, scaled by 100 and posted in ADR-0006's own order through the compiled
binary over HTTP — Jan 10 +10,000, Jan 30 +5,000, then Jan 20 +3,000 **backdated third**:

| as of | receivable, minor units | ADR-0006's table ×100 |
| --- | --- | --- |
| 2026-01-15 | 10,000 | 10,000 |
| **2026-01-25** | **13,000** | **13,000** — the truth, against a running balance's 18,000 |
| 2026-02-01 | 18,000 | 18,000 |

The recorded axis is the same function with the cursor as its parameter: `trial_balance_at` returned
18,000 at the pinned cursor and 230,000 at a cursor above everything. **One function serves both axes,
and the axis a caller asked about is which parameter they varied** — which is why the surface wants one
resource with both parameters named on it rather than two resources.

## F · What a report costs, and where the cost sits

**Measured. Indicative, not a benchmark** — five passes per cell, median quoted, another agent's spike
on the same PostgreSQL throughout, loadavg 2.32–4.22 recorded on every line.

| book | `trial_balance_at` | `balance_sheet_at` | `income_statement_for` | current balance (`SUM` over stripes) | mid-book effective range |
| --- | --- | --- | --- | --- | --- |
| 10,000 entries | 9.9 ms | 64.8 ms | 37.6 ms | **0.100 ms** | 6.9 ms |
| 100,000 entries | 76.2 ms | 1,207.9 ms | 473.0 ms | **0.094 ms** | 61.6 ms |
| 1,000,000 entries | 1,057.2 ms | **11,428.1 ms** | 4,302.9 ms | **0.091 ms** | 574.7 ms |

Ranges across the five passes were tight: `balance_sheet_at` at 1 M, 11,296–12,163 ms;
`trial_balance_at` at 1 M, 1,012–1,081 ms; the current-balance read at 1 M, 0.084–0.133 ms. *(Two
custom-plan medians for `balance_sheet_at` at 1 M appear on this page and they are not the same
measurement: 11,428.1 ms is this ladder's, taken with `EXPLAIN (ANALYZE …)` over five passes, and
11,046–11,079 ms is the plan-cache experiment's. Both are custom-plan figures from different runs, and
neither is quoted as the other.)*

Three things the table says:

- **The result is tiny and the scan is not.** At 1 M entries the three reports return **2, 10 and 4
  rows**. Pagination has nothing to paginate.
- **`balance_sheet_at` is the binding constraint**, at ~11× `trial_balance_at` on the same book.
  Extrapolating linearly from 1 M it meets the serving pool's `statement_timeout = '30s'` at **order
  2–3 million entries** — one tenant, one currency, three years. `income_statement_for` meets it around
  **7 M** and `trial_balance_at` around **28 M**. A read-only pool's own longer timeout is worth having
  and fixes little: at linear growth, 90 s is reached at ~8 M entries instead of ~2.5 M. **The order of
  magnitude is 10^6, not 10^9**, and that is the finding.
- **The current-balance read is flat** — 0.091–0.100 ms across a hundredfold change in book size, as a
  `SUM` over the account's stripe rows. ADR-0006's *"current balance (the hot path)"* and
  [ADR-0018](/decisions/0018-batching-and-stripe-selection)'s stripe `SUM` are both confirmed on a real
  book at three sizes.

**Corroborated from outside the harness**: the reconciliation sweep on this book took **28,970 ms**,
because `recon_equation_breaks` calls `balance_sheet_at` per tenant. The daily sweep is already at
29.0 s against a 30 s budget at 1.11 M entries, and it survives only because `reconcile` opens its own
`PgConnection` and sets no `statement_timeout` on it.

**Where `balance_sheet_at`'s cost sits.** It touched 47.3 M shared buffers for a ten-row answer,
against `trial_balance_at`'s 27 k on the same journal. The term is the **un-closed-earnings plug**, a
correlated subquery in the `SELECT` list whose plan is
`Nested Loop -> Bitmap Heap Scan on ledger_transactions -> Index Scan using ix_entries__txn on ledger_entries (loops=500000)`
— **half a million index probes for one scope row**, 2.48 M buffers, against `pos`'s hash join at
27 k — and it is evaluated once per `(tenant, currency)` scope, so a two-currency tenant pays it twice.
Every cell in the ladder above is a **custom-plan** number, because each `psql -c` opens a fresh
connection: the ladder measures the slow plan throughout, which is the conservative direction.

**And the checkpoint has no reader, confirmed catalog-wide rather than from three
`pg_get_functiondef` calls:**

```
ledger_period_balances is referenced by: <no function>
and by these views: recon_checkpoint_breaks
```

What this adds to [spike 016](/spikes/016-close-cost-at-scale)'s finding and to M5's plan is a target
and a term: **`balance_sheet_at` first**, because it is 11× `trial_balance_at` and is what
`recon_equation_breaks` calls per tenant, so wiring it pays twice; and **the plug**, whose shape needs
rewriting rather than merely bounding.

## G · The surface and the errors — reasoned, not measured

Five routes, and only five, argued against [ADR-0014](/decisions/0014-http-api)'s route table, which is
machine-checked against the committed spec in both directions so that a route that ships is documented
forever.

| route | pinned by |
| --- | --- |
| `GET /v1/accounts/{account_id}/balance` | nothing — it means *posted, now* |
| `GET /v1/reports/trial-balance` | cursor + effective range |
| `GET /v1/reports/balance-sheet` | cursor + `as_of` instant + chart version |
| `GET /v1/reports/income-statement` | cursor + half-open effective range + chart version |
| `GET /v1/transactions/{transaction_id}` | nothing — the rows are immutable |

The balance endpoint has to read `ledger_accounts` and not only `ledger_account_balances`, and that is
proven rather than argued:

```
a real account with activity            stripe_rows = 6, balance_minor = 442000
an account id that does not exist       stripe_rows = 0, balance_minor = NULL
an account that EXISTS but has never
  been written (no balance row yet)     stripe_rows = 0, balance_minor = NULL
…and the account row itself             account_exists = 1
a currency the account does not hold    stripe_rows = 0
```

A balance row is created lazily by the first write, so the cache alone cannot tell an unknown account
from a dormant one or from a currency the account does not hold — all three are zero rows and a NULL
sum. Note the `stripe_rows = 6` on the active account: **eight stripes declared, six existing**, which
is the lazy-creation property in the same output.

**The chart version is the only input that raises.** `balance_sheet_at(…, 999)` and
`income_statement_for(…, 999)` both fire their A13 guard as `23514`. Everything else is silence:

| condition | what a caller sees |
| --- | --- |
| a tenant that does not exist | 0 rows |
| a tenant whose name was typo'd by one character | 0 rows |
| a real tenant with no accounts yet | 0 rows |
| **a reader scoped to `t1` asking for `t2`** | **0 rows** |
| **a reader with no scope at all asking for its own tenant** | **0 rows** |

**Five conditions, one observable — and two of the five are the fail-closed path working exactly as
designed.** *(`FINDINGS.md`'s seven-line summary calls this "four different conditions" while its own
table lists five; the table is the one with the outputs beside it.)* Distinguishing them would require
consulting something *outside* the RLS fence, and the fence's whole purpose is that there is no such
thing. The asymmetry is the part to state out loud: a wrong `chart_version` **raises** while a wrong
`tenant_id` is answered with silence, and an integrator will learn the wrong lesson from whichever they
hit first.

## H · Isolation

**A single call needs no transaction for consistency**, because one statement is one snapshot at every
isolation level — `trial_balance_at` is `LANGUAGE sql STABLE` and inlines (its plan is the aggregate
itself), `balance_sheet_at` plans as an opaque `Function Scan`, and either way one call is one
snapshot. **So the transaction the read path opens is the GUC's, not the snapshot's**, and it gets
snapshot consistency for free.

**A multi-statement read needs `REPEATABLE READ`, and the cursor is not a substitute.** Two
`balance_sheet_at` calls at the **same fixed cursor** in one transaction, with an account created
between them:

```
READ COMMITTED READ ONLY:    statement 1: rows = 20     statement 2: rows = 30
REPEATABLE READ READ ONLY:   statement 1: rows = 30     statement 2: rows = 30
```

**The snapshot covers exactly the gap the cursor leaves** — the unpinnable branches, which are
precisely the tables with no `xact_id`. The cursor pins the amounts; the snapshot pins the row set.

**And a long report pins everyone else's cursor, measured directly.** An 11-second `REPEATABLE READ
READ ONLY` report on the million-entry book, with the horizon sampled while it ran:

```
before the report opens:      cursor_now = 16170
while the report is running:  cursor_now = 16170, backends_pinning_xmin = 4
```

The cursor did not move for the report's whole duration, so every report issued in that window is
pinned behind it and omits anything committed in it. Read replicas do not fix it: `pg_snapshot_xmin` is
the cluster's. The mitigation is to make the reports faster — wire the checkpoint — not to choose a
different isolation level.

---

## What this spike refutes, withdraws or corrects

Collected because this project treats a withdrawn claim as a first-class result. `FINDINGS.md` lists
seven, each naming the file and the sentence, **one of them this spike's own.**

1. **`crates/db/src/lib.rs`, the doc comment on `CONNECTIONS_ABOVE_THE_WRITERS`:** *"these six are what
   keep the startup schema gate — and any future reader — from waiting behind a pool of writers that is
   full by design."* **The "any future reader" clause is withdrawn.** This is that reader: a report
   holds a connection for 4–11 s at a million entries, six exhaust the headroom, and the seventh loses
   its 15 s acquire against 32 dispatchers that are full by design. More decisively, sharing that pool
   means sharing its *login*. The six keep the one job the sentence's first half gives them, and
   neither constant moves.
2. **`migrations/00001_baseline.sql`, the balance-sheet header, point 4:** *"It names its chart version
   and its cursor is a parameter, so an issued statement is reproducible after any backdated posting
   (ADR-0011, proven)."* **True as written and misleading as read.** The cursor confirmation above is
   fresh proof of the clause's actual claim; the new-account result shows the same call at the same
   cursor **and** the same chart version coming back with ten more rows. The numbers are reproducible;
   the row set is not. The correction is one clause, not a redesign — and it is a fact the **API** has
   to carry, because the API is what will promise a caller that a stored cursor reproduces a statement.
3. **The same block, and ADR-0011 §4's signature table**, describe the chart version as pinning the
   presentation. It pins it **only for a version below `max(version)`**;
   `refuse_stale_chart_version()` freezes history and does not freeze the present.
4. **[ADR-0013](/decisions/0013-write-path-contract)'s cost list:** *"`SET LOCAL` per transaction, never
   `SET ROLE` per tenant — both recent RLS plan-cache CVEs came from role switching."* Two corrections
   in opposite directions. The **scope** is right and the **form** is incomplete: `SET LOCAL` takes no
   bind parameter and `tenant_id` is caller-supplied text, so the instruction has to be
   `set_config('app.tenant_id', $1, is_local => true)` — same scope, plus a bind. And the plan-cache
   clause, tested at its worst case, **does not reproduce**; it should stay as provenance for avoiding
   per-*tenant* role switching and stop being an argument against `SET LOCAL ROLE`, which this spike
   relies on and measures safe.
5. **The baseline's RLS comment:** *"the TWO-argument `current_setting` returns NULL when the GUC is
   unset — `tenant_id = NULL` matches nothing, so an unscoped session FAILS CLOSED."* **Incomplete in a
   way that matters.** After `RESET` the GUC is `''`, and what fails closed there is
   `ck_*__tenant_non_empty` on all nine tenant-keyed tables — a `CHECK` constraint the RLS section
   never mentions. The property holds; it has two mechanisms and the comment names one.
6. **Nothing in the tree says the report functions guard their arguments, and the A13 comment implies
   the class was closed.** The same class is **open** for the cursor, the as-of instant and the
   effective range. No function is `STRICT`; `EXECUTE` is `PUBLIC` on all five.
7. **A claim of this spike's own, withdrawn.** An earlier draft attributed `balance_sheet_at`'s 47.3 M
   buffers to *"the cursor arriving as a bound parameter defeating the selectivity estimate"* and to
   *"the plug, which the decomposition accounts for."* **Both were tested and both are false**: the plug
   costs 1,583 ms with a literal cursor and 1,536 ms with a bound one (2.51 M buffers either way), and
   the decomposition sums to ~2.54 M buffers against the function's 47.3 M. What the measurement
   supports is narrower and more useful — three plan shapes at 11.0 s / 4.2 s / 2.7 s, with the generic
   plan the fast one and `force_custom_plan` the trap.

## What could not be settled

- **The 19× buffer gap** between `balance_sheet_at`'s inlined body (2.49 M) and the function's custom
  plan (47.3 M) is unexplained. Two hypotheses were tested and refuted, and it is labelled unexplained
  rather than narrated. Settling it wants `auto_explain.log_nested_statements`, which is a
  `shared_preload_libraries` change and therefore a change to `docker-compose.yml`, outside this
  spike's boundary.
- **The A14 refusal could not be triggered** — an in-scope type with posted entries that the chart
  version does not present. Every `account_type` is presented at every version on this chart
  (`unpresented_type_at_v3` returned 0 rows), which is itself a small positive result about
  `schema/chart.sql`. It is ADR-0011's own tested guard and is taken on that evidence, not re-proven
  here. *(It is reachable on a chart that omits one — see
  [spike 021](/spikes/021-reporting-layer-defects), where the same raise takes out the whole
  reconciliation summary.)*
- **The pool-exhaustion arithmetic is reasoned, not measured.** Producing it would mean saturating 38
  connections with a mix of 11-second reads and postings, which measures `max_connections` rather than
  anything about the read path.
- **Whether the checkpoint can bound the un-closed-earnings plug without reopening ADR-0011 §A3.** A3
  chose the plug's shape *so that its caption cannot move under a fixed cursor* — it reads no
  `ledger_period_closes` on purpose — and bounding it by the checkpoint is a change to that reasoning
  rather than a free optimisation. **It wants a measurement, not an ADR paragraph.**
- **Nothing was measured over a network.** Every number is localhost, which the roadmap already calls
  the project's largest open caveat. For reads it matters differently than for writes: the transaction
  the GUC forces is two extra round trips on a read whose own cost is milliseconds to seconds, so the
  overhead is negligible for the reports and is the dominant term for the balance endpoint, whose own
  work is 0.09 ms.
- **The read path itself is not built.** This spike settles its contract and writes no service code;
  every Rust file under `harness/` is throwaway and depends on none of `ledger`, `ledger-postgres`,
  `api` or `openledger`.
