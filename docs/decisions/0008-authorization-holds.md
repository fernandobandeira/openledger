# 0008 — A hold is a SUM over an append-only event log, and its timers live in the same Postgres

**Status:** accepted
**Evidence:** spikes [006](../../spikes/006-append-only-holds/README.md),
[008](../../spikes/008-processor-hold-semantics/README.md),
[005](../../spikes/005-durable-timers/README.md) and [010](../../spikes/010-go-or-rust/README.md).

## The decision

An authorization moves no money and writes no ledger entry — nothing is owed when the terminal beeps,
and the purchase may never clear. But the amount is not spendable either, and the next authorization
has about a second to decide if it fits. So a hold is **derived from an immutable log of processor
messages**, never a running amount anyone updates.

**The budget, because it is the only latency-bound path in the system.** The network gives roughly
**one second** end to end; the target for our own synchronous work is **p99 under 300 ms**. What runs
inside it is one short transaction: lock the credit line, read the posted balance, sum the live holds,
decide, write the hold row. **The ledger write is not in it** — a clearing is recorded as an event and
posted by a job outside the deadline ([0002](./0002-scaling.md)). Every design choice below that looks
like premature optimization is paying for this number, and **it has never been measured**: spike 010
recorded single-shot wall times of 9.1 ms including connection setup on a laptop-class container,
which is not a p99 and must not be quoted as one. The authorization path needs its own spike.

The vocabulary, since every sentence uses it:

| | |
| --- | --- |
| `card_auth_events` | One row per processor message — authorization, incremental, clearing, reversal, advice, expiry_reversal. Append-only; a correction is a new row. |
| `amount_delta` | The normalised signed amount on that row. **Always a delta**, never a wire value; the adapter converts. |
| `group_key` | Identifies one authorization's family of messages. **Not sent by the processor** — it is our inference about which authorization a clearing belongs to. |
| `card_auth_event_group` | Membership: which event belongs to which `group_key`. System-versioned: `assigned_at` and `superseded_at` are both wall-clock *system* time, not a business axis — the ledger's genuine bitemporal pair is `ledger_transactions (effective_at, recorded_at)` ([0006](./0006-time-and-as-of.md)). An assignment is superseded, never updated. |
| `authorized_minor` | Running sum of **increase-side** deltas only. This is what a cumulative restatement restates. |
| `total_minor` | Materialised net sum of every delta in the group — increases minus clearings and reversals. May go negative. |
| `held_minor` | `GREATEST(total_minor, 0)`, and 0 once expired. **The number available credit is computed against.** |
| `total_convention` | `'delta'` or `'total'` — whether this group's increase-side messages carry an increment or a restated cumulative total. Fixed by the first one; mixing is refused. |

| | |
| --- | --- |
| **1. Stored amounts are always deltas** | The adapter converts its processor's convention *at the boundary*, under the group's lock, before the row is written. The derivation is then a plain `SUM` — commutative, and order-tolerant by construction rather than by timestamp — with two qualifications, both under *Known*: a convention mix, and an `expiry_reversal` racing our own sweep. |
| **2. Group membership is a separate system-versioned table** | There is deliberately no `group_key` column on the event. Re-grouping is routine — a clearing arrives unmatched and is attached later, a mis-grouped increment is split out — and storing the inference on the event would force that correction to `UPDATE` a row we call immutable. |
| **3. Expiry is a flag, not an event** | An event carrying `−remaining` would have to read the aggregate to compute its own amount: a read-modify-write smuggled into an append-only log, and a read does not commute. The mirror image is the same mistake and shipped once — an `expiry_reversal` carrying `+remaining` made one 100.00 authorization hold 200.00, still 100.00 after full capture, drift silent because the log genuinely contained the `+10000`; it now carries **zero**, clearing a flag that never subtracted. An expired group re-opens on any increase-side message, including a restatement whose delta is zero, since the restatement itself is the liveness signal; a late clearing does not resurrect it. `expired_authorized` and `expired_total` snapshot the group at release so the alarm can tell *exposure added after a release* from *an event merely arriving after one*. |
| **4. Over-capture clamps to zero and is recorded** | A $1 fuel authorization clearing at $95 must contribute 0 to available credit, never *raise* it. The clamp maps three conditions onto one 0 — legitimate over-capture, an adapter feeding a total into a delta column, a mis-grouped clearing — so `overcaptured_at` and `low_water_minor` make it an alarmable state rather than a value swallowed at `SELECT` time. |
| **5. The per-group total is materialised** | Because the authorization deadline is about a second end to end and summing an unbounded log is unbounded work. *That is an argument, not a measurement*: spike 006 says the derivation "has not been benchmarked here", and the cost of the alternative is unmeasured. **Two views watch it.** `card_auth_unmatched` is the review queue: an event with no live assignment is unmatched *by definition*, so the queue cannot drift from the data it describes. `card_hold_drift` is the alarm — a materialised total disagreeing with its log, a log with no materialised total, a group mixing conventions, exposure added after expiry, a group under water with un-posted decreases. [`schema/schema.sql`](../../schema/schema.sql) is the implementation. |
| **6. The expiry timer is a job row in our own Postgres. No Temporal.** | Durable timers run inside the application binary, backed by the same database the ledger writes to, and the product layer gets a narrow interface whose **transaction parameter is the point**: `at(tx, kind, key, when, payload)` and `cancel(tx, kind, key)`. The job row commits in the same transaction as the ledger write, so *"the hold row and its expiry timer both exist, or neither"* is a database guarantee rather than a convention. Exactly one driver ships: **`graphile_worker` 0.13.5** (MIT, on `sqlx` 0.9.0). **The ledger core takes no scheduler dependency at all** ([0002](./0002-scaling.md) — every timer belongs to a rail). |

The four properties that matter for the timer, run against a real `ledger_write` table:

```
A. enqueue in tx, ROLLBACK   ledger_write=0  jobs=0        neither row exists
B. enqueue in tx, COMMIT     ledger_write=1  jobs=1        both exist
C. 7-day absolute run_at     run_at=2026-09-02 …
D. idempotent by job key     1 row after 3 enqueues
```

## Why a SUM over a log

**A clearing has no reliable key back to its authorization.** Network identifiers (ARN, RRN) do not
agree across messages, so grouping is an *inference*, and inferences get corrected. Highnote: *"Do not
rely solely on network reference IDs to correlate authorization and clearing events. Network
identifiers are not guaranteed to be consistent across the lifecycle of a transaction"* — and they
ship an unmatched queue rather than guessing, out-of-order clearing being a routine sequence in their
message table. *(Spike 008 has the URL; re-fetched and matched verbatim.)*

**Processors disagree on delta versus cumulative total, with no norm to fall back on.** Adyen and
Pismo send deltas; **Marqeta** says so unambiguously — *"`authorization.incremental` — Increases the
amount of a previous authorization by adding to it **without replacing it**"*. Lithic, Column and Unit
send restated totals. Treasury Prime releases the old hold and re-holds at the new total, neither. And
**Stripe, Increase, Galileo and Treasury Prime each send both in one message** — Galileo puts the
cumulative amount in the primary fields and, in its own words, *"the incremental amount will be
present in the local amount fields"*. Keeping `raw_amount` and `raw_is_total` verbatim beside the
normalised delta is the only defensible response to six conventions with no norm. *(Spike 008 read
thirteen processors' references; six of fifty-one pages carry a link — treat the rest as unverified.)*
And **messages arrive out of order, are re-delivered, and sometimes never arrive** — merchants should
reverse what they do not capture and many do not. Order tolerance is what lets a SUM answer.

**Two divergences from the field, both deliberate.** About half the systems surveyed write a durable,
balance-affecting row at authorization time, so *"an authorization writes no ledger entry" is a
product choice, not a domain law* — the unqualified claim is that **an authorization posts nothing to
a balance anyone is owed against.** And **six of the thirteen model expiry as a release event** where
property 3 uses a flag — Pismo and Column document no expiry release at all, TigerBeetle expires as an
engine operation, so this is a minority position, not a solitary one.

## Why the timer is a job row and not a workflow engine

> Every Temporal, Rails and pricing figure in this section is **unverified** — no fetchable source sits next to it. Treat them as the reasoning that was persuasive at the time, not as evidence.

| | |
| --- | --- |
| **The requirement is durable *scheduling*, not workflow *orchestration*** | The reference product needs timers that survive restarts — a hold expires after ~7 days, an ACH return window closes ~2 banking days after funds land, statements close monthly, disputes have deadlines — and the longest chain in the design is two steps (ACH settles → wait → post). Nothing uses Temporal's distinguishing features: workflow-as-code with replay, signals into running workflows, child workflows, or versioning. |
| **The exactly-once guarantee is already ours** | Temporal delivers exactly-once *effects* as at-least-once execution plus idempotent handlers. [0005](./0005-event-log-and-write-path.md) already requires every handler to be idempotent — that is what the event log is for. Temporal would be a second implementation of a guarantee the ledger already provides. |
| **Temporal cannot enqueue transactionally, and here that decides it** | `StartWorkflow` is a gRPC call to another service and cannot join our transaction — using it means building an outbox, i.e. building a Postgres queue *and then* putting Temporal behind it. The alternative is one row in the transaction we are already committing, which is properties A and B above. |
| **Long timers are harder under Temporal, not easier** | Its own documentation uses our exact shape — sleep on a timer, then run an activity — as the worked example of what breaks: reordering those commands between deploys makes replay non-deterministic. Every deploy during a 7-day hold window becomes a versioning exercise. A job row is inert JSON handed to whatever code is current. |
| **The footprint is disproportionate to 0.05 jobs per second** | Temporal Server is four services (frontend, history, matching, worker) with its own persistence database and migrations, plus a separate visibility store; `numHistoryShards` is fixed at deploy time and changing it requires a cluster rebuild; minor versions must be upgraded sequentially with a schema migration each; RBAC ships **off by default** (four roles behind a `ClaimMapper` and `NewDefaultAuthorizer`, but the default is `noopAuthorizer`) and there is no audit logging — notable for the component driving money-movement timers. Its tested Postgres matrix stops at 16.6; we target 18. And the promise that a small team can drop this into AWS is a claim about *one* managed database. |
| **Precedent** | Rails 8 made Solid Queue — a database-backed queue — its default, moving *away* from Redis, and runs 20M jobs/day for HEY at 37signals. Removing the accessory service was worth more than the specialised backend. |

### The reframe that lowers the bar — and why the scheduler is not correctness-critical

Available credit comes from `card_hold_groups.held_minor`, **not** a timer, so a hold past its
deadline but not yet swept still counts. Every timer here **fails conservatively when late**: a late
expiry under-reports available credit, a late ACH finalization holds a receivable open longer. Nothing
produces a wrong ledger, only a temporarily pessimistic one — the scheduler is an *actuator*, not
correctness-critical. A reconciliation sweep makes a lost job recoverable, not silent:

```sql
SELECT g.tenant_id, g.company_id, g.group_key
FROM card_hold_groups g
WHERE g.expired_at IS NULL AND g.held_minor > 0
  AND EXISTS (
      SELECT 1 FROM card_auth_event_group m
      JOIN card_auth_events e ON e.tenant_id = m.tenant_id AND e.id = m.event_id
      WHERE m.tenant_id = g.tenant_id AND m.group_key = g.group_key
        AND m.superseded_at IS NULL
        AND e.hold_expires_at < now());
```

`ix_hold_groups__held` earns this — `(tenant_id, company_id) WHERE held_minor > 0`. The sweep filters
on the partial predicate with no tenant or company equality: the `WHERE` clause is the useful half.

**The sweep is inert today, and executing it will not tell you that.** It parses and runs, and matches
zero rows on every database this API can build, because nothing writes
`card_auth_events.hold_expires_at` — the column exists, the ingest path has no parameter for it, so
the predicate is NULL everywhere. Making it live means modelling the deadline a processor sends. Until
then that recovery does not exist — which matters less than it sounds (an unswept hold over-reserves)
and more than nothing (the sweep was load-bearing in the argument against a durable scheduler).

## Alternatives

| | Why not |
| --- | --- |
| **A mutable `holds` row with a running amount** | The obvious model. It needs a reliable clearing→authorization key that does not exist, and every correction becomes an `UPDATE` to the number the authorization decision reads. |
| **Store both conventions, resolve absolutes by `occurred_at`** | The earlier design. Processor timestamps are second-granularity and unordered, so ties fell through to insertion order: the same facts produced different holds depending on which webhook's TCP connection finished first, and it silently **under-reserved credit**. Order-dependence does not vanish here — it moves to ingest, where a lock can serialise it. That is the trade. |
| **Expiry as an event carrying `−remaining`** | Field-standard, and rejected by property 3: it cannot commute, and the mirror image of the same mistake has already cost us a doubled hold. |
| **Derive a restatement's delta from `total_minor`** | Wrong base — the net total also carries clearings and reversals — and the same three messages then produced four holds across six orderings, with no error and no drift, falsifying the headline claim of this file. Hence `authorized_minor`. |
| **`underway` instead of `graphile_worker`** | **Verified rejection:** `underway` 0.2.0 pins `sqlx ^0.8.2` and fails against 0.9.0 with `multiple different versions of crate sqlx_postgres in the dependency graph`. |
| **Temporal Cloud** | Not an option for an open-source project: the plan floor is $100/month against an actual consumption cost here of about $14. An OSS user should not have to buy a SaaS subscription to get hold expiry. *(Unverified — no source.)* |
| **Self-hosted Temporal** | The reasons above. The one thing it would buy — a real multi-month workflow engine — is the bet named below. |
| **A scheduler abstraction with two drivers** | An abstraction with one implementation is a seam; with two speculative ones it is a tax. A Temporal driver is *possible* via an outbox — document it, and let the first user who actually runs Temporal contribute it. |

## What it costs

| | |
| --- | --- |
| **Serialised per group** | Ingest, repair and re-grouping each take the group's lock — contention is per authorization, which is not a hot row. Re-grouping locks the event row first, then both groups in `group_key` order, materialising the destination at its place in that order. |
| **A foreign key takes a lock on your behalf, in an order you did not choose** | The membership insert takes an implicit `FOR KEY SHARE` on the event through `fk_event_group__event`, so a lock-ordering argument counting only the locks written in the function is not an argument. This is the most expensive trap here. Every symptom was a deadlock, and deadlocks abort cleanly: they cost availability, not correctness. An advisory lock over the message key space is **not** the fix — it produced 6 deadlocks in 6 trials where the unmodified code produced 0, because a lock taken before the natural one adds an ordering rather than removing one. |
| **Mixing conventions in one group is irreconcilable** | `{authorization +100.00 as a delta, incremental 120.00 as a total}` yields 120.00 in one arrival order and 220.00 in the other, because a total arriving before the delta it restates carries nothing saying it already includes it. Only refusing the mix can fix it. Within one convention, deltas commute and totals resolve to the maximum seen. An adapter should prefer an explicit total field over inferring the convention — Stripe, Increase, Galileo and Treasury Prime each send **both** in one message. |
| **A cumulative total cannot be re-grouped *mid-group*** | Its stored delta is relative to the source group's base at the moment it arrived, and that base is not recoverable. **The blanket refusal is over-broad**: `raw_amount` and `raw_is_total` are kept verbatim on the event precisely so the wire value survives normalisation, so splitting a totals event to a *new, empty* group recovers exactly — `delta = raw_amount − 0`. The refusal should be narrowed to a destination that already has a base. See the first *Known* entry below, which the current rule makes uncorrectable. |
| **The application role cannot take the event lock this ADR requires** | Re-grouping locks the event row first, and `SELECT … FOR UPDATE` on `card_auth_events` needs `UPDATE` privilege — which `openledger_app` is not granted and is explicitly revoked. Verified: `permission denied for table card_auth_events`. Either grant `UPDATE` and lean on the append-only trigger to keep it a lock rather than mutability, or find an ordering that does not need it. Open. |
| **A group row cannot be deleted** | `expired_at`, its snapshots and `low_water_minor` are not in the log, so rebuilding one invents them: an expired group came back live with its post-expiry alarm permanently disarmed. Materialisations may be rewritten; state that is not a materialisation may not be removed. |
| **A group carries one currency, with no default** | Summing minor units across denominations reported 100.00 USD + 50.00 EUR as "held 15000" — the vacuity [0007](./0007-schema-conventions-and-chart.md) removed from the accounting equation, sitting where the number *is* available credit. |
| **Three things the model cannot express** | A **single-message transaction** (Lithic's `FINANCIAL_AUTHORIZATION`, Marqeta's `auth_plus_capture`; PIN-debit or ATM volume breaks the model). An **end-of-sequence indicator**, which several processors send and which ends a group without waiting for expiry. And **a hold that differs from the authorized amount** (Stripe holds $100 on a $1 fuel check): there is no independent hold field — `held_minor` is `GREATEST(total_minor, 0)`, and `total_minor` is the *net* of every delta, so it cannot be set apart from what the messages say. Each needs a design decision. |
| **Expiry windows are policy, not protocol** | Our release timer is not the network's clearing deadline — that clock drives dispute eligibility and does not extend on an increment. Visa Core Rules ([public PDF](https://usa.visa.com/dam/VCOM/download/about-visa/visa-rules-public.pdf), 18 Apr 2026) §5.7.3.5 Table 5-12: card-present **5 calendar days**; card-absent **10**, or **30** with the extended-authorization indicator; and with the *estimated* indicator **30** for cruise line, lodging and vehicle rental but **10** for the other estimated categories, from *"the date of a valid Authorization"*; rule **0031022**: *"An Incremental Authorization Request does not extend the processing timeframes in Table 5-12, General Approval Response Validity Timeframes and Table 5-13, Country-Specific Approval Response Validity Timeframe Requirements."* Region-variable, so it is policy input, not a constant to hard-code. |
| **STIP and fuzzy matching are unmodelled** | Stand-in processing produces authorizations we never saw. The schema records *which* method assigned a group (`lifecycle_id`, `rrn`, `fuzzy`, `manual`) and keeps the trail, but the matcher is not built. |
| **Statement close is a self-rescheduling one-shot job**, not a periodic job | Per-customer timezones make it one anyway. |
| **We give up one ergonomic** | River's `UniqueSkippedAsDuplicate` reports whether an enqueue was deduplicated; `graphile_worker`'s job-key idempotency collapses the duplicate silently (property D above). Nothing else differs between them on the four properties tested. |
| **The dispute bet** | Four of the five timers are genuinely one-shot. **Disputes are not** — a real chargeback lifecycle is a multi-month state machine (filed, representment, pre-arbitration, arbitration, ruling) with external events arriving early, late, or never, and human steps between: exactly the shape Temporal exists for. If dispute handling grows into it, migrating means moving live in-flight state across a 120-day window during which both systems are authoritative. We take the bet because a hand-rolled state machine over a `disputes` table with deadline-driven jobs is boring, well-understood, and **auditable** — a reviewer or an actual auditor can read a table and a transition function, where reconstructing a dispute from a Temporal event history is strictly harder — and because the risk is confined to the product layer, which [0002](./0002-scaling.md) keeps a plug-in rather than a fork. **The ledger core takes no dependency on any of this**: holds are a product-layer concern built on the core, the core does not know they exist, and it touches a scheduler either way, never. |

> **The concurrency figures below — 6-of-6, 91 under mixed load, 720 permutations — came from the PL/pgSQL implementation and its test suite, both deleted by [0004](./0004-where-logic-lives.md). Nothing in this tree reproduces them.** They are kept because the *class* they describe is a design constraint; the counts are not re-checkable.

## Known, and not fixed

**A cumulative-total group cannot be corrected once something is mis-grouped in, and neither watcher
can see it.** A second, genuinely different authorization fuzzy-matched into a `total_convention =
'total'` group gets delta `wire − authorized_minor` — for an equal amount, **zero**. Reproduced:

```
 processor_msg_id |     kind      | wire  | raw_is_total | stored_delta
 msg-1            | authorization | 10000 | t            |        10000
 msg-2            | authorization | 10000 | t            |            0

 TRUE live exposure  20000        REPORTED held_minor  10000
 card_hold_drift: 0 rows          card_auth_unmatched: 0 rows
```

Every watcher is blind, each for its own reason. `card_hold_drift` is silent because the log
**genuinely contains the zero** — the materialisation is faithful to a log that has already lost the
money. The convention disjunct is silent because **there is no convention mix to find**: a totals
message went into a totals group, so `any_total` is true, `any_delta` false, and the stored convention
matches the log. (`any_total`/`any_delta` are `bool_or`, so the `amount_delta <> 0` filter changes
nothing either way — an earlier version blamed that filter, which would send a fixer at a filter whose
removal fixes nothing.) The review queue is silent because the event *has* a live membership, and
re-grouping it out is refused by the rule above. The loss is not $100 — it is the destination's
`authorized_minor` at match time, bounded only by what the group had accumulated. A *smaller* second
authorization computes a negative delta and dies on `ck_auth_events__sign`: **the safe case errors,
the dangerous case is silent.** The narrowing in *What it costs* starts a fix — splitting to a new
empty group is exactly recoverable from `raw_amount`. What is missing is anything that *notices*.

**`held_minor` is order-dependent when an `expiry_reversal` races our own sweep, and the
under-reserving order is the likely one.** An `expiry_reversal` carries a zero delta because expiry
never subtracted. But the expiry flag is set by *our* sweep, on a clock the log cannot order:

```
 group | live_exposure | reported_held
 G-A   |         10000 |         10000    sweep first, then expiry_reversal
 G-B   |         10000 |             0    expiry_reversal first, then sweep
```

An early-arriving reversal is a no-op clearing a flag that is not set, and it leaves nothing behind:
an `expiry_reversal` is deliberately **not** increase-side, so it cannot re-open the group the way a
zero-delta restatement can. The sweep then expires against live exposure and `held_minor` goes to 0.
**How often this happens is unknown, and the earlier claim that it is "the expected case" was
unsupported.** It reasoned from Visa's Table 5-12 window being shorter than our hold — but that table
is the *acquirer's clearing-submission* deadline, which this same ADR insists is a different clock.
Worse, every expiry-time message [spike 008](../../spikes/008-processor-hold-semantics/README.md)
documents is a **release**, not an un-expiry, so nothing here establishes that an `expiry_reversal` is
even a message a processor sends: **the wire event this kind maps to is unidentified.** This
**qualifies property 1**: the `SUM` is commutative, but `held_minor` is that `SUM` gated by a flag set
out-of-band, and property 3's "expiry is a flag" is where the order-dependence enters. The fix is a
design decision — record that a reversal was seen in a form the sweep must consult, or make expiry
itself an event and accept the read-modify-write — and neither is taken here.

Recorded rather than closed, because each needs a design decision rather than a guard:

| | |
| --- | --- |
| **A cumulative restatement that DECREASES is refused, and the refusal is sticky** | `authorized_minor` only rises, so a processor restating a lower subtotal after a partial reversal is refused as out-of-order, and the group can never accept a total below its high-water mark again. Measured: 60.00 held against 90.00 real. Representing a decreasing authorized subtotal is the missing piece. |
| **A refused convention mix leaves an order-dependent number in service** | Only the *second* message is refused; the first is already applied, so the same two messages leave 50.00 or 100.00 held depending on arrival order. If refusing the mix is the answer, the *group* should be quarantined, not the message. |
| **The over-reversal alarm self-heals, so a real under-reservation ends silent** | Drift reports a group whose bloodless decreases — reversals and negative advice, neither of which posts to the ledger — exceed its increases. It fires in the *precursor* state and goes false the instant the next genuine increase is absorbed by the negative residue, because that increase raises the compared quantity by exactly what it swallowed. Measured: two reversals against one authorization, then an ordinary incremental — **100.00 live, 0.00 held, 0.00 posted, drift back to zero rows.** Latching it on `low_water_minor` looks like the fix and is not: a group whose messages arrive decrease-first legitimately dips below any clearing so far. **The log cannot decide the question** — a reversal arriving before its authorization and one that should never have been sent are the same three columns, so deciding needs the reversal-to-authorization linkage this ADR does not model. |
| **The clamp hides state, not just presentation** | `held_minor` clamps the report; nothing clamps `total_minor`. Authorize 100.00, clear 100.00, then a spurious reversal of 100.00 leaves the group at −100.00; a genuine 100.00 incremental nets against that residue and the group reports 0 held against 100.00 of live un-cleared exposure. **Detected, not prevented**: drift's `total_minor < 0 AND bloodless_decreases > 0` disjunct fires when the group goes under water, then self-heals as above. An over-capture on a *clearing* is a different case and is correct — a clearing has posted, so exposure is posted + held. |
| **An emptied group pins its currency forever** | Group rows cannot be deleted, so once every event is moved out the `currency` is permanent, and a later message for that key in another currency is refused and never stored. Reusing one inferred `group_key` across currencies is not a realistic domain event, so this is recorded rather than guarded. |
| **Re-grouping can deadlock against a multi-group adapter transaction** | It sorts its two locks by `group_key`; a single ingest takes its one lock in call order, so a batch touching `ZZZ` then `AAA` takes them backwards — 91 deadlocks under mixed load. An ingest cannot sort a lock it does not know about, so the fix belongs in a batch API that sorts. |
