# 0010 — Authorization holds as an append-only event log

**Status:** accepted
**Date:** 2026-08-25

## Context

An authorization writes nothing to the ledger. Nothing is owed when the terminal beeps, so there
is no transaction to record — but the money is not spendable either, and the next authorization
has roughly a second to decide whether it fits. Something has to hold the amount.

The obvious model is a mutable `holds` row with a running amount. It does not survive the domain:

- **A clearing has no reliable key back to its authorization.** Network identifiers (ARN, RRN) do
  not agree across messages, so which authorization a clearing belongs to is an *inference*, and
  inferences get corrected.
- **Processors disagree on whether an incremental authorization carries a delta or a cumulative
  TOTAL.** [Spike 006](../../spikes/006-append-only-holds/README.md) surveys three; they do not
  agree. (An earlier draft of this ADR said "six of eleven processors surveyed." No such survey
  exists — not in the spike, and not published anywhere I could reach. The disagreement is real
  and is the whole reason for the design below; the sample size was invented, and is struck.)
- Messages arrive out of order, are re-delivered, and are sometimes never sent at all.

[Spike 006](../../spikes/006-append-only-holds/README.md) has the survey.
[`migrations/0003`](../../migrations/0003_card_holds.sql) is the implementation.

## Decision

**The hold is a SUM over an immutable append-only event log, not a mutable amount.**

Four things follow, and each one is load-bearing:

**1. Stored amounts are always deltas.** An adapter converts its processor's convention into a
delta *at the boundary*, under the group's lock, before the row is written. The derivation is then
a plain `SUM` — commutative, and order-tolerant by construction rather than by timestamp.

The earlier design stored both conventions and resolved absolutes by `occurred_at`. Processors
emit second-granularity timestamps and none guarantees ordering, so ties fell through to insertion
order: the same facts produced different holds depending on which webhook's TCP connection
finished first, and it silently **under-reserved credit**. Order-dependence does not vanish here;
it moves to ingest, where a lock can serialise it. That is the trade, stated plainly.

**2. Group membership is a separate bitemporal table.** There is deliberately no `group_key` column
on the event. Re-grouping is routine — a clearing arrives unmatched and is attached later; a
mis-grouped increment must be split out — and storing the inference on the event would force that
correction to `UPDATE` a row we call immutable. Assignments are superseded, never updated, so the
event stays a genuinely immutable financial fact and the reasoning about it stays auditable.

**3. Expiry is a flag, not an event.** An event carrying `-remaining` would require reading the
aggregate to compute its own amount — a read-modify-write smuggled into an append-only log, and a
read does not commute.

**4. Over-capture clamps to zero and is recorded.** A $1 fuel authorization clearing at $95 must
contribute 0 to available credit, never *raise* it. But the clamp maps three different conditions
onto the same 0 — legitimate over-capture, an adapter feeding a total into a delta column, and a
mis-grouped clearing — so the condition is also written down, as an alarmable state rather than a
value swallowed at `SELECT` time.

The per-group total is **materialised**, because an authorization has a hard latency deadline —
roughly a second, end to end — and deriving a hold by summing an unbounded event log is unbounded
work.

**That is an argument, not a measurement.** An earlier draft claimed "1131 ms over two years of
history, against a 1500 ms budget." Neither number has a source: [spike
006](../../spikes/006-append-only-holds/README.md) says in terms that the derivation "has not been
benchmarked here," and every other budget figure in this repository says ~1 s, not 1500 ms. Both
are struck. The materialised total stays on the reasoning above; the cost of the alternative is
**unmeasured**, and is on the list.

## What the acceptance test found

[`tests/card_holds.sql`](../../tests/card_holds.sql) attests the flow. Writing it surfaced four
defects in a design that had already been through adversarial review — which is the argument for
executable attestation over careful reading:

| | |
| --- | --- |
| **A hold total summed across currencies.** 100.00 USD + 50.00 EUR reported as "held 15000". | The same vacuity removed from the accounting equation in [0009](./0009-chart-and-completeness.md), sitting in the authorization decision, where the number *is* available credit. A group now carries one currency and `held_for_company` requires one — deliberately with no default. |
| **Splitting a mis-grouped event under-reserved credit.** Moving it to a new group key left a membership row pointing at a group that was never materialised: 80.00 held, 50.00 reported. | Re-grouping now materialises the destination. The drift alarm was blind to it too — the view started `FROM card_hold_groups`, so a *missing* group could not appear. It is now a `FULL OUTER JOIN`. |
| **Correcting the same event twice in one transaction hit a primary-key violation.** The key was `(event_id, assigned_at)`, and `now()` is transaction time — constant across the transaction. | Identity is a `uuidv7`. The same lesson as [0005](./0005-reproducible-as-of.md): a timestamp is not an ordering key. |
| **A re-delivered cumulative total crashed on a CHECK.** Restating the same total yields a delta of 0, which the sign constraint refused. | A zero delta is legal for a cumulative restatement — it is a genuine fact, not an error. |

The first two both under-reserve credit, which the design document already names as the worst
failure available here. Neither was found by reading.

### And three more, which needed *concurrent* attack

Fixing the four above introduced or exposed three defects that no single-session test can reach.
All three were reproduced with two interleaved sessions and are now covered by
[`tests/concurrency.sh`](../../tests/concurrency.sh):

| | |
| --- | --- |
| **The re-grouping guards were bypassable.** `regroup_auth_event` read the destination `FOR UPDATE` *before* materialising it, so while another transaction was mid-creation of that group the row was invisible, `FOUND` was false, and **both** guards were skipped. A USD event joined a group being created as EUR — 1500 "held", being 1000 EUR plus 500 USD summed as if they were one unit. | Materialise first, then lock, then validate — the order `record_auth_event` already used. |
| **Worse: a live authorization joined a group being expired.** `held_for_company` then reported **0 against real exposure of 1000**, and `card_hold_drift` could not see it, because the clamp lives in `held_minor` while the alarm compares `total_minor` — and those agreed. Invisible to the unmatched queue too, since the event had a live membership row. | Same fix. The alarm now also reports any event assigned to a group *after* it expired, because the clamp is the thing hiding the number. |
| **The lock that fixed the lost update introduced a deadlock.** Re-grouping locked the destination, then `recompute_hold_group` locked the source — so two operators moving events in opposite directions between the same two groups took the same two locks backwards. 198 deadlocks under mixed load. | Lock both groups up front, in `group_key` order. The same lesson as sorting the legs in `post()`. |

**What held under the same attack**, and is worth recording as attested rather than assumed:
`record_auth_event` has no window — `INSERT … ON CONFLICT DO NOTHING` waits on a concurrent
inserter (measured: a second session blocked 2.96 s, then saw the row and locked it). 3,600
concurrent calls on one group produced a materialised total exactly equal to the log, and
**concurrent ingest on a single group cannot deadlock** — it takes exactly one row lock. The
cumulative-total conversion also fails closed: 1,304 of 1,800 racing attempts were refused as
out-of-order, and the derived total was never wrong.

## Consequences

- **The unmatched queue is a view, not a special value.** An event with no live assignment is
  unmatched by definition, so the queue cannot drift from the data it describes.
- **`card_hold_drift` is the alarm**, and it now covers both directions: a materialised total that
  disagrees with its log, and a log that has no materialised total.
- **The over-capture flag must not latch.** Because the sum is order-tolerant, a group whose events
  arrive out of order dips negative in passing; a latching flag would turn every such delivery into
  a false alarm. It describes the current total, so a transient dip self-heals.
- **Ingest is serialised per group.** Contention is per authorization, which is not a hot row.
- The ledger takes no dependency on any of this: holds are a product-layer concern built on the
  core, and the core does not know they exist.

## Not decided here

- **Hold expiry windows are policy, not protocol.** Our release timer is not the network's clearing
  deadline: that clock drives dispute eligibility and does not extend on an increment. Both are
  stored; neither is derived from the other.

  **Correction to a correction.** An earlier version of this bullet retracted the day counts as
  unverifiable. **That retraction was wrong, and the original research was right.** The public
  Visa Core Rules PDF (18 Apr 2026) extracts cleanly and §**5.7.3.5 "Transaction and Processing
  Timeframes"** reads *"An Acquirer must process a completed Transaction as specified in Table
  5-12."* Table 5-12: card-present **5 calendar days**, card-absent 10, extended/Estimated
  (cruise, lodging, vehicle rental) 30, with footnote 1 — *"Timeframe starts on the date of a valid
  Authorization."* That is auth-to-clearing, not response time. Rule **0031022** is verbatim *"An
  Incremental Authorization Request does not extend the processing timeframes in Table 5-12"*,
  which is the source of the "does not extend on an increment" claim above. Spike 006's citation is
  sound in every particular and is reinstated. Two real refinements: Visa treats authorization validity and the clearing deadline
  as *one* rule rather than two, and the figure is region-variable — so it is policy input, not a
  constant to hard-code.
- **STIP** — stand-in processing, where the network approves on our behalf while we are down —
  produces authorizations we never saw. Unmodelled.
- **Fuzzy matching itself.** The schema records *which* method assigned a group (`lifecycle_id`,
  `rrn`, `fuzzy`, `manual`) and keeps the trail. The matcher is not built.
