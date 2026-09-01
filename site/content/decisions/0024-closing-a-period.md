# 0024 — A period is defined and closed over HTTP, and the close is one transaction

**Status:** accepted (ruled 2026-09-01). It builds [0011](/decisions/0011-period-close-and-report-axes) §2,
which specified the close and was never implemented, under
[0020](/decisions/0020-checkpoint-on-the-report-path)'s corrected checkpoint rules.
**Evidence:** `ledger_periods`, `ledger_period_closes` and `ledger_period_balances` in
`migrations/00001_baseline.sql`; the reader and the identity admission in
`migrations/00004_the_report_path_reads_the_checkpoint.sql`.

## The decision

**`POST /v1/periods` defines a period; `POST /v1/periods/{code}/close` closes one, for one
currency.** The roadmap's settled framing says *"the core ships a period close, statements, and
checkpoints together"* — the statements shipped with M5 and the checkpoint reader shipped with
[0020](/decisions/0020-checkpoint-on-the-report-path), while **nothing in Rust has ever written a
close**. Only the e2e fixtures did, by hand, in SQL. This is the third leg.

**Defining a period is the same shape as opening an account** ([0021](/decisions/0021-accounts-over-http)):
an accepted operation that moves no money, so it claims an idempotency key and writes a
`ledger_events` row in the same database transaction as the `ledger_periods` insert, and inherits
the replay contract unchanged. The body is `code`, `starts_at`, `ends_at` and `tz`.

**The zone is stored and never re-resolved.** [0011](/decisions/0011-period-close-and-report-axes) §5
is emphatic and measured: a local midnight is not always a real instant (Brazil's DST transitions
took effect at 00:00, so `2018-11-04 00:00` in `America/Sao_Paulo` never happened and PostgreSQL
silently resolves it to 01:00), and the same local date resolves *an hour apart* across a tzdata
update. So the caller sends **resolved instants** plus the zone as provenance; the API never accepts
a local date and a zone and resolves them itself. `ck_periods__tz_known` refuses an unrecognised
zone, and `ex_periods__no_overlap` — a GiST exclusion over `tstzrange` — refuses a period that
overlaps another on the same tenant, which is a constraint the API surfaces rather than re-checks.

**A close is per `(tenant, period, currency)`, because `pk_closes` is.** Closing a book that holds
three currencies is three calls. This is not a convenience gap: a close computes and stores a
per-currency position, and one call that swept three currencies would either succeed partially or
need a transaction spanning three independent closes.

**The close is one database transaction, and its order is load-bearing.** In this order, which
[0020](/decisions/0020-checkpoint-on-the-report-path) proved:

1. claim the idempotency key — deterministic, `tenant:close:period:currency`, exactly as
   [0011](/decisions/0011-period-close-and-report-axes) §2 specifies, so `uq_events__idempotency`
   refuses the second attempt on its own;
2. write the `period_close` transaction: **one posting per temporary account** (revenue and expense)
   with `retained_earnings` as the destination, `effective_at = ends_at - 1 microsecond` — the last
   *representable* instant inside a half-open period, which `timestamptz`'s microsecond resolution
   makes exact rather than a `23:59:59` approximation;
3. write the `ledger_period_closes` row naming that transaction;
4. **then** write the checkpoint — `ledger_period_balances`, one row per account — because
   [0020](/decisions/0020-checkpoint-on-the-report-path) showed identity admission is inert if the
   checkpoint is computed before the closing entries exist. Its bound is
   `xact_id < C OR transaction_id = <this close>`, the same predicate `recon_checkpoint_breaks`
   recomputes with, so the two agree by construction rather than by coincidence.

**A period with nothing to sweep closes cleanly, and that is a fix already in the schema.** Migration
`00004` carved out the entryless close in `recon_transaction_breaks` precisely because
[0020](/decisions/0020-checkpoint-on-the-report-path) found that a period with no revenue or expense
could not be closed without breaking the sweep. The writer relies on that carve-out rather than
refusing the case.

**No Income Summary account**, per [0011](/decisions/0011-period-close-and-report-axes) §2: temporary
accounts close **directly** to `retained_earnings`. The middle account is a manual-bookkeeping
checksum, and this transaction is balanced by construction.

**The refusals**, each a constraint or a state the schema already holds:

| `type` | when |
| --- | --- |
| `period_unknown` | `{code}` names no period on this tenant |
| `period_already_closed` | `pk_closes` — this period and currency are closed, and a close happens once |
| `period_overlaps` | `ex_periods__no_overlap`, on definition |
| `period_zone_unknown` | `ck_periods__tz_known` |
| `retained_earnings_unknown` | the tenant holds no `retained_earnings` house account in that currency, so the sweep has no destination |
| `invalid_request` | `ends_at` not after `starts_at`, a malformed instant, a bad currency |
| `idempotency_key_reused` | the shared spine, as everywhere else |

## What we considered

| | Why not |
| --- | --- |
| **Leaving the close to SQL** (the status quo) | It is the last operation with no API, and the roadmap's own framing says the close ships *with* the statements and the checkpoint. Two of the three shipped without it. |
| **A `--close` CLI subcommand instead of a route** | `migrate` and `reconcile` are commands because they are *operational* — a pre-deploy job and a scheduled sweep. A close is a **posting**, made by whoever runs the books, and postings are HTTP here. |
| **Closing every currency in one call** | `pk_closes` is per currency, so it would be N closes behind one response — partial success, or a transaction spanning independent closes. |
| **Accepting a local date and a zone, and resolving them** | Measured to be wrong twice over: a local midnight that never happened resolves silently to another instant, and the same pair resolves an hour apart after a tzdata update. The period stores resolved instants; the zone is provenance. |
| **Computing the checkpoint before writing the closing entries** | Identity admission is inert then — the entries it must admit do not exist yet. Proven in [spike 020](/spikes/020-checkpoint-on-the-report-path). |
| **Refusing to close a period with nothing to sweep** | `00004` already carved out the entryless close for exactly this. Refusing would make a quiet month an error. |
| **An Income Summary account** | A manual-bookkeeping checksum. This transaction is balanced by construction. |

## What it costs

- **A close blocks behind any open writer on an account it sweeps**, because it upserts the balance
  cache of every one of them — recorded as a defect in
  [0020](/decisions/0020-checkpoint-on-the-report-path) and not fixed here. On a busy book the close
  wants a quiet moment, and nothing in the API says so.
- **The close is linear in account count and additive per currency** — ~49 s and 1,000,003 checkpoint
  rows for a million accounts in one currency, with the **write** dominating at ~96%
  ([spike 016](/spikes/016-close-cost-at-scale)). An HTTP request is a poor shape for that, and the
  read pool's timeout does not apply to it because it is a write. **A deployment at that size wants
  the close as a job, not a request**, and this decision does not provide one.
- **Nothing stops closing a period whose `ends_at` is in the future.** A close is an ordinary posting
  and the schema permits it; refusing it would need a clock the writer does not have
  ([0006](/decisions/0006-time-and-as-of): `recorded_at` is the database's, `effective_at` is the
  caller's, and nothing invents a third). `close_disclosures` enumerates late arrivals either way.
- **`cursor_precedes_close` remains a known false positive** for a deployment storing
  `pg_snapshot_xmin` as its close cursor
  ([0020](/decisions/0020-checkpoint-on-the-report-path)). This writer does not store that value, so
  it does not trip it — but the predicate is still wrong for one that would.
- **Reversing a close is refused** and stays refused ([0016](/decisions/0016-pending-to-posted)):
  un-closing would contradict a standing checkpoint. A close is corrected by a later posting, like
  everything else here.
