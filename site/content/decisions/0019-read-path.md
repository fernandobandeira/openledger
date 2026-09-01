# 0019 — The read path is a second port on a second pool, and the cursor is validated before it reaches SQL

**Status:** accepted (ruled 2026-09-01)
**Evidence:** [spike 019](/spikes/019-read-path-contract) for every measurement and every refutation
below; [spike 021](/spikes/021-reporting-layer-defects) for the reporting-layer defects the read path
must not inherit.

## The decision

**The reports become HTTP.** `report_cursor()`, `trial_balance_at`, `income_statement_for` and
`balance_sheet_at` have existed since the baseline and **had never been called from Rust on a request path**; the HTTP
surface was one route and the port was one trait with one method. *(Two of them are executed from
Rust on every sweep — `reconciliation`'s equation row is `recon_equation_breaks(report_cursor(),
'infinity')`, which calls `balance_sheet_at` per tenant. That call is where this ADR's own 29-second
figure comes from.)* This decision is the contract the
read path honours — [M5](/roadmap#m5--bitemporal-reads)'s half that is not the checkpoint.

**A read runs on its own pool, under its own login, whose only membership is `openledger_read` — and
issues `SET LOCAL ROLE openledger_read` inside every read transaction anyway.** Not defence in depth
for its own sake: **a login that is a member of both `openledger_app` and `openledger_read` reads
every tenant.** RLS policies are permissive and OR'd, and `pg_has_role` — not equality — decides
which apply, so the writer's `USING (true)` unions with the reader's tenant qual and `app.tenant_id`
becomes decoration. Measured side by side: the dual-membership login read **6 entries across t1 and
t2** with `app.tenant_id = 't1'` set, and **4 — t1 only** — behind `SET LOCAL ROLE`. The shipped tree
could not observe this, because its one `DATABASE_URL` is the owner's and the owner is not subject to
RLS at all. The separate login makes the fence structural; the `SET LOCAL ROLE` keeps it if a
deployment ever wires one login for both.

*(**Amended 2026-09-01, by the e2e slice that was written to prove this.** The sentence above once
read that a one-login deployment "is safe **only** because the adapter issues `SET LOCAL ROLE`". That
"only" is wrong, and the correction is worth more than the claim: **over HTTP the tenant fence is not
falsifiable at all.** Deleting the adapter's `SET LOCAL ROLE` leaves every fence test green; deleting
the pool's `SET ROLE` **as well** also leaves them green. The reason is structural — every statement
this read path issues carries its own tenant predicate, `trial_balance_at(p_tenant, …)` and
`balance_sheet_at(p_tenant, …)` by argument, and `WHERE a.tenant_id = $1` on the balance, transaction
and bounds reads — so RLS is the **second** line of defence on all five routes and never the only one.
And because there is no authentication ([0017](/decisions/0017-no-authentication)), a caller may name
any tenant and legitimately be given it, so RLS buys **no confidentiality at the API boundary** in the
first place. What it does buy is real and worth keeping: a defence against SQL that forgets its
predicate, and a fence around the direct database readers — analysts, BI tools, a `psql` session —
that reach these functions without passing through this contract at all.)*

A third permissive `USING (true)` family exists for
`openledger_recon`, which a login carrying *that* membership would union in exactly the same way.

**Two things this ruling rests on that were not previously written down.** First, the fence's
fail-closed behaviour is not the GUC's doing: after `RESET`, `app.tenant_id` is `''`, **not** NULL, so
`tenant_id = ''` matches nothing only because `ck_*__tenant_non_empty` forbids an empty tenant. That
`CHECK` is load-bearing for tenant isolation and nothing said so — a future migration relaxing it
would open a cross-tenant read on reset connections. Second, **[0013](/decisions/0013-write-path-contract)'s
RLS plan-cache clause is withdrawn as an argument against switching roles per read**: the worst case
was constructed — one cached statement text, four executions across a role change and two GUC values,
starting from a plan prepared as the owner with no RLS qual at all — and every result was correct. The
sentence stays as provenance for avoiding per-*tenant* roles; it is no longer a reason to avoid
`SET LOCAL ROLE`.

**Every read is an explicit `READ ONLY` transaction, and the reason is the tenant fence rather than
isolation.** `set_config('app.tenant_id', $1, true)` outside a transaction is discarded before the
next statement, so an autocommit read is unscoped-and-empty forever. The scope is set as
`SELECT set_config('app.tenant_id', $1, true)` — a **bind parameter**, because `tenant_id` is
caller-supplied text from a request body ([0017](/decisions/0017-no-authentication)) and this is the
only form that carries it as data rather than as SQL. That **refines [0013](/decisions/0013-write-path-contract)'s
`SET LOCAL` instruction**, which cannot take a bind. Session-scoped `SET` is refused everywhere:
sqlx 0.9 issues no reset on release, and a session `SET app.tenant_id = 't1'` was inherited by the
next checkout, which read t1's rows believing itself unscoped — while a session
`SET ROLE openledger_read` handed the *writer* a role with no `INSERT` grant. The
single-round-trip form `WITH s AS (SELECT set_config(…)) SELECT …` is refused too: PostgreSQL
guarantees no evaluation order between a non-data-modifying CTE and the outer query, and a tenant
fence resting on an unspecified evaluation order is not a fence. The price is **four round trips per
read** — `BEGIN`, `set_config`, the report, `COMMIT` — where the refused one-statement form would
have been one, plus whatever the cursor validation below costs. Negligible against a report.

**`report_cursor()` is confirmed as the as-of mechanism, end to end on the shipped functions.** The
interleaving that refuted [0006](/decisions/0006-time-and-as-of)'s watermark — a transaction starting
before the cursor and committing after it — left all three reports **byte-identical**, while
`max(xact_id) + 1` moved 131,000 → 230,000 across the same commit.

**The cursor is validated by the read path before it reaches SQL, and the reason is that the database
cannot refuse a bad one.** An absent cursor is pinned server-side and **never reaches a function as
SQL NULL**; a supplied one must parse as `xid8`, sit at or below the current horizon and **strictly above**
the book's oldest `xact_id`, or it is `422 cursor_invalid`. **Strictly** above, because the reports
filter `xact_id < :cursor`: a cursor equal to the oldest admits nothing and returns the same all-zero
fabrication the rule exists to refuse. Both bounds are themselves database reads — the horizon from
`report_cursor()`, the floor from an aggregate over `ledger_entries` — so "before it reaches SQL"
means before it reaches a *report*, not without a round trip. And the floor is read **inside the
scoped transaction**, so it is that tenant's oldest rather than the cluster's. The race is benign in
the one direction that matters: `pg_snapshot_xmin` is non-decreasing, so a cursor valid when stored
never rises above a later horizon. Two legal values are why:

| supplied | what the shipped SQL answers |
| --- | --- |
| SQL `NULL` | the **complete** balance-sheet face at 0.00, *balanced* — and `recon_equation_breaks(NULL, …)` reports **zero breaks** on the fabrication |
| `'-1'::xid8` | silently wraps to `18446744073709551615` and returns the **entire unpinned book**, with today's correct numbers |

The second is the worse one, because it looks right. Both are legal `xid8`, so no `CHECK` and no
`STRICT` reaches them — the *function* guards can only stop the absent cursor, which is why they are
a separate migration and do not block M5. **Every report route returns the cursor the read path
pinned**, always, including when the caller supplied none: it is the only way a caller can notice
that the cluster horizon is lagging, which it does for reasons outside this database. Note where that
lives — `balance_sheet_at` and `income_statement_for` return `pinned_cursor` as a column;
`trial_balance_at` does not, so on that route it is the read path echoing what it passed.

**Every statement call passes `chart_version` explicitly.** The default is `max(version)` resolved at
run time — explicit v1 and the default returned 1 and 3 on the same database. The residual is stated
rather than fixed: naming a version pins the presentation only *below* `max(version)`, because
`refuse_stale_chart_version()` freezes history and not the present, and a statement pinned at the
current version gained a line at a fixed cursor.

**Both range bounds are half-open, and `as_of` is an `ends_at` rather than a business date — the
endpoint descriptions say so.** `effective_at < p_asof` and `[p_from, p_to)` are the same predicate
family on all three functions ([0011](/decisions/0011-period-close-and-report-axes) §A3), so a caller
passing a business date gets the position at the **start** of that day and **silently loses a day at
every period boundary**. Silently is the operative word: nothing raises, and the number is plausible.

**The contract promises that an issued report's *amounts* are reproducible at a stored cursor — with
one carve-out that is a real hole and not a nicety — and it does not promise the *row set* at all.**
The lines are enumerated from `ledger_accounts`, `chart_versions`, `chart_presentation`, `fs_lines`
and `account_types`, **none of which carries an `xact_id` column**, so one new EUR account with
nothing posted to it added ten balance-sheet rows and four income-statement rows at a fixed cursor,
every pre-existing amount byte-identical. That is the clause `balance_sheet_at`'s own header comment
was missing.

**The carve-out: an income statement's amounts are *not* fully reproducible.**
`income_statement_for` excludes closing entries with `NOT EXISTS (… FROM ledger_period_closes …)`,
and `ledger_period_closes` is append-only but carries **no `xact_id`** — so that predicate is an
**unpinned filter**, not an enumeration. A close row inserted *after* a statement is issued, naming a
transaction below its cursor, **retroactively removes that transaction's entries from the
already-issued statement**. An amount moves, not a line. Until `ledger_period_closes` carries a
commit position of its own, the honest promise is: the balance sheet's and trial balance's amounts
are reproducible, and the income statement's are reproducible *except across a subsequent close of a
period it covers*.

**And the unfiltered `ledger_transactions` join is sound — recorded so nobody "fixes" it.** Every
aggregation joins `ledger_transactions` on `status = 'posted'` without filtering that table by
`xact_id`, which reads like the same omission and is not one: `fk_entries__transaction` means an
entry cannot exist before its transaction, so an entry below the cursor has a transaction below it,
and `status` is immutable under `ck_txn__append_only` (`ENABLE ALWAYS`) plus
`REVOKE UPDATE … FROM openledger_app`. **The safety is a key and a trigger rather than a predicate**,
which is worth stating rather than inheriting.

**Five routes, and only five.**

| route | pinned by |
| --- | --- |
| `GET /v1/accounts/{account_id}/balance` | nothing — it means *posted, now* |
| `GET /v1/reports/trial-balance` | cursor + effective range |
| `GET /v1/reports/balance-sheet` | cursor + `as_of` instant + chart version |
| `GET /v1/reports/income-statement` | cursor + half-open effective range + chart version |
| `GET /v1/transactions/{transaction_id}` | nothing — the rows are immutable |

**One trial-balance endpoint serves both time axes, by parameter and never by a mode flag** —
[0006](/decisions/0006-time-and-as-of)'s recorded axis *is* the cursor and its effective axis *is*
the range, so one function already answers both. Two resources for two parameters of one function is
Formance's `pit`-resolves-to-six-columns mistake. **The balance endpoint reads `ledger_accounts`, not
only `ledger_account_balances`**, because a balance row is created lazily by the first write, so the
cache alone cannot tell an unknown account from a dormant one — all three return zero rows and a NULL
sum, and `404 account_unknown` versus `200` with `posted_minor: 0` is a distinction only the account
register can draw. **No stripe appears in any response** ([0013](/decisions/0013-write-path-contract) §4):
the read is a `SUM` over the stripe rows, measured **flat at 0.091–0.100 ms across a hundredfold
book**, and shipping it is how an integrator is stopped from writing the single-row read that
under-reports. **`GET /v1/transactions/{id}` is in scope** because a write-only API is not an adoption
surface: the shipped endpoint returns two UUIDs and nothing over HTTP could say what they point at,
and [0016](/decisions/0016-pending-to-posted) made `status`, `resolves_id` and `reverses_id` wire
concepts a caller could not read back.

**A second inbound port, `Reports` — not a second method on `Ledger`.** Every variant of
`WriteError` **except `Storage`** promises *"nothing was written"*, which is not a sentence a read can
say, and
`port.rs`'s own doc sets the test reads fail: *"anything else the API grows must earn its place here
first."* Behind it, a thin `ReportService` in `crates/ledger` owning only the cursor rule — because
that rule is judgement, not SQL, and judgement is what keeps an inbound port from being the adapter
— a separate outbound `ReportStore` port, and `PgReportStore` in `crates/ledger/postgres`, which owns
the `BEGIN` / `set_config` / `SET LOCAL ROLE` bracket because those statements are PostgreSQL's
dialect ([0004](/decisions/0004-where-logic-lives)). The read pool is a second newtype in
`crates/db`, where [0015](/decisions/0015-workspace-enforcement) puts pool hardening.

**`deny.toml` needs no change, and that is a positive result rather than an absence.** Every edge
above is already permitted, the domain crate stays sqlx-free and runtime-free, and `clippy.toml`'s
ambient-clock ban needs no `#[expect]` because a read path invents no clock — though note that ban
covers `SystemTime::now` and `Instant::now` only, and `OffsetDateTime::now_utc` is reachable from
`crates/api` unlinted. **The ratchet also earns its keep**: building the read pool in `crates/api` —
the obvious shortcut, since the handler is what needs it — is refused by
`{ crate = "db", wrappers = ["ledger-postgres", "openledger"] }`. **It is a red CI check, not a
compile error**: `cargo deny check bans` is its own job, and `deny.toml`'s comment on that very entry
records that `api` importing `db` *"compiled clean"* before the row existed — which is why the row
exists. *(An earlier draft of this ADR called it "a failed build". That overstates the mechanism in
the one direction a reader would rely on.)*

**`READ ONLY` always; `READ COMMITTED` for a single-statement report, `REPEATABLE READ` only when a
read becomes multi-statement — and there the cursor is not a substitute for it.** One statement is
one snapshot at every isolation level, so `REPEATABLE READ` on a single-call report buys nothing.
**What it would add is the transaction's idle time around the statement, not the report's duration** —
a report pins the horizon for as long as it runs at any isolation level, which is the cost bullet
below and not an argument between levels. But two `balance_sheet_at` calls **at the same fixed cursor**
returned 20 then 30 rows under `READ COMMITTED` and 30 then 30 under `REPEATABLE READ`: the snapshot
covers exactly the gap the cursor leaves, which is the unpinnable row set above.

**Errors follow [0014](/decisions/0014-http-api)'s subject-then-condition grammar, declared per
endpoint. Six are new** — `cursor_invalid`, `chart_version_unknown`, `chart_version_incomplete`,
`transaction_unknown`, `tenant_mismatch` and `report_timed_out` — **and two are shared with the write
path, deliberately**: `invalid_request`, which every report route needs for a malformed instant or an
unparseable cursor (`22P02`), and `account_unknown`, which **carries 404 here against its 422 there**.
That last one is a status collision on one `type` name, and it is legal only because ADR-0014 declares
responses per endpoint rather than per enum — it is called out here so the next reader does not take
it for a slip. `report_timed_out` is **503**, not 500 and not 504, because `57014` means the service is healthy, the
request was too expensive, and retrying it unchanged fails identically. **An unknown tenant is `200`
with an empty answer, never `404`**, because there is no tenant registry to consult
([0011](/decisions/0011-period-close-and-report-axes) §5: *"nothing in the schema declares a
tenant"*), so inventing the status means inventing the registry.

## What we considered

| | Why not |
| --- | --- |
| **A read method on the existing `Ledger` port** | Its errors all promise "nothing was written". A read cannot say that, and the port's own doc demands a capability earn its place. `AppState` was written to take a second field. |
| **Sharing the writer's pool** | Two independent refusals. A login that can write reads every tenant (above) — that one is measured. The second is *reasoned, not measured*: a report holds a connection for 4–11 s at a million entries, so six headroom connections would be exhausted by six concurrent reports while 32 dispatchers are full by design. The pool comment's "any future reader" clause is **withdrawn** — this is that reader. |
| **`SET LOCAL app.tenant_id = <interpolated>`** | `SET LOCAL` takes no bind parameter; the `set_config` form does, and a caller's string has no business being SQL. |
| **The one-statement `WITH set_config(…) SELECT …` read** | Undocumented evaluation order between a non-data-modifying CTE and the outer query — under a tenant fence. Two round trips is cheaper than a fence that might not be one. |
| **Passing a caller's cursor straight through to SQL** | `-1` and `0` are legal `xid8`. One fabricates an all-zero balanced statement; the other returns the whole unpinned book looking correct. |
| **Letting `chart_version` default** | It resolves at run time to a version whose content can still change. |
| **Pagination** | At a million entries the three reports return **2, 10 and 4 rows**. There is nothing to page, and pagination would answer a cost question with an interface change. |
| **Any listing, search or filter endpoint** | Each needs an ordering and a page key this spike did not design; shipping one under ADR-0014's machine-checked route table documents it forever. |
| **Exposing the reconciliation views or `close_disclosures` over HTTP** | Cross-tenant views on a deliberately unauthenticated service ([0017](/decisions/0017-no-authentication)), and a disclosure whose attestation feed does not exist. |
| **A cursor-minting endpoint** | Every report already returns the cursor it used. |
| **`plan_cache_mode = force_custom_plan`** | It pins the **slow** plan — see the costs. |
| **A 404 for an unknown tenant** | There is no registry to distinguish it from an empty one. |

## What it costs

- **The API cannot tell an empty book from an RLS scope-out, and that is a design consequence rather
  than a gap.** Five conditions produce one observable — unknown tenant, typo'd tenant, tenant with
  no accounts, a reader scoped to a different tenant, and an unscoped session — and **two of the five
  are the fail-closed path working correctly**. Distinguishing them needs a source outside the fence,
  and the fence's purpose is that there is none. **The asymmetry deserves naming**: a wrong
  `chart_version` *raises* while a wrong `tenant_id` is answered with silence, and an integrator will
  learn the wrong lesson from whichever they hit first. `422 tenant_mismatch` — comparing the
  requested `tenant_id` against the scope the read path itself set — is the only mitigation available
  inside the fence, and it is **vacuous today by construction**: it stops being vacuous the day a
  gateway supplies the scope instead of the body.
- **A report holds the cluster horizon for its whole duration.** An 11-second `REPEATABLE READ`
  report held `report_cursor()` still throughout, so every report issued in that window is pinned
  behind it. Read replicas do not fix this: `pg_snapshot_xmin` is the cluster's, and a third party
  demonstrated it from another database entirely while this spike ran.
- **A pooled read path has a warm-up, and the fast plan is the generic one.** The same
  `balance_sheet_at` call on the same data costs **11.0 s** on a connection's first five executions
  (plpgsql's custom plan), **4.2 s** from the sixth (its generic plan), and **2.7 s** with the cursor
  as an inlined literal. So the sixth report on each connection is the first fast one. The **19×
  buffer gap** between the inlined body (2.49 M) and the custom plan (47.3 M) is **unexplained**;
  two hypotheses were tested and refuted, and settling it needs `auto_explain.log_nested_statements`.
- **The timeout ceiling is `10^6` entries, not `10^9`.** Indicative, on a loaded machine:
  `balance_sheet_at` is 11.4 s at 1 M entries, so ~2–3 M meets a 30 s budget;
  `income_statement_for` ~7 M; `trial_balance_at` ~28 M. The read pool therefore sets its own,
  longer, `statement_timeout` — **and that buys less than one order of magnitude**: 90 s is reached
  at ~8 M entries instead of ~2.5 M. The real fix is the checkpoint, which is M5's other half.
  Corroborated from outside the harness: the daily sweep on a 1.11 M-entry book took **28,970 ms**,
  surviving only because `reconcile` sets no `statement_timeout` on its own connection.
- **A report total is an exact-integer *string* on the wire; a posting amount stays a JSON number.**
  This is the API half of a schema fix, and it is decided here rather than left open. The three
  functions declare `bigint` in their `RETURNS TABLE` and cast a `numeric` total back down, so a legal
  book makes a report **raise** rather than answer — `ERROR: bigint out of range`, produced through
  the shipped writer over HTTP in six calls ([spike 021](/spikes/021-reporting-layer-defects), the
  inverse of the defect that was reported). Migration `00004` widens those declarations to `numeric`,
  and a `numeric` cannot be handed to a JSON consumer as a number: **JSON's own numeric type loses
  precision above 2⁵³**, so a total large enough to have needed widening would be silently rounded by
  the parser at the other end — trading a loud refusal for a quiet wrong answer, which is the trade
  this project exists to refuse. So a report's `amount_minor` is serialized as a decimal string
  holding an exact integer. **Posting amounts on the way in are unaffected and stay `i64`**: a single
  posting is bounded by `ledger_entries.amount_minor` and only an *aggregate* can exceed it. The
  asymmetry is deliberate and costs every caller one parse.
- **Two round trips per read**, from refusing the single-statement scope-and-select. Negligible
  against a report; dominant only against the balance endpoint, which is the one read that should be
  measured over a network before it is trusted.
- **The function-level NULL guards are a separate migration and deliberately not a blocker.**
  `EXECUTE` is `PUBLIC` **by default** on all five reporting functions — the four above plus
  `recon_equation_breaks`; the committed migrations contain no `GRANT EXECUTE` at all — so the SQL is
  reachable by an analyst, a BI tool or a `psql` session that never passes through this contract.
  `trial_balance_at` cannot carry a guard while it stays `LANGUAGE sql`, so this covers two functions
  of the three. The read path owns the *plausible* cursor;
  the function guard owns the *absent* one.
