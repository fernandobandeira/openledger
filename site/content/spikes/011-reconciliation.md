# Spike 011 — Which pairs of numbers should agree, and what compares them?

**Status:** closed. Seven reporting views, each drift reproduced and caught, with a negative control.
Feeds [ADR-0010](/decisions/0010-reconciliation).

**Question.** This schema publishes the same fact more than once — a cached balance and the entries
behind it, a journal and three reports over it, two scopes holding two sides of one obligation, an
`available` number and a `posted` one. Every pair should agree. **Zero views compare any of them**:
the ledger-side drift views went with [ADR-0004](/decisions/0004-where-logic-lives) and the only
replacement ever written, `card_hold_drift`, is parked. What are the pairs, what does the comparison
cost, and when does it run?

**Ran** 2026-08-27 · PostgreSQL 18.6 (Alpine, container), `shared_buffers` 128 MB, `work_mem` 4 MB,
default `max_parallel_workers_per_gather = 2`. Everything below reproduces from
`spikes/013-reconciliation/` — `./run.sh` for the correctness run, `./run.sh scale` for the cost run.
Prior art read from source at pinned commits, or from the vendor's own published page, and which is
said each time.
> **Note on reproducing this spike.** Its runs predate the 2026-08-27 integration that folded the
> proposed DDL of ADRs 0009–0013 into `migrations/00001_baseline.sql`
> ([0003](/decisions/0003-migrations)'s editable-until-v0.1 exception), so the overlay files in this
> spike's directory target the *pre-merge* baseline — recover it from git history to re-run them
> verbatim. The merged baseline was re-verified end to end at integration time.

---

## The answer

**Seven views, and the shape matters more than the SQL.** Four are **break lists** that must return
zero rows; two are **reconciliation statements** that always return rows and must foot to zero; one
is the summary an operator actually runs.

| view | kind | must be |
| --- | --- | --- |
| `recon_balance_breaks` | break list | empty — the cache against the journal, in six separate classes |
| `recon_entry_breaks` | break list | empty — entries no report can count, enumerated one row each |
| `recon_transaction_breaks` | break list | empty — debits ≠ credits, per currency, plus entryless transactions |
| `recon_scope_breaks` | break list | empty — the two sides of a cross-scope obligation, summed across tenants |
| `recon_journal_to_reports` | statement | `unexplained = 0` — journal, less pending, less orphaned, against `trial_balance` |
| `recon_pending_bridge` | statement | `reconciles` — available = posted + pending, with the pending population named |
| `reconciliation` | summary | six rows, `breaks = 0` on each |

**A break list and a statement are not the same object and must not be merged.** A check that returns
nothing because it was never run is indistinguishable from one that passed —
[ADR-0004](/decisions/0004-where-logic-lives)'s `TRUNCATE` finding is exactly that: *"there was
nothing left to disagree with — **silence read as assent**."* So the summary always returns its six
rows, and the two statements always return a row per scope even when the difference they explain is
zero.

**The single most useful finding of the run is that the obvious check is wrong.** The decision log
says of the journal-versus-reports gap that *"three lines of SQL would surface it"*. Three lines of
SQL surface a **false positive on every healthy book that has a hold on it**: a raw journal-minus-
report difference is nonzero for every pending transaction, by design
([ADR-0007](/decisions/0007-schema-conventions-and-chart) rule 14). Measured on the clean book below,
with one pending withdrawal and nothing wrong: naive gap **50,000**, actual break **0**. The
reconciling items have to be named and subtracted before the residual means anything, which is
exactly the shape of a bank reconciliation and the reason this is a statement rather than a
subtraction.

**Second finding: the three jobs of the balance cache row fail separately, so they can be detected
separately, so the row does not need to be split.** The decision log's objection to one row being the
write lock, the counter and the balance is that *"the drift check, the sequence and the lock all fail
together"*. They are three classes in one view — `balance_drift`, `seq_ahead`/`seq_behind`, `seq_gap`
— and each was reproduced with the other two clean. That is the evidence
[ADR-0010](/decisions/0010-reconciliation) declines to split the row on.

**Third: the sweep is a scan and must be scheduled like one.** Serial, `work_mem` 4 MB, the whole
summary took **410 ms at 100,000 entries and 6,334 ms at 1,000,000** — 15.5× for 10× the journal,
because the book crosses `shared_buffers` between the two (36 MB against 377 MB). Per view the same
tenfold ranged from 4.0× to 11.9×. **The ratio is the finding; localhost is not a benchmark.** It
cannot run on a read path and it should not run per write.

---

# The evidence

## The clean book, and the negative control

Three scopes, two currencies, one cross-scope obligation posted on **both** sides, one pending
withdrawal. `02_seed_clean.sql` writes it the way the writer is specified to write — the balance row
is upserted first and *returns* the sequence number the entry then carries — so a drift has to be
injected deliberately rather than arriving by accident.

```
--- reconciliation: every check, clean book
       check_name        | breaks
-------------------------+--------
 balance_cache           |      0
 cross_scope_mirror      |      0
 journal_to_reports      |      0
 orphan_entries          |      0
 pending_bridge          |      0
 unbalanced_transactions |      0

--- the journal-to-reports statement foots in every scope and currency
 tenant_id | currency | journal_debits | pending_debits | orphan_debits | reported_debits | tb_debits | unexplained_debits
-----------+----------+----------------+----------------+---------------+-----------------+-----------+--------------------
 op        | EUR      |        5000000 |              0 |             0 |         5000000 |   5000000 |                  0
 op        | USD      |       10025006 |              0 |             0 |        10025006 |  10025006 |                  0
 t1        | USD      |       10050900 |          50000 |             0 |        10000900 |  10000900 |                  0
 t2        | EUR      |        5000000 |              0 |             0 |         5000000 |   5000000 |                  0
```

**This is the half that is easy to skip, and this project has shipped its failure.** ADR-0007 records
a schema-snapshot check of *"twenty-one lines containing one `SELECT` that emits a string, with no
committed snapshot, no comparison and no failure path — it runs green against the shipped schema and
a mutated one alike."* So every injection below rolls back, and the control is re-run afterwards:
`run.sh` ends by printing the same six zeros it started with.

Note the third row already. `journal_debits` 10,050,900 against `tb_debits` 10,000,900 on a book with
**nothing wrong with it**. That 50,000 is the pending withdrawal.

## Drift 1 — the cache against the journal

> *"Using only the app role's granted `UPDATE`, the cache was moved from 1,000.00 to 100.00 with
> `last_seq` forged; the balance sheet was unchanged and every check stayed green."*

Reproduced on the account a customer is actually shown, with `last_seq` written to the value it
already held — which is what *forged* means here: a check watching only the counter sees nothing.

```
=== the forgery: nothing but the grant the baseline hands openledger_app
SET ROLE openledger_app;
UPDATE ledger_account_balances ... SET output = 1000000, last_seq = 3;
UPDATE 1

=== after: the fast-path read moved, the balance sheet did not
 cache_balance_minor | last_seq          |  fs_line       | amount_minor
---------------------+----------          ----------------+--------------
             -949100 |        3          | customer_funds |      9999100

 tenant_id | currency | cache_balance_minor | journal_balance_minor | drift_minor | cache_last_seq | max_seq | entry_count |     reasons
-----------+----------+---------------------+-----------------------+-------------+----------------+---------+-------------+-----------------
 t1        | USD      |             -949100 |              -9949100 |     9000000 |              3 |       3 |           3 | {balance_drift}
```

99,491.00 of customer money read as 9,491.00 from the cache, with the balance sheet unmoved at
99,991.00 — because the reports read the journal and the cache reads nothing. `drift_minor` is
9,000,000 and the report is untouched, which is the whole point: **no report can be the drift check,
because a report that could see this would be reading the wrong number.**

The comparison is genuinely independent, which the number it replaces was not.
[Spike 009](/spikes/009-where-the-balance-lives) dropped a per-entry running balance that looked like
a check on the cache and was not — *"the writer computed it from the cache, in the same transaction,
from the same locked row. Two numbers with one source agree when they are both wrong."* The journal
is append-only and the cache is not; that asymmetry is what makes this comparison mean something.

## Drift 2 — the counter, three ways, with the balance clean

| injection | `drift_minor` | `cache_last_seq` | `max_seq` | `entry_count` | reported |
| --- | --- | --- | --- | --- | --- |
| `last_seq += 48` | 0 | 51 | 3 | 3 | `{seq_ahead}` |
| ...then one ordinary posting | 0 | 52 | 52 | 4 | `{seq_gap}` |
| `last_seq = 1` | 0 | 1 | 3 | 3 | `{seq_behind}` |
| an `INSERT` supplying `account_seq = 52` | 0 | 52 | 52 | 4 | `{seq_gap}` |

**The two directions of counter drift are not the same failure and the view says which.** Pulled
*behind* the journal it fails closed — the next posting is handed a number an entry already holds and
`uq_entries__account_seq` refuses it, verified: `duplicate key value violates unique constraint
"uq_entries__account_seq"`. Pushed *ahead* it fails **silently**: the next posting takes 52, the
account's history reads 1, 2, 3, 52, and gaplessness — the property that makes *"no entry is
missing"* checkable at all — is gone with no error anywhere.

The last row is [ADR-0004](/decisions/0004-where-logic-lives)'s own case reached from the other side:
*"an `INSERT` left a 48-wide gap and later filled it with a backdated, balanced, same-account round
trip."* The transaction balances, the cache agrees with the journal to the cent, and the only thing
wrong is that entries 4 through 51 do not exist. `unbalanced_transactions` is 0 for it, `drift_minor`
is 0 for it, and `seq_gap` is what sees it.

## Drift 3 — what an orphan is

**Stated rather than assumed: an orphan is an entry that all three shipped report views structurally
cannot include, for a reason other than its status.** All three make the same three joins —
`ledger_transactions` on `(tenant, id)`, `ledger_accounts` on `(tenant, id, currency)`,
`account_types` on `purpose` — so the population is exactly the entries that fail one of them, and
there are exactly three classes. A `pending` entry is *not* an orphan: it is excluded on purpose and
is a named reconciling item.

Every one of those joins is a foreign key, so this list is empty on the ordinary write path. It is
not the ordinary write path that produces one. All **36** internal foreign-key triggers ship
`ENABLE ORIGIN`, and `session_replication_role = 'replica'` — the logical-replication apply path, and
what `pg_restore --disable-triggers` sets — skips them. That is how each case below was made,
because it is how this actually happens.

```
=== 3a - an entry pair on an account that does not exist. 50,000.00.
--- every shipped check is still green: the pair is balanced and absent
 tenant_id | currency | tb_debits | tb_credits
-----------+----------+-----------+------------
 t1        | USD      |  10000900 |   10000900

--- the reconciliation statement, which names where the gap went
 tenant_id | currency | journal_debits | pending_debits | orphan_debits | reported_debits | tb_debits | unexplained_debits | journal_minus_report_debits
-----------+----------+----------------+----------------+---------------+-----------------+-----------+--------------------+-----------------------------
 t1        | USD      |       15050900 |          50000 |       5000000 |        10000900 |  10000900 |                  0 |                     5050000

--- ...and the population itself, enumerated rather than summarised
 tenant_id |               entry_id               |              account_id              | currency | direction | amount_minor |   reason
-----------+--------------------------------------+--------------------------------------+----------+-----------+--------------+------------
 t1        | 01a043fd-4ef0-7596-9964-a033d0233020 | 01a04000-0000-7000-8000-0000000000aa | USD      | debit     |      5000000 | no_account
 t1        | 01a043fd-4ef0-7bc7-b7ac-f698e6d1f637 | 01a04000-0000-7000-8000-0000000000bb | USD      | credit    |      5000000 | no_account
```

Read the two right-hand columns together. `journal_minus_report_debits` is **5,050,000** — the
50,000.00 orphan *and* the 500.00 hold, indistinguishable. `unexplained_debits` is **0**, because
both reconciling items are named. The break is not the gap; the break is what is left of the gap
after the named items come out, and the orphan is two rows you can put in a ticket.

Two more classes, same mechanism:

| injection | what it does to the reports | class |
| --- | --- | --- |
| `DELETE FROM account_types WHERE code = 'fee_revenue'` | t1's revenue leaves the income statement and its trial balance stops footing — 10,000,900 debits against 10,000,000 credits, reported by nothing | `no_account_type` |
| an entry whose transaction row is absent | invisible to every report; also opens a `seq_gap` on its account | `no_transaction` |

The second row of that table is worth its own sentence: **`fk_accounts__type` refuses that `DELETE`
on the ordinary path** — ADR-0007 records the refusal, *"update or delete on table `account_types`
violates foreign key constraint"* — and on the replica path it succeeds, taking a chart row out from
under posted history.

## Drift 4 — debits ≠ credits, which nothing reports

> *"The register already says nothing **enforces** it. The sharper point: nothing **reports** it
> either. A posted transaction with one entry, or zero entries, is accepted and appears in no
> exception list."*

Four cases, all written with nothing but the app role's ordinary `INSERT` grant and no foreign key
skipped:

| case | currency | debits | credits | legs | reason |
| --- | --- | --- | --- | --- | --- |
| one leg | USD | 0 | 25000 | 1 | `single_leg` |
| two legs disagreeing by 10.00 | USD | 2500 | 1500 | 2 | `debits_ne_credits` |
| a transaction with no legs | *null* | 0 | 0 | 0 | `no_entries` |
| one USD leg and one EUR leg | USD | 10000 | 0 | 1 | `single_leg` |
| | EUR | 0 | 10000 | 1 | `single_leg` |

The last case is why the view groups per currency and not per transaction.
[ADR-0007](/decisions/0007-schema-conventions-and-chart) rule 12 says the equation is evaluated per
currency and *"a currency-blind one is vacuous"*; grouped currency-blind, that transaction foots to
zero and is not in the list at all.

The third case is the state `TRUNCATE ledger_entries, ledger_account_balances` left behind in
ADR-0004 — *"eleven transactions standing with zero entries, every currency `balanced = t`, drift at
zero rows."* It needs a `LEFT JOIN` to see, because there is no entry to group by, which is why
"entryless" is a class rather than a special case of imbalance.

**This does not enforce balance and is not a substitute for the write primitive.** A caller holding
`INSERT` can still write every row above; [ADR-0005](/decisions/0005-event-log-and-write-path)'s
posting type is what makes them unrepresentable. What changes is that the claim becomes checkable
against the data instead of being an unfalsifiable statement about a writer that does not exist yet.

## Drift 5 — the two sides of a cross-scope obligation

> *"A tenant booking 100,000.00 of `due_from_treasury` against an operator booking 60,000.00 of
> `due_to_tenants` leaves every scope balanced, every check green, and 40,000.00 of asset owed by
> nobody."*

Reproduced by having the operator write back 40,000.00 of what it owes — one balanced, ordinary,
correctly-keyed transaction in its own book that the tenant never hears about. **Tenant-locality is
what makes this invisible**: no transaction may span two scopes, so there is no row anywhere holding
both numbers, and the comparison has to aggregate across tenants. It is the only view here that does.

```
--- both scopes balance, both trial balances foot. Every check that exists today is green.
 tenant_id | currency | tb_debits | tb_credits          unbalanced | cache_breaks | orphans
-----------+----------+-----------+------------        ------------+--------------+---------
 op        | USD      |  14025006 |   14025006                   0 |            0 |       0
 t1        | USD      |  10000900 |   10000900

--- the two sides, compared
     near_type     |    far_type    | currency | near_minor | far_minor | gap_minor | net_of_counterparties
-------------------+----------------+----------+------------+-----------+-----------+-----------------------
 due_from_treasury | due_to_tenants | USD      |   10000000 |  -6000000 |   4000000 | t
```

The invariant is an elimination: **for a mirrored pair, the deployment-wide sum of the debit-positive
balance over both types is zero, per currency.** It works because the pair is opposite-signed by
construction — a claim on the operator is an asset to the tenant and a liability to the operator —
and it is the elimination ADR-0007 says the golden trace asserts *"at every step"* and no view
performs.

**The pairing cannot be derived from today's chart.** `is_perimeter` says an account mirrors an
*external* balance; `counterparty_scope` says whether members of a split may be netted. Neither names
the type on the other side. Deriving it from the `due_from_` / `due_to_` naming is the cheap answer
and it is the one this project's own rule refuses — a convention is not a constraint. So the view
reads one proposed nullable foreign key, `account_types.mirror_type`, and ADR-0010 carries the DDL.

**And here is what the comparison cannot see**, on the same book, measured rather than asserted:

```
=== 5b - a third scope holding an offsetting position of the same size
 tenant_id |      purpose      | currency | balance_debit_positive
-----------+-------------------+----------+------------------------
 op        | due_to_tenants    | USD      |               -6000000
 t1        | due_from_treasury | USD      |               10000000
 t3        | due_from_treasury | USD      |               -4000000

--- the pair now sums to zero. The view is silent and both scopes are wrong.
(0 rows)
```

t1 is still owed 100,000.00 that the operator acknowledges 60,000.00 of; a third scope's opposite
position of the same size cancels it. This is the same netting failure `counterparty_scope` was
declared for, one level up: the operator holds **one** `due_to_tenants` account per scope
(`uq_accounts__house` is `(tenant_id, purpose, currency)`), so the figure being compared is already
net of counterparties before any view sees it. The view emits `net_of_counterparties` to say so.
Making it gross needs the counterparty in the account key —
[roadmap question 5](/roadmap#per-shard-lines-and-the-counterparty-axis) —
not a change here.

## Drift 6 — the one that is not a drift

[`database.md`](/database)'s table, rebuilt on a scope of its own: one posted 100.00 and one pending
500.00, signs flipped to the account's normal balance.

| read | answer |
| --- | --- |
| cache row (`input - output`) | **600.00** |
| recompute from `ledger_entries` | **600.00** |
| recompute joined to `status = 'posted'` | 100.00 |
| `trial_balance` | 100.00 |
| `balance_sheet`, `customer_funds` | 100.00 |

```
=== the bridge: available = posted + pending, and the population named
 tenant_id |     purpose     | currency | available_balance_minor | posted_balance_minor | pending_balance_minor | pending_txns | oldest_pending_effective_at | reconciles
-----------+-----------------+----------+-------------------------+----------------------+-----------------------+--------------+-----------------------------+------------
 t4        | customer_wallet | USD      |                  -60000 |               -10000 |                -50000 |            1 | 2026-06-11 00:00:00+00      | t
 t4        | fbo_cash        | USD      |                   60000 |                10000 |                 50000 |            1 | 2026-06-11 00:00:00+00      | t

=== zero breaks: this book is healthy and the two numbers still differ
```

**Nothing here is broken, and that is the finding.** The two published numbers differ because they
answer different questions, and until now nothing in the artefact said so or let you get from one to
the other. The bridge is a statement, not a break list: `reconciles` asserts
`available = posted + pending` exactly, and it goes false only when the cache has drifted — which
drift 1 already reports. It explains a difference; it does not find one.

`oldest_pending_effective_at` is in the view because a reconciling item that never clears is a break
that has not been named yet. The FDIC's manual is blunt about the same population in a bank:
*"Most suspense items are researched and cleared the following day"*, and examiners are told to note
*"the recurring use and aging of reconciling items"*
([RMS Manual of Examination Policies §3.7 and §4.2](https://www.fdic.gov/risk-management-manual-examination-policies/section3-7)).

## The sweep does not block anything, and it pins one thing

Read-only, in one transaction, at 1,000,000 entries — every relation lock it takes:

```
 obj                       |      mode
---------------------------+-----------------
 ledger_entries            | AccessShareLock
 ledger_transactions       | AccessShareLock
 ledger_account_balances   | AccessShareLock
 ...30 rows, every one AccessShareLock
```

`ACCESS SHARE` conflicts only with `ACCESS EXCLUSIVE`, so the sweep cannot block a posting; it can be
blocked by DDL, and it blocks DDL. **What it does hold is a transaction horizon:**

```
 state  | backend_xmin | global_xmin |    held_for
--------+--------------+-------------+-----------------
 active |       358593 |      358593 | 00:00:01.229966
```

`backend_xmin` *is* the global xmin for as long as the sweep runs. That is the price of reading all
six views against one snapshot, and it is a real cost on this schema specifically:
[spike 009](/spikes/009-where-the-balance-lives) found `ledger_account_balances` needs a **scheduled
`VACUUM`** that autovacuum will never provide, and a sweep holding xmin is holding back exactly that
vacuum. It also pins [ADR-0006](/decisions/0006-time-and-as-of)'s as-of watermark, which is defined
off `pg_snapshot_xmin`. A sweep long enough to matter has to be bounded — per tenant, per currency —
rather than run as one transaction over the whole deployment.

## Why one snapshot, demonstrated

Six views, six statements. Under `READ COMMITTED` each takes its own snapshot, so the summary can
report a break that the list enumerating it no longer contains. The repair path is itself a writer,
and so is every posting, so this is not hypothetical. `12_snapshot.sh` forges the cache, starts a
sweep, and commits a repair 2 s into it:

```
=== READ COMMITTED
 READ COMMITTED | summary says  |      1
 READ COMMITTED | list contains |      0
=== REPEATABLE READ
 REPEATABLE READ | summary says  |      1
 REPEATABLE READ | list contains |      1
```

An operator paged at 02:00 by a count, finding nothing to look at. **The sweep is one
`REPEATABLE READ READ ONLY` transaction**, which is safe here in a way it is not on the write path:
[ADR-0002](/decisions/0002-scaling)'s serialization failures come from `ON CONFLICT DO UPDATE` under
contention, and this transaction writes nothing.

The repair in that script is also the shape the ADR adopts — the cache row is rebuilt **from the
journal**, never set to whatever makes the difference disappear. The FDIC manual names the
alternative and lists it as a control failure: *"forced balancing"*.

## What it costs to run

Five runs per view, medians, at the server's defaults — which includes
`max_parallel_workers_per_gather = 2`. The whole-summary row is **serial**, three runs, because the
parallel plan for it does not survive this container (below), so the last row is not comparable with
the six above it and is not their sum. **The server was shared with other work throughout**, which is
visible in the spread and is the same caveat [spike 003](/spikes/003-throughput-ceiling) carries:
re-measuring the same configuration there moved the baseline from 833 to 482 purely from machine
load.

| | 100,000 entries | 1,000,000 entries | ×10 data |
| --- | --- | --- | --- |
| `recon_balance_breaks` | 17.5 ms | 82.4 ms | 4.7× |
| `recon_entry_breaks` | 35.4 ms | 284.6 ms | 8.0× |
| `recon_transaction_breaks` | 85.5 ms | 1,015.5 ms | 11.9× |
| `recon_scope_breaks` | 75.4 ms | 401.6 ms | 5.3× |
| `recon_journal_to_reports` | 101.7 ms | 407.2 ms | 4.0× |
| `recon_pending_bridge` | 56.6 ms | 259.4 ms | 4.6× |
| **the whole summary, serial** | **410 ms** | **6,334 ms** | **15.5×** |

**The ratio is the finding, and the ratio moves.** One view is structurally different from the rest:
pending transactions are rare, so `recon_pending_bridge` filters `ledger_transactions` first and
reaches the entries through `ix_entries__txn`. **It is the only view here that never scans
`ledger_entries`**, so it scales with the size of the pending population rather than with history —
which is the right shape for the one view whose population is meant to clear.

> **`count(*)` over a view is not a measurement of the view, and this row is how that was found.**
> The bridge's two `LEFT JOIN`s are on keys the right side is provably unique on — a primary key, and
> a `GROUP BY` on the join key — so PostgreSQL removes both when nothing selects their columns.
> `SELECT count(*) FROM recon_pending_bridge` at 1,000,000 entries: **21 ms**, with half the view
> planned away. The same count with `WHERE NOT reconciles`, which is what `reconciliation` actually
> does: **259 ms**. Twelve times, silently. The table above uses the second form, and the harness was
> corrected rather than the number explained. None of the other five is affected — each has a `WHERE`
> or `HAVING` over the joined columns, and `recon_journal_to_reports` is a `FULL JOIN`, which is not
> removable.

Every row grows, and the summary grows faster than any of its parts: the journal is 36 MB at the
first size and 377 MB at the second, against `shared_buffers` of 128 MB, so the small book is cached
and the large one is not. Budget the sweep as
**linear, and re-measure at your size**. Against this project's own figures it sits where you would
expect — ADR-0006's effective-axis aggregate is *"roughly 0.10 µs per entry"* and spike 009's
per-account recompute is 57.5 ms for a 1M-entry account, where this reads every entry six times over
and gets ~6 µs/entry.

Three cost findings worth carrying:

**`work_mem` is worth 12%, not 4×.** At 1M entries, serial: 6,122 ms at the default 4 MB against
5,461 ms at 64 MB, medians of three. Spike 009 found the status-aware per-account recompute *spilled
to disk* at 4 MB and cost 4× for it; these views aggregate before joining and mostly do not spill —
`recon_transaction_breaks`'s incremental sort peaks at 28 kB of quicksort memory.

**How it is written is worth 1.23×, and the shipped view takes the faster form.**
`recon_transaction_breaks` written as `ledger_transactions LEFT JOIN ledger_entries … GROUP BY` plans
as a merge join driven by an index scan over every entry: 931 ms. Aggregating the legs first and then
joining: 754 ms, medians of three at 1M. Same class of rewrite as spike 009's *"write it
uncorrelated"*, smaller effect, same lesson — and it is why the shipped view has a `legs` CTE.

**The summary needs shared memory the repo's own compose file does not ask for.** With parallelism
on, `SELECT count(*) FROM reconciliation` at 1M entries failed three times out of three:

```
ERROR:  could not resize shared memory segment "/PostgreSQL.826777454" to 2097152 bytes:
        No space left on device
CONTEXT:  parallel worker
```

`docker-compose.yml` sets no `shm_size`, so the container gets Docker's default **64 MB** `/dev/shm`
— verified, `docker exec … df -h /dev/shm` reports `shm 64.0M`. Six subqueries each planning parallel
hashes exhaust it. With `max_parallel_workers_per_gather = 0` the same query succeeds every time, at
6.3 s against the 1.8 s the parallel plan reaches before it dies, which is why every headline number
here is the serial one. The server was shared while this was measured, so the *threshold* is not
attributable to this query alone; the missing `shm_size` and the 64 MB default are facts about the
repository either way, and one line fixes it.

## Prior art — read at pinned commits

**Nobody in this field ships this, and one project ships it as a product feature.** The vocabulary is
the first thing to get straight: *reconciliation* in every vendor's documentation means
ledger-versus-the-outside-world. The stored-versus-recomputed thing has no settled name — Modern
Treasury calls it **cache drift**, Envato calls it **validation**.

| | ships stored-vs-recomputed? | what they do instead |
| --- | --- | --- |
| **Formance** (`335bd03`) | **No** | `grep -rni drift\|repair` over the whole repository: **zero matches**. `reconcile` matches only a Kubernetes-style config reconciler in `tools/provisioner/` |
| **TigerBeetle** (`9d2f5d6`) | **Test only** | The auditor rebuilds expected state from the request stream and panics on mismatch — in the VOPR simulator and the Vortex harness, not in production |
| **Modern Treasury** | **Internally, as ops** | Published: verify, then *turn cache reads off* for drifted accounts, then backfill with a runbook |
| **Envato `double_entry`** (`f1474f0`) | **Yes, shipped** | `LineCheck` + `AccountFixer`, incremental, results persisted, recommended "hourly to daily" |
| **pgledger** (`c18c7d2`) | No | Stores the balance three ways — account balance, per-entry previous and current — and compares none of them |
| **Beancount / Ledger / hledger** | Inverted | No stored balance at all; a `balance` assertion compares a **human-declared external** figure to a full re-derivation |

**Formance is the cautionary one and the detail is worse than the absence.** Their repair migrations
recompute unconditionally and detect nothing: `28-fix-pcv-missing-asset` rebuilds
`transactions.post_commit_volumes` from `moves` with a window function and blanket-updates every
pre-v12 transaction, with no comparison step and no count of how many rows were wrong. Its
predecessor, `27-fix-invalid-pcv`, is now literally
`do $$ begin raise notice 'Migration superseded by next migration'; end $$;` — **the first repair
migration was itself buggy and had to be repaired.** The one comparison in the entire repository runs
exactly once, inside migration `11-make-stateless`, immediately after backfilling `accounts_volumes`
from `sum()` over `moves`:

```sql
ASSERT (select coalesce(sum(input), 0) from accounts_volumes)
     = (select coalesce(sum(output), 0) from accounts_volumes);
```

A global debits-equal-credits check, at migration time, and never again. And the recompute path they
would need *already exists*: their point-in-time volume queries bypass the aggregate and re-sum from
`moves` (`internal/storage/ledger/resource_volumes.go:69-71`) while non-PIT queries read
`accounts_volumes` directly. **Two paths to the same number, in one codebase, never diffed.**

**TigerBeetle has the check and it is test-only**, which is a legitimate answer and not an oversight.
`src/state_machine/auditor.zig` — *"The Auditor constructs the expected state of its corresponding
StateMachine from requests and replies"* — byte-compares a looked-up `Account` against its model and
`@panic`s. `src/testing/vortex/workload.zig` — *"This workload generates requests, and reconciles
replies with a model, tracking account balances"* — re-derives `debits_posted`/`credits_posted` from
transfers and field-compares. Both are reachable only from the VOPR simulator and the Vortex harness.
What ships instead is assertions compiled in (`build.zig` pins `ReleaseSafe`, and TIGER_STYLE:
*"Assertions downgrade catastrophic correctness bugs into liveness bugs"*) plus
*"this simulator … running 24/7 on 1024 cores"* (`docs/concepts/safety.md`). Their docs never
characterise the account row as derived: *"It is up to the application to compute the balance from the
cumulative debits/credits."* The reason they can get away with it is structural — there is no
`UPDATE`, no `DELETE`, and no privilege to write an account row directly, so the population that
corrupts a cache here does not exist there.

**Modern Treasury is the closest thing to prior art for what to *do* about a nonzero row**, and
[ADR-0006](/decisions/0006-time-and-as-of) already cites them for it. From *How to Scale a Ledger,
Part VI*, under "Monitoring Cache Drift":

> "Reading Account balances from a cache improves performance, but it means that balance reads may
> diverge from source-of-truth Entries; it's also possible for bugs to cause this divergence. We
> handle this by: Regularly verifying each Account's cached balances match the sum of Entries …
> Automatically turning off cache reads for Accounts that have drifted … Providing tools for a
> backfill process and a runbook for on-call engineers to triage and address cache drift problems
> 24/7."

Three moves: **verify**, **degrade**, **repair with a human**. Their customer-facing *"Account
Reconciliation"* product is the other axis entirely — ledger against a bank statement — and their
customers get the guarantee as an assertion rather than as a query they can run.

**Envato's `double_entry` is the one unambiguous yes**, and its README is the sentence this ADR is
built on: *"DoubleEntry tries really hard to make sure that stored account balances reflect the
running balances from the `double_entry_lines` table, but there is always the unlikely possibility
that something will go wrong."* `LineCheck` walks new lines incrementally from the last checked id
and persists its results to an audit table; `AccountFixer` recomputes from scratch and repairs. Their
recommendation is *"a scheduled job, somewhere on the order of hourly to daily"*, with the warning
that *"this process locks accounts as it inspects their balances"* — which ours does not, because it
takes `ACCESS SHARE` and nothing else.

## Prior art — how banks do it

Every quote below is from a document fetched from the regulator's own site.

**Daily, and the cadence is written down.** The Federal Reserve's *Commercial Bank Examination
Manual* §2320.4 asks, in the internal-control questionnaire: *"Are the above ledger or individual
subsidiary accounts balanced to the general ledger on a **daily basis**?"* — and §7030.4 adds the
segregation rule in the same breath: *"balanced daily with the appropriate general ledger accounts
and reconciling items adequately investigated **by persons who do not normally handle loans and post
records**."* The OCC's *Internal and External Audits* booklet (M-AUD v1.0, current) puts
*"balancing subsidiary records to general ledger control totals"* in the scope of audit itself.

**Reconciling items age, and the ages are short.** FDIC RMS §3.7: *"Most suspense items are
researched and cleared the following day"*, and examiners *"should determine if institutions
regularly reconcile suspense accounts and charge off stale suspense items."* Fed CBEM §2300.1:
*"Nothing should be allowed to remain in those accounts for any significant length of time — usually
no more than a few business days. All difference accounts should be closed out at least quarterly."*
The OCC's *Cash Accounts* booklet records a **3-day limit** as common practice for uncollected cash
items. **The 30/60/90-day aging buckets everyone quotes appear in none of these documents** — the
figures that do appear are one day, three days, "a few business days", two months, and quarterly.

**Segregation of duties is the sourced argument for a separate role.** FDIC RMS §4.2, on internal
routine and controls: *"personnel that originate transactions should not reconcile the entries to the
general ledger"*, and the same section names **forced balancing** — plugging the difference — as a
failure mode to look for. In this schema the app role holds `UPDATE` on `ledger_account_balances`,
which is precisely the number `recon_balance_breaks` checks, so the sweep runs as a role that cannot
write it.

**One negative worth recording so nobody cites it wrongly.** PCAOB **AS 2201**, the SOX 404(b)
auditing standard, was fetched in full: the words *reconciliation* and *reconcile* **do not appear in
it**. It requires evaluating the *"period-end financial reporting process"*. Do not cite SOX as
requiring reconciliation. Basel's *Principles for the Sound Management of Operational Risk* (March
2021) does mention it — Principle 9 ¶51(f), *"Regular verification and reconciliation of transactions
and accounts"* — as one bullet in an illustrative list, which is breadth rather than a mandate.

> **Not verified.** Every `ffiec.gov` host returned HTTP 403, so there is no FFIEC quote here and any
> claim attributed to the FFIEC BSA/AML or IT handbooks in this project is unsourced. COSO's own
> framework is paywalled and was not fetched; the GAO Green Book (GAO-14-704G), which is the free
> COSO-aligned text, names *"comparisons, reconciliations"* as a control activity and prescribes no
> frequency. 12 CFR 364 Appendix A was bot-walled; only the FDIC's paraphrase of it was read.

## What this does not do

**A drift view detects disagreement, never fabrication.** That sentence is ADR-0004's, about
validating `account_seq` against the cache, and it applies to everything here. A caller holding both
`INSERT` on `ledger_entries` and `UPDATE` on `ledger_account_balances` — which is exactly what the
baseline grants `openledger_app` — can write an entry **and** advance the cache to match it, and
every view above stays empty. What the journal's append-only property buys is that the fabrication
has to be *added*, never hidden: the entry is in the list forever. That is a different guarantee and
a weaker one, and it is the honest description of this layer.

Four more limits, each demonstrated above rather than argued: the mirror view compares figures that
are already net of counterparties (5b); it cannot tell a timing difference — the operator posting its
side tomorrow — from a loss; the orphan classes are empty on every path that enforces its foreign
keys, so this layer's value on the ordinary write path is a *proof of absence* rather than a finding;
and the whole sweep is periodic, so between two runs a forged cache is simply the answer customers
get.
