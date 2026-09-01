# 0011 — The close is an ordinary posting, and a report is its parameters

**Status:** accepted — its `xid8` cursor supersedes the as-of *mechanism* of [0006](/decisions/0006-time-and-as-of) (refuted by measurement in §1, not merely refined).
**Evidence:** [spike 012](/spikes/012-period-close)

## The decision

**A real ledger has to do two things that simply keeping a list of transactions does not give you for
free: close its books at the end of each period, and reproduce a statement it has already handed
out.** This decision settles both — and answers five smaller questions along the way. Neither is
complicated once it is said plainly.

**Closing the books.** At the end of each month or year, a business tallies up what it earned and
what it spent during that period, folds that result into its running total of lifetime profit, and
resets the period's earned-and-spent counters back to zero so the next period starts fresh. Without
that reset, "this year's profit" would keep secretly including every previous year as well — a figure
that is both wrong and grows without bound. We do this the plain way: as one ordinary transaction, the
same kind of balanced entry as any other. Nothing about it is special or privileged.

**Reproducing a statement already issued.** Once you have handed someone a financial statement dated
"as of June 30", it has to keep saying the exact same thing forever — even if some June paperwork only
reaches you in July. Timestamps cannot guarantee that: two things recorded seconds apart can be saved
to the database in the opposite order, so a clock does not reliably tell you which one came first. So
instead, each report remembers exactly which transactions already existed at the moment it was
produced. A piece of late paperwork gets added after that line, so it does not change the
already-finished report — it only shows up in the reports you produce from then on.

**Everything below is those two ideas made exact.** The thread through all of it: a report can be
reproduced only if it records where it stopped along *two* separate axes — the business dates it
covers, and the point in the database's own history it was run against — and **the only thing in this
schema that can mark that second point is the id of the transaction that wrote each row.** That single
fact answers five open questions at once:

| | |
| --- | --- |
| **The cursor is `xid8`, not a timestamp and not a sequence** | `ledger_entries`, `ledger_transactions` and `ledger_events` each carry `xact_id xid8 NOT NULL DEFAULT pg_current_xact_id()`. A report captures `pg_snapshot_xmin(pg_current_snapshot())` and filters `xact_id < :cursor`, forever |
| **The period close is an ordinary balanced transaction** | Posted by the writer through the posting primitive ([0005](/decisions/0005-event-log-and-write-path)) — one transaction, one posting per temporary account, destination `retained_earnings`. No trigger, no `UPDATE`, no privileged path |
| **The same close writes a checkpoint** | `ledger_period_balances` — every account's balance as at the period end, at the cursor the close pinned. Derived, rebuildable, off the write path |
| **Two of the three statements stop being views** | `balance_sheet` and `income_statement` become set-returning functions taking an effective range (or instant), a commit cursor and a chart version; `trial_balance` **stays a view** (the per-account gross substrate the reconciliation layer reads at "now"), with `trial_balance_at()` as its pinned form. A statement without a period is not a statement |
| **A period stores resolved instants; the zone is provenance** | `ledger_periods (starts_at, ends_at, tz)`, half-open, resolved once. The zone says *whose* business date it was; it never re-resolves the boundary |

The cursor is what ties them together. A checkpoint computed at cursor **C** is safe *because* an
entry backdated into that closed period after the fact arrives with a **higher** `xid8` and therefore
lands in the tail rather than invalidating the stored balance. **The restatement rule falls out of
the cursor instead of being bolted onto the close.**

---

## 1 · Why `xid8`, and why not the watermark [0006](/decisions/0006-time-and-as-of) proposed

[0006](/decisions/0006-time-and-as-of) reproduced the failure and specified a fix. The failure
reproduces; **the fix does not work**, and this ADR is partly a correction of that one.

The failure first, on the shipped schema, `spike_wsc`, 2026-08-27. One writer open, one report run
either side of its commit, the same literal instant `T` passed to the same query both times, nothing
backdated and nothing mutated:

| | revenue on the recorded axis | `balanced` | drift rows |
| --- | --- | --- | --- |
| while writer A is open | **110,000.00** | t | 0 |
| after A commits, same `T` | **160,000.00** | t | 0 |

45.5%, every check green. `recorded_at` is `now()`, which PostgreSQL documents as *"the start time of
the current transaction"* and adds that *"their values do not change during the transaction. This is
considered a feature."* It is — for [SQL:2011 conformance](https://sigmodrecord.org/publications/sigmodRecord/1209/pdfs/07.industry.kulkarni.pdf),
which *"leaves it up to SQL-implementations to pick an appropriate value for the transaction
timestamp … but it does require the transaction timestamp of a transaction to remain fixed during
the entire transaction."* Conformant and anomalous are the same property here.

**0006's proposed watermark is refuted by measurement.** It reads: each event records the
transaction that wrote it, and `W = min(seq) - 1` over events whose xid ≥ `pg_snapshot_xmin`. The
hole is that the minimum is taken over rows the reporter can *see*, and the row that will break the
report is the one it cannot. Isolated on its own table, driven through the interleaving that matters
— **A starts first and commits last, B starts later and commits sooner**, so A's transaction id is
*lower* than B's:

| candidate cursor | at issue, A open | after A commits | verdict |
| --- | --- | --- | --- |
| **[0006](/decisions/0006-time-and-as-of)'s `W = min(seq) - 1`** | 0 rows at or below `W` | **1 row** at or below `W` | a row appeared below a watermark already issued |
| **`max(xact_id) + 1`** | 130,000.00 | **180,000.00** | A's lower id sits under a cursor derived from B's |
| **`pg_snapshot_xmin`** | 110,000.00 | **110,000.00** | stable |

**`pg_snapshot_xmin` works for two reasons that must both hold, and both do.** Transaction ids are
handed out monotonically, so a row written after the cursor was captured can never carry an id below
it. And xmin is the lowest id still *running*, so everything below it is already decided — committed
or aborted, and an aborted row is invisible forever. Together: the set `xact_id < C` is fixed for all
time the moment `C` is read. `xid8` is the 64-bit epoch-extended form, so there is no wraparound to
handle, and it is a proper total order rather than a modular one.

This is what the temporal-database literature asks for and names the consequence of missing.
Transaction times must be *"consistent with the serialization order of the transactions"*
([Jensen, Clifford, Gadia, Segev, Snodgrass, 1992](https://sigmodrecord.org/publications/sigmodRecord/9209/pdfs/140979.140996.pdf)),
and when they are not, *"it can happen that the answer to the timeslice query never existed as a
current state"* — [Jensen & Lomet, VLDB 2001](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/temporaltime.pdf),
whose worked example is the table above with different names. Their fix is ours: *"It is easy to
avoid the above anomalies if a transaction T's timestamp can be established at the time at which T is
committing."* **The anomaly has no agreed name** — do not invent one for it.

**Everyone who got this right stores an identifier, not a clock.** MariaDB ships two system-versioning
modes and documents exactly why: with `TIMESTAMP` versioning *"a row might have been inserted in a
long transaction, and became visible hours after it was inserted"*, so transaction-precise history
means *"rows inserted before that point, but committed after will not be shown"* — and to do it
*"InnoDB needs to remember not timestamps, but transaction identifier per row."* XTDB gets it from a
**single-writer, totally-ordered durable log**, and still tells you to keep an opaque `SNAPSHOT_TOKEN`
rather than a wall-clock `SNAPSHOT_TIME`, because the timestamp form *"may return different results"*
on a lagging node. TigerBeetle's `timestamp` **is** a commit order — *"the TigerBeetle cluster assigns
all timestamps"*, *"totally ordered"*, asserted in the state machine as
`assert(timestamp > self.commit_timestamp)` — which is why an as-of read there is stable by
construction and needs no cursor at all.

**And the closest prior art has none of this.** Formance's whole point-in-time axis rests on
`transaction_date()`, which caches `statement_timestamp()` in a session temp table — *weaker* than
`now()`, since it is the first *statement*'s time — and is the `DEFAULT` for `moves.insertion_date`,
`moves.effective_date`, `transactions.timestamp` and `logs.date`. A repository-wide search at
`335bd03c08de46bae6895471702d9656958c64f5` for `pg_current_xact_id`, `txid_current`, `pg_snapshot`
and `xmin` returns **zero occurrences**. Their own `logs` sequence comment says it: *"we can still
have 'holes' on id since a sql transaction can be reverted after a usage of the sequence."*

### What the design adds, exactly

`xact_id` is **not** denormalised from the transaction under a composite foreign key, unlike
`effective_at` and `currency`. That is deliberate and it is the case that proves it. A leg appended
to an already-committed transaction — the seal hole the schema admits to, reachable with nothing but
the app role's `INSERT` grant — gets its *own*, higher `xid8`. Under a foreign key it would inherit
the old transaction's id and **rewrite an issued report**. Measured on a February book:

| | issued at cursor C | re-issued at the same C | the parameterless view |
| --- | --- | --- | --- |
| after a backdated clearing **and** a rogue appended pair | 500.00 | **500.00** | **1,166.00** |

500.00 → 1,166.00 is the number the schema's own comment records for the seal hole. **The cursor does
not close it — it makes an issued statement immune to it**, which is a different and cheaper thing.

`ix_entries__asof_recorded` becomes `ix_entries__asof_commit (tenant_id, account_id, xact_id)`. The
old index keyed `recorded_at DESC` — an index on the column this ADR just proved cannot order
commits, serving a question that cannot be answered correctly. The replacement serves two: the
recorded-axis read, now reproducible, and the checkpoint's backdated-arrivals term below.

---

## 2 · The close: an ordinary transaction, and a table that says which one

**Nothing about a close is privileged.** It is one `ledger_events` row with a deterministic
idempotency key (`tenant:close:period:currency`, so `uq_events__idempotency` refuses the second
attempt), one `ledger_transactions` row of `kind = 'period_close'`, and one posting per temporary
account with `retained_earnings` as the destination — so no leg is constructible on its own, exactly
as [0005](/decisions/0005-event-log-and-write-path) requires. Its `effective_at` is
`ends_at - interval '1 microsecond'`: the last *representable* instant inside a half-open period,
which `timestamptz`'s microsecond resolution makes exact rather than a "23:59:59" approximation.

**What closes is revenue and expense, per tenant per currency, into `retained_earnings`.** On a
three-year book — 20,000.00 / 25,000.00 / 6,000.00 of revenue against 5,000.00 / 10,000.00 /
2,000.00 of expense — closing 2024 and 2025:

| balance sheet at 2026-12-31 | before any close | after |
| --- | --- | --- |
| Cash and cash equivalents | 134,000.00 | 134,000.00 |
| Shareholders equity | 100,000.00 | 100,000.00 |
| Retained earnings | *absent — the account exists and is zero* | **30,000.00** |
| Undistributed earnings (since inception) | **34,000.00** | **4,000.00** |

34,000.00 against a true current year of 4,000.00 is the register's number, and it is now on the
right line. The earnings plug carries **one constant caption** — *"Undistributed earnings (since
inception)"* — in both columns (A3): it is the net of **all** temporary accounts at the cursor,
closing entries included, so before any close it is the whole since-inception earnings (34,000.00) and
after closing 2024–2025 it is exactly what is not yet closed (4,000.00), with `retained_earnings`
carrying the 30,000.00 that was. A caption that changed with whether a close had happened would move
under a fixed cursor, which is itself a reproducibility break; it does not.
The post-closing trial balance is the accountants' one: `operating_cash` 130,000.00,
`paid_in_capital` −100,000.00, `retained_earnings` −30,000.00, and every temporary account **exactly
0.00**.

**No Income Summary account.** The classic form is four entries — revenue to Income Summary, expenses
to Income Summary, Income Summary to Retained Earnings, dividends to Retained Earnings
([OpenStax, *Principles of Accounting* §5.1](https://openstax.org/books/principles-financial-accounting/pages/5-1-describe-and-prepare-closing-entries-for-a-business)).
The middle account is a manual-bookkeeping checksum, and the practitioner literature says so:
*"Since the income summary account is only a transitional account, it is also acceptable to close
directly to the retained earnings account and bypass the income summary account entirely"*
([AccountingTools](https://www.accountingtools.com/articles/closing-entries-closing-procedure)); OpenStax
itself concedes *"no matter which way you choose to close, the same final balance is in retained
earnings."* Our checksum is that the transaction is balanced by construction.

**Every system that puts the close in the journal then has to teach its reports to ignore it, and
they pick three different mechanisms** — a tag (hledger's `clopen:`), a flag column (ERPNext's
`is_period_closing_voucher_entry`), an account type (Odoo's `equity_unaffected`). GnuCash has none of
the three and publishes the consequence on the same page as the feature: *"closing the books reduces
the usefulness of the standard reports because the reports don't currently understand closing
transactions."* **We use a key.** `ledger_period_closes (tenant_id, period_code, currency)` names the
closing transaction, so `income_statement` excludes it with `NOT EXISTS` against a primary key rather
than by matching a free-text `kind`. Verified: with the 2025 close sitting inside 2025, the 2025
income statement still reports 25,000.00 / 10,000.00 / 15,000.00.

**And the close is a bookkeeping convention, not a standards requirement — say so.** IAS 1 requires
comparatives (¶38: *"an entity shall present comparative information in respect of the preceding
period for all amounts reported in the current period's financial statements"*), two of everything
(¶38A), reclassification of comparatives when presentation changes (¶41), and at least annual
reporting (¶36). It does **not** require a closing entry. Searched exhaustively over the operative
text, the terms *closing entry*, *income summary*, *trial balance*, *journal*, *ledger*, *nominal
account*, *temporary account* and *debit* occur **zero times**; *retained earnings* occurs three
times, and at ¶108 it is prefixed *"for example"*. The mandated line at ¶54(r) is *"issued capital and
reserves attributable to owners of the parent"*. **That is exhaustive for IAS 1 and not for IFRS as a
whole**, and IFRS 18 replaces IAS 1 for periods beginning on or after 1 January 2027 — its operative
text has not been read here.

So the close is ours to design, and two shapes are defensible: post the entries (hledger, GnuCash,
Odoo, TigerBeetle's own close-account recipe), or compute them at report time (QuickBooks, per
Lumen — *"when you run a report, the software treats the accounts as if they were closed at the end
of all the prior periods"*). **We post them, because a ledger whose `retained_earnings` account never
receives an entry cannot show a lender a statement of changes in equity, and because a computed close
is a second definition of a balance — the thing [spike 009](/spikes/009-where-the-balance-lives)
deleted a column to avoid.**

---

## 3 · The checkpoint: what it buys and why it is not `balance_after` again

`ledger_period_balances` holds one row per account per closed period: the account's cumulative
balance at the period end, computed from entries with `xact_id < C`. It is the **at-close** position,
closing entries included, so a temporary account's checkpoint row is exactly 0 and
`retained_earnings` carries the swept earnings.

*(**A4's mechanism is replaced, 2026-09-01 — [0020](/decisions/0020-checkpoint-on-the-report-path).**
This sentence read that the at-close position follows from holding `computed_at_xid` "at or above the
closing transaction's own `xact_id`", enforced by `recon_close_breaks`. **That is unsatisfiable in one
transaction rather than merely unbuilt**, proven across three candidate cursor values by two horizon
states: `pg_current_xact_id()` gives equality, which holds only on an idle cluster — with one other
writer open, `recon_close_breaks` fires `cursor_precedes_close` on a **correct** close — while
`report_cursor()` sits below the close's own xid and silently loses a real posting, 10,570 read as
10,500. `xid8` has no successor operator, so there is no third value to reach for. The at-close
position is obtained instead by admitting the close **by transaction identity**, which holds under
both horizon states. Until that migration lands, the shipped checkpoint is the **pre-close**
position.)*

As-of then reads **checkpoint + two tails**:

- entries effective **after** the close boundary and at or before the as-of instant, and
- entries effective **before** it whose `xact_id` is at or above the close's cursor — the backdated
  arrivals, which is why `ix_entries__asof_commit` exists. Confirmed by plan: `Index Scan using
  ix_entries__asof_commit`, `Index Cond: … xact_id >= … AND xact_id < pg_snapshot_xmin(…)`.

400,000 entries on one account over three years, twelve quarterly periods closed, PostgreSQL 18.6,
localhost, median of 7. **The ratio is the finding, not the number.**

| as of | entries in range | aggregate over all history | checkpoint + tail |
| --- | --- | --- | --- |
| 2023-04-01 | 43,200 | 5.18 ms | 0.71 ms |
| 2024-01-01 *(on a close boundary)* | 175,200 | 27.22 ms | **0.67 ms** |
| 2024-02-15 *(mid-period)* | 196,800 | 26.92 ms | **3.48 ms** |
| 2025-01-01 *(on a close boundary)* | 350,880 | 30.18 ms | **0.67 ms** |
| 2025-02-15 *(mid-period)* | 372,480 | 30.91 ms | **3.31 ms** |
| 2025-10-01 | 400,000 | 32.06 ms | 0.66 ms |

Three runs of the same file moved the 43,200-row figure between 4.75 and 5.44 ms and left every
ratio intact, which is the project's usual result and the reason the ratios are what is claimed.

Both mid-period rows are in the table on purpose: **a line drawn only through the close boundaries
would be a flattering one.** The honest claim is not that as-of becomes constant, it is that its cost
stops depending on the age of the book and starts depending on the length of one period — **45–49×
at a close boundary, 8–9× mid-period**, and neither ratio shrinks as history grows. The two forms agree to the
minor unit at every point, including after a posting **backdated into an already-closed period**
(both −35,211,400).

**This benefit is real and, on the shipped baseline, not yet realized.** The measurement above is of a
query that *reads the checkpoint*; the statement functions this ADR ships do **not** — `balance_sheet_at`,
`income_statement_for` and `trial_balance_at` never reference `ledger_period_balances` (proven from
`pg_get_functiondef`), and the checkpoint's only reader is `recon_checkpoint_breaks`.

*(**"so they aggregate `ledger_entries` from inception" is withdrawn as stated, 2026-09-01** —
[0020](/decisions/0020-checkpoint-on-the-report-path). It is true of `balance_sheet_at` **alone**:
`trial_balance_at` and `income_statement_for` each carry `effective_at >= p_from`, so a caller asking
for one month scans one month. `balance_sheet_at` has no lower bound by nature — a position is
cumulative — and it is the one the sweep calls at `'infinity'` per tenant, so it is the whole of the
milestone. The flow statement is refused the checkpoint structurally: the accounts it reports are
exactly the ones a close zeroes.)*

Wiring the read benefit into the report path — plus partitioning
the checkpoint by period — is roadmap **M5** work, re-measured at scale in [spike 020](/spikes/016-close-cost-at-scale)
(this site's spike 016; the spike directories carry their own numbering)
(the read benefit reproduces at ~40–230× at a close boundary on a million-entry book).

The checkpoint costs **24 rows and 32 kB against 800,024 entries and 253 MB**.

**Why this is not the column [spike 009](/spikes/009-where-the-balance-lives) deleted.**
`balance_after` was a running balance per *entry*, on the *recorded* axis, written on the *write*
path, computed by the writer from the same locked row it was supposed to check. This is one row per
account per *period*, on the *effective* axis — the axis every as-of question is actually asked on —
written by a batch job, and exactly recomputable from the journal at a stated cursor, which makes
reconciling it a real check rather than a tautology. Fragment reached the same shape from the other
end, keeping balance deltas per {year, month, day, hour} bucket for *"a fixed write cost, regardless
of the timestamp the Ledger Entry is posted to"*. ERPNext keeps both a `GL Entry` stream and an
`Account Closing Balance` snapshot and **tests that they agree**; so should we.

---

## 4 · The statements take parameters, which means they stop being views

**A view takes no parameter, and a documented `WHERE` contract cannot substitute for one on an
aggregating view.** `SELECT * FROM income_statement WHERE effective_at < '2026-03-01'` fails with
`column "effective_at" does not exist`, and it always will: the view's output is
`tenant_id, currency, fs_line, caption, sort_order, amount_minor, side`. A predicate written outside
an aggregate applies **after** the `GROUP BY`, so there is nowhere for a date bound to bind. That is
structural, not an omission.

So `trial_balance_at` becomes a `LANGUAGE sql STABLE` set-returning function, and the two *statements*
become `LANGUAGE plpgsql STABLE` functions — plpgsql because each must **`RAISE`** on an unknown chart
version and on an in-scope account with posted entries that the chosen version does not present (A13,
A14), which a bare `sql` body cannot do. Each statement takes a chart version as its final parameter
(defaulting to current) and returns that version plus the pinned cursor as columns, so a reader can
tell a fresh report from one pinned behind a stale horizon:

| | signature | returns |
| --- | --- | --- |
| `trial_balance_at` | `(tenant, effective_from, effective_to, cursor)` | per-account gross (`sql`, inlined) |
| `income_statement_for` | `(tenant, effective_from, effective_to, cursor, chart_version = current)` — a **flow**, so a half-open range | `…, chart_version, …, side, pinned_cursor` |
| `balance_sheet_at` | `(tenant, as_of, cursor, chart_version = current)` — a **position**, so one instant | `…, chart_version, …, side, pinned_cursor` |

Their bodies are the baseline views' bodies plus two predicates
(`effective_at >= :from AND effective_at < :to`, `xact_id < :cursor`). The chart-outward `CROSS JOIN
fs_lines`, the currency in every join, and the `sort_order` ordering are copied verbatim, so
[0007](/decisions/0007-schema-conventions-and-chart)'s completeness property is unchanged in the half
that was ever true. **PostgreSQL inlines a simple SQL-language set-returning function** — which is why
`trial_balance_at` still plans as a nested loop over an index scan on `ledger_entries` rather than a
`Function Scan`; the two statement functions trade that inlining for the ability to fail loudly on a
bad chart version, and their inner query plans the same nested loop.

**The parameterless views are dropped rather than kept alongside.** Keeping them would leave the
wrong number reachable by the shortest query, which is the state the register already complains
about. An issued statement is then identified by its parameters — the effective range and the cursor
— and those are what get stored beside it.

---

## 5 · The zone lives on the period, and what is stored is the instant

**A period boundary is resolved once, from a local date in a named zone, and only the resolved
instants are stored.** `ledger_periods (tenant_id, code, starts_at, ends_at, tz)`, half-open. The
report call takes instants and never a zone. Three measurements say why:

| | |
| --- | --- |
| **A local midnight is not always a real instant** | Brazil's DST transitions took effect at 00:00 local, so `2018-11-04 00:00` in `America/Sao_Paulo` never happened. PostgreSQL resolves it silently to an instant that renders back as **01:00** — no error, a period an hour short |
| **The same local date resolves differently after a tzdata update** | `2019-02-16 00:00` and `2020-02-16 00:00` in the same zone resolve **an hour apart**, because Brazil abolished DST by decree between them. A stored (local date, zone) pair is a promise to re-run a lookup against whatever tzdata is installed on the day someone re-reads the report |
| **Whose zone it is moves money between statements** | One posting effective `2026-03-01 02:00+00` is **420.00** of February revenue with the period resolved in `America/New_York` and **0.00** in `UTC`, `Asia/Kathmandu` or `Australia/Lord_Howe` |

**Not per tenant**, because there is no tenant registry to hang it on — `tenant_id` is a bare `text`
column on every table and nothing declares a tenant. **Not per report call**, because two callers
naming "February" would then disagree about what February is, and the disagreement would not be
visible in either report. The period row is the one place that already has to exist.

The zone is `text` and **is** constrainable declaratively: `timezone(text, timestamptz)` is marked
`IMMUTABLE` (`pg_proc.provolatile = 'i'`, verified), an unrecognised name *raises* rather than
returning `NULL`, so `ck_periods__tz_known` refuses `Middle/Earth` with `time zone "Middle/Earth" not
recognized`. That PostgreSQL believes this function immutable while the IANA database is legislation
is not a bug to route around — **it is the argument for storing the resolved instant.**

And half-open, not `BETWEEN`: `effective_at <= '2026-02-28 23:59:59'` drops an entry effective at
`2026-02-28 23:59:59.999999`, measured, two rows to zero.

---

## The DDL

**Applied** — folded into `migrations/00001_baseline.sql` on 2026-08-27 under
[0003](/decisions/0003-migrations)'s editable-until-v0.1 exception, after being proven as an
overlay in [spike 012](/spikes/012-period-close). Several integration-time deviations from the text
below, each deliberate. **`trial_balance` stays a view** (it is the reconciliation substrate
[0010](/decisions/0010-reconciliation)'s views read, per-account gross arithmetic at "now", with
`security_invoker` so a scoped reader is scoped through it too) while `trial_balance_at()` is the
pinned form and the two *statements* exist only as functions. **The statement functions are
`plpgsql`, take a chart version as their final parameter** (defaulting to current) and return the
version and pinned cursor as columns — [0012](/decisions/0012-chart-governance)'s coordination note
asked for the cursor and the chart version in one signature, and they `RAISE` on an unknown version or
an unpresented account rather than fabricating a statement (A13, A14). **The earnings plug is the net
of all temporary accounts at the cursor, closing entries included** — the `max(ends_at)` watermark the
overlay carried is gone, the caption is constant, and `balance_sheet_at` is **half-open**
(`effective_at < as_of`) to match the period model (A3). **`ledger_period_closes` is typed**:
`uq_txn__id_kind` + a generated `closing_kind` + `fk_closes__txn_kind` force the named transaction to be
a `period_close`, `fk_closes__txn_effective` + `ck_closes__txn_in_period` force it to fall inside the
period, and `recon_close_breaks` refuses a `computed_at_xid` below the close's own `xact_id` (A4). And
**several reconciliation views this ADR recommended and did not write now exist** —
`recon_checkpoint_breaks`, `recon_close_breaks`, `recon_cursor_breaks`, `recon_equation_breaks` and
`close_disclosures`, documented in [0010](/decisions/0010-reconciliation). The merged whole was
re-verified end to end: close, constant-caption plug, checkpoint recomputation clean, the accounting
equation and cursor checks zero on a clean book, and an issued statement byte-identical across a
**backdated ordinary posting** — the close-plug interaction that an earlier watermark form got wrong
(recording a close rewrote already-issued balance sheets at a fixed cursor) is what A3 corrects, so a
recorded close no longer moves an issued statement either.

```sql
-- 1. the cursor
ALTER TABLE ledger_transactions
    ALTER COLUMN xact_id DROP DEFAULT,
    ALTER COLUMN xact_id TYPE xid8 USING (xact_id::text::xid8),
    ALTER COLUMN xact_id SET DEFAULT pg_current_xact_id();
ALTER TABLE ledger_entries ADD COLUMN xact_id xid8 NOT NULL DEFAULT pg_current_xact_id();
ALTER TABLE ledger_events  ADD COLUMN xact_id xid8 NOT NULL DEFAULT pg_current_xact_id();

DROP INDEX ix_entries__effective;
CREATE INDEX ix_entries__effective
    ON ledger_entries (tenant_id, account_id, effective_at, xact_id);
DROP INDEX ix_entries__asof_recorded;
CREATE INDEX ix_entries__asof_commit
    ON ledger_entries (tenant_id, account_id, xact_id);

-- 2. periods. btree_gist is TRUSTED on PostgreSQL 13+, so a database owner installs it
-- without superuser -- verified on 18.6. It is the only dependency this ADR adds.
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE ledger_periods (
    tenant_id  text NOT NULL,
    code       text NOT NULL,
    starts_at  timestamptz NOT NULL,
    ends_at    timestamptz NOT NULL,
    tz         text NOT NULL,
    CONSTRAINT pk_periods PRIMARY KEY (tenant_id, code),
    CONSTRAINT ck_periods__non_empty CHECK (ends_at > starts_at),
    CONSTRAINT ck_periods__tz_known
        CHECK ((timestamp '2000-01-01 00:00' AT TIME ZONE tz) IS NOT NULL),
    CONSTRAINT uq_periods__bounds UNIQUE (tenant_id, code, starts_at, ends_at),
    CONSTRAINT ex_periods__no_overlap EXCLUDE USING gist (
        tenant_id WITH =, tstzrange(starts_at, ends_at, '[)') WITH &&)
);

-- 3. the close
CREATE TABLE ledger_period_closes (
    tenant_id       text NOT NULL,
    period_code     text NOT NULL,
    currency        char(3) NOT NULL,
    starts_at       timestamptz NOT NULL,
    ends_at         timestamptz NOT NULL,
    transaction_id  uuid NOT NULL,
    computed_at_xid xid8 NOT NULL,
    closed_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_closes PRIMARY KEY (tenant_id, period_code, currency),
    CONSTRAINT ck_closes__currency_iso CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT fk_closes__period FOREIGN KEY (tenant_id, period_code, starts_at, ends_at)
        REFERENCES ledger_periods (tenant_id, code, starts_at, ends_at),
    CONSTRAINT fk_closes__txn FOREIGN KEY (tenant_id, transaction_id)
        REFERENCES ledger_transactions (tenant_id, id),
    CONSTRAINT uq_closes__txn UNIQUE (tenant_id, transaction_id)
);

-- 4. the checkpoint
CREATE TABLE ledger_period_balances (
    tenant_id   text NOT NULL,
    period_code text NOT NULL,
    currency    char(3) NOT NULL,
    account_id  uuid NOT NULL,
    input       bigint NOT NULL,
    output      bigint NOT NULL,
    CONSTRAINT pk_period_balances PRIMARY KEY (tenant_id, period_code, currency, account_id),
    CONSTRAINT ck_period_balances__non_negative CHECK (input >= 0 AND output >= 0),
    CONSTRAINT fk_period_balances__close FOREIGN KEY (tenant_id, period_code, currency)
        REFERENCES ledger_period_closes (tenant_id, period_code, currency),
    CONSTRAINT fk_period_balances__account FOREIGN KEY (tenant_id, account_id, currency)
        REFERENCES ledger_accounts (tenant_id, id, currency)
);

GRANT SELECT, INSERT ON ledger_periods, ledger_period_closes, ledger_period_balances
    TO openledger_app;
```

**No trigger.** Every guard above is a key, a `CHECK` or an exclusion constraint, and the close is a
posting the writer makes like any other. The default remains none ([0004](/decisions/0004-where-logic-lives)).

## What we considered

| | Why not |
| --- | --- |
| **[0006](/decisions/0006-time-and-as-of)'s gapless sequence watermark** | Refuted by measurement, above: the minimum is taken over rows the reporter can see, and the row that breaks the report is the one it cannot. A writer that took a lower sequence value and has not committed sits below the watermark and appears later. |
| **`max(seq)` or `max(xact_id)` as the cursor** | Same interleaving, same failure: 130,000.00 → 180,000.00. Values are handed out at insert time and commit out of order. |
| **A commit timestamp column, written by the writer at commit** | There is no such moment inside a PostgreSQL transaction — `COMMIT` is where the row is already frozen. `track_commit_timestamp` exists and gives per-xid commit times, but it is a GUC an operator can turn off, its data ages out with the transaction id, and it does not survive a logical restore either. `xid8` at least tells you honestly when it is meaningless. |
| **Serialize all writes behind one commit-ordered lock**, so a sequence *is* commit order | Trivially correct and measured expensive: [spike 003](/spikes/003-throughput-ceiling)'s single-contended-row case, and the lock is **global**, so every lever [0002](/decisions/0002-scaling) rests on is defeated. It is also what XTDB does — a single-writer totally-ordered log — and the reason they can afford it is that they are not trying to hold 800 clearings a second on one Postgres. |
| **A `periods` table with stored closing balances and no closing entries** | The roadmap's middle option. It fixes the *cost* and leaves the *number* wrong: `retained_earnings` still never receives an entry, so there is no statement of changes in equity and the balance sheet's equity section is still a derived plug. It also gives one balance two definitions, which is [spike 009](/spikes/009-where-the-balance-lives)'s finding. |
| **Closing entries and no checkpoint** | Fixes the number and leaves the cost. The close already computes exactly the balances the checkpoint stores; writing them is one `INSERT … SELECT` in a transaction that is running anyway. |
| **Compute the close at report time**, as QuickBooks does | Cheap, and it means the ledger never records the close. A reader with SQL access sees a different equity section from a reader using the reports, and nothing in the journal says a period was ever closed. |
| **An Income Summary clearing account** | A manual-bookkeeping checksum; the practitioner sources call bypassing it acceptable and the software-shaped ones say it is already bypassed. Our checksum is that the posting balances by construction. |
| **A period *lock* refusing postings into a closed period** | The obvious ERP answer, and it contradicts append-only in the one direction that matters: a late clearing carrying a closed period's business date is *normal*, and refusing it means the money exists nowhere. The cursor makes the entry harmless to already-issued reports without refusing it. A lock may still be wanted later as a *policy*; it is not needed for correctness and is not part of this decision. |
| **Keep the parameterless views alongside the functions** | Leaves the wrong number reachable by the shortest query. |
| **Document a `WHERE` contract per view instead of parameters** | Structurally impossible on an aggregating view: the predicate lands after the `GROUP BY` and the column is not in the output. Demonstrated. |
| **A timezone per tenant** | There is no tenant registry to put it on — nothing in the schema declares a tenant. It would have to be invented for this, and a zone is a property of a *reporting period*, not of a tenant: the same tenant can and does report a US statutory period and an internal management period. |
| **A timezone per report call** | Two callers naming "February" disagree, invisibly, and the disagreement is not recorded in either report. |
| **Store (local date, zone) and resolve at read time** | Measured: the same local date in the same zone resolves an hour apart across a tzdata update, so an issued statement silently restates itself when the server is patched. |

## What it costs

| | |
| --- | --- |
| **The cursor lags the newest commits, and the lag is the longest open transaction** | Measured directly: at the instant the report was issued, the `pg_snapshot_xmin` cursor excluded a transaction that had *already committed*, because an older one was still running. The report was 110,000.00 when the truth was 130,000.00. That is the price of reproducibility and it is not small. **It bit this ADR's own measurements**: one run of the checkpoint file lost a posting it had just committed, because a different workstream's benchmark held a transaction open on the same server — the horizon is per *cluster*, not per database. On RDS the holders are not only our writers: `pg_dump`, an idle-in-transaction session, a logical replication slot, `hot_standby_feedback` from a replica and any prepared transaction all hold xmin back. **A batched posting run open for minutes pins every report behind it.** |
| **A close cannot complete while xmin is pinned below it** | The close captures its cursor from the same horizon, so a long-running transaction delays the *close*, not just reports. It is a batch job and can retry; it is still an operational coupling between an unrelated `pg_dump` and month-end. |
| **`xid8` does not survive a logical restore, and the ADR must say so out loud** | `pg_dump` / `pg_restore` re-inserts every row under new transaction ids, so **every stored cursor becomes meaningless against the restored database** and every issued report becomes unreproducible there. A physical replica or PITR restore preserves them; a logical one does not. Nothing about `xid8` announces this — the column will look fine and answer wrongly. If reproducibility must survive logical restore, the cursor has to be exported and re-mapped alongside the rows, and that machinery is not designed here. |
| **A checkpoint is a second copy of a balance, and it is now reconciled** | Exactly recomputable at a stated cursor, which is what makes it checkable — and `recon_checkpoint_breaks` now does check it, recomputing each stored row at its own `computed_at_xid` and comparing values (not mere presence, so a dormant 0/0 row is not a false break). It rides the same daily sweep as `ledger_account_balances` versus the journal — but that sweep is **O(entries × closes)** (it re-aggregates the whole prefix per close: 1 : 3.2 : 5.8 : 8.2 over 3/6/9/12 closes, [spike 020](/spikes/016-close-cost-at-scale)), so bounding the per-close prefix scan is M5 work too. ERPNext tests its equivalent; now so do we. |
| **Twelve quarterly closes on one tenant wrote 24 checkpoint rows** — for one account | Per account per period per currency. On a million-account book with monthly closes that is twelve million rows a year, which is the trade: a bounded write against an unbounded read. It wants partitioning by period before it wants anything else, and that is not designed here. |
| **Two statements stop being views, and an integrator's `SELECT * FROM balance_sheet` breaks** | That is intended — the query it breaks returns a since-inception number — but it is a breaking change to the one interface an adopter can reach without writing Rust. `trial_balance` and `trial_balance_at()` still carry the `SELECT`/read grants; the two statement functions are reached by `EXECUTE`, which for a freshly-created function is granted to `PUBLIC` by default, so nothing had to be *moved* — the baseline adds no explicit `EXECUTE` grant (`proacl` is the default), and the surface an adopter loses is the two views, not `trial_balance`. |
| **The tenant parameter is exactly the parameter [0007](/decisions/0007-schema-conventions-and-chart) says should not exist** | *"reports enumerate from the chart outward, so there is no parameter in which to pass an incomplete account list."* The line enumeration is unchanged — the `CROSS JOIN fs_lines` is verbatim — but the *scope* is now named by the caller rather than discovered from `ledger_accounts`. The baseline's own comment already admitted completeness is *"guaranteed WITHIN a scope, not across them"*; this makes the admission structural. |
| **The close is measured at scale, and the WRITE dominates — not the aggregation** | [Spike 020](/spikes/016-close-cost-at-scale): closing **1,000,000 accounts in one currency took ~49 s** and wrote **1,000,003 checkpoint rows / 135 MB**. The cost is **linear in account count and additive per currency** (three currencies is three closes), and the ~49 s is **~96% checkpoint *write*** — one row per account plus PK/FK maintenance — against **~4% aggregation** (the `INSERT … SELECT`'s own scan is ~2 s). The earlier framing of the cost as the SELECT was wrong; it is the write. It wants partitioning of `ledger_period_balances` by period before anything else, which is not designed here (M5). |
| **`ex_periods__no_overlap` adds an extension dependency** | `btree_gist`. Trusted on PostgreSQL 13+, so no superuser is needed — but it is the first non-core dependency in the tree, and a deployment that cannot install extensions cannot have the constraint. |
| **Backdating into a closed period is *permitted*, and it is now disclosed** | The arithmetic is right and the reports restate correctly at a new cursor. The notification that was missing now exists: `close_disclosures` enumerates exactly "entries whose `effective_at` precedes a close and whose `xact_id` exceeds it" — the analogue of IAS 1.41's reclassification disclosure (*this period's figures changed after it was issued*), one index scan over `ix_entries__asof_commit`. What is still not built is the *feed* that surfaces the disclosure to whoever issued the report. |
| **Multi-currency close is per currency and the closing rate lives nowhere** | Consistent with [0005](/decisions/0005-event-log-and-write-path)'s open cost on cross-currency, and it means a consolidated statement across currencies is still not expressible. |
| **This ADR corrects an `accepted` one** | [0006](/decisions/0006-time-and-as-of)'s as-of mechanism is refuted here by measurement, not merely refined. That edit has landed: 0006's section now reads *"The as-of cursor is decided, and 0011 replaced the mechanism"*, its status line records the supersession, and its recorded-axis read points at the `xid8` cursor — so the decision log no longer describes two incompatible cursors. |
