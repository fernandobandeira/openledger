# Spike 012 — What does an "as of" have to name before a statement can be re-issued?

**Status:** closed. Produced [ADR-0011](/decisions/0011-period-close-and-report-axes), and **refutes
the as-of mechanism [ADR-0006](/decisions/0006-time-and-as-of) specified** — the failure 0006 measured
is real, the watermark it proposed to fix it is not.

**Question.** Five entries in the decision log are the same question wearing different clothes. The
as-of cursor is unbuilt and `recorded_at` cannot order commits. The balance sheet has no period, so
its earnings plug sums all history — 34,000.00 against a true current year of 4,000.00 — and
`retained_earnings` ships and stays zero. Historical balances get slower as history grows. No report
accepts either time axis, so an issued statement cannot be reproduced after any backdated posting.
And a period boundary is a business-date boundary in *someone's* zone, and nothing says whose.
**What is the smallest set of columns and tables that closes all five, and does it survive contact
with a concurrent writer?**

**Ran** 2026-08-27 · PostgreSQL 18.6 · `spike_wsc`, rebuilt from `migrations/00001_baseline.sql`,
`schema/chart.sql` and the proposed DDL for every step. Everything below reproduces from
`spikes/014-period-close/` — `./run.sh` for all of it, `./run.sh 05` for one step. Prior art read
from source at pinned commits, or from the standard-setter's own PDF, and each is labelled which.
> **Note on reproducing this spike.** Its runs predate the 2026-08-27 integration that folded the
> proposed DDL of ADRs 0009–0013 into `migrations/00001_baseline.sql`
> ([0003](/decisions/0003-migrations)'s editable-until-v0.1 exception), so the overlay files in this
> spike's directory target the *pre-merge* baseline — recover it from git history to re-run them
> verbatim. The merged baseline was re-verified end to end at integration time.

---

## The answer

**One column: `xact_id xid8` on every journal row, and a cursor of
`pg_snapshot_xmin(pg_current_snapshot())`.** Everything else falls out of it.

A report pins `xact_id < :cursor` and re-runs identically forever, because transaction ids are handed
out monotonically (nothing written later can carry a lower one) and xmin is the horizon below which
every transaction is *decided* (nothing below it can still appear). A period close pinned at the same
kind of cursor can store period-end balances that **a backdated entry cannot invalidate**, because
the late arrival carries a higher id and lands in a tail term. **The restatement rule is not designed;
it is what the cursor already does.**

The five rows close like this:

| the open row | what closes it |
| --- | --- |
| the as-of cursor is unbuilt | `xact_id xid8` + `pg_snapshot_xmin`. §2, §3 |
| the balance sheet has no period | the close as an ordinary posting; `retained_earnings` receives entries. §4 |
| historical balances get slower | the same close writes `ledger_period_balances`; **45–49× at a close boundary, 8–9× mid-period**, and neither ratio decays with history. §5 |
| no report takes either axis | the three statements become functions of (effective range, cursor). A view *cannot* take a parameter and a `WHERE` contract cannot reach inside an aggregate. §6 |
| statement periods have a timezone | `ledger_periods` stores **resolved instants**; the zone is provenance, because a local date is not a stable instant. §7 |

---

# The evidence

## 1 · The setup

`spike_wsc` is the shipped baseline plus `spikes/014-period-close/00_overlay.sql` — the ADR's proposed
DDL, applied nowhere else — plus `01_book.sql`, which is a posting helper that does what the Rust
writer is specified to do (one event, one transaction, two entries, `account_seq` issued under the
lock the balance-row upsert already takes) and the three statements re-expressed as parameterised
functions. Nothing in either file is proposed as product; ADR-0004 is explicit that a ledger does not
post from PL/pgSQL, and the helper exists so the numbers below are reproducible.

The concurrency in steps 02, 03 and 06 is **driven, not slept for**. The second session reads from a
FIFO, and the driver blocks until it can *see* that session holding a transaction id in
`pg_stat_activity` before it issues anything. A spike whose result depends on a `sleep` landing right
is not evidence.

## 2 · ADR-0006's failure, reproduced

`02_cursor_instability.sh`. One writer open, one report either side of its commit, the same literal
instant `T` passed to the same query both times.

```
-- committed history: 110,000.00 of fee revenue
-- writer A is open (asserted, not slept for). Report instant T = 2026-08-27 16:08:21.132395+00
-- FIRST RUN, while A is still open:
 revenue_as_recorded |  balanced | drift_rows
---------------------+-----------+------------
 110,000.00          |  t        |          0
-- A committed. SECOND RUN. Same T, same query, nothing backdated:
 revenue_as_recorded |  balanced | drift_rows
---------------------+-----------+------------
 160,000.00          |  t        |          0
```

**45.5%, both checks green both times.** The mechanism, printed by the same script: both transactions
wrote a `recorded_at` *earlier* than `T`, so both were always in range — one of them simply was not
visible yet.

```
   recorded_at   | txn_recorded_at | in_range_of_t | xact_id
-----------------+-----------------+---------------+---------
 16:08:21.089365 | 16:08:21.089365 | t             |  491193
 16:08:21.108532 | 16:08:21.108532 | t             |  491194
```

`recorded_at` is `now()`. PostgreSQL: *"These SQL-standard functions all return values based on the
start time of the current transaction"*, and *"their values do not change during the transaction.
This is considered a feature."* It is a feature — of SQL:2011 conformance, which *"leaves it up to
SQL-implementations to pick an appropriate value for the transaction timestamp … but it does require
the transaction timestamp of a transaction to remain fixed during the entire transaction"*
(Kulkarni & Michels, *Temporal features in SQL:2011*, SIGMOD Record 41(3) p.39 n.3). Conformant and
unusable as a commit order are the same property.

## 3 · Three candidate cursors, one interleaving

`03_cursor_stable.sh`. **A starts first and commits last; B starts later and commits sooner.** A's
transaction id is therefore *lower* than B's, which is what breaks every "highest thing I can see"
scheme. B posts to different accounts than A — on the same accounts it does not interleave at all,
it blocks on A's balance-row lock, which is the write path working as designed.

```
-- committed before either writer starts: 110,000.00 of revenue
-- A open, B committed. Three cursors captured at this instant:
--   (a) ADR-0006 sequence watermark   W = 1
--   (b) naive max(xact_id) + 1          = 553011
--   (c) pg_snapshot_xmin                = 553009

-- ISSUED, while A is open:
 a_rows_at_or_below_W | b_revenue_naive_max | c_revenue_xmin_cursor
----------------------+---------------------+-----------------------
                    0 | 130,000.00          | 110,000.00

-- A committed. Nothing backdated. Same three cursors, same three queries:
 a_rows_at_or_below_W | b_revenue_naive_max | c_revenue_xmin_cursor
----------------------+---------------------+-----------------------
                    1 | 180,000.00          | 110,000.00

 seq |           who            | xact_id
-----+--------------------------+---------
   1 | A -- batched posting run |  553009
   2 | B -- ordinary posting    |  553010
```

**(a) is the mechanism [ADR-0006](/decisions/0006-time-and-as-of) specified, and it fails.** Its rule
is `W = min(seq) - 1` over events whose xid ≥ `pg_snapshot_xmin`. The minimum can only be taken over
rows the reporter can *see*, and the row that breaks the report is the one it cannot: A holds `seq`
1 invisibly, B's visible `seq` 2 sets `W = 1`, and A's row appears *below an already-issued
watermark*. Isolated on its own two-column table so the mechanism is the only thing under test.

**(b) fails on the same interleaving** and is the reason 0006 rejected a bare `bigserial`, restated
in transaction ids: values are handed out at *insert* time and commit out of order, so a cursor
derived from B sits above A.

**(c) is stable, and the third column shows what it costs**: at issue it reports 110,000.00 when
130,000.00 had already committed, because B's commit is above the horizon A is pinning. The lag is
the price, and §8 has more of it.

**Why (c) is correct, stated as the two facts it needs.** Transaction ids are assigned
monotonically, so a row written after the cursor was captured can never carry an id below it. And
xmin is the lowest id still *running*, so everything below it has already committed or aborted, and
an aborted row is invisible forever. The set `{xact_id < C}` is therefore frozen the moment `C` is
read. `xid8` is the epoch-extended 64-bit form, so wraparound is not a case to handle.

### The literature already names this, and the field is split by it

| | system-time source | commit-ordered? |
| --- | --- | --- |
| **TigerBeetle** | the cluster primary, via consensus | **yes** |
| **XTDB v2** | a single-writer totally-ordered durable log | **yes** |
| **MariaDB**, `TRANSACTION` versioning | transaction id + a commit-id registry | **yes** |
| **MariaDB**, `TIMESTAMP` versioning | insert-time timestamp | no — and the docs say so |
| **SQL Server** temporal | transaction **begin** time | no |
| **SQL:2011** | implementation's choice; only *fixed per transaction* | **not required** |
| **Formance** | `transaction_date()` = first statement's time, cached | **no** |

- Jensen, Clifford, Gadia, Segev & Snodgrass, *A Glossary of Temporal Database Concepts* (SIGMOD
  Record 21(3), 1992), §3.2: **"Transaction times are consistent with the serialization order of the
  transactions."**
- Jensen & Lomet, *Transaction Timestamping in (Temporal) Databases* (VLDB 2001), p.1: **"If the
  transaction timestamp order does not agree with a serialization order, it can happen that the
  answer to the timeslice query never existed as a current state."** Their worked example is §2's
  table with different letters, and their fix is ours: *"It is easy to avoid the above anomalies if a
  transaction T's timestamp can be established at the time at which T is committing, as the timestamp
  can then be chosen to agree with the commit ordering of the transactions."*
- **The anomaly has no agreed name.** Jensen & Lomet call it "the two anomalies exposed in Figure 1";
  Snodgrass calls it states "inconsistent with serializability"; MariaDB names only the cure. *Do not
  invent a term for it* — the ANSI "non-repeatable read" is a different, within-transaction
  phenomenon.
- **MariaDB documents the trade openly** and is the closest thing to a vendor statement of this ADR:
  with `TIMESTAMP` versioning *"a row might have been inserted in a long transaction, and became
  visible hours after it was inserted"*; transaction-precise history means *"rows inserted before
  that point, but committed after will not be shown"*; and to get it *"InnoDB needs to remember not
  timestamps, but transaction identifier per row."* The cost they publish is worth copying down:
  *"PARTITION BY SYSTEM_TIME is not supported when using transaction-precise system versioning."*
- **XTDB has the commit order and still tells you not to use a clock as the handle.** System time
  comes from a single-writer log — *"All transactions that perform writes are serialized via a
  totally-ordered durable log"* — and yet: *"`SNAPSHOT_TIME` does not provide repeatable queries to
  the same level as `SNAPSHOT_TOKEN` … subsequent queries — even with the same `SNAPSHOT_TIME` — may
  return different results … If you need full query repeatability (for audit purposes, say) you
  should store and re-use the `SNAPSHOT_TOKEN`."* An opaque token, stored beside the report. That is
  what `xid8` is here.
- **TigerBeetle assigns the order and asserts it.** *"the TigerBeetle cluster assigns all
  timestamps"*; *"All `timestamp`s within TigerBeetle are unique, immutable and totally ordered"*;
  `assert(timestamp > self.commit_timestamp or self.aof_recovery)` in `src/state_machine.zig` at
  `9d2f5d625ab6ec0367f88402ef03612f36fc00a4`. So their as-of read needs no cursor — the axis *is*
  one. Note what that costs them in the other direction: `imported` transfers must be *"strictly
  increasing"* and *"at least one nanosecond ahead of the timestamp of the last transfer committed by
  the cluster"*, so **you cannot backfill behind live traffic at all**, and their docs recommend
  importing *"only on a fresh cluster or during a scheduled maintenance window"*. One axis, bought
  with the thing this ledger cannot give up.

### Formance, read at `335bd03c08de46bae6895471702d9656958c64f5`

A repository-wide search for `pg_current_xact_id`, `txid_current`, `pg_snapshot`, `pg_current_snapshot`
and `xmin` returns **zero occurrences**. There is no commit-ordered cursor of any kind. Every column
their `pit` parameter can filter on defaults to `transaction_date()`, which caches
`statement_timestamp()` in a session temp table — the *first statement's* time, weaker than `now()` —
and is the default for `moves.insertion_date`, `moves.effective_date`, `transactions.timestamp`,
`logs.date` and `accounts.first_usage`. Their own log-sequence comment states the consequence they
did find: *"we can still have 'holes' on id since a sql transaction can be reverted after a usage of
the sequence."*

Three notes on [spike 001](/spikes/001-formance)'s claim that `pit` resolves to six columns across
seven endpoints, re-checked at this commit: **it verifies**, and it is worse in two ways and better
in none. The six are `created_at`, `accounts.first_usage`, metadata `date`, `moves.effective_date`,
`moves.insertion_date`, `transactions.timestamp`. `pit` is also accepted on `/v2/{ledger}/logs` and
**silently discarded** — `func (h logsResourceHandler) BuildDataset(_ common.RepositoryHandlerBuildContext[any])`,
the `_` being the whole finding — and it works on two endpoints their OpenAPI does not document. Its
description in their generated API reference is the literal string `none`. And the axis *selector* is
the thing spelled three ways (`use_insertion_date`, `useInsertionDate`, `insertionDate`), baked into
two option structs with different JSON tags for the same field; `pit` itself is spelled two
(`pit`, `endTime`). Sharpest: `/v1/…/aggregate/balances` hard-codes the insertion axis and
`/v2/…/aggregate/balances` defaults to the effective one, so **the same `pit` means a different axis
depending on which version of the same endpoint you call**, undocumented.

## 4 · The close, as an ordinary posting

`04_period_close.sql`. A three-year book: revenue 20,000.00 / 25,000.00 / 6,000.00, expense
5,000.00 / 10,000.00 / 2,000.00.

```
== BEFORE ANY CLOSE: the baseline view, unparameterised ==
 Cash and cash equivalents                | 134,000.00
 Shareholders equity                      | 100,000.00
 Undistributed earnings (since inception) |  34,000.00
```

That is the register's number: 34,000.00 against a true current year of 4,000.00, and
`retained_earnings` absent because nothing has ever routed to it. Closing 2024 and 2025 — two
ordinary transactions, one posting per temporary account, `retained_earnings` as the destination:

```
== the closing transaction, as it sits in the journal ==
      purpose      | direction |  amount   |        effective_at
-------------------+-----------+-----------+----------------------------
 fee_revenue       | debit     | 25,000.00 | 2025-12-31 23:59:59.999999
 interest_expense  | credit    | 10,000.00 | 2025-12-31 23:59:59.999999
 retained_earnings | debit     | 10,000.00 | 2025-12-31 23:59:59.999999
 retained_earnings | credit    | 25,000.00 | 2025-12-31 23:59:59.999999

== BALANCE SHEET as at 2026-12-31, after the close ==
 Cash and cash equivalents | 134,000.00
 Shareholders equity       | 100,000.00
 Retained earnings         |  30,000.00
 Earnings since last close |   4,000.00

   assets   | liab_and_equity | balanced
------------+-----------------+----------
 134,000.00 | 134,000.00      | t

== INCOME STATEMENT, per period. Each period reports ITS OWN year. ==
 period |  revenue  |  expense  | net_income
--------+-----------+-----------+------------
 2024   | 20,000.00 | 5,000.00  | 15,000.00
 2025   | 25,000.00 | 10,000.00 | 15,000.00
 2026   |  6,000.00 | 2,000.00  |  4,000.00

== the POST-CLOSING TRIAL BALANCE: only permanent accounts carry a balance ==
 operating_cash    | asset    | 130,000.00
 paid_in_capital   | equity   | -100,000.00
 retained_earnings | equity   |  -30,000.00
 interest_expense  | expense  |        0.00
 fee_revenue       | revenue  |        0.00
```

Three details in there are the design.

**`effective_at = ends_at - interval '1 microsecond'`.** A half-open period `[starts_at, ends_at)`
has no "last day"; it has a last *representable instant*, and `timestamptz` resolves to a microsecond,
so this is exact rather than a `23:59:59` approximation that would drop entries. §7 measures the
approximation dropping them.

**The 2025 income statement still reports 25,000.00, even though the 2025 close sits inside 2025.**
Everyone who puts the close in the journal has to teach the reports to ignore it, and they pick
three different mechanisms: a **tag** (hledger's `clopen:`), a **flag column** (ERPNext's
`is_period_closing_voucher_entry`), an **account type** (Odoo's `equity_unaffected`). We use a
**key**: `ledger_period_closes (tenant_id, period_code, currency)` names the closing transaction, and
`income_statement_for` excludes it with `NOT EXISTS` against a primary key. GnuCash has none of the
three and publishes the result on the same page as the feature — *"closing the books reduces the
usefulness of the standard reports because the reports don't currently understand closing
transactions."*

**No Income Summary account.** The classic form is four entries: revenue to Income Summary, expenses
to Income Summary, Income Summary to Retained Earnings, dividends to Retained Earnings (OpenStax,
*Principles of Accounting* Vol. 1 §5.1). The middle account is a manual-bookkeeping checksum, and
both the practitioner and the textbook say skipping it is fine: *"Since the income summary account is
only a transitional account, it is also acceptable to close directly to the retained earnings account
and bypass the income summary account entirely"* (AccountingTools); *"No matter which way you choose
to close, the same final balance is in retained earnings"* (OpenStax). Our checksum is that the
posting is balanced by construction.

**And `ex_periods__no_overlap` refuses an overlapping period declaratively** — an exclusion constraint
on `(tenant_id WITH =, tstzrange(starts_at, ends_at, '[)') WITH &&)`, no trigger. It costs one
extension, `btree_gist`, which is **trusted** on PostgreSQL 13+ (`pg_available_extension_versions.trusted
= t`, verified on 18.6), so a database owner installs it without superuser.

### What the standards actually require, quoted

The operative IAS 1 text, from the IFRS Foundation's own PDF:

- **¶38** — *"Except when IFRSs permit or require otherwise, an entity shall present comparative
  information in respect of the preceding period for all amounts reported in the current period's
  financial statements."*
- **¶38A** — two of every statement, as a minimum.
- **¶41** — *"If an entity changes the presentation or classification of items in its financial
  statements, it shall reclassify comparative amounts unless reclassification is impracticable."*
- **¶36** — *"An entity shall present a complete set of financial statements (including comparative
  information) at least annually."*

**And the negative result, which is what makes the close ours to design.** Searched over the operative
text: *closing entry*, *income summary*, *trial balance*, *journal*, *ledger*, *nominal account*,
*temporary account*, *bookkeeping*, *double-entry*, *chart of accounts* and *debit* occur **zero
times**. *Retained earnings* occurs three times, and at ¶108 it is prefixed *"for example"*; the
mandated equity line at ¶54(r) is *"issued capital and reserves attributable to owners of the
parent"*. **IAS 1 prescribes presentation, not bookkeeping.** Two honest limits on that claim: it is
exhaustive for IAS 1 and **not** for IFRS as a whole, and **IFRS 18 replaces IAS 1 for periods
beginning on or after 1 January 2027** — its operative text has not been read here, and nothing in
this spike should be quoted about it.

So the field splits, and both sides are defensible:

| | period-end result is |
| --- | --- |
| **hledger**, **GnuCash**, **Odoo**, **TigerBeetle**'s close-account recipe | ordinary balanced transactions |
| **ERPNext** | **both** — real `GL Entry` rows *and* an `Account Closing Balance` snapshot, with a test asserting the two agree |
| **django-ledger**, **Modern Treasury** (`ledger_account_statement`) | a stored period-balance table |
| **QuickBooks** (per Lumen) | nothing stored — *"when you run a report, the software treats the accounts as if they were closed at the end of all the prior periods"* |
| **Formance**, **Fragment**, **Medici**, **pgledger**, **Beancount** (persists nothing) | no period close at all |

Formance's absence is measured, not assumed: a search over `*.go`, `*.sql`, `*.md` and `*.yaml` for
`period close`, `closing entr`, `retained earning`, `fiscal` and `accounting period` returns **zero
hits**, and their only stored aggregate, `accounts_volumes`, has **no date column at all**.

**We do what ERPNext does — both — and hledger's stated reason is the one that generalises**:
*"at some point you will probably want to partition your data by time, for performance or data
integrity or regulatory reasons."*

## 5 · What the checkpoint buys

`05_checkpoint_cost.sql`. 400,000 entries on one account across three years, twelve quarterly periods
closed. As-of reads **checkpoint + two tails**: entries effective after the close boundary, and
entries effective *before* it that arrived *after* it. Median of 7, localhost, warm.

| as of | entries in range | aggregate over all history | checkpoint + tail |
| --- | --- | --- | --- |
| 2023-04-01 | 43,200 | 5.18 ms | 0.71 ms |
| 2024-01-01 *(close boundary)* | 175,200 | 27.22 ms | **0.67 ms** |
| 2024-02-15 *(mid-period)* | 196,800 | 26.92 ms | **3.48 ms** |
| 2025-01-01 *(close boundary)* | 350,880 | 30.18 ms | **0.67 ms** |
| 2025-02-15 *(mid-period)* | 372,480 | 30.91 ms | **3.31 ms** |
| 2025-10-01 | 400,000 | 32.06 ms | 0.66 ms |

**Both mid-period rows are here on purpose.** A line drawn only through the close boundaries would be
a flattering one: the tail is empty there. The claim is not that as-of becomes constant — it is that
its cost **stops depending on the age of the book and starts depending on the length of one period**.
45–49× at a close boundary and 8–9× mid-period, and neither ratio decays as history grows. Three runs of the file
moved the 43,200-row figure between 4.75 and 5.44 ms and left every ratio intact; **the ratio is the
finding, not the number**, and localhost is not a benchmark.

The two forms agree to the minor unit at all six points, and — the case that matters — **after a
posting backdated into an already-closed period**: both −35,211,400. The checkpoint is not
invalidated by the late arrival, because the arrival's `xact_id` is above the close's cursor and it
lands in the second tail term. That term is why `ix_entries__asof_recorded` becomes
`ix_entries__asof_commit (tenant_id, account_id, xact_id)`:

```
   ->  Index Scan using ix_entries__asof_commit on ledger_entries e
         Index Cond: ((tenant_id = 't1') AND (account_id = …)
                      AND (xact_id >= (InitPlan 2).col1)
                      AND (xact_id < pg_snapshot_xmin(pg_current_snapshot())))
         Filter: (effective_at < '2025-01-01 00:00:00+00')
```

Without that index the backdated-arrivals term scans the whole pre-close prefix and the checkpoint
buys nothing. The old index keyed `recorded_at DESC` — an index on the column §2 just disqualified.

**The checkpoint costs 24 rows and 32 kB against 800,024 entries and 253 MB.**

**Why this is not `balance_after` coming back.** [Spike 009](/spikes/009-where-the-balance-lives)
deleted a running balance that was per *entry*, on the *recorded* axis, on the *write* path, computed
by the writer from the same locked row it was supposed to check. This is per *account per period*, on
the *effective* axis — the axis every as-of question is actually asked on — written by a batch job,
and exactly recomputable at a stated cursor, which makes comparing it a real check rather than a
tautology. Fragment reached the same shape from the other end, keeping balance deltas per
{year, month, day, hour} bucket for *"a fixed write cost, regardless of the timestamp the Ledger
Entry is posted to"*.

## 6 · An issued statement, re-issued

`06_reproducible_report.sh`. Post February revenue, issue the February income statement at a cursor,
then do two things to the book that both leave every check green.

```
-- ISSUED. effective range [2026-02-01, 2026-03-01)   commit cursor 553277
 caption | amount
---------+--------
 Revenue | 500.00

-- A LATE CLEARING ARRIVES, carrying the network's February business date.
-- AND THE SEAL HOLE: a balanced pair of legs appended to the ALREADY-COMMITTED
-- February transaction, using nothing but the app role's INSERT grant.

-- RE-ISSUED with the SAME two parameters:
 Revenue | 500.00
-- ...and the baseline's parameterless view, over the same book:
 Revenue | 1,166.00
-- A NEW report, at a NEW cursor, restates February -- visibly, as a new document:
 Revenue | 1,166.00

 balanced | entries
----------+---------
 t        |       6
```

500.00 → 1,166.00 is the number `migrations/00001_baseline.sql`'s own comment records for the seal
hole. **The cursor does not close that hole — it makes an issued statement immune to it**, and that
is what decides one detail of the DDL: `xact_id` is *not* denormalised from the transaction under a
composite foreign key the way `effective_at` and `currency` are. Under such a key the appended legs
would inherit the original transaction's id, sit below the issued cursor, and rewrite the report.
Carrying their own id, they cannot. **The two values are allowed to differ, and the difference is the
information.**

**Why a function and not a documented `WHERE` contract on the views**, from the same script:

```
psql: SELECT * FROM income_statement WHERE effective_at < '2026-03-01'
ERROR:  column "effective_at" does not exist

income_statement exposes: tenant_id, currency, fs_line, caption, sort_order, amount_minor, side
```

A view takes no parameter, and a predicate written outside an **aggregating** view applies after the
`GROUP BY`, where the column it needs does not exist and cannot be made to. That is structural. The
replacement costs no plan — PostgreSQL inlines a simple SQL-language set-returning function, so
`trial_balance_at(…)` still plans as nested loops over an index scan on `ledger_entries`, not a
`Function Scan` over a materialised result.

## 7 · Whose midnight

`07_timezone.sql`. `grep -rn "AT TIME ZONE"` over this repository returns zero hits, and
[ADR-0006](/decisions/0006-time-and-as-of), which owns time, scopes itself away from the question.

**A local midnight is not always a real instant.** Brazil's DST transitions took effect at 00:00
local, so on the spring-forward night local midnight did not happen:

```
 boundary_asked_for  |    resolved_instant    | offset_from_utc |   renders_back_as
---------------------+------------------------+-----------------+---------------------
 2018-11-04 00:00:00 | 2018-11-04 03:00:00+00 | -03:00:00       | 2018-11-04 01:00:00
 2019-02-16 00:00:00 | 2019-02-16 02:00:00+00 | -02:00:00       | 2019-02-16 00:00:00
 2020-02-16 00:00:00 | 2020-02-16 03:00:00+00 | -03:00:00       | 2020-02-16 00:00:00
```

Row 1: asked for midnight, got an instant that renders back as **01:00**. No error, no warning, a
period an hour short. Rows 2 and 3 are the second finding: **the same wall-clock boundary in the same
zone, an ordinary mid-February midnight, one hour apart** — because Brazil abolished DST by decree
between them. A stored (local date, zone) pair is not an instant; it is a promise to re-run a lookup
against whatever tzdata is installed on the day someone re-reads the statement. This server knows 599
zones and 195 abbreviations, and every one of them is legislation.

**And whose zone it is moves money between statements.** One posting, effective `2026-03-01 02:00+00`:

```
 period_resolved_in  |     feb_starts_at      |      feb_ends_at       | february_revenue
---------------------+------------------------+------------------------+------------------
 UTC                 | 2026-02-01 00:00:00+00 | 2026-03-01 00:00:00+00 | 0.00
 America/New_York    | 2026-02-01 05:00:00+00 | 2026-03-01 05:00:00+00 | 420.00
 Asia/Kathmandu      | 2026-01-31 18:15:00+00 | 2026-02-28 18:15:00+00 | 0.00
 Australia/Lord_Howe | 2026-01-31 13:00:00+00 | 2026-02-28 13:00:00+00 | 0.00
```

**Half-open, not `BETWEEN`.** An entry effective at `2026-02-28 23:59:59.999999`:

```
 effective_at <  2026-03-01           (half-open)     |       2
 effective_at <= 2026-02-28 23:59:59  (to the second) |       0
 effective_at <= 2026-02-28           (to the day)    |       0
```

So `ledger_periods` stores **resolved instants** and keeps the zone as provenance:

```
  code   |       starts_at        |        ends_at         |        tz
---------+------------------------+------------------------+------------------
 2026-02 | 2026-02-01 05:00:00+00 | 2026-03-01 05:00:00+00 | America/New_York
```

**The zone name *is* constrainable, declaratively**, which was not obvious. `timezone(text,
timestamptz)` is marked `IMMUTABLE` (`pg_proc.provolatile = 'i'`, verified), so a `CHECK` may call
it, and an unrecognised name *raises* rather than returning `NULL`:

```
NOTICE:  refused a nonsense zone: time zone "Middle/Earth" not recognized
```

That PostgreSQL believes this function immutable while the IANA database is legislation is not
something to route around. **It is the argument for storing the resolved instant.**

## 8 · What went wrong while running this, and what it proves

**The cursor's lag bit the spike that was measuring it, three times.** `pg_snapshot_xmin` is the
*cluster's* horizon, not the database's: a transaction held open in a **different database on the
same server** — another workstream's benchmark, in this case — pinned it below rows this script had
just committed itself. One run of §5 lost a posting it had made, and one run of §7 reported 0.00 of
February revenue in every zone.

The fix in the scripts is `sp_wait_for_cursor()`, which polls until the horizon passes the newest
committed entry, so that experiments *about something else* are not silently measuring the lag. The
fix in production is that there is none: this is the cost, and ADR-0011 records it as one. On RDS the
holders are not only our writers — `pg_dump`, an idle-in-transaction session, a logical replication
slot, `hot_standby_feedback` from a replica and any prepared transaction all hold xmin back.

**The second thing that went wrong is worth writing down too.** The first version of §3 had B posting
to the *same* accounts as A, and it deadlocked the script — B blocked on A's balance-row lock until A
committed, so there was no interleaving at all. That is the write path working exactly as designed
([spike 009](/spikes/009-where-the-balance-lives): the balance row *is* the serialization point), and
it means **the dangerous interleaving is precisely the one between writers that do not contend** —
different accounts, different tenants, a batch job beside an API call. Contending writers are already
ordered. The ones that are not are the ones a report has to be pinned against.

## What this spike did not do

- **No RDS, no network, no durability tuning.** Every number is localhost on one machine with other
  workstreams hitting the same server, which is how §8 happened.
- **The close was not measured at scale.** Twelve quarters on one 400,000-entry account was fast
  enough not to notice, and that is not a measurement. A close over a million accounts writes a row
  per account and scans the period once; nothing here says what that costs.
- **Nothing reconciles the checkpoint against the journal.** It is exactly recomputable, which is what
  makes the check possible, and the check is not written. ERPNext tests its equivalent; that test is
  the obvious next thing.
- **`xid8` across a logical restore was reasoned about, not tested.** `pg_dump`/`pg_restore` re-inserts
  under new transaction ids, so stored cursors are meaningless against the restored database. That
  follows from how the type is assigned and it deserves its own run before anyone relies on it.
- **IFRS 18 was not read.** IAS 1's operative text was, exhaustively; the successor standard was not.
