# Spike 023 — the read-path contract, as rulings

Numbered so an ADR can be written from them. Each carries a one-line **because** and a pointer to the
finding that earns it. **Refusals are numbered too** — they are the part of a contract that ages best.

---

## A · How a read reaches the database

**A1 · Every read runs inside an explicit transaction, and the reason is the tenant GUC, not
isolation.**
*Because* `set_config(..., is_local => true)` outside a transaction is discarded before the next
statement, so an autocommit read is unscoped-and-empty forever (FINDINGS 1.5).

**A2 · The scope is set with `SELECT set_config('app.tenant_id', $1, true)` — a bind parameter, never
`SET` and never `SET LOCAL`.**
*Because* `SET app.tenant_id = $1` is a syntax error, `tenant_id` is caller-supplied text from a
request body (ADR-0017), and this is the only form that carries it as data rather than as SQL
(FINDINGS 1.4). **This refines ADR-0013's `SET LOCAL` instruction** — same scope, plus a bind.

**A3 · Never `SET` a GUC or a role at session scope on a pooled connection.**
*Because* sqlx 0.9 issues no reset on release: a session `SET app.tenant_id = 't1'` was inherited by
the next checkout, which read t1's rows believing itself unscoped (FINDINGS 1.2), and a session
`SET ROLE openledger_read` handed the *writer* a role with no `INSERT` grant (FINDINGS 2.1).

**A4 · The read path takes its own pool, on its own login, whose only membership is
`openledger_read` — and issues `SET LOCAL ROLE openledger_read` inside every read transaction
anyway.**
*Because* a login that is a member of both `openledger_app` and `openledger_read` reads **every
tenant**: RLS policies are permissive and OR'd, and the writer's `USING (true)` applies to any
`current_user` that inherits it, so `app.tenant_id` becomes decoration (FINDINGS 2.3). The separate
login makes the fence structural; the `SET LOCAL ROLE` keeps it if a deployment ever wires one login
for both, and `SET ROLE` in `after_connect` is not sufficient on its own because `RESET ROLE` climbs
back out of it (FINDINGS 2.4).

**A5 · Refuse the single-round-trip form
`WITH s AS (SELECT set_config('app.tenant_id', $1, true)) SELECT …`.**
*Because* PostgreSQL guarantees no evaluation order between a non-data-modifying CTE and the outer
query, so whether the GUC is set before the RLS qual is evaluated is not a documented property — and
a tenant fence resting on an unspecified evaluation order is not a fence (FINDINGS 1.5). The cost of
refusing it is two round trips per read, negligible against every report and dominant only against
R1, which is why R1 is the one read that should be measured over a network before it is trusted.

**A6 · `POOL_CONNECTIONS` and `CONNECTIONS_ABOVE_THE_WRITERS` do not move, and the doc comment's
"any future reader" clause is withdrawn.**
*Because* a report holds a connection for 4–11 s at a million entries, so six would be exhausted by
six concurrent reports and the seventh would lose its 15 s acquire against 32 dispatchers that are
full by design — and the deciding reason is A4's, not capacity: the reader must not share the
writer's *login* (FINDINGS 2.7). The `const` assertion in `crates/openledger/src/batching.rs` stays
true untouched.

**A7 · The read pool sets its own `statement_timeout`, longer than the writer's 30 s, and its own
`idle_in_transaction_session_timeout`.**
*Because* both are available as `after_connect` settings on a second pool and `openledger_read` can
even raise `statement_timeout` per transaction itself (FINDINGS 2.6), and the writer's values are
sized for three-round-trip appends. **State plainly that this buys less than one order of magnitude**
— 90 s is reached at ~8 M entries instead of ~2.5 M (FINDINGS 5.3).

**A8 · Withdraw the RLS plan-cache clause as an argument against role switching per read.**
*Because* the worst case was constructed and did not reproduce: one cached statement text, four
executions across a role change and two GUC values, each correct, starting from a plan prepared as
the owner with no RLS qual at all (FINDINGS 2.5). Keep the sentence as provenance for avoiding
per-*tenant* roles; stop treating it as a reason to avoid `SET LOCAL ROLE`.

## B · The cursor

**B1 · `report_cursor()` is confirmed as the as-of mechanism, on the shipped functions, end to end.**
*Because* a transaction that started before the cursor and committed after it — the exact
interleaving that refuted ADR-0006's watermark — left all three reports byte-identical, while
`max(xact_id) + 1` moved 131,000 → 230,000 across the same commit (FINDINGS 3.1).

**B2 · Every report endpoint returns the `pinned_cursor` it used, always, including when the caller
supplied none.**
*Because* the cursor is the only thing that lets a caller notice that the cluster horizon is lagging
— and it lags for reasons outside this database: another agent's spike, in a different database,
held it back while a third of this book sat above it (FINDINGS 3.7).

**B3 · An absent `cursor` is pinned server-side. It must never reach the function as SQL NULL.**
*Because* a NULL cursor returns the complete balance-sheet face at 0.00, balanced, and
`recon_equation_breaks(NULL, …)` reports **zero breaks** on that fabrication — the same defect class
the baseline already documents and guards for the chart version, unguarded for the cursor
(FINDINGS 3.4).

**B4 · A caller-supplied cursor is validated by the read path before it reaches SQL: it must parse as
`xid8`, be at or below the current horizon, and be at or above the book's oldest `xact_id`. Anything
else is `422 cursor_invalid`.**
*Because* `'-1'::xid8` silently wraps to `18446744073709551615` and returns the **entire unpinned
book** with today's correct numbers — an unreproducible report that looks fine, which is harder to
catch than the all-zero case; and `'0'` gives the all-zero fabrication with no error either
(FINDINGS 3.5). The database cannot refuse these: they are legal `xid8` values.

**B5 · The report functions should grow their own `RAISE` guards for a NULL cursor, a NULL as-of and
a NULL range — and this is defence in depth, not the primary defence.**
*Because* `EXECUTE` is `PUBLIC` on all five functions and none is `STRICT`, so the SQL is reachable
by an analyst, a BI tool or a psql session that never passes through B3 and B4 (FINDINGS 3.4). **The
layer that owns the rule is the read path** (B3, B4), because only it knows what a *plausible* cursor
is; the function's guard is what stops the *absent* one. It is a new numbered migration and therefore
a separate change from building the read path — say so, and do not let the migration block M5.

**B6 · Every statement call passes `chart_version` explicitly. The read path never lets the default
resolve.**
*Because* the default is `max(version)` read at run time: explicit v1 and the default gave 1 and 3 on
the same database (FINDINGS 3.6). **And state the residual honestly**: naming the version pins the
presentation only for a version *below* `max(version)`; a statement pinned at the current version
gained a line at a fixed cursor, because `refuse_stale_chart_version()` freezes history and not the
present.

**B7 · The contract promises that the *amounts* of an issued report are reproducible at a stored
cursor, and does not promise that the *row set* is.**
*Because* every amount comes from a cursor-pinned branch, while the lines are enumerated from
`ledger_accounts`, `chart_versions`, `chart_presentation`, `fs_lines`, `account_types` and
`ledger_period_closes` — **none of which carries an `xact_id` column at all**. One new EUR account,
nothing posted to it, added ten balance-sheet rows and four income-statement rows at a fixed cursor,
with every pre-existing amount byte-identical (FINDINGS 3.2, 3.3). This is the one clause
`balance_sheet_at`'s own header comment needs.

**B8 · Record that the unfiltered `ledger_transactions` join is sound, and why, so nobody "fixes" it.**
*Because* the safety is a foreign key and a trigger rather than a predicate: `fk_entries__transaction`
means an entry cannot exist before its transaction, so an entry below the cursor has a transaction
below it, and `status` is immutable under `ck_txn__append_only` (`ENABLE ALWAYS`) plus
`REVOKE UPDATE … FROM openledger_app` (FINDINGS 3.2).

## C · The endpoints

**C1 · Five routes, and only five.**

| route | method | pinned by |
| --- | --- | --- |
| `/v1/accounts/{account_id}/balance` | GET | nothing — it means *posted, now* |
| `/v1/reports/trial-balance` | GET | cursor + effective range |
| `/v1/reports/balance-sheet` | GET | cursor + `as_of` instant + chart version |
| `/v1/reports/income-statement` | GET | cursor + half-open effective range + chart version |
| `/v1/transactions/{transaction_id}` | GET | nothing — the rows are immutable |

*Because* ADR-0014's route table is machine-checked against the committed spec in both directions, so
a route that ships is documented forever, and each of these five answers a question an adopter
demonstrably has (FINDINGS Q6).

**C2 · One trial-balance endpoint serves both time axes, by parameter and never by a mode flag.**
*Because* ADR-0006's recorded-axis mechanism *is* the cursor and the effective axis *is* the range,
so `trial_balance_at` already answers both — proven on the same function at 10,000 / 13,000 / 18,000
across the backdated entry, and at 18,000 / 230,000 across two cursors (FINDINGS 4.1, 4.2). Two
resources for two parameters of one function is Formance's `pit`-resolves-to-six-columns mistake.

**C3 · `GET /v1/transactions/{id}` is in scope for M5.**
*Because* a write-only API is not an adoption surface: the shipped endpoint returns two UUIDs and
nothing over HTTP can say what they point at, and ADR-0016 made `status`, `resolves_id` and
`reverses_id` wire concepts a caller currently cannot read back. It costs one statement, needs no
cursor (the rows are immutable), takes no chart version, and adds one error class (FINDINGS Q6 R5).

**C4 · The balance endpoint reads `ledger_accounts`, not only `ledger_account_balances`.**
*Because* a balance row is created lazily by the first write, so the balance table alone cannot
distinguish an unknown account from a dormant one or from a currency the account does not hold — all
three return zero rows and a NULL sum (FINDINGS 8.4). `404 account_unknown` versus `200` with
`posted_minor: 0` is a distinction only `ledger_accounts` can draw.

**C5 · No stripe appears in any response.**
*Because* ADR-0013 §4 makes it an invariant, and the balance endpoint exists partly to keep it: the
read is a `SUM` over the stripe rows, measured **flat at 0.091–0.100 ms across a hundredfold book**
(FINDINGS 5.1), and shipping it is how an integrator is stopped from writing the single-row read that
under-reports.

**C6 · The balance sheet's `as_of` takes a period's `ends_at`, never a business date, and the
description says so.**
*Because* `effective_at < p_asof` is half-open (ADR-0011 §A3), so a business date returns the
position at the *start* of that day and silently loses a day at every period boundary — the
correction ADR-0006's mechanism table already carries.

## D · Errors

**D1 · Adopt the ten-row grammar table in FINDINGS 8.6 as the read path's declared responses**, per
endpoint, per ADR-0014's *"each endpoint documents only the errors it can actually return"*. New
`type`s: `chart_version_unknown`, `chart_version_incomplete`, `cursor_invalid`, `account_unknown`,
`transaction_unknown`, `tenant_mismatch`, `report_timed_out`. None of the write path's eight is
reused, and every one follows the subject-then-condition grammar.

**D2 · An unknown tenant is `200` with an empty list, never `404`.**
*Because* there is no tenant registry — ADR-0011 §5: *"nothing in the schema declares a tenant"* — so
inventing the status means inventing the registry (FINDINGS 8.2).

**D3 · State in the ADR that the API cannot distinguish an empty book from an RLS scope-out, and
that this is a design consequence rather than a gap.**
*Because* five conditions produce one observable — unknown tenant, typo'd tenant, tenant with no
accounts, reader scoped to another tenant, unscoped session — and two of the five are the fail-closed
path working correctly (FINDINGS 8.3). Distinguishing them needs a source outside the fence, and the
fence's purpose is that there is none. **Name the asymmetry too**: a wrong `chart_version` raises
while a wrong `tenant_id` is answered with silence, and an integrator will learn the wrong lesson
from whichever they hit first.

**D4 · Compare the requested `tenant_id` against the scoped `app.tenant_id` and refuse a mismatch
with `422 tenant_mismatch`, even though the check is vacuous today.**
*Because* it is the only mitigation available *inside* the fence — the read path knows what it scoped
the session to, because it set it — it costs one comparison, and it is exactly the check that stops
being vacuous the day a gateway supplies the scope rather than the body (FINDINGS 8.3).

**D5 · A statement timeout is `503 report_timed_out`, not 500 and not 504.**
*Because* `57014` means the service is healthy and the request was too expensive, and retrying it
unchanged fails identically — which is what a caller needs told (FINDINGS 9.4).

## E · The hexagon

**E1 · A second inbound port, `Reports`, not a second method on `Ledger`.**
*Because* `Ledger` is *post a transaction* and every variant of its `WriteError` promises "nothing
was written", which is not a sentence a read can say — and `port.rs`'s own doc sets the test that
reads fail (FINDINGS Q7). `AppState` was written for this: reads land as one more field.

**E2 · A thin `ReportService` in `crates/ledger`, whose only job is the cursor rule.**
*Because* B3, B4 and B6 are judgement, not SQL, and the core is where judgement lives — this is the
one thing that stops the inbound port's implementor from simply being the adapter.

**E3 · A separate outbound port `ReportStore` in `crates/ledger`, one method per report function,
implemented by `PgReportStore` in `crates/ledger/postgres` — which also owns the
`BEGIN` / `set_config` / `SET LOCAL ROLE` bracket.**
*Because* `Repository`'s doc scopes it to *"what the **writer** service asks of storage"*, and the
session statements are PostgreSQL dialect, which ADR-0004 puts in the adapter.

**E4 · The read pool is a second newtype in `crates/db`.**
*Because* ADR-0015 puts pool hardening there as that crate's decision, and A6/A7 are pool-sizing
reasoning.

**E5 · `deny.toml` needs no change, and the ADR should say so as a positive result.**
*Because* every edge above is already permitted by the capability map as written, the domain crate
stays sqlx-free and runtime-free, and `clippy.toml`'s ambient-clock ban needs no `#[expect]` (a read
path invents no clock). **And the ratchet earns its keep here**: building the read pool in
`crates/api` — the obvious shortcut, since the handler is what needs it — is a *failed build*, because
`{ crate = "db", wrappers = ["ledger-postgres", "openledger"] }` refuses it. That is the
`api → adapter` edge ADR-0015 says the two workspace entries exist to close by machine, working
(FINDINGS Q7).

**E6 · `GET /v1/transactions/{id}` goes on `Reports`, not on a third port.**
*Because* a third manifest's worth of ceremony for one method buys a boundary nothing crosses —
ADR-0015's own reason for refusing a `ports` crate — and from the caller's side it is the same
capability: *tell me what the book says*.

## F · Isolation

**F1 · `READ ONLY` on every read transaction.**
*Because* it binds immediately, costs nothing, and turns a write smuggled into a read path into a
refusal by the transaction rather than by a grant.

**F2 · `READ COMMITTED` for a single-report endpoint; `REPEATABLE READ` only when a read becomes
multi-statement.**
*Because* one statement is one snapshot at every isolation level, so `REPEATABLE READ` on a
single-call report buys nothing and holds the horizon for its duration (FINDINGS 9.1, 9.3).

**F3 · When a read does become multi-statement, `REPEATABLE READ` is required and the cursor is not a
substitute.**
*Because* two `balance_sheet_at` calls at the *same fixed cursor* returned 20 then 30 rows under
`READ COMMITTED` and 30 then 30 under `REPEATABLE READ` — **the snapshot covers exactly the gap the
cursor leaves**, which is B7's unpinnable branches (FINDINGS 9.2).

**F4 · Price the horizon a report holds, in the ADR's cost list.**
*Because* an 11-second `REPEATABLE READ` report held `report_cursor()` still for its whole duration,
so every report issued in that window is pinned behind it — measured directly (FINDINGS 9.3), and
demonstrated at scale by a third party in another database (FINDINGS 3.7). Read replicas do not fix
it: `pg_snapshot_xmin` is the cluster's.

## G · Cost, and what M5 should build first

**G1 · Refuse pagination.**
*Because* at a million entries the three reports return **2, 10 and 4 rows**: there is nothing to
page, and pagination would answer a cost question with an interface change (FINDINGS 5.1).

**G2 · State the timeout ceiling as an order of magnitude: the inception scan meets 30 s at
`10^6` entries, not `10^9`.**
*Because* measured (indicative, loadavg 2.32–4.22, another agent on the machine):
`balance_sheet_at` is 11.4 s at 1 M entries, so ~2–3 M meets 30 s;
`income_statement_for` ~7 M; `trial_balance_at` ~28 M (FINDINGS 5.1). Corroborated from outside the
harness: the daily sweep on this 1.11 M-entry book took **28,970 ms**, and survives only because
`reconcile` sets no `statement_timeout` on its own connection.

**G3 · The checkpoint wiring M5 already owns should start with `balance_sheet_at`, and with the
un-closed-earnings plug specifically.**
*Because* `balance_sheet_at` is ~11× `trial_balance_at` on the same book and is what
`recon_equation_breaks` calls per tenant, so wiring it pays twice; and the cost concentrates in the
plug, a correlated subquery whose plan takes **half a million index probes for one scope row** and
which is evaluated once per `(tenant, currency)` (FINDINGS 5.2). Confirmed catalog-wide that
`ledger_period_balances` is read by **no function** and by one view.

**G4 · Flag, and do not resolve here, that bounding the plug reopens ADR-0011 §A3.**
*Because* A3 chose the plug's shape precisely so its caption cannot move under a fixed cursor — it
reads no `ledger_period_closes` on purpose — and bounding it by the checkpoint is a change to that
reasoning rather than a free optimisation. It wants a measurement, not an ADR paragraph.

**G5 · Record the plan-cache trap, and refuse `plan_cache_mode = force_custom_plan`.**
*Because* the same `balance_sheet_at` call on the same data costs **11.0 s** on a connection's first
five executions (the custom plan), **4.2 s** from the sixth (the generic plan), and **2.7 s** with the
cursor as a literal — and `force_custom_plan` pins the slow one permanently (FINDINGS 5.2). A pooled
read path therefore has a warm-up: the sixth report on each connection is the first fast one. The
19× buffer gap between the inlined body and the function's custom plan is **unexplained** and is
recorded as such.

---

## What to refuse, gathered

| refused | because |
| --- | --- |
| sharing the writer's pool | A4 — a login that can write reads every tenant, and A6 — six headroom connections against 4–11 s reports |
| a session-scoped `SET` or `SET ROLE` anywhere on a pooled connection | A3 — measured to leak into the next request |
| `SET LOCAL app.tenant_id = <interpolated>` | A2 — the parameterised form exists; interpolating a caller's string does not need to |
| the one-statement `WITH set_config(…)` read | A5 — undocumented evaluation order under a tenant fence |
| passing a caller's cursor straight through | B4 — `-1` and `0` are legal `xid8` and the database cannot refuse them |
| letting the chart-version default resolve | B6 — it moves at run time |
| pagination | G1 — 2 to 10 rows at a million entries |
| `plan_cache_mode = force_custom_plan` | G5 — it pins the 11 s plan |
| a 404 for an unknown tenant | D2 — there is no tenant registry to consult |
| any listing, search or filter endpoint | Q6 — every one needs an ordering and a page key this spike did not design |
| exposing the reconciliation views or `close_disclosures` over HTTP | Q6 — cross-tenant views on an unauthenticated service (ADR-0017), and a disclosure with no feed |
| a cursor-minting endpoint | Q6 — every report already returns the cursor it used |
| promising that a stored cursor reproduces a report's **row set** | B7 — the amounts, yes; the rows, no, and the tables involved carry no `xact_id` |
