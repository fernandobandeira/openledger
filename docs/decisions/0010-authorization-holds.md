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

*EVERY quantitative figure in this section comes from one-off adversarial runs, not from the
shipped suite* — the deadlock counts in the table above (198) and under "Recorded rather than
closed" (91); the 2.96 s block and 3,600 concurrent calls below; and, further down, "18 of 20
trials", "seven of the eight" and "1,304 of 1,800". An earlier version of this note said "the
paragraph below", singular, and left the last three unmarked. They all come from one-off runs, not from the shipped
suite: `tests/concurrency.sh` defaults to 6 workers x 15 operations. They are recorded as
observations, not as reproducible benchmarks — the harness that produced them is not in the repo.*

**What held under the same attack**, and is worth recording as attested rather than assumed:
`INSERT … ON CONFLICT DO NOTHING` waits on a concurrent inserter (measured: a second session
blocked 2.96 s, then saw the row and locked it), and 3,600 concurrent calls on one group produced
a materialised total exactly equal to the log.

*This paragraph used to add "`record_auth_event` has no window", and that was wrong twice over.*
The retraction below correctly says the "cannot deadlock" claim was false, and blames the foreign
key's implicit `FOR KEY SHARE` in the attach path. A **second** reproducer was found later and is a
different lock in a different function: the fresh-ingest path took the group row `FOR UPDATE`
before it could know whether the message already existed, so ingest ran group-then-message while
attach ran message-then-group. Two *ordinary single-group* ingests then deadlocked, **10 of 10
trials**, with the group pre-created and committed so it was a plain row lock and not a race to
create anything. **`INSERT … ON CONFLICT DO NOTHING` is itself a lock acquisition** — the lesson
this file states for `regroup_auth_event` and had not applied to ingest.

The fix was **not** the remedy this ADR names for the sibling case. An advisory lock over the
message key space, taken first on every path, was written, measured, and **reverted**: on a batch
carrying an authorization and its increment it produced 6 deadlocks in 6 trials where the
unmodified code produced 0. A lock taken before the natural one adds an ordering; it does not
remove one. What shipped instead is narrower and free -- the attach path and `regroup_auth_event`
lock the *event row* first, explicitly. `tests/concurrency.sh` races that, and an 8-session review
recorded 61 deadlocks under an unsorted multi-group load with not one deadlock context naming
`card_auth_events`.

**That is not the same as "every path takes them event-then-group", which an earlier version of this
paragraph claimed, and which is false.** `record_auth_event`'s lost-race recursion takes the group
row `FOR UPDATE` and only then recurses into a frame that locks the event — group-then-event. A
later review built the cycle and got the context the sentence above says never appears:

```
ERROR:  deadlock detected
CONTEXT:  while locking tuple in relation "card_auth_events"
          SQL statement "SELECT 1 FROM card_auth_events
                          WHERE tenant_id = p_tenant AND id = v_event FOR UPDATE"
          PL/pgSQL function record_auth_event(...)      <-- the event lock
          PL/pgSQL function record_auth_event(...)      <-- the lost-race recursion
```

One single-group ingest against one regroup — **not** the recorded "unsorted multi-group caller"
class. Correctness held throughout (drift 0, the right total, no message landed twice, no double
membership); availability did not. The honest statement is the one this file makes generally and
made too strongly here: *deadlocks abort cleanly and cost availability, not correctness.* Two paths
take the locks in the same order; the recursion is a third and does not. Sorting it means the fresh
path would have to know the event id before it takes the group lock, which is the thing the dedup
design exists to avoid, so it is recorded rather than closed.

The advisory lock is gone from the tree, so the 6-of-6 and 0-of-6 counts above are no longer
reproducible from the code. They are recorded as the reason a fix this ADR twice recommended is
not present.

This paragraph used to end: *"and concurrent ingest on a single group **cannot deadlock** — it
takes exactly one row lock."* **That was false, and it was false because of a lock nobody wrote.**
The re-delivery attach takes the `card_hold_groups` row `FOR UPDATE` and then, through
`fk_event_group__event`, an implicit `FOR KEY SHARE` on the event row when it inserts the
membership — and `regroup_auth_event` takes those two in the *opposite* order, event first, on
purpose. A matcher attaching a queued event against an operator moving the same event deadlocked in
**18 of 20 trials**, each one aborting the adapter's whole webhook transaction. Correctness held
throughout; availability did not. The attach path now takes the event lock first, explicitly, which
also closed a second defect in the same three lines: eight concurrent re-deliveries all read the
membership with no lock held, all saw none, and **seven of the eight** got a raw duplicate-key
error instead of the exposure they asked for.

The lesson is narrower than "take more locks". It is that **a foreign key acquires a lock on your
behalf, in an order you did not choose**, and a lock-ordering argument that counts only the locks
written in the function is not an argument. The
cumulative-total conversion also fails closed: 1,304 of 1,800 racing attempts were refused as
out-of-order, and the derived total was never wrong.

### And five more, all under-reserving credit, all invisible to the alarm

A fourth round attacked the flow specifically for the cardinal sin: reporting **less** exposure
than is really live, so an authorization is approved that should not be. Every one of these did
that, and `card_hold_drift` reported nothing for any of them.

| What broke | The fix |
| --- | --- |
| **A cumulative total could be RE-GROUPED.** Its stored `amount_delta` is a *relative* quantity — `wire_amount − authorized_minor`, computed under the **source** group's lock against the **source** group's base — so re-summing it against a different base is arithmetic on two unrelated numbers. Two authorizations of 100.00 and 250.00 in one group, then moving the second out, left the destination holding 150.00 against a true 250.00, while `card_auth_events` still recorded the wire amount as 250.00: the audit trail and the total disagreed, on the wrong number. It also poisoned the over-capture signal — the ordinary clearing that followed printed a permanent 100.00 over-capture. | Refused. Re-deriving the delta needs the destination's base *at the time the message arrived*, which is not recoverable. The convention guard compared only labels, so `total → total` passed. |
| **`total_convention` was set in exactly one place**, the fresh-ingest `UPDATE`. The re-delivery attach, `regroup_auth_event` and `recompute_hold_group` all left it `NULL` — and the mixing guard reads `IS NOT NULL AND …`, so **any group whose first increase arrived by re-delivery had no convention and the guard never engaged.** A delta processor's genuine +120.00, normalised as a total by a second adapter, became +20.00. Reachable through the public API alone. | Derived from the log, by every path that recomputes. `card_hold_drift` compares it too — a group holding both kinds is the state this ADR calls irreconcilable, and the alarm never looked. |
| **A re-delivery naming a *corrected* group** created a phantom group from caller parameters, returned that phantom's 0 to the adapter while 600.00 was live, and fixed a currency **permanently** from unchecked input — after which every genuine message for that key was refused forever, and refused messages are never stored, so they never reached the review queue either. | Dedup runs before any group is materialised. A re-delivery naming a different key is now refused, not swallowed: that is the processor and the operator disagreeing about where a message belongs, which is what `regroup_auth_event` exists to settle deliberately. |
| **`regroup_auth_event` read the event's current group with no lock** and never re-read it, so a concurrent move superseded a membership in a group this call held no lock on and never recomputed. Two operators moving one event X→Y and X→Z left Y and Z each materialising the full amount. | Lock the event row first. It is the thing being moved. |
| **A deleted group row was rebuilt WRONG rather than failing.** `expired_at`, its snapshots and `low_water_minor` are not in the log, so a repair invented them: an expired group came back **live**, its post-expiry alarm permanently disarmed. And an ordinary incremental after a delete had ingest report 70.00 against 1,070.00 of live exposure — drift fires afterwards, but the authorization decision does not wait for it. | `card_hold_groups` rows cannot be deleted. Materialisations may be rewritten; the row carrying the part of the state that is *not* a materialisation may not be removed. |

## Consequences

- **The unmatched queue is a view, not a special value.** An event with no live assignment is
  unmatched by definition, so the queue cannot drift from the data it describes.
- **`card_hold_drift` is the alarm**, and it now covers both directions: a materialised total that
  disagrees with its log, and a log that has no materialised total.
- **The over-capture flag must not latch.** Because the sum is order-tolerant, a group whose events
  arrive out of order dips negative in passing; a latching flag would turn every such delivery into
  a false alarm. It describes the current total, so a transient dip self-heals.
- **Ingest is serialised per group.** Contention is per authorization, which is not a hot row.
- **So is the repair, and so is a re-grouping.** `recompute_hold_group` takes the row lock itself
  rather than relying on its caller; `regroup_auth_event` locks the event, then both groups in
  `group_key` order, materialising the destination *at its place in that order*. Each of those is
  load-bearing and each is now raced by [`tests/concurrency.sh`](../../tests/concurrency.sh) —
  which took three attempts for the repair's lock, because the two obvious races both passed
  against code that did not have it.
- **A group's convention is a derived fact, not a stored decision.** It is recomputed from the log
  wherever membership changes, so no path can leave the mixing guard disarmed.
- The ledger takes no dependency on any of this: holds are a product-layer concern built on the
  core, and the core does not know they exist.

### One finding declined, with the argument

**Scope, stated up front, because the migration says it and this ADR did not:** the argument below
covers `clearing` **and nothing else**. A clearing posts to the ledger, so the cleared money is a
receivable and exposure is posted + held. `reversal` and negative `advice` post nothing at all, and
for those the netting *is* a real under-reservation — see the over-reversal bullet under "Known,
and not fixed".

A reviewer reported that an over-capture nets against later exposure: a $1.00 fuel authorization
clearing at $95.00 leaves `total_minor` at −94.00, and a subsequent $100.00 incremental then holds
**6.00, not 100.00** — 94.00 apparently under-reserved, with the alarm silent.

**The netting is correct, and the reasoning that says otherwise stops one step too early.** The
$95.00 clearing has already *posted to the ledger* — a clearing is the event that writes entries,
which is the whole point of the authorization/clearing split. The customer's exposure is therefore
95.00 of posted receivable **plus** 6.00 of un-cleared hold = 101.00, which is exactly the 1.00 +
100.00 that was authorized. A hold is the un-cleared remainder by construction; asking it to also
carry the cleared part would double-count it against available credit.

What the report does correctly identify is the wording. *"An over-capture must contribute 0, never
raise available credit"* is loose: `held_minor` is clamped at 0, so an over-captured group never
*adds* credit — but the negative residue does reduce that group's future hold.

**An earlier version of this paragraph then made a stronger claim, and the stronger claim is
false.** It read: *"an over-capture never makes `held_for_company` smaller than the un-cleared
exposure of that group."* It does, and the sequence is three messages. Authorize 100.00, clear
100.00, then a spurious reversal of 100.00: the group sits at −100.00 with `held_minor` clamped to
0. Now a genuine 100.00 incremental arrives on the same group. It nets against the residue, the
group returns to 0, and `held_for_company` still reports 0 — 100.00 of live un-cleared exposure,
nothing held, nothing posted. That is under-reserving credit, which this file calls the cardinal
sin, and the clamp is what hides it: clamping the *report* does not clamp the *state*.

The system does not prevent this. It **detects** it: `card_hold_drift`'s
`total_minor < 0 AND bloodless_decreases > 0` disjunct fires the moment the group goes under water,
before the increase that would be swallowed — and then goes silent again, exactly as
*"The over-reversal alarm SELF-HEALS"* below records for the no-clearing variant. Verified on a
clean database against `0001`–`0003`: drift 1 row after the reversal, 0 rows after the incremental.
Detection is the honest description; the sentence above claimed prevention.

Where it *would* be a real defect is if the later increase belonged to a **different**
authorization that merely shares an inferred `group_key`. That is a grouping error, and it is what
the unmatched queue and `regroup_auth_event` exist to correct — it is not the sum being wrong.

## Known, and not fixed

Five findings from adversarial review are recorded rather than closed, because
each needs a design decision rather than a guard:

- **A cumulative restatement that DECREASES is refused, and the refusal is sticky.**
  A processor reporting cumulative totals restates a *lower* subtotal after a
  partial reversal. `authorized_minor` only rises, so the message is refused as
  out-of-order and the group can never accept a total below its high-water mark
  again — measured: 60.00 held against 90.00 real. Representing a decreasing
  authorized subtotal is the missing piece.
- **A refused convention mix leaves an order-dependent number in service.** Only
  the *second* message is refused; the first is already applied. The same two
  messages therefore leave 50.00 or 100.00 held depending on arrival order. If
  refusing the mix is the answer, the *group* should be quarantined, not just the
  message.
- **The over-reversal alarm SELF-HEALS, so a real under-reservation ends silent.**
  `card_hold_drift` reports a group whose bloodless decreases — reversals and
  negative advice, neither of which posts to the ledger — exceed its increases.
  That fires in the *precursor* state and goes false the instant the next genuine
  increase is absorbed by the residue, because that increase raises the compared
  quantity by exactly the amount it swallowed. Measured: two reversals against one
  authorization, then an ordinary incremental — **100.00 live, 0.00 held, 0.00
  posted, and drift back to zero rows.**

  No predicate fixes it, and the attempt is instructive. Latching on
  `low_water_minor` — monotone, unerasable — false-positives on the central claim
  of this design: a group whose messages arrive decrease-first dips below any
  clearing that has landed yet, which is exactly the order tolerance the whole
  file exists to provide (`tests/card_holds.sql` permutation 4,3,2,1 catches it
  immediately). **The log cannot decide the question**: a reversal that arrives
  before its authorization and a reversal that should never have been sent are the
  same three columns. Deciding needs the processor's reversal-to-authorization
  linkage, which this ADR deliberately does not model — that is why grouping is
  called a revisable inference. `low_water_minor` keeps the durable evidence that
  the group was ever there.

  *This paragraph exists because `migrations/0003` said "the ambiguity is recorded
  in ADR-0010" and it was not. Writing that a thing is recorded elsewhere is not
  recording it.*
- **An emptied group pins its currency forever.** Group rows cannot be deleted (they carry
  `expired_at` and `low_water_minor`, which are not in the log), so once every event has been moved
  out of a group its `currency` is permanent, and a later message for that key in another currency
  is refused and never stored. Reusing one inferred `group_key` across currencies is not a
  realistic domain event, so this is recorded rather than guarded — but it is the residue of the
  phantom-group defect above, and worth knowing before someone reuses keys deliberately.
- **`regroup_auth_event` can deadlock against a multi-group adapter transaction.**
  It sorts its two locks by `group_key`; `record_auth_event` takes its single lock
  in call order, so a batch touching `ZZZ` then `AAA` takes them backwards.
  Measured at 91 deadlocks under mixed load. Opposite-direction regroups are fine —
  it is regroup versus an unsorted multi-statement caller. A single-group ingest
  cannot sort a lock it does not know about, so the fix belongs in a batch API that
  sorts. **Not** in an advisory lock over the same key space: that was the other half of
  this same recommendation, it was built, and it made things worse (6 deadlocks in 6
  trials against 0, above). Every deadlock aborted cleanly, so this costs availability,
  not correctness.

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
