# Spike 025 — the harness specification

**The question.** An adversarial read-only audit produced twelve findings against the shipped
reporting functions and the reconciliation views. Which of them are real on a real book?

This project's standard is *proved red before trusted green*. A finding that cannot be reproduced is
withdrawn, not fixed — so this spike is as much a check on the auditor as on the schema. Ten
findings were handed over (F1–F10, the twelve collapsed to ten subjects); every one is either
reproduced against a live book with the exact statement and the exact output recorded, or refuted by
naming the constraint that makes the state unwritable.

Everything below runs against `migrations/00001_baseline.sql` + `00002` + `00003` applied by the
**compiled** `openledger migrate`, plus `schema/chart.sql`. No SQL in this spike modifies the
shipped schema. Where a finding's fix had to be evaluated, the candidate expression was evaluated
**as a query, side by side with the shipped one**, inside the scratch database — never as DDL
against a migration.

---

## Ground rules

- **A clean negative control before every injection.** Spike 011's rule, and its reason:
  ADR-0007 records a schema-snapshot check of *"twenty-one lines containing one `SELECT` that emits
  a string, with no committed snapshot, no comparison and no failure path."* A red that was already
  red proves nothing. Every reproduction below opens with `SELECT * FROM reconciliation` returning
  **ten rows at zero breaks**, and where a finding claims the checks stay green, all ten rows are
  pasted, not the one that was expected to move.
- **The front door where the front door reaches.** The book is written by the shipped writer over
  HTTP (`POST /v1/transactions`), so a defect is a defect of the artefact. Where a state is only
  expressible below the API — a `kind` the writer never emits, a supplied `xact_id`, a close row —
  the reproduction says **which role it ran as**, because "the writer can reach this" and "only the
  owner can reach this" are different severities. Two reproductions run as `openledger_app`
  deliberately (F2a, F2b, F8); one runs as a `LOGIN` role inheriting `openledger_read` (F9); the
  rest run as the owner and say so.
- **No timing runs at all.** Nothing here is a performance question. No configuration was measured,
  no loadavg recorded, no comparison of durations made or implied.
- **Forward-only injections, and an exact restore.** `refuse_mutation()` refuses `UPDATE` and
  `DELETE` on `ledger_entries`, `ledger_transactions`, `ledger_events`, the three chart tables,
  `ledger_periods`, `ledger_period_closes` and `perimeter_attestations` — so a reproduction cannot
  tidy up after itself. `REPRO/reset.sh` restores the negative-control book from a `TEMPLATE` copy
  taken once, which is byte-exact and needs no `DELETE`.

### The deviation, stated plainly: this spike runs on its own PostgreSQL instance

The brief said to work in a `spike025` database on the `make up` server at port 5433. **That is not
where these runs happened**, for two reasons, and both are the subject of a finding.

1. **The shared cluster's horizon was held back by a neighbour, so the negative control was
   unobtainable there.** On the first attempt, `SELECT * FROM reconciliation` on the freshly seeded
   `spike025` at port 5433 reported `cursor_forgery: 12` and `accounting_equation: 0` — the second
   green only because the balance sheet at `report_cursor()` was entirely zero. `pg_stat_activity`
   named the cause: a backend on database `spike024arms`, `idle in transaction`, holding xid 15760
   for four minutes, while this book's entries sat at 15777–15782.

   ```
    xmin  | max_entry
   -------+-----------
    15760 |     15782

    pid  |   datname    |        state        | backend_xid | xact_age
   ------+--------------+---------------------+-------------+-----------------
    6042 | spike024arms | idle in transaction |       15760 | 00:03:47.380258
    6045 | spike024arms | active              |       15761 | 00:03:47.354173

       reason     | count
   ---------------+-------
    above_horizon |    12
   ```

   That is **F10, reproduced by accident before it was reproduced on purpose**, on a book written
   entirely by the shipped writer, by a transaction in a database this book has never heard of.
2. **F10 requires opening a long-running transaction in a second database on the same instance.**
   Doing that on port 5433 would have dragged two other agents' horizons back and corrupted their
   measurements — the very effect the finding is about.

So: a private `postgres:18-alpine` container on **port 5455** carries the book and the
per-finding scratch databases, and a second on **port 5456** carries F10's own book plus the
neighbour database whose transaction is held. Nothing on port 5433 was written to, and no
`make up`, `make reset` or `docker compose` command was run. The `spike025` database on port 5433
was created, seeded and left alone; the accidental capture above is the only thing read from it.

---

## The book

Ten accounts, two tenants, one currency, six posted transactions and one pending withdrawal.
`REPRO/00_accounts.sql` opens the register; `REPRO/01_seed_book.sh` writes the transactions through
the shipped writer over HTTP.

**No perimeter type is used, and that is a deliberate constraint on the book rather than a
convenience.** `chart_lint`'s `perimeter_unattested` is an **error** rule and fires for every
`is_perimeter` account carrying posted entries until an attestation feed exists — which no part of
this artefact has yet. A book holding `operating_cash` therefore cannot reach ten zeros, and a
negative control that starts at nine zeros and one red cannot support any of the claims below.
Every `'none'`-scope type is held in a house account and every `per_shard` type is owner-keyed, so
`chart_lint` rules 3, 4 and 5 are quiet by construction rather than by luck.

| tenant | purpose | owner | category |
| --- | --- | --- | --- |
| t1 | `customer_receivable` | co_1 | asset |
| t1 | `customer_wallet` | co_1 | liability |
| t1 | `platform_rev_share_payable` | co_1 | liability |
| t1 | `outbound_transfer_in_transit` | co_1 | liability |
| t1 | `fee_revenue` | house | revenue |
| t1 | `platform_rev_share_expense` | house | expense |
| t1 | `paid_in_capital` | house | equity |
| t1 | `retained_earnings` | house | equity |
| t2 | `customer_receivable` | co_2 | asset |
| t2 | `fee_revenue` | house | revenue |

The transactions, all in August 2026 so that a period close of `2026-08` is available to F2 and F8:

| key | effective | posting | amount |
| --- | --- | --- | --- |
| `fund-1` | 2026-08-02 | `paid_in_capital` → `customer_receivable` | 1,000,000 |
| `fee-1` | 2026-08-05 | `fee_revenue` → `customer_receivable` | 250,000 |
| `wallet-1` | 2026-08-10 | `customer_wallet` → `customer_receivable` | 500,000 |
| `revshare-1` | 2026-08-20 | `platform_rev_share_payable` → `platform_rev_share_expense` | 30,000 |
| `withdraw-1` | 2026-08-25 | `outbound_transfer_in_transit` → `customer_wallet`, **pending** | 50,000 |
| `fee-1` (t2) | 2026-08-05 | `fee_revenue` → `customer_receivable` | 100,000 |

The pending withdrawal is there for the same reason spike 011's clean book carries one: the
journal-to-reports statement is *non-zero on a healthy book that has a hold on it*, and a control
that never exercises a reconciling item cannot show that the item is being subtracted by name.

## The negative control

```
$ psql "$DATABASE_URL" -f REPRO/02_control.sql

       check_name        | breaks
-------------------------+--------
 balance_cache           |      0
 orphan_entries          |      0
 unbalanced_transactions |      0
 cross_scope_mirror      |      0
 journal_to_reports      |      0
 checkpoint_drift        |      0
 close_typing            |      0
 cursor_forgery          |      0
 accounting_equation     |      0
 chart_lint              |      0
(10 rows)

        fs_line        |   side    | amount_minor
-----------------------+-----------+--------------
 cash                  | asset     |            0
 restricted_cash       | asset     |            0
 receivables           | asset     |      1750000
 other_assets          | asset     |            0
 payables              | liability |        30000
 customer_funds        | liability |       500000
 borrowings            | liability |            0
 equity                | equity    |      1000000
 retained_earnings     | equity    |            0
 current_year_earnings | equity    |       220000
(10 rows)

 tenant_id | currency | journal_debits | pending_debits | reported_debits | tb_debits | unexplained_debits
-----------+----------+----------------+----------------+-----------------+-----------+--------------------
 t1        | USD      |        1830000 |          50000 |         1780000 |   1780000 |                  0
 t2        | USD      |         100000 |              0 |          100000 |    100000 |                  0
```

Assets 1,750,000 against liabilities-and-equity 1,750,000, and the 50,000 the journal carries above
the reports is the pending withdrawal, named and subtracted. `openledger reconcile` on this book
prints `book reconciled — 10 checks, 0 breaks` and exits 0.

**The horizon wait is part of the control, not an incidental.** `report_cursor()` is
`pg_snapshot_xmin(pg_current_snapshot())`, so every statement pinned at it reads an all-zero book
until the cluster horizon retires the seed's own entries — and `recon_equation_breaks` returns zero
rows over an all-zero book, which reads **green**. Every script below therefore polls

```sql
SELECT coalesce(max(xact_id) <= pg_snapshot_xmin(pg_current_snapshot()), true) FROM ledger_entries
```

to true before reading anything cursor-pinned, bounded and server-side, exactly as
`crates/e2e/tests/e2e/support/book.rs::wait_for_the_horizon_to_retire_this_book` does. A green that
was produced by a lagged cursor is the shape this spike exists to distrust.

---

## The shape of each reproduction

| # | subject | the state to reach | how it is read |
| --- | --- | --- | --- |
| F1 | `recon_equation_breaks` is an identity | a chart version that misroutes a position *within* its declared side | the face moves, `gap_minor` stays 0, ten checks green |
| F2a | a close with no close row | a genuine `kind='period_close'` sweep and no `ledger_period_closes` row | August reports 0.00 revenue, balance sheet correct, ten green |
| F2b | a revenue transaction labelled `period_close` | a fully valid close row naming a 700,000 fee | revenue vanishes, balance sheet foots, ten green |
| F3 | a NULL cursor | nothing — the clean book, called with `NULL` | the full face at 0.00, balancing, and a green check |
| F4 | `recon_journal_to_reports` does not foot | one entry effective 2226; then an out-of-window debit cancelling an unpresented one | `unexplained ≠ 0` on a correct book; then `= 0` on a broken one |
| F5 | one unpresented type errors the summary | a chart version omitting a type that has posted entries | `SELECT * FROM reconciliation` **raises** |
| F6 | the `numeric` lesson missed in three places | two large legal entries on two stripes of one account | `bigint out of range`, or a constraint that refuses it |
| F7 | the current chart version is open | an `fs_lines` row appended to the current version | the same `(cursor, version)` returns a different face |
| F8 | `computed_at_xid` unbounded above | a close cursor at the top of the `xid8` range, with an honest-cursor control on t2 | `close_disclosures` permanently empty |
| F9 | a wrong tenant is answered with silence | a reader scoped to t1 asking for t2 | zero rows, where a bad chart version raises |
| F10 | the cursor check's justification | a held transaction in a second database on the same instance | `above_horizon` on an honest book |

Three of these needed a state the schema refuses, and the refusal is the result: F1's proposed
cross-side routing, F7's proposed re-pointing of an existing presentation row, and the parts of F6
that no constraint permits. Those are recorded as refutations of the mechanism with the finding's
substance re-tested by the route that is open.

## The files

```
REPRO/00_accounts.sql   the account register
REPRO/01_seed_book.sh   the six transactions, through the shipped writer over HTTP
REPRO/02_control.sql    the negative control: ten checks, the two statements, the two statements' inputs
REPRO/reset.sh          restore the control book from the TEMPLATE copy
REPRO/F1_*.sql  F1b_*.sql  F2a_*.sql  F2b_*.sql  F3_*.sql  F4_*.sql
REPRO/F5_*.sql  F6_*.sql   F7_*.sql   F8_*.sql   F9_*.sql   F10_*.sh
```

Each `F*` script is self-contained against a freshly restored control book. `FINDINGS.md` carries
the verdicts and the pasted output; `FIX-NOTES.md` carries the fix shape and its cost for every
finding that reproduced.

## Rebuilding the environment

The two containers were removed after the runs, so the machine is as it was found. To rebuild the
book (from the repository root):

```sh
docker run -d --name spike025-db -e POSTGRES_USER=openledger -e POSTGRES_PASSWORD=openledger   -e POSTGRES_DB=openledger -p 5455:5432 postgres:18-alpine
until docker exec spike025-db pg_isready -U openledger -q; do :; done

BASE=postgres://openledger:openledger@localhost:5455
psql "$BASE/postgres?sslmode=disable" -c 'CREATE DATABASE spike025;'

cargo build -p openledger
export DATABASE_URL="$BASE/spike025?sslmode=disable"      # never --database-url; it is visible in ps
./target/debug/openledger migrate
psql "$DATABASE_URL" --single-transaction -q -f schema/chart.sql
psql "$DATABASE_URL" -q -f spikes/025-reporting-layer-defects/REPRO/00_accounts.sql
BIND=127.0.0.1:8125 ./spikes/025-reporting-layer-defects/REPRO/01_seed_book.sh
psql "$DATABASE_URL" -f spikes/025-reporting-layer-defects/REPRO/02_control.sql

# the exact restore point every reproduction starts from
psql "$BASE/postgres?sslmode=disable" -c 'CREATE DATABASE spike025_clean TEMPLATE spike025;'
```

Then, per finding: `BASE=$BASE REPRO/reset.sh` followed by
`psql "$DATABASE_URL" -f REPRO/F<n>_*.sql`. F6 and F9 carry their own `F6_run.sh` / `F9_run.sh` and
expect their own databases (`spike025_f6`, `spike025_f9`), each a `TEMPLATE spike025_clean` copy. F10
needs a **second instance** and rebuilds its own book; its script header carries the commands.
