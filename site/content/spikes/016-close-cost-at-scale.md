# Spike 016 — What does a period close cost at a million accounts, and does the checkpoint pay for itself?

**Status:** closed. **The close is linear in account count and per currency (~49 s / 1,000,003 rows /
135 MB for 1 M accounts, one currency); the WRITE dominates (~96%), not the aggregation (~4%); and the
checkpoint's read benefit is real but not wired into the report path.** Closes the decision log's
"close cost unmeasured" row. Feeds [ADR-0011](/decisions/0011-period-close-and-report-axes) and roadmap
[M5](/roadmap#m5--bitemporal-reads).

**Question.** [ADR-0011](/decisions/0011-period-close-and-report-axes) writes the period close as one
`INSERT … SELECT` per currency over every account, and claims a 45–49× as-of read benefit from the
`ledger_period_balances` checkpoint. Two things were unmeasured: what the close *costs* on a wide book,
and whether the shipped statement functions actually *use* the checkpoint. The deliverables are in the
repository at `spikes/020-close-cost-at-scale/` (`run.sh`, the SQL, `transcript.txt`). Localhost PG 18 —
**shape, not a benchmark.**

## The answers

**The close is linear in account count and additive per currency.** Closing **1,000,000 accounts in one
currency took ~49 s** and wrote **1,000,003 checkpoint rows / 135 MB** (the `ledger_period_closes` row is
48 kB). Three currencies is three closes, additively — the close is per `(tenant, currency)`.

**The WRITE dominates, not the aggregation — which inverts ADR-0011's framing.** The `INSERT … SELECT`'s
own aggregation scan runs in **~2 s** on the million-account book (`EXPLAIN ANALYZE`), i.e. **~4%** of
the ~49 s; the remaining **~96%** is the checkpoint *write* — one row per account plus primary-key and
foreign-key maintenance on `ledger_period_balances`. ADR-0011 framed the cost as the SELECT; the
measurement says it is the write. What it wants before anything else is **partitioning the checkpoint by
period**.

**The checkpoint has no reader on the report path — so the 45–49× benefit is real but unrealized.** A
static check over `pg_get_functiondef` shows `balance_sheet_at`, `income_statement_for` and
`trial_balance_at` **never reference `ledger_period_balances`**; the checkpoint's *only* reader is
`recon_checkpoint_breaks`. So the shipped as-of path scans `ledger_entries` from inception. The benefit
itself reproduces — a query that *does* read the last period's checkpoint plus tails is **~40–230× faster
at a close boundary** than the from-inception aggregate on a million-entry book — but nothing on the
report path takes it. Wiring it in is roadmap [M5](/roadmap#m5--bitemporal-reads).

**And `recon_checkpoint_breaks` is O(entries × closes) — super-linear.** It re-aggregates the whole
prefix once per close, so its cost grows **1 : 3.2 : 5.8 : 8.2** over 3 / 6 / 9 / 12 closes, confirming
the earlier adversary finding. Bounding the per-close prefix scan is part of the same M5 work.

## A stale-helper note

Spike 020 also found that the **spike-014 period-close helper wrote the checkpoint `input`/`output`
backwards** relative to the shipped baseline's convention (the baseline and `recon_checkpoint_breaks`
take `input` = debit legs, `output` = credit legs, posted only). The **baseline is correct**; the spike
helper was the superseded one, and the scaling harness here follows the baseline convention.
