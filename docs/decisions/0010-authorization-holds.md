# 0010 — A hold is a SUM over an append-only event log, not a mutable amount

**Status:** accepted
**Date:** 2026-08-25

## The decision

An authorization moves no money and writes no ledger entry — nothing is owed when the terminal beeps,
and the purchase may never clear. But the amount is not spendable either, and the next authorization
has about a second to decide whether it fits. So a hold is **derived from an immutable log of
processor messages**, never stored as a running amount anyone updates. The vocabulary, since every
sentence below uses it:

| | |
| --- | --- |
| `card_auth_events` | One row per processor message — authorization, incremental, clearing, reversal, advice, expiry_reversal. Append-only; a correction is a new row. |
| `amount_delta` | The normalised signed amount on that row. **Always a delta**, never a wire value; the adapter converts. |
| `group_key` | Identifies one authorization's family of messages. **Not sent by the processor** — it is our inference about which authorization a clearing belongs to. |
| `card_auth_event_group` | Membership: which event belongs to which `group_key`, bitemporally. An assignment is superseded, never updated. |
| `authorized_minor` | Running sum of **increase-side** deltas only. This is what a cumulative restatement restates. |
| `total_minor` | Materialised net sum of every delta in the group — increases minus clearings and reversals. May go negative. |
| `held_minor` | `GREATEST(total_minor, 0)`, and 0 once expired. **The number available credit is computed against.** |
| `total_convention` | `'delta'` or `'total'` — whether this group's increase-side messages carry an increment or a restated cumulative total. Fixed by the first one; mixing is refused. |

**1. Stored amounts are always deltas.** The adapter converts its processor's convention *at the
boundary*, under the group's lock, before the row is written. The derivation is then a plain `SUM` —
commutative, and order-tolerant by construction rather than by timestamp — with two qualifications, both under *Known*: a convention mix, and an `expiry_reversal` racing our own sweep.

**2. Group membership is a separate bitemporal table.** There is deliberately no `group_key` column on
the event. Re-grouping is routine — a clearing arrives unmatched and is attached later, a mis-grouped
increment is split out — and storing the inference on the event would force that correction to
`UPDATE` a row we call immutable.

**3. Expiry is a flag, not an event.** An event carrying `−remaining` would have to read the aggregate
to compute its own amount: a read-modify-write smuggled into an append-only log, and a read does not
commute. The mirror image is the same mistake and shipped once — an `expiry_reversal` carrying
`+remaining` made one 100.00 authorization hold 200.00, still 100.00 after full capture, drift silent
because the log genuinely contained the `+10000`; it now carries **zero**, clearing a flag that never
subtracted. An expired group re-opens on any increase-side message, including a restatement whose delta
is zero, since the restatement itself is the liveness signal; a late clearing does not resurrect it.
`expired_authorized` and `expired_total` snapshot the group at release so the alarm can tell *exposure
added after a release* from *an event merely arriving after one*.

**4. Over-capture clamps to zero and is recorded.** A $1 fuel authorization clearing at $95 must
contribute 0 to available credit, never *raise* it. The clamp maps three conditions onto one 0 —
legitimate over-capture, an adapter feeding a total into a delta column, a mis-grouped clearing — so
`overcaptured_at` and `low_water_minor` make it an alarmable state rather than a value swallowed at
`SELECT` time.

**5. The per-group total is materialised**, because the authorization deadline is about a second end to
end and summing an unbounded log is unbounded work. *That is an argument, not a measurement*: spike 006
says the derivation "has not been benchmarked here", and the cost of the alternative is unmeasured.

Two views watch it. `card_auth_unmatched` is the review queue: an event with no live assignment is
unmatched *by definition*, so the queue cannot drift from the data it describes. `card_hold_drift` is
the alarm — a materialised total disagreeing with its log, a log with no materialised total, a group
mixing conventions, exposure added after expiry, a group under water with un-posted decreases.
[`schema/schema.sql`](../../schema/schema.sql) is the implementation; spikes
[006](../../spikes/006-append-only-holds/README.md) and
[008](../../spikes/008-processor-hold-semantics/README.md) are the research.

## Why

**A clearing has no reliable key back to its authorization.** Network identifiers (ARN, RRN) do not
agree across messages, so grouping is an *inference*, and inferences get corrected. Highnote: *"Do not
rely solely on network reference IDs to correlate authorization and clearing events. Network
identifiers are not guaranteed to be consistent across the lifecycle of a transaction"* — and they ship
an unmatched queue rather than guessing, with out-of-order clearing a routine sequence in their message
table, not an edge case. *([spike 008](../../spikes/008-processor-hold-semantics/README.md) carries the URL; re-fetched and matched verbatim.)*

**Processors disagree on delta versus cumulative total, with no norm to fall back on.** Adyen and
Pismo send deltas; Lithic, Galileo, Column and Unit send restated totals; Treasury Prime sends
neither, releasing the old hold and holding at the new total. **Marqeta's own reference contradicts
itself on one page**, calling `authorization.advice` *"Decreases the amount"* in two tables and
*"Replaces the amount"* in a third. Keeping `raw_amount` and `raw_is_total` verbatim beside the
normalised delta is the only defensible response. *(Spike 008 read thirteen processors' published
references; six of fifty-one pages carry a link — treat the rest as unverified.)*

**Messages arrive out of order, are re-delivered, and are sometimes never sent** — merchants are supposed
to reverse what they do not capture and many do not. Order tolerance is what lets a SUM be the answer.

**Two divergences from the field, both deliberate.** About half the systems surveyed write a durable,
balance-affecting row at authorization time, so *"an authorization writes no ledger entry" is a product
choice, not a domain law* — the unqualified claim is that **an authorization posts nothing to a balance
anyone is owed against.** And **six of the thirteen model expiry as a release event** where property 3
uses a flag — Pismo and Column document no expiry release at all, and TigerBeetle expires as an engine
operation, so this is a minority position rather than a solitary one.

## Alternatives

| | Why not |
| --- | --- |
| **A mutable `holds` row with a running amount** | The obvious model. It needs a reliable clearing→authorization key that does not exist, and every correction becomes an `UPDATE` to the number the authorization decision reads. |
| **Store both conventions, resolve absolutes by `occurred_at`** | The earlier design. Processor timestamps are second-granularity and unordered, so ties fell through to insertion order: the same facts produced different holds depending on which webhook's TCP connection finished first, and it silently **under-reserved credit**. Order-dependence does not vanish here — it moves to ingest, where a lock can serialise it. That is the trade. |
| **Expiry as an event carrying `−remaining`** | Field-standard, and rejected by property 3: it cannot commute, and the mirror image of the same mistake has already cost us a doubled hold. |
| **Derive a restatement's delta from `total_minor`** | Wrong base — the net total also carries clearings and reversals — and the same three messages then produced four holds across six orderings, with no error and no drift, falsifying the headline claim of this file. Hence `authorized_minor`. |

## What it costs

| | |
| --- | --- |
| **Serialised per group** | Ingest, repair and re-grouping each take the group's lock — contention is per authorization, which is not a hot row. Re-grouping locks the event row first, then both groups in `group_key` order, materialising the destination at its place in that order. |
| **A foreign key takes a lock on your behalf, in an order you did not choose** | The membership insert takes an implicit `FOR KEY SHARE` on the event through `fk_event_group__event`, so a lock-ordering argument counting only the locks written in the function is not an argument. This is the most expensive trap here. Every symptom was a deadlock, and deadlocks abort cleanly: they cost availability, not correctness. An advisory lock over the message key space is **not** the fix — it produced 6 deadlocks in 6 trials where the unmodified code produced 0, because a lock taken before the natural one adds an ordering rather than removing one. |
| **Mixing conventions in one group is irreconcilable** | `{authorization +100.00 as a delta, incremental 120.00 as a total}` yields 120.00 in one arrival order and 220.00 in the other, because a total arriving before the delta it restates carries nothing saying it already includes it. Only refusing the mix can fix it. Within one convention, deltas commute and totals resolve to the maximum seen. An adapter should prefer an explicit total field over inferring the convention — Stripe, Increase, Galileo and Treasury Prime each send **both** in one message. |
| **A cumulative total cannot be re-grouped *mid-group*** | Its stored delta is relative to the source group's base at the moment it arrived, and that base is not recoverable. **The blanket refusal is over-broad**: `raw_amount` and `raw_is_total` are kept verbatim on the event precisely so the wire value survives normalisation, so splitting a totals event to a *new, empty* group recovers exactly — `delta = raw_amount − 0`. The refusal should be narrowed to a destination that already has a base. See the first *Known* entry below, which the current rule makes uncorrectable. |
| **A group row cannot be deleted** | `expired_at`, its snapshots and `low_water_minor` are not in the log, so rebuilding one invents them: an expired group came back live with its post-expiry alarm permanently disarmed. Materialisations may be rewritten; state that is not a materialisation may not be removed. |
| **A group carries one currency, with no default** | Summing minor units across denominations reported 100.00 USD + 50.00 EUR as "held 15000" — the vacuity [0009](./0009-chart-and-completeness.md) removed from the accounting equation, sitting where the number *is* available credit. |
| **Three things the model cannot express** | A **single-message transaction** (Lithic's `FINANCIAL_AUTHORIZATION`, Marqeta's `auth_plus_capture`; PIN-debit or ATM volume breaks the model). An **end-of-sequence indicator**, which several processors send and which ends a group without waiting for expiry. And **a hold that differs from the authorized amount** (Stripe holds $100 on a $1 fuel check): there is no independent hold field — `held_minor` is `GREATEST(total_minor, 0)`, and `total_minor` is the *net* of every delta, so it cannot be set apart from what the messages say. Each needs a design decision. |
| **Expiry windows are policy, not protocol** | Our release timer is not the network's clearing deadline — that clock drives dispute eligibility and does not extend on an increment. Visa Core Rules (public PDF, 18 Apr 2026) §5.7.3.5 Table 5-12: card-present **5 calendar days**, card-absent 10, extended/estimated 30, from *"the date of a valid Authorization"*; rule **0031022**: *"An Incremental Authorization Request does not extend the processing timeframes in Table 5-12."* Region-variable, so it is policy input, not a constant to hard-code. |
| **STIP and fuzzy matching are unmodelled** | Stand-in processing produces authorizations we never saw. The schema records *which* method assigned a group (`lifecycle_id`, `rrn`, `fuzzy`, `manual`) and keeps the trail, but the matcher is not built. |

The ledger itself takes no dependency on any of this: holds are a product-layer concern built on the
core, and the core does not know they exist.

## Known, and not fixed

**A cumulative-total group cannot be corrected once something is mis-grouped into it, and neither
watcher can see it.** A second, genuinely different authorization fuzzy-matched into an existing
`total_convention = 'total'` group computes its delta as `wire − authorized_minor`. For an equal
amount that is **zero**. Reproduced against the schema:

```
 processor_msg_id |     kind      | wire  | raw_is_total | stored_delta
 msg-1            | authorization | 10000 | t            |        10000
 msg-2            | authorization | 10000 | t            |            0

 TRUE live exposure  20000        REPORTED held_minor  10000
 card_hold_drift: 0 rows          card_auth_unmatched: 0 rows
```

Every watcher is blind, and each for a reason worth stating. `card_hold_drift` is silent because the
log **genuinely contains the zero** — the materialisation is perfectly faithful to a log that has
already lost the money. The convention disjunct is silent because `any_total`/`any_delta` filter
`amount_delta <> 0`, so a zero-delta event is excluded from the one check that inspects it. The
review queue is silent because the event *has* a live membership. And re-grouping it out is refused
by the rule above.

The loss is not $100 — it is the destination's `authorized_minor` at match time, so it is bounded
only by what the group had already accumulated. A *smaller* second authorization computes a negative
delta and dies on `ck_auth_events__sign`: **the safe case errors, the dangerous case is silent.**

The narrowing in *What it costs* is the start of a fix — splitting to a new empty group is exactly
recoverable from `raw_amount`. What is still missing is anything that *notices*.

**`held_minor` is order-dependent when an `expiry_reversal` races our own sweep, and the
under-reserving order is the likely one.** An `expiry_reversal` carries a zero delta because expiry
never subtracted anything. But the expiry flag is set by *our* sweep, on a clock the log does not
order. Same two facts, two orders:

```
 group | live_exposure | reported_held
 G-A   |         10000 |         10000    sweep first, then expiry_reversal
 G-B   |         10000 |             0    expiry_reversal first, then sweep
```

An early-arriving reversal is a no-op clearing a flag that is not set, and it leaves nothing behind:
an `expiry_reversal` is deliberately **not** increase-side, so it cannot re-open the group the way a
zero-delta restatement can. The sweep then expires against live exposure and `held_minor` goes to 0.

**Early arrival is the expected case, not an edge case** — our hold is typically 7 days where Visa's
card-present window is 5, so processor-side expiry activity lands *inside* our window by design.

This **qualifies property 1**. The `SUM` is commutative; `held_minor` is the `SUM` gated by a flag
set out-of-band, and that gate is not ordered by the log. Property 3's "expiry is a flag" is where
the order-dependence enters. The fix is a design decision — record that a reversal was seen in a form
the sweep must consult, or make expiry itself an event and accept the read-modify-write — and neither
is taken here.


Recorded rather than closed, because each needs a design decision rather than a guard:

- **A cumulative restatement that DECREASES is refused, and the refusal is sticky.** `authorized_minor`
  only rises, so a processor restating a lower subtotal after a partial reversal is refused as
  out-of-order, and the group can never accept a total below its high-water mark again. Measured: 60.00
  held against 90.00 real. Representing a decreasing authorized subtotal is the missing piece.
- **A refused convention mix leaves an order-dependent number in service.** Only the *second* message is
  refused; the first is already applied, so the same two messages leave 50.00 or 100.00 held depending on
  arrival order. If refusing the mix is the answer, the *group* should be quarantined, not the message.
- **The over-reversal alarm self-heals, so a real under-reservation ends silent.** Drift reports a group
  whose bloodless decreases — reversals and negative advice, neither of which posts to the ledger —
  exceed its increases. It fires in the *precursor* state and goes false the instant the next genuine
  increase is absorbed by the negative residue, because that increase raises the compared quantity by
  exactly what it swallowed. Measured: two reversals against one authorization, then an ordinary
  incremental — **100.00 live, 0.00 held, 0.00 posted, drift back to zero rows.** Latching it on
  `low_water_minor` looks like the fix and is not: a group whose messages arrive decrease-first
  legitimately dips below any clearing so far. **The log cannot decide the question** — a reversal
  arriving before its authorization and one that should never have been sent are the same three columns,
  so deciding needs the reversal-to-authorization linkage this ADR does not model.
- **The clamp hides state, not just presentation.** `held_minor` clamps the report; nothing clamps
  `total_minor`. Authorize 100.00, clear 100.00, then a spurious reversal of 100.00 leaves the group at
  −100.00; a genuine 100.00 incremental nets against that residue and the group reports 0 held against
  100.00 of live un-cleared exposure. **Detected, not prevented**: drift's `total_minor < 0 AND
  bloodless_decreases > 0` disjunct fires when the group goes under water, then self-heals as above. An
  over-capture on a *clearing* is a different case and is correct — a clearing has posted, so exposure
  is posted + held.
- **An emptied group pins its currency forever.** Group rows cannot be deleted, so once every event is
  moved out the `currency` is permanent, and a later message for that key in another currency is refused
  and never stored. Reusing one inferred `group_key` across currencies is not a realistic domain event,
  so this is recorded rather than guarded.
- **Re-grouping can deadlock against a multi-group adapter transaction.** It sorts its two locks by
  `group_key`; a single ingest takes its one lock in call order, so a batch touching `ZZZ` then `AAA`
  takes them backwards — 91 deadlocks under mixed load. An ingest cannot sort a lock it does not know
  about, so the fix belongs in a batch API that sorts.
