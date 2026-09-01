# Spike 023 — findings

Every claim below is labelled **proven** (with the command and the output that proves it),
**measured** (with the loadavg and the indicative caveat) or **unmeasured / reasoned** (with the
reasoning). Numbers are grep-able in `out/`.

**The oracle.** `book reconciled — 10 checks, 0 breaks, 28970 ms` on the whole book, 1.11 M entries,
after every experiment (`out/99-oracle.txt`). The gate held; the wobble in the middle of the run,
and why it was not this book's fault, is in `SPEC.md` and in finding 3.7 below.

**One number that is not a finding but is the honest banner:** another agent's spike ran against the
same PostgreSQL cluster throughout, and the 1-minute loadavg during the cost measurements sat between
**2.32 and 4.22**. Everything under Q5 is *shape*, not a benchmark.

---

## The seven-line summary

1. **The read path requires a transaction.** Not for isolation — for the GUC.
   `set_config(..., is_local => true)` outside an explicit transaction is gone by the next statement,
   and it is the only form that takes a bind parameter. **Proven.**
2. **A shared pool is only safe if every read issues `SET LOCAL ROLE openledger_read`** — because a
   login that is a member of both `openledger_app` and `openledger_read` reads **every tenant**,
   `app.tenant_id` notwithstanding. RLS policies are permissive and OR'd, and membership, not
   equality, decides which apply. **Proven, and it is the sharpest finding in the spike.**
3. **The `xid8` cursor holds, end to end, through all three shipped functions** — including against
   a transaction that started before the cursor and committed after it, the exact interleaving that
   killed ADR-0006's watermark. **Proven.** The refuted watermark was re-run beside it and moved
   131,000 → 230,000 across the same commit.
4. **But the cursor does not pin the whole report, and two of the unpinned branches are
   unpinnable.** `ledger_accounts`, `chart_versions`, `chart_presentation`, `fs_lines`,
   `account_types` and `ledger_period_closes` carry **no `xact_id` column at all**. A new account
   adds rows to an issued statement at a fixed cursor; the chart-version *default* is read at run
   time. **Proven.**
5. **An absent or malformed cursor fabricates.** `NULL` returns the complete face at 0.00, balanced,
   and `recon_equation_breaks(NULL, …)` reports **zero breaks** on it. `'-1'::xid8` silently wraps to
   `18446744073709551615` and returns the **entire** unpinned book. No function is `STRICT`, none
   guards its cursor, and `EXECUTE` is `PUBLIC` on all five. **Proven.**
6. **Four different conditions produce one observable: zero rows.** Unknown tenant, tenant typo,
   tenant with no accounts, and scoped-out-by-RLS are indistinguishable to a caller — while a wrong
   *chart version* raises. **Proven.**
7. **The inception scan meets the 30 s timeout at order 10^6 entries, not 10^9**, and
   `balance_sheet_at`'s cost is decided by *how the cursor reaches the planner*: 11.0 s, 4.2 s or
   2.7 s for the same SQL on the same data. **Measured.**

---

## Q1 · Tenant scoping on a pooled connection

### 1.1 The fail-closed claim is true, and it is true through every report surface — **proven**

`out/q1-guc.txt`, section A. As `openledger_read` with `app.tenant_id` never set:

```
unset app.tenant_id, reader role            entries=0 guc=<NULL> tenants=<none>
unset GUC, through the report surfaces      trial_balance=0 trial_balance_at=0
                                            balance_sheet_at=0 income_statement_for=0
```

The baseline's comment (`migrations/00001_baseline.sql`, above the policies) asserted this and
nothing had executed it. It holds on the base tables, on the `security_invoker` view, and on both
`SECURITY INVOKER` plpgsql statement functions.

### 1.2 A session `SET` leaks across a pool checkout — **proven**

Same file, section B, on a real `sqlx::PgPool` configured like `crates/db`'s, `max_connections(1)`:

```
checkout 1: SET app.tenant_id = 't1', then read     entries=4 guc=t1 tenants=t1
checkout 2: sets NOTHING, reads as if for t2        entries=4 guc=t1 tenants=t1
```

**sqlx 0.9 issues no reset on release.** Checkout 2 inherited t1's scope and read t1's rows while
believing itself unscoped. This is the leakage failure mode in its plainest form: the *next request*
does not have to be malicious or even buggy — it has to be a request that trusts the pool.

### 1.3 `SET LOCAL` does not leak, and neither does `set_config(..., true)` — **proven**

Section C: inside `BEGIN … READ ONLY`, `SET LOCAL app.tenant_id = 't1'` read 4 t1 entries; after
`COMMIT` the same connection read **0**, and so did the next checkout.

### 1.4 `SET` takes no bind parameter, and `set_config` does — **proven**, and this is a correctness finding rather than an ergonomic one

Section D:

```
SET app.tenant_id = $1     REFUSED: syntax error at or near "$1"
set_config($1, is_local => true) in a transaction     applied=t2 entries=2 tenants=t2
…and with a hostile tenant_id as the bind
     applied="t2'; SET ROLE openledger_app; --" entries=0 current_user=openledger_read
```

`tenant_id` is caller-supplied `text` from a request body — ADR-0017 is explicit that it is *"data
scoping, not an auth claim"* — so the only form of the statement that can carry it is the one that
carries it as **data**. With `SET`, the read path would have to interpolate a caller's string into
SQL. The hostile value above was stored verbatim as the GUC, matched no tenant, and left
`current_user` untouched.

**ADR-0013's cost list says `SET LOCAL` per transaction.** That sentence is right about the *scope*
and, taken literally as a statement, wrong about the *form*: `SET LOCAL` cannot express a
parameterised tenant. The correct instruction is `set_config('app.tenant_id', $1, is_local => true)`
inside an explicit transaction, which has `SET LOCAL`'s scope and a bind parameter. This is a
refinement of ADR-0013, not a refutation of it — and it is the difference between a read path with
one string interpolation on it and a read path with none.

### 1.5 `is_local => true` with no explicit transaction is a silent no-op — **proven**, and it is what makes the transaction mandatory

Section E:

```
set_config(local) then a separate statement    applied=t1 next statement sees guc=
…and the read it was supposed to scope         entries=0
```

`LOCAL` scope is the current transaction, and in autocommit **each statement is its own
transaction**, so the setting is discarded before the read that needed it. The failure direction is
benign (0 rows, not the wrong tenant's rows) — but a read path built this way returns an empty book
for every request, forever, and the tenant fence never fires because nothing ever gets past it.

**So the read path requires a transaction, and the reason is the GUC, not isolation.** The cost is
two extra round trips per read (`BEGIN`, `COMMIT`) on top of the `set_config` and the report itself
— four where an unscoped read would be one. On localhost that is ~0.2 ms; over a network at
ADR-0002's ~0.5 ms round trip it is ~1.5 ms of pure overhead per report, which for a report costing
milliseconds to seconds is noise and for a hot per-account balance read is not (see 5.1).

The one-round-trip alternative — `WITH s AS (SELECT set_config('app.tenant_id', $1, true)) SELECT …`
— is **refused on principle rather than on measurement**: PostgreSQL guarantees no evaluation order
between a non-data-modifying CTE and the outer query, so whether the GUC is set before the RLS qual
is evaluated is not a property the documentation gives. A tenant fence that depends on an
unspecified evaluation order is not a fence. *(Attempted in `out/q1-guc.txt` section E; the case
there ran as the owner, who is not subject to RLS, so it establishes nothing either way — which is
itself the reason to refuse the shape rather than trust an observation of it.)*

### 1.6 After `RESET`, the GUC is `''`, not NULL — and what fails closed is a `CHECK` constraint, not NULL semantics — **proven**

`out/q2-role.txt`, section F:

```
fresh connection, never SET       current_setting => None
after SET then RESET              current_setting => Some("")
can a tenant be named ''?         REFUSED: violates check constraint "ck_accounts__tenant_non_empty"
```

The baseline's comment names exactly one mechanism — *"the TWO-argument `current_setting` returns
NULL when the GUC is unset … so an unscoped session FAILS CLOSED"*. That covers a connection that
was never scoped. It does **not** cover a connection that was scoped and then reset, which is the
state a pool with an `after_release` hook would leave: there the GUC is the empty string,
`tenant_id = ''` is a real comparison rather than a NULL one, and what saves it is
`ck_*__tenant_non_empty CHECK (btrim(tenant_id) <> '')` on all nine tenant-keyed tables — refused
above even for the owner, who bypasses both RLS and grants.

**This is a load-bearing dependency nothing documents.** A future migration that relaxed those
checks would open a cross-tenant read on reset connections, and no comment in the RLS section would
warn about it.

---

## Q2 · Assuming the read role

### 2.1 A session `SET ROLE` survives a checkout and disarms the writer — **proven**

`out/q2-role.txt`, section A:

```
checkout 1: SET ROLE openledger_read      current_user=openledger_read
checkout 2: the WRITER's next posting     current_user=openledger_read
                                          INSERT REFUSED: permission denied for table ledger_accounts
```

The hazard is real in the direction that costs money, and it fails *closed* — a 500 on a posting,
not a silent write to the wrong place.

### 2.2 `SET LOCAL ROLE` is sufficient, composes with the GUC, and survives an error — **proven**

Sections B and C. Inside the read's own transaction, `SET LOCAL ROLE openledger_read` followed by
`set_config('app.tenant_id', 't1', true)` — the GUC set *after* the role change, therefore under the
read role's privileges, which works because `app.` is a placeholder namespace and therefore
`USERSET`. After `COMMIT` the connection is the login again; after a `division by zero` and a
`ROLLBACK` it is the login again with the GUC back to `<NULL>`.

### 2.3 The finding that decides Q2: a login that is a member of both roles reads every tenant — **proven**

`out/02-policy-union.txt`. Two purpose-built logins (`sql/01-login-roles.sql`), same script:

| | `spike023_reader` (member of `openledger_read`) | `spike023_dual` (member of `openledger_app` **and** `openledger_read`) |
| --- | --- | --- |
| no GUC at all | **0 entries** | **6 entries, tenants t1,t2** |
| `set_config('app.tenant_id','t1',true)`, inherited membership, no `SET ROLE` | 4 entries, t1 | **6 entries, tenants t1,t2** |
| the same behind `SET LOCAL ROLE openledger_read` | 4 entries, t1 | 4 entries, t1 |

The mechanism: a PostgreSQL row-security policy applies to any `current_user` that
`pg_has_role(current_user, polrole, 'USAGE')` reaches, and multiple permissive policies are **OR'd**.
The baseline declares three per tenant-keyed table — the reader's `tenant_id = current_setting(…)`,
the writer's `USING (true)`, the sweep's `USING (true)`. A login that inherits `openledger_app` gets
`tenant_id = current_setting(…) OR true`. **The tenant fence evaporates, silently, with every
policy, grant and comment in the schema exactly as written.**

This does not contradict anything in ADR-0013 — its §5 is about roles, and the roles are right. What
it establishes is that **the fence is a property of `current_user`, not of the connection or the
GUC**, and therefore that "share the writer's pool" and "read as the read role" are not independent
choices. The shipped tree has never been able to observe this, because it has one `DATABASE_URL` and
it is the owner's, and the owner is not subject to RLS at all.

### 2.4 A dedicated read pool with `SET ROLE` in `after_connect` works, and its role is escapable — **proven**

Section D. A second `PgPool` whose `after_connect` issues `SET ROLE openledger_read` once:

```
fresh connection, nothing set per request              current_user=openledger_read entries=0
one request: transaction + set_config, no role statement    entries=2 tenants=t2
RESET ROLE on a read-pool connection                   Ok("ok") current_user=openledger
```

The first two lines are the shape's whole value: **there is no per-request role statement to
forget**, and a connection that has never been scoped reads nothing. The third line is its limit —
`RESET ROLE` climbs back to the login. That is acceptable for a pool whose SQL the read path writes
(nothing in the read path issues `RESET ROLE`) and unacceptable as a *security* boundary against
arbitrary SQL, which the read path is not. The boundary that does not have that hole is a separate
**login** that is a member of `openledger_read` and nothing else — `spike023_reader` above, whose
`RESET ROLE` lands on a role with no grants and no writer policy.

### 2.5 The RLS plan-cache hazard does not reproduce — **proven, and it withdraws a worry**

Section E. One connection, one SQL text, sqlx's per-connection prepared-statement cache, four
executions across a role change *and* two GUC values, starting from the worst case (the first plan
prepared as the **owner**, for whom RLS does not apply at all, so the cached plan carries no RLS
qual whatsoever):

```
1st execution: OWNER, no GUC                    entries=1110024 tenants=big100k,big10k,big1m,t1,t2
2nd execution: same text, reader scoped to t1    entries=22 tenants=t1
3rd execution: same text, GUC moved to t2        entries=2 tenants=t2
4th execution: same text, back to the OWNER      entries=1110024 tenants=…
```

Every execution is correct for the role and scope in force. **ADR-0013's cost-list worry — *"both
recent RLS plan-cache CVEs came from role switching"* — is a real historical class and is not a live
hazard on PostgreSQL 18.6 with sqlx 0.9.** The sentence should stay in the ADR as provenance for
*why* the design avoids per-tenant role switching, and should stop being a reason not to use
`SET LOCAL ROLE`, which is a different mechanism and is measured safe here.

### 2.6 A read pool can carry its own `statement_timeout`, and so can a single read — **proven**

Section G: a read pool whose `after_connect` sets `statement_timeout = '90s'` reports `90s` and
`current_user=openledger_read`; and `openledger_read` can itself issue
`SET LOCAL statement_timeout = '120s'` inside the read's transaction, which reports `2min`. So Q5's
"a longer timeout for reads" is available **either** as a second pool **or** as one more statement in
the read's existing transaction — no second pool is required for the timeout alone.

### 2.7 What it means for `POOL_CONNECTIONS` and `CONNECTIONS_ABOVE_THE_WRITERS` — **unmeasured / reasoned**

The doc comment on `CONNECTIONS_ABOVE_THE_WRITERS` says the six are headroom for the startup schema
gate *"and any future reader"*. **This is that reader, and six is not enough — but the number is not
the problem; sharing is.**

The arithmetic, against `DISPATCHERS = 32`, `POOL_CONNECTIONS = 38`, `ACQUIRE_TIMEOUT = 15 s` and
this spike's measured report costs: a report holds its connection for the whole of its transaction,
and a `balance_sheet_at` on a million-entry book holds it for **4–11 s** (5.1). Six concurrent
reports exhaust the headroom; the seventh competes with 32 dispatchers that are full **by design**
(ADR-0018 §2 sizes the pool so every dispatcher has a connection), and loses its acquire at 15 s.
That is not a read path degrading, it is a read path taking the write path's connections and then
failing anyway.

Three further reasons the read path should not share the pool, none of which is about capacity:

- **2.3's policy union.** Sharing the pool means sharing the *login*. If that login can write, every
  read must remember `SET LOCAL ROLE` or the fence is gone. A separate pool on a read-only login
  makes the fence structural instead of remembered.
- **The timeouts want different values.** The writer's statements are single-millisecond appends and
  30 s is a generous outer bound; a report's are seconds and 30 s is a live limit (5.1).
- **`idle_in_transaction_session_timeout = '60s'`** is sized for a writer whose transaction is three
  round trips. A read transaction is legitimately longer-lived, and a read pool can say so.

**So: its own pool, on its own login, with `SET ROLE` in `after_connect` — and `SET LOCAL ROLE` kept
anyway** as the belt to that braces, because 2.4 shows the pool's role is escapable and 2.3 shows
what it costs when it is. Neither `POOL_CONNECTIONS` nor `CONNECTIONS_ABOVE_THE_WRITERS` then moves,
and the `const` assertion in `crates/openledger/src/batching.rs` that couples them stays true. The
six keep the job they have: the startup schema gate. **The doc comment's "any future reader" clause
should be withdrawn** — it promised headroom to a reader that should not be in that pool at all.

---

## Q3 · Cursor reproducibility

### 3.1 The `xid8` cursor holds through all three shipped functions — **proven**

`out/q3-transcript.txt` §2–3, `out/q3-diff-C.txt`. The interleaving is ADR-0006's, constructed
deliberately: adversary A opens a transaction and posts (`xact_id 15783`) without committing; B posts
through the compiled binary over HTTP and commits (`xact_id 15784`), so **A started first, holds the
*lower* id, and commits last**. At that instant:

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

The watermark's diff (`out/q3-diff-W.txt`) is 131,000 → **230,000** on `receivables`,
`current_year_earnings` and `revenue`, and 131,000 → 230,000 on the trial balance. **Spike 012 proved
this class on isolated tables; it is now proven on `trial_balance_at`, `balance_sheet_at` and
`income_statement_for` as shipped.**

The negative control is a cursor explicitly above every committed write: 18,000 at the pinned cursor
against 230,000 at `15785` (`out/q3-report-at-C-after.txt` vs
`out/q3-report-at-above-everything.txt`). The pinned cursor is withholding, not merely agreeing with
itself.

### 3.2 The branch audit — read out of `pg_get_functiondef`, not the source file — **proven**

`out/03-functiondef.txt`. Every branch of every aggregation, classified.

**Pinned by `p_cursor`:**

| function | branch | line in the dump |
| --- | --- | --- |
| `trial_balance_at` | the single aggregate | 29 |
| `income_statement_for` | the A14 existence guard | 65 |
| `income_statement_for` | `dp` (the amounts) | 87 |
| `balance_sheet_at` | the A14 existence guard | 134 |
| `balance_sheet_at` | `pos` (the per-account position) | 166 |
| `balance_sheet_at` | `plug` (the un-closed-earnings subquery) | 215 |
| `recon_equation_breaks` | passes `p_cursor` through to `balance_sheet_at` | 244 |

**Every amount in every report comes from a pinned branch.** That is the half of the reproducibility
claim that holds unconditionally.

**Not pinned, and the reason each one is not:**

| branch | table | why |
| --- | --- | --- |
| `scopes` — `SELECT DISTINCT tenant_id, currency FROM ledger_accounts` (91, 150) and `recon_equation_breaks`' `tenants` (240) | `ledger_accounts` | **no `xact_id` column, and no append-only trigger either** — the row is deliberately updatable (ADR-0009's freeze keys exist because it is) |
| `v_cv := COALESCE(p_chart_version, (SELECT max(version) FROM chart_versions))` (45, 117) | `chart_versions` | no `xact_id`; the *default* is a run-time read |
| `JOIN chart_presentation p ON p.chart_version = v_cv` (84, 165, 213) and `JOIN fs_lines f ON f.chart_version = v_cv` (98, 189) | both | no `xact_id`; pinned by the **version** only once a later version exists (3.6) |
| `JOIN account_types t ON t.code = a.purpose` (26) | `account_types` | no `xact_id`; supplies `purpose` and `category` on the trial balance |
| `NOT EXISTS (… FROM ledger_period_closes …)` (88) | `ledger_period_closes` | append-only, but no `xact_id`: a close row inserted later, naming a transaction below the cursor, retroactively removes that transaction's entries from an already-issued income statement |
| `JOIN ledger_transactions x … AND x.status = 'posted'` (22, 59, 80, 128, 161, 209) | `ledger_transactions` | **carries `xact_id` and is not filtered by it — and is nonetheless sound.** `fk_entries__transaction` means an entry cannot exist before its transaction, so any entry below the cursor has a transaction below the cursor; and `status` is immutable (append-only trigger `ck_txn__append_only`, `tgenabled='A'`, plus `REVOKE UPDATE … FROM openledger_app`). The safety is a **key and a trigger**, not a predicate, and that is worth stating rather than inheriting |

Catalog confirmation, from the run itself:

```
tables carrying xact_id: ledger_entries, ledger_events, ledger_transactions
tables the reports read that carry NO xact_id: account_types, chart_presentation,
    chart_versions, fs_lines, ledger_accounts, ledger_period_closes
```

### 3.3 A new account changes an issued statement's row set at a fixed cursor — **proven**

`out/q3-diff-scopes.txt`. Cursor fixed at 15760; one new EUR `fee_revenue` account created; nothing
posted to it. The balance sheet gained **ten rows** (a whole zero-valued EUR face plus the EUR
earnings plug) and the income statement gained **four**. Every amount on every pre-existing row is
byte-identical.

**This refutes, in a narrow and precise way, a claim `balance_sheet_at`'s own header comment makes.**
The comment at `migrations/00001_baseline.sql` (the balance-sheet block, point 4) reads: *"It names
its chart version and its cursor is a parameter, so an issued statement is reproducible after any
backdated posting (ADR-0011, proven)."* The clause as written — *reproducible after any backdated
**posting*** — survives, and 3.1 is fresh proof of it. What does not survive is the unqualified
reading the read path will be tempted into: **the numbers are reproducible; the row set is not.** A
report re-run at the same cursor and the same chart version can come back with more lines than it
had, because the lines are enumerated from a table the cursor cannot reach.

That is not a defect in the enumeration — ADR-0007's completeness property *wants* the chart-outward
enumeration, and the function's own comment already admits the honest limit one level further out
(*"a scope with no accounts at all remains invisible"*). It is a fact the **API** has to carry,
because the API is what will promise a caller that a stored cursor reproduces a statement.

### 3.4 A NULL cursor fabricates a complete, balanced, all-zero statement — **proven**

`out/q3-transcript.txt` §5, `out/q8-transcript.txt` §4:

```
balance_sheet_at('t1','infinity', NULL, 3)
  rows=20   assets=0   liab_eq_earn=0   rows_with_null_pinned_cursor=20
recon_equation_breaks(NULL,'infinity')
  equation_breaks=0
income_statement_for('t1', -inf, inf, NULL, 3)   4 rows, all 0
trial_balance_at('t1', -inf, inf, NULL)          0 rows
```

The mechanism: no function is `STRICT` (`proisstrict = false` on all five, printed in §1),
`e.xact_id < NULL` is NULL and filters every entry — but **the statements enumerate their lines from
the chart**, so the *shape* of the answer survives intact and only the numbers go to zero. The
accounting equation then holds trivially, and the highest-leverage reconciliation check in the
system reports **zero breaks on a fabrication**. `trial_balance_at` is the exception precisely
because it enumerates from the *entries*, so it returns nothing instead of returning a lie.

The same is true of the other arguments (§6): a NULL `p_asof` gives 10 rows at 0, a NULL effective
range gives 4 rows at 0. **`EXECUTE` is the default — `proacl` is NULL on all five, i.e. `PUBLIC`.**

**This is the same defect class the file already documents and guards for the chart version**, at the
A13 comment: *"the old COALESCE never touched `chart_versions`, so `income_statement_for(..., 999)`
returned a fabricated, all-zero, perfectly balanced statement citing a version nobody created."*
Guarded for the chart version; unguarded for the cursor, the as-of instant and the effective range.
It is a live hazard for the read path specifically, because an HTTP caller is exactly the thing that
will supply an absent parameter.

There is one tell: `pinned_cursor` comes back NULL on all 20 rows. A handler can detect it. Relying
on that is defence at the outermost layer of a five-layer stack whose innermost layer has `EXECUTE`
to `PUBLIC`.

### 3.5 A malformed cursor is worse than an absent one — **proven**

`out/q8-transcript.txt` §3 and `out/q8-minus-one-cursor.txt`:

| cursor | result |
| --- | --- |
| `'not-a-cursor'` | `ERROR 22P02: invalid input syntax for type xid8` — the good case |
| `'0'` | 20 rows, total **0** — the same fabrication as NULL |
| `'18446744073709551615'` (xid8 max) | 20 rows, total **884,000** — the whole book, unpinned |
| **`'-1'`** | **20 rows, total 884,000** — because `'-1'::xid8 = '18446744073709551615'::xid8` is `t` |

`-1` is the natural sentinel for "no cursor" in any signed integer, and it silently wraps to the
maximum. The report it produces has **today's correct numbers** and a `pinned_cursor` of
18,446,744,073,709,551,615, which will still be above every transaction id forever — so it is an
*unpinned* report that looks fine and re-runs identically until the book changes, then changes with
it. That is harder to catch than the all-zero case.

### 3.6 The chart-version default is read at run time; passing it explicitly pins the presentation only once a later version exists — **proven**

`out/q3-transcript.txt` §7:

```
default resolves to version 3
explicit v1 vs default: 1 vs 3
appending a line to the FROZEN version 1: ERROR ... below the current maximum 3 ... frozen history
appending a line to the CURRENT version 3, at a FIXED cursor: rows 10 -> 11
```

`chart_versions`, `chart_presentation` and `fs_lines` all carry `ENABLE ALWAYS` append-only triggers
(`tgenabled = 'A'`), and `refuse_stale_chart_version()` refuses a row naming a version below
`max(version)`. So a version below the maximum is genuinely frozen and naming it pins the
presentation completely. **The current maximum is not frozen**: a row appended to it added a line to
a balance sheet at a *fixed cursor and a fixed version*, 10 rows → 11.

Two consequences the read path owns: it must always pass the chart version explicitly (otherwise the
default moves under it), and even then a statement pinned at the *current* version is only as stable
as the chart's next edit.

### 3.7 The cursor lags by the cluster, and it happened to us — **proven, unbidden**

`out/q3-horizon-pinned-by-another-database.txt`:

```
 pid  |   datname    |        state        |          xact_start           | backend_xmin
 6042 | spike024arms | idle in transaction | 2026-09-01 14:48:22.954045+00 |
 6045 | spike024arms | active              | 2026-09-01 14:48:22.98013+00  |        15760

 cursor_now | entries_total | entries_a_report_would_see | entries_above_the_horizon
      15760 |            12 |                          8 |                         4
```

A session belonging to **another agent's spike, in a different database on the same cluster**, held
`report_cursor()` at 15760 for the whole Q3 run. At the moment above, a third of this book's
committed entries were above the horizon; later in the run it was half (8 of 16). `reconcile`
reported **10,016 `cursor_forgery` breaks**, every one `reason = above_horizon` with
`xact_id = txn_xact_id` — no forgery, and nothing wrong with the book
(`out/q5-gate-cursor-forgery-is-the-horizon.txt`).

ADR-0011 and ADR-0010 both predict this in prose. It is now reproduced by accident, by a third party,
on this project's own development cluster, within one working session. **The read path cannot treat
"the cursor is roughly now" as an assumption**, and an endpoint that returns `pinned_cursor` is
returning the only thing that lets a caller notice.

---

## Q4 · Backdating on both axes

### 4.1 The effective axis reproduces ADR-0006's worked table exactly — **proven**

`out/q3-transcript.txt` §9. Three postings through the compiled binary over HTTP, the third
backdated between the first two (Jan 10 +10,000; Jan 30 +5,000; then Jan 20 +3,000), read at three
instants:

| as of | receivable, minor units | ADR-0006's table x100 |
| --- | --- | --- |
| 2026-01-15 | 10,000 | 10,000 |
| **2026-01-25** | **13,000** | **13,000** — the truth, against a running balance's 18,000 |
| 2026-02-01 | 18,000 | 18,000 |

ADR-0006's failure — *"As of Jan 25 by running-balance lookup: 180. The truth: 130"* — is now the
shipped function's correct answer at the scaled figure, and the entry that would have broken a
running balance arrived **third**.

### 4.2 The recorded axis is the same function with the cursor as its parameter — **proven**

Same section. `trial_balance_at('t1','-infinity','infinity', <cursor>)` at the pinned cursor
returned 18,000 while a cursor above everything returned 230,000 (3.1). There is no separate
recorded-axis function and there does not need to be: ADR-0006's mechanism table already says the
recorded-axis read is *"aggregate filtered by the commit cursor `xact_id < :cursor`"*, and that is
`p_cursor`. **One function serves both axes; the axis a caller asked about is which parameter they
varied.** That has a direct consequence for Q6: two axes do not want two resources, they want one
resource with both parameters named on it — which is exactly ADR-0006's *"an as-of query names the
column it filters"* satisfied by the signature rather than by the path.

### 4.3 Both axes are reproducible, and the effective axis inherits 3.3's caveat — **proven**

The effective-axis reads above were each taken at `report_cursor()` and are stable under it for the
same reason 3.1 is. What they inherit is 3.3: the *amounts* on the effective axis are pinned; a new
account can still add a zero-valued line.

---

## Q5 · Result size and the statement timeout

**Measured. Indicative, not a benchmark.** Five passes per cell, median quoted, full range printed,
`EXPLAIN (ANALYZE, TIMING OFF, BUFFERS)`. Another agent's spike was running against the same
PostgreSQL for the whole measurement; **the 1-minute loadavg is recorded on every line of
`out/q5-transcript.txt` and sat between 2.32 and 4.22.** Absolute numbers are shape only; the growth
and the ordering are the claims.

### 5.1 The ladder — **measured**

| book | `trial_balance_at` | `balance_sheet_at` | `income_statement_for` | current balance (`SUM` over stripes) | mid-book effective range |
| --- | --- | --- | --- | --- | --- |
| 10,000 entries | 9.9 ms | 64.8 ms | 37.6 ms | **0.100 ms** | 6.9 ms |
| 100,000 entries | 76.2 ms | 1,207.9 ms | 473.0 ms | **0.094 ms** | 61.6 ms |
| 1,000,000 entries | 1,057.2 ms | **11,428.1 ms** | 4,302.9 ms | **0.091 ms** | 574.7 ms |

Ranges across the five passes were tight — `balance_sheet_at` at 1 M: 11,296–12,163 ms;
`trial_balance_at` at 1 M: 1,012–1,081 ms; the current-balance read at 1 M: 0.084–0.133 ms.

Three things the table says:

- **The result is tiny and the scan is not.** At 1 M entries the three reports return **2, 10 and 4
  rows**. Pagination has nothing to paginate.
- **`balance_sheet_at` is the binding constraint**, at ~11x `trial_balance_at` on the same book.
  Extrapolating linearly from 1 M, it meets the serving pool's `statement_timeout = '30s'` at
  **order 2–3 million entries** — one tenant, one currency, three years. `income_statement_for`
  meets it around 7 M and `trial_balance_at` around 28 M. **The order of magnitude is 10^6, not
  10^9**, and that is the finding.
- **The current-balance read is flat**, 0.091–0.100 ms across a hundredfold change in book size, as a
  `SUM` over the account's stripe rows. ADR-0006's *"current balance (the hot path)"* and ADR-0018's
  stripe `SUM` are both confirmed on a real book at three sizes.

Corroboration from outside the harness: the reconciliation sweep on this book took **28,970 ms**
(`out/99-oracle.txt`), because `recon_equation_breaks` calls `balance_sheet_at` per tenant. **The
daily sweep is already at 29.0 s against a 30 s budget at 1.11 M entries**, and it only survives
because `reconcile` opens its own `PgConnection` and sets no `statement_timeout` on it. ADR-0010 tells
deployments to budget the sweep as linear and re-measure at their size; this is that measurement, at
a size a real deployment reaches quickly.

### 5.2 Where `balance_sheet_at`'s cost goes, and the plan-cache finding — **measured**

`balance_sheet_at` at 1 M entries touched **47.3 M shared buffers** for a ten-row answer, against
`trial_balance_at`'s 27 k on the same journal. Chasing that produced the most actionable measurement
in the spike. Same function, same data, same cursor — **three plans, three costs**:

| how the query reaches the planner | median | buffers | evidence |
| --- | --- | --- | --- |
| the function, **custom** plan — calls 1–5 on a connection | **11,046–11,079 ms** | 47.3 M | `out/q5-plpgsql-generic-plan.txt` |
| the function, **generic** plan — call 6 onward | **4,138–4,200 ms** | 7.44 M | same |
| the same body inlined with the cursor as a **literal** | **2,731–2,767 ms** | 2.49 M | `out/q5-inlined-literal-body.txt`, `sql/20-…` |
| `SET plan_cache_mode = force_custom_plan` | 11,061–11,207 ms | 47.3 M | `out/q5-plpgsql-generic-plan.txt` |

**A 4.0x spread on identical SQL over identical data, decided entirely by how the cursor reaches the
planner — and the direction is the opposite of the usual advice.** PL/pgSQL builds a custom plan for
the first five executions of a statement on a connection and then considers a generic one; here the
*generic* plan is 2.6x faster, so the sixth report on each pooled connection is the first fast one,
and `force_custom_plan` — the knob an operator reaches for when a generic plan misbehaves — pins the
slow plan permanently. Note also that every cell in 5.1 is a **custom-plan** number, because each
`psql -c` opens a fresh connection: the ladder measures the slow plan throughout, which is the
conservative direction.

The term the cost concentrates in is the **un-closed-earnings plug**, a correlated subquery in the
`SELECT` list. Its plan (`out/q5-balance-sheet-decomposed.txt`,
`sql/20-balance-sheet-body-inlined.sql`) is
`Nested Loop -> Bitmap Heap Scan on ledger_transactions -> Index Scan using ix_entries__txn on ledger_entries (loops=500000)`
— **half a million index probes** for one scope row, 2.48 M buffers, against `pos`'s hash join at
27 k. The plug is evaluated **per `(tenant, currency)` scope**, so a two-currency tenant pays it
twice.

Two hypotheses tested and **refuted**, recorded because they are the obvious ones:

- *"The cursor arriving as a bound parameter is what ruins the plan."* No: the plug run with the
  cursor as a literal and as a `PREPARE`d bind parameter cost 1,583 ms / 2.51 M and 1,536 ms / 2.51 M
  — indistinguishable (`out/q5-plug-literal-vs-bound.txt`, `sql/23-…`).
- *"The decomposition accounts for the function's cost."* It does not: the parts sum to ~2.54 M
  buffers and the function's custom plan spends 47.3 M. **The decomposition is a lower bound on where
  the cost goes, not a full account**, and the 19x gap between the inlined body and the function's
  custom plan is **not explained here**. It is labelled unexplained rather than narrated.

### 5.3 The verdict on pagination, timeouts and the checkpoint — **reasoned from 5.1 and 5.2**

- **Pagination is refused.** The reports return 2–10 rows at a million entries; there is nothing to
  page. Pagination would be answering a cost question with an interface change.
- **A read-only timeout is worth having and does not fix anything.** 2.6 shows it is available two
  ways. It converts a 30-second cliff into a 90-second cliff, which buys less than one order of
  magnitude: at linear growth, 90 s is reached at ~8 M entries instead of ~2.5 M. It is the right
  default for a read pool and it is not the answer.
- **The answer is the checkpoint, which is exactly what roadmap M5 already says.** And it remains
  unwired — confirmed here from a **catalog-wide** search rather than from three
  `pg_get_functiondef` calls (`out/q5-transcript.txt`):

  ```
  ledger_period_balances is referenced by: <no function>
  and by these views: recon_checkpoint_breaks
  ```

  No function in the schema reads it; one reconciliation view does. ADR-0011 §3 and the roadmap both
  say this; this spike confirms it over every function body and every view definition on the
  database, which is a slightly stronger form of the same claim.

  **What this spike adds to that plan is a target and a term.** The target: `balance_sheet_at`, not
  `trial_balance_at`, is the function that must read the checkpoint first — it is 11x the cost and it
  is what `recon_equation_breaks` calls per tenant, so wiring it pays twice. The term: the
  **un-closed-earnings plug** is where the cost sits, and its shape (a correlated subquery per scope)
  is what needs rewriting, not merely bounding. Note that ADR-0011 §A3 chose that shape deliberately
  — the plug reads *no* `ledger_period_closes` precisely so its caption cannot move under a fixed
  cursor — so bounding it by the checkpoint is a change to the reasoning A3 settled, not a free
  optimisation. **That tension is not resolved here and should not be resolved in an ADR without a
  measurement.**

---

## Q6 · The endpoint surface — **unmeasured / reasoned**

Against ADR-0014's *"the API is the adoption surface"*, and against its harder rule: *"responses are
declared per endpoint, and the 422 `type`s … are exactly the ones the writer can produce there."*
Also against its route table, which is machine-checked in both directions against the committed
spec, so **a route that ships is documented forever**.

Five routes. Every report route takes `tenant_id` and an optional `cursor`, and returns the
`pinned_cursor` it used.

### R1 · `GET /v1/accounts/{account_id}/balance`

**Why it earns its place:** it is the only read with a latency deadline rather than a throughput
target (ADR-0002; the card rail's authorization path is its consumer), it is measured **flat at
~0.09 ms across a hundredfold book** (5.1), and it is the read a naive integrator gets *wrong* — one
row instead of a `SUM` over stripes, which under-reports. Shipping it is how the stripe stays
invisible above `ledger_account_balances`, which ADR-0013 §4 makes an invariant.

| | |
| --- | --- |
| parameters | `tenant_id` (query, required), `currency` (query, required — the balance row's key includes it) |
| returns | `posted_minor`, `currency`, and `as_of: "now"` |
| **no cursor** | This is the cache, not the journal. It means *posted, now* (the settled framing decision "the cache means posted"), and pinning it to a cursor would be a second definition of a balance — spike 009's finding. **Say so in the description.** |
| errors | `404 account_unknown` — and see 8.4: this requires reading `ledger_accounts`, because the balance table alone cannot tell an unknown account from an account that has never been written |
| **not returned** | the stripe count, or anything stripe-shaped. ADR-0013 §4: a stripe never appears in an API response |

### R2 · `GET /v1/reports/trial-balance`

| | |
| --- | --- |
| parameters | `tenant_id`; `effective_from`, `effective_to` (RFC 3339, half-open, both required); `cursor` (optional) |
| returns | one row per (account, currency) with `debits`, `credits`, `balance_debit_positive`, plus `pinned_cursor` |
| errors | `422 invalid_request` (a malformed instant), `422 cursor_invalid`; no 404 — a tenant with no rows is 200 and an empty list (8.2) |

**This one endpoint serves both time axes** (4.2), and that is the design, not a shortcut: widen the
range and vary the cursor for the recorded axis; fix the cursor and vary the range for the effective
axis. ADR-0006's *"an as-of query names the column it filters, and a resource has one such column"*
is honoured by the **signature**, since both columns are named parameters and neither is a mode flag.
`trial_balance_at` takes no chart version, so R2 has no A13/A14 error class at all.

### R3 · `GET /v1/reports/balance-sheet` and R4 · `GET /v1/reports/income-statement`

| | |
| --- | --- |
| R3 parameters | `tenant_id`; `as_of` (required, an instant — a **position**); `cursor`; `chart_version` |
| R4 parameters | `tenant_id`; `effective_from`, `effective_to` (required, half-open — a **flow**); `cursor`; `chart_version` |
| both return | `currency`, `chart_version`, `fs_line`, `caption`, `sort_order`, `amount_minor`, `side`, `pinned_cursor` |
| errors | `422 chart_version_unknown` (SQLSTATE 23514, 8.1); `422 chart_version_incomplete` (the A14 refusal); `422 invalid_request`; `422 cursor_invalid`; `503 report_timed_out` (9.4) |

The asymmetry between an instant and a range is ADR-0011 §4's and must not be smoothed over: a
position takes one instant, a flow takes a half-open range, and *"a statement without a period is not
a statement."* R3's `as_of` takes a period's `ends_at`, never a business date — ADR-0006's mechanism
table carries the correction and the reason (`effective_at < p_asof` is half-open, so a business date
gives the position at the *start* of that day).

### R5 · `GET /v1/transactions/{transaction_id}`

**In scope, and this is the argument.** A write-only API is not an adoption surface: the one endpoint
that exists returns `{event_id, transaction_id}` and there is currently **no way, over HTTP, to see
what those ids point at**. An adopter's first hour — ADR-0014's own test of the surface — currently
ends at a pair of UUIDs and a psql prompt. And ADR-0016 made `status`, `resolves_id` and
`reverses_id` load-bearing wire concepts: a caller that posts a pending transaction has no way to
confirm it was recorded as pending, and a caller that reverses one cannot see the mirror the server
derived.

**And it is cheap in exactly the way scope creep is not**: it reads `ledger_transactions` and
`ledger_entries` by primary key, needs one statement, needs no cursor (a transaction and its entries
are immutable — `ck_txn__append_only` and `ck_entries__append_only`, both `ENABLE ALWAYS`), takes no
chart version, and adds one error class the grammar already has a shape for.

| | |
| --- | --- |
| parameters | `tenant_id` (query, required) |
| returns | `kind`, `status`, `effective_at`, `recorded_at`, `resolves_id`, `reverses_id`, `event_id`, and its entries (`account_id`, `direction`, `amount_minor`, `currency`, `account_seq`) |
| errors | `404 transaction_unknown` |
| **not returned** | `stripe`, on the transaction or its entries (ADR-0013 §4). `account_seq` *is* returned, because gaplessness is the property a caller can audit; that the counter is per `(account, stripe)` is documented, not exposed |

### What is deliberately left out

- **A listing or search endpoint of any kind** — no `GET /v1/transactions`, no `GET /v1/accounts`, no
  entry listing. These are the endpoints that need pagination, ordering, filtering and a stable sort
  key, and every one of those is a design question this spike did not ask. R5 is by id only.
- **An account-creation endpoint.** Accounts are created by hand today (the e2e suite does it in
  SQL), and the chart is deployment-global with its own governance ADR. A write endpoint is not a
  read-path decision.
- **A period-close endpoint, and `close_disclosures`.** The close is a posting the writer makes
  (ADR-0011 §2); the disclosure *feed* is explicitly unowned on the roadmap. Exposing the disclosure
  list without the feed that consumes it ships an endpoint with no consumer.
- **The reconciliation views.** They aggregate across tenants, they are granted to
  `openledger_recon` and not to `openledger_read`, and their operator interface is an **exit code**
  (ADR-0010). Putting a cross-tenant view behind an HTTP route on a service with no authentication
  (ADR-0017) is the one move this surface must not make.
- **A cursor-minting endpoint.** A caller does not need `report_cursor()` as a resource; every report
  returns the cursor it used, and that is the only cursor worth storing.
- **A balance-as-of-a-business-date endpoint for one account.** R2 already answers it — restrict the
  range and read the account's row — and a second resource for a projection of the first is the
  `pit`-resolves-to-six-columns mistake ADR-0006 catalogues in Formance.

---

## Q7 · Where the read path lives in the hexagon — **reasoned, and the ratchet does not move**

**A second inbound port, not a second method on `Ledger`.** `port.rs`'s doc sets the test —
*"anything else the API grows must earn its place here first"* — and reads fail it: `Ledger` is *post
a transaction*, its error enum is `WriteError` and every variant of it promises *"nothing was
written"*, which is not a sentence a read can say. `crates/api`'s `AppState` was written for this
exact day: *"a struct rather than the bare port so the next port — reads will get their own when the
first read endpoint arrives — lands as one more field."*

The shape:

| where | what | why there |
| --- | --- | --- |
| `crates/ledger/src/port.rs` (or a sibling `reports.rs`) | the inbound `Reports` trait, its parameter and row types, and a `ReadError` enum | the domain crate owns the ports that constrain it; the types name no sqlx |
| `crates/ledger` | a thin `ReportService` | **only** to own the cursor rule (Q3): refuse an absent or implausible cursor, pin one server-side when the caller sent none, and require an explicit chart version. That is the one piece of read-path *judgement*, and it belongs in the core rather than in the adapter or the handler |
| `crates/ledger/src/repository.rs`'s neighbour — a new outbound `ReportStore` | one method per report function, plus the scoped-read bracket | `Repository`'s doc says it is *"what the **writer** service asks of storage"* and *"one method per statement"*; reads get their own outbound port for the same reason, and the rule carries over unchanged |
| `crates/ledger/postgres` | `PgReportStore`, and the read transaction's `BEGIN` / `set_config` / `SET LOCAL ROLE` bracket | the SQL and the session statements are both PostgreSQL dialect, and this crate is where the dialect lives (ADR-0004: *"the SQL in the adapter is the product's reasoning about PostgreSQL"*) |
| `crates/db` | a second pool newtype for the read login, with its own `after_connect` and its own timeouts | ADR-0015: *"pool hardening lives here as this crate's decision, not the caller's"*, and 2.7 is pool-sizing reasoning, which is this crate's subject |
| `crates/openledger` | wires `PgReportStore` into `ReportService` into `AppState`'s second field | it is the composition root and already the only place the adapter is named |

**`deny.toml` needs no change, and I checked rather than assumed.** Every edge above is already
allowed by the capability map as written: `sqlx -> db, ledger-postgres, e2e`;
`db -> ledger-postgres, openledger`; `ledger-postgres -> openledger`; `axum -> api`;
`utoipa -> api`. The domain crate stays absent from the sqlx list and gains nothing that would put it
there — the `Reports` port names only domain types — and the read path needs no runtime, so `tokio`'s
list is untouched too. `clippy.toml`'s ambient-clock ban needs no `#[expect]`: a read path invents no
clock, since as-of instants come from the caller and cursors come from the database.

**The one place the read path *would* have needed the ratchet relaxed is the place this design
avoids**, and it is worth naming: if the read pool were built in `crates/api` — the obvious shortcut,
since the handler is what needs it — `api` would need `db`, which the map refuses:
`{ crate = "db", wrappers = ["ledger-postgres", "openledger"] }`. That is exactly the
`api -> adapter` edge ADR-0015 says the two workspace-crate entries exist to close by machine. It
works: the shortcut is a failed build, and the correct shape is the one above.

**A second question the ADR should rule on:** R5 (read back a transaction) is not a *report* — it
takes no cursor and no chart version. It can sit on `Reports` as one more method or take a third
port. **One port**, because the alternative is a manifest's worth of ceremony for one method and the
two are the same capability from the caller's side: *tell me what the book says.*

---

## Q8 · The error grammar for reads

`out/q8-transcript.txt`, every case with `VERBOSITY=verbose` so the SQLSTATE is printed.

### 8.1 The chart version is the only input that raises — **proven**

```
balance_sheet_at('t1', 'infinity', report_cursor(), 999)
    ERROR:  23514: chart version 999 does not exist
income_statement_for(..., 999)
    ERROR:  23514: chart version 999 does not exist
```

Both A13 guards fire, both as `23514` (`check_violation`). The A14 refusal — an in-scope type with
posted entries the version does not present — **could not be triggered on this chart**: every
`account_type` is presented at every version (`unpresented_type_at_v3` returned 0 rows), which is
itself a small positive result about `schema/chart.sql`. It is ADR-0011's own tested guard and is
taken on that evidence, not re-proven here.

`trial_balance_at` takes no chart version, so it has no A13/A14 class at all.

**Mapping:** both are `422`, per ADR-0014's rule that 422 means *correct the request*. Error `type`s
under its grammar (subject first, condition second): **`chart_version_unknown`** and
**`chart_version_incomplete`**. Not 404: the resource is the report, and the report exists — one of
its parameters is wrong, which is the exact distinction 422 was chosen for.

### 8.2 An unknown tenant, a typo'd tenant, and an empty book — **proven**

```
balance_sheet_at('nope', …)               bs_rows = 0
trial_balance_at('nope', …)               tb_rows = 0
balance_sheet_at('t11', …)                bs_rows = 0     -- 't1' with one character added
```

And the two shapes of empty:

```
a tenant with ACCOUNTS but no entries     bs_rows = 10, total = 0
a tenant with NO accounts at all          bs_rows = 0
```

**Mapping:** `200` with an empty list, and **no 404 for an unknown tenant.** There is no tenant
registry — ADR-0011 §5 says so explicitly (*"nothing in the schema declares a tenant"*) — so "unknown
tenant" is not a state the database can report. Inventing a 404 would mean inventing the registry, or
inferring existence from `ledger_accounts`, which is the same enumeration-from-data the schema
already calls an honest limit.

### 8.3 Four conditions, one observable — **proven, and this is Q8's real answer**

`out/q8-transcript.txt` §7 beside §5 and §6:

| condition | what a caller sees |
| --- | --- |
| a tenant that does not exist | 0 rows |
| a tenant whose name was typo'd by one character | 0 rows |
| a real tenant with no accounts yet | 0 rows |
| **a reader scoped to `t1` asking for `t2`** | **0 rows** |
| **a reader with no scope at all asking for its own tenant** | **0 rows** |

```
reader scoped to t1, asking for t2            balance_sheet_at(t2)          rows = 0
reader with NO scope, asking for t1           balance_sheet_at(t1) unscoped rows = 0
```

**The API cannot distinguish them, and it should not try.** Two of the five are the fail-closed path
working exactly as designed; the other three are caller mistakes. Distinguishing them would require
the read path to consult something *outside* the RLS fence — and the fence's whole purpose is that
there is no such thing.

What follows is a design consequence to state in the ADR rather than a bug to fix:

- **An empty report is not evidence of an empty book.** It is evidence that the caller's tenant, the
  session's scope, and the book's contents do not jointly produce rows.
- **The asymmetry with the chart version is the point.** A wrong `chart_version` **raises**; a wrong
  `tenant_id` is answered with silence. The same class of caller mistake gets a loud refusal on one
  parameter and a fabricated-looking empty statement on the other, and an integrator will learn the
  wrong lesson from whichever they hit first.
- **The one mitigation available inside the fence** is that the read path *knows* which tenant it
  scoped the session to, because it set the GUC. If the requested `tenant_id` and the scoped
  `app.tenant_id` differ, that is a caller error the handler can name **without** asking the database
  anything — `422 tenant_mismatch`. Under ADR-0017 the two are the same value today (the body names
  the book and the read path scopes to it), so the check is vacuous *now* and is exactly the check
  that stops being vacuous the day a gateway starts supplying the scope. It costs one comparison.

### 8.4 An unknown account and an account that has never been written are the same too — **proven**

`out/q8-transcript.txt` §8:

```
a real account with activity            stripe_rows = 6, balance_minor = 442000
an account id that does not exist       stripe_rows = 0, balance_minor = NULL
an account that EXISTS but has never
  been written (no balance row yet)      stripe_rows = 0, balance_minor = NULL
…and the account row itself              account_exists = 1
a currency the account does not hold     stripe_rows = 0
```

A balance row is created lazily by the first write (ADR-0013 §4: *"raising `stripe_count` needs no
backfill: the next writer to pick a new stripe creates it with the upsert it was going to run
anyway"*), so `ledger_account_balances` alone **cannot** tell an unknown account from a dormant one,
or from a currency the account does not hold. The only thing that can is `ledger_accounts`. Note the
`stripe_rows = 6` on the active account: eight stripes were declared and six exist, which is the
lazy-creation property in the same output.

**So R1 must consult `ledger_accounts`, not only the balance table** — a `LEFT JOIN` from
`ledger_accounts` keeps it one statement, and the point for the contract is that the balance table is
not sufficient: 404 `account_unknown` versus 200 with `posted_minor: 0` is a distinction only
`ledger_accounts` can draw.

### 8.5 A malformed cursor — **proven**

3.5's table is the evidence. Mapping:

- `'not-a-cursor'` raises `22P02` → **`422 invalid_request`** (ADR-0014 grandfathers that name as the
  generic body refusal).
- `'-1'`, `'0'` and `xid8` max **do not raise**. They are syntactically valid `xid8` values, and the
  database has no way to know they are nonsense. **The refusal has to be the read path's**, which is
  why the cursor rule belongs in `ReportService` (Q7) and not in the handler's deserialization: a
  cursor must be a value inside the plausible range — at or below the current horizon and above the
  book's oldest `xact_id` — and anything else is **`422 cursor_invalid`**.
- **NULL** is the case with no wire form at all: an absent `cursor` query parameter. Two defensible
  answers, and the ADR must pick one in the open — pin a fresh cursor server-side and return it, or
  refuse. **Pin it**, because a caller running a report *now* should not have to know what a cursor
  is to get a correct answer, and because the returned `pinned_cursor` is then the thing they store.
  What must never happen is the absent parameter reaching the function as SQL NULL (3.4).

### 8.6 The summary table an ADR can be written from

| condition | SQLSTATE | HTTP | `type` |
| --- | --- | --- | --- |
| nonexistent chart version | 23514 | 422 | `chart_version_unknown` |
| chart version does not present an in-scope type | 23514 | 422 | `chart_version_incomplete` |
| unparseable cursor or instant | 22P02 or none | 422 | `invalid_request` |
| syntactically valid but implausible cursor (`-1`, `0`, max) | **none** | 422 | `cursor_invalid` — the service's refusal, not the database's |
| absent cursor | none | 200 | none — pin one server-side and return it |
| unknown account | none | 404 | `account_unknown` (needs `ledger_accounts`, 8.4) |
| unknown transaction | none | 404 | `transaction_unknown` |
| unknown tenant, typo'd tenant, tenant with no accounts, scoped-out reader, unscoped session | none | **200, empty** | none — indistinguishable by construction (8.3) |
| requested tenant differs from the scoped tenant | none | 422 | `tenant_mismatch` (vacuous today, 8.3) |
| statement timeout | 57014 | 503 | `report_timed_out` — see 9.4 |

Every `type` above follows ADR-0014's grammar (subject first, condition second), and none of the
write path's eight is reused.

---

## Q9 · Isolation for a report

### 9.1 A single call needs no transaction for consistency — **proven**

A single statement is one snapshot at every isolation level, which `reconcile.rs`'s own comment
already says of the sweep. `out/q9-transcript.txt` §D shows the two function shapes and the
difference between them: `trial_balance_at` is `LANGUAGE sql STABLE` and **inlined** (the plan is the
aggregate itself, `HashAggregate -> Hash Join -> Index Scan`), while `balance_sheet_at` plans as an
opaque `Function Scan`. Either way, one call is one snapshot.

**So the transaction the read path opens is Q1's, not Q9's.** That is the finding: the read path
needs a transaction for the tenant GUC and gets snapshot consistency for free.

### 9.2 A multi-statement read needs `REPEATABLE READ`, and the cursor does not substitute — **proven**

Two `balance_sheet_at` calls at the **same fixed cursor** in one transaction, with an account created
between them:

```
READ COMMITTED READ ONLY:    statement 1: rows = 20     statement 2: rows = 30
REPEATABLE READ READ ONLY:   statement 1: rows = 30     statement 2: rows = 30
```

(`out/q9-read-committed.txt`, `out/q9-repeatable-read.txt`.) Under `READ COMMITTED` the same report
at the same cursor returned ten more rows on its second call. **The snapshot covers exactly the gap
the cursor leaves** — 3.2's unpinnable branches, which are precisely the tables with no `xact_id` —
and the two mechanisms are therefore complementary rather than redundant: the cursor pins the
amounts, the snapshot pins the row set.

### 9.3 …and what `REPEATABLE READ` costs everyone else, measured — **measured**

`out/q9-transcript.txt` §C. An 11-second `REPEATABLE READ READ ONLY` report on `big1m`, with the
horizon sampled while it ran:

```
before the report opens:                       cursor_now = 16170
while the report is running:                   cursor_now = 16170, backends_pinning_xmin = 4
  pid 10525  spike023  active  backend_xmin 16170  SELECT count(*) FROM balance_sheet_at('big1m…
```

The cursor did not move for the report's whole duration. **A long report pins the cursor of every
report issued after it, including its own successors** — ADR-0010's cost list says exactly this
(*"it pins [ADR-0006]'s as-of watermark, which is defined off `pg_snapshot_xmin`"*) and 3.7 is a
third party demonstrating it at scale. At 5.1's numbers, a `REPEATABLE READ` balance sheet on a
million-entry book holds the horizon back by 4–11 seconds, so every report issued in that window is
pinned behind it and omits anything committed in it.

### 9.4 The ruling — **reasoned from 9.1–9.3**

`READ ONLY` always: it binds immediately, it is free, and the e2e suite already holds it red-path for
the sweep (a write smuggled into a read path is refused by the transaction, not by a grant).

`READ COMMITTED` for a single-report endpoint (R1–R5 as specified), because one call is one snapshot
and `REPEATABLE READ`'s only effect there would be to hold the horizon for the duration.
**`REPEATABLE READ` for a multi-statement read**, and R1 and R5 are the two that would need it least
(R1 reads the cache and takes no cursor; R5 reads immutable rows by primary key).

And the cost is the ruling's other half: **a read path that grows a multi-statement report must
budget the horizon it holds**, which is a coupling between the read path's latency and every other
report's freshness that no amount of read-replica routing removes, because `pg_snapshot_xmin` is the
cluster's. The mitigation is 5.3's — make the reports faster, i.e. wire the checkpoint. It is not an
isolation-level choice.

The `statement_timeout` interaction is the last piece: at 30 s a report that exceeds the budget is
killed with `57014` (`query_canceled`). That is **503**, not 500 and not 504 — the service is
healthy, the request was too expensive, and retrying it unchanged will fail identically, which is
what a caller needs told. `type`: `report_timed_out`.

---

## What this spike refutes, withdraws or corrects

Collected here because this project treats a withdrawn claim as a first-class result. Each names the
file and the sentence.

**1 · `crates/db/src/lib.rs`, the doc comment on `CONNECTIONS_ABOVE_THE_WRITERS`:** *"these six are
what keep the startup schema gate — and any future reader — from waiting behind a pool of writers
that is full by design."* **The "any future reader" clause is withdrawn.** This is that reader
(2.7): a report holds a connection for 4–11 s at a million entries, six of them exhaust the
headroom, and the seventh loses its `ACQUIRE_TIMEOUT` at 15 s against 32 dispatchers that are full by
design. More decisively, sharing that pool means sharing its *login*, and 2.3 shows a login that can
write reads every tenant. The six should keep the one job the sentence's first half gives them.

**2 · `migrations/00001_baseline.sql`, the balance-sheet header, point 4:** *"It names its chart
version and its cursor is a parameter, so an issued statement is reproducible after any backdated
posting (ADR-0011, proven)."* **True as written and misleading as read.** 3.1 is fresh proof of the
clause's actual claim; 3.3 shows that an issued statement re-run at the same cursor **and** the same
chart version can come back with ten more rows, because the lines are enumerated from
`ledger_accounts`, which carries no `xact_id`. The numbers are reproducible; the row set is not. The
correction the ADR owes a reader is one clause, not a redesign.

**3 · The same block, and ADR-0011 §4's signature table:** the chart version is described as pinning
the presentation. 3.6 shows it pins it **only for a version below `max(version)`**. A statement
pinned at the *current* version gained a line at a fixed cursor. `refuse_stale_chart_version()`
freezes history and does not freeze the present.

**4 · `site/content/decisions/0013-write-path-contract.md`, cost list:** *"`SET LOCAL` per
transaction, never `SET ROLE` per tenant — both recent RLS plan-cache CVEs came from role
switching."* Two corrections, in opposite directions. The **scope** is right and the **form** is
incomplete: `SET LOCAL` takes no bind parameter (1.4), and `tenant_id` is caller-supplied text, so
the instruction has to be `set_config('app.tenant_id', $1, is_local => true)` — same scope, plus a
bind. And the plan-cache clause, tested at its worst case, **does not reproduce** on PostgreSQL 18.6
with sqlx 0.9 (2.5): four executions of one cached statement text across a role change and two GUC
values were each correct for the role and scope in force. It should stay as provenance for avoiding
per-*tenant* role switching and stop being an argument against `SET LOCAL ROLE`, which this spike
relies on and measures safe.

**5 · The baseline's RLS comment:** *"the TWO-argument `current_setting` returns NULL when the GUC is
unset — `tenant_id = NULL` matches nothing, so an unscoped session FAILS CLOSED."* **Incomplete, in
a way that matters.** It covers a connection never scoped. After `RESET`, the GUC is `''`, not NULL
(1.6), and what fails closed there is `ck_*__tenant_non_empty` on all nine tenant-keyed tables — a
`CHECK` constraint the RLS section never mentions. The property holds; it has two mechanisms and the
comment names one.

**6 · Nothing in the tree says the report functions guard their arguments, and the A13 comment
implies the class was closed.** *"The old COALESCE never touched `chart_versions`, so
`income_statement_for(..., 999)` returned a fabricated, all-zero, perfectly balanced statement citing
a version nobody created."* The same class is **open** for the cursor, the as-of instant and the
effective range (3.4, 3.5): a NULL cursor returns the complete face at 0.00 with
`recon_equation_breaks` reporting zero breaks on it, and `'-1'::xid8` returns the whole unpinned book.
No function is `STRICT`; `EXECUTE` is `PUBLIC` on all five.

**7 · A claim of this spike's own, withdrawn.** An earlier draft of 5.2 attributed
`balance_sheet_at`'s 47.3 M buffers to *"the cursor arriving as a bound parameter defeating the
selectivity estimate"*, and to *"the plug, which the decomposition accounts for."* **Both were tested
and both are false**: the plug costs 1,583 ms with a literal cursor and 1,536 ms with a bound one,
and the decomposition sums to ~2.54 M buffers against the function's 47.3 M. What the measurement
does support is narrower and more useful — three plan shapes at 11.0 s / 4.2 s / 2.7 s, with the
*generic* plan the fast one and `force_custom_plan` the trap — and the 19x gap between the inlined
body and the function's custom plan is recorded as **unexplained**.

## What could not be settled

- **The 19x buffer gap** between `balance_sheet_at`'s inlined body (2.49 M) and the function's custom
  plan (47.3 M) is unexplained. Two hypotheses were tested and refuted (5.2). Settling it wants
  `auto_explain.log_nested_statements`, which is a `shared_preload_libraries` change and therefore a
  change to `docker-compose.yml`, which is outside this spike's boundary.
- **The A14 refusal** (an in-scope type the chart version does not present) could not be triggered on
  `schema/chart.sql`, because every type is presented at every version. Taken on ADR-0011's evidence.
- **The pool-exhaustion arithmetic in 2.7 is reasoned, not measured.** Producing it would mean
  saturating 38 connections with a mix of 11-second reads and postings, which measures
  `max_connections` rather than anything about the read path.
- **Whether the checkpoint can bound the un-closed-earnings plug without reopening ADR-0011 §A3** is
  the real M5 question underneath 5.3, and it is a design question with a measurement attached rather
  than a finding this spike produced. A3 chose the plug's shape *so that its caption cannot move
  under a fixed cursor*; bounding it by `ledger_period_closes` is exactly what A3 removed.
- **Nothing here was measured over a network.** Every number is localhost, which the roadmap already
  calls the project's largest open caveat. For reads it matters differently than for writes: the
  transaction Q1 forces is two extra round trips on a read whose own cost is milliseconds to seconds,
  so the overhead is negligible for R2–R5 and is the dominant term for R1, whose own work is 0.09 ms.
- **The read path itself is not built.** This spike settles its contract and writes no service code;
  every Rust file under `harness/` is throwaway and depends on none of `ledger`, `ledger-postgres`,
  `api` or `openledger`.
