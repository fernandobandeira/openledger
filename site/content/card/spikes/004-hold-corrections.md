# Spike 004 — Can the hold model's recorded-not-closed findings be closed, or only recorded?

**Status:** closed. Every finding in
[card 0001 · authorization holds §*Known, and not fixed*](/card/decisions/0001-authorization-holds#known-and-not-fixed)
was reproduced against the parked schema and each one now has a design decision behind it:
[card 0002 · hold corrections](/card/decisions/0002-hold-corrections). Two of the findings turned out to be
worse than recorded, one turned out to be unfixable and had to be converted into a detectable
state rather than a correct number, and one kind of processor message turned out not to exist.

**Question.** ADR-0001 records nine defects it declines to fix, at least four of which
under-reserve credit. Are they closable by design, or is "recorded" the honest ceiling?

**Ran** 2026-08-27 · PostgreSQL 18.6 · scratch database `spike_wsg`, built by loading
`migrations/00001_baseline.sql` and then `parked/card/schema.sql` on top — the documented manual
path, which **loads cleanly** in one `--single-transaction` paste: 1 enum, 4 tables, 10 indexes,
2 triggers, 2 views, 4 grants, 1 revoke — the counts
[the parked-card page](/card/parked) claims, confirmed from `pg_indexes` and `pg_trigger`.
> **Note.** These runs predate the 2026-08-27 integration that reshaped
> `migrations/00001_baseline.sql` (ADRs 0009–0013). The parked card DDL loads on the merged core
> too — CI asserts it on every push ([0008](/decisions/0008-module-boundaries)) — but to
> re-run this spike's transcripts verbatim, recover the pre-merge baseline from git history.

Everything below is in `spikes/017-hold-corrections/` and reproduces with
`./run.sh`.

## The answer

**Eight of the nine are closable; the ninth is not, and the fix for it is to make the ambiguity
into a state rather than a number.** The through-line is one rule, and it is the opposite of what
the schema does today:

> **Never refuse a processor message you cannot reconcile. Store it, and quarantine the number.**
> A refused message is a financial fact destroyed — the processor will not resend it, and every
> watcher then agrees with a log that has already lost the money.

Four of the nine findings are the same failure wearing different clothes: the writer refuses or
silently absorbs a message it cannot convert, and the resulting number is *smaller* than the
group's live exposure. The corrections are in [card 0002 · hold corrections](/card/decisions/0002-hold-corrections).

| finding | reproduced | closable | how |
| --- | --- | --- | --- |
| mis-grouped cumulative total | ✅ 20000 live, 10000 held | ✅ | a matcher rule, plus a noticer that looks at *shape*, not amounts |
| `expiry_reversal` races the sweep | ✅ 10000 vs 0 | ✅ | **the kind does not exist on any wire** — delete it; and the sweep's predicate was the real bug |
| decreasing restatement refused, sticky | ✅ 6000 held, 9000 live | ⚠️ | **not** correctable order-independently. Quarantine it, hold the largest reading |
| convention mix, order-dependent | ✅ 10000 or 12000 | ✅ | quarantine the group, hold 22000 |
| over-reversal alarm self-heals | ✅ drift 1 → 0 | ✅ | neither linkage nor a latch: make the residue unabsorbable |
| the clamp hides state | ✅ 0 held, 10000 live | ✅ | same one column |
| emptied group pins its currency | ✅ refused, 0 rows stored | ✅ | it is a pure materialisation; let it be rewritten |
| re-grouping deadlock | ✅ 6/6 → 0/6 | ✅ | a batch-API lock contract |
| dead columns, stale prose | ✅ | ✅ | consumers or deletion |

---

## 1. The mis-grouped cumulative total: reproduced exactly, and the noticer cannot be arithmetic

`01-misgrouped-total.sql`, on the parked schema unmodified:

```
 processor_msg_id |     kind      | wire  | raw_is_total | stored_delta
 msg-1            | authorization | 10000 | t            |        10000
 msg-2            | authorization | 10000 | t            |            0

 true_live_exposure_from_the_scenario | reported_held | authorized_minor | total_convention
                                20000 |         10000 |            10000 | total

 card_hold_drift_rows | card_auth_unmatched_rows
                    0 |                        0

 smaller_second_auth
 REFUSED: ck_auth_events__sign (delta -5000 for kind authorization)
```

ADR-0001's numbers, to the digit — including its sharpest observation, that **the safe case errors
and the dangerous case is silent**.

**And no arithmetic over the log can notice it.** A second authorization for an equal amount and a
restatement to an unchanged total are the same three columns: same `kind` value is not required,
same wire amount, same computed delta of zero. Every candidate invariant was tried and each one
holds in the failure state:

| candidate | why it does not fire |
| --- | --- |
| `authorized_minor = MAX(raw_amount)` over the group's totals events | 10000 = MAX(10000, 10000). Holds. |
| `amount_delta = raw_amount − base` | 0 = 10000 − 10000. Holds — and it holds even with the base recorded. |
| the convention disjuncts | a totals message went into a totals group; there is no mix. |
| the review queue | the event has a live membership. |

So the noticer has to look at something other than the amounts. Two things are available and
neither is currently read: **the `kind`** and **the match `method`**. A group with two live
`authorization` events is a mis-grouping on every processor [spike
002](/card/spikes/002-processor-hold-semantics) read — a restatement arrives as `incremental` or
`advice`, never as a second `authorization` — and `uq_auth_events__msg` already removes the only
false positive (a redelivered message under the same object id). Fired against the same scenario
with the match forced through:

```
 group_key |       reason       | n
 G1        | two_authorizations | 2

 card_hold_drift_rows
                    1
```

## 2. `expiry_reversal`: the wire event does not exist, and the sweep was the real defect

ADR-0001 says the kind's wire event "is unidentified". It is worse than unidentified.

**Eight vendors' published references were read for an event that restores a hold the platform has
already released. None documents one.** The two names that look like matches are both something
else, and both were re-fetched here directly rather than taken from a summary:

| vendor | closest candidate | verbatim | verdict |
| --- | --- | --- | --- |
| **Marqeta** | `authorization.reversal.issuerexpiration` | *"Reverses or drops an `authorization` journal entry due to elapsed time. Initiated by Marqeta."* ([event types](https://www.marqeta.com/docs/core-api/event-types)) | a **release**, not an un-expiry |
| **Galileo** | `BEXR: auth_exp_reversal` | *"If this authorization was reversed, the reversal expires at the same time, and Galieo sends `BEXR: auth_exp_reversal`."* ([auth_exp](https://docs.tech.sofi.com/pro/reference/api-reference-events-api-auth-exp)) — the vendor's own typo preserved | the **reversal record** expiring, not the expiry being reversed |
| **Stripe** | — | three `issuing_authorization.*` event types; status enum `pending / closed / expired / reversed`, with no documented return to `pending` | no such event |
| Lithic, Treasury Prime, Highnote, Adyen, Unit | — | expiry is a one-way ledger move in each; Highnote explicitly routes a late clearing on an expired authorization through a **refund**, not a reinstated hold | no such event |

Increase, Column and Pismo were not fetched, and that is stated rather than papered over.

The race reproduces as ADR-0001 records it —

```
 group_key | live_exposure_from_the_scenario | reported_held
 G-A       |                           10000 |         10000     sweep first, then expiry_reversal
 G-B       |                           10000 |             0     expiry_reversal first, then sweep
```

— and then goes further in two directions the ADR does not record.

**The favourable order does not survive the next pass of the same job.** The sweep is recurring.
Run it once more against G-A and the flag comes straight back, because the old event's
`hold_expires_at` is past due forever:

```
 ga_second_pass
              1
 group_key | reported_held
 G-A       |             0
 G-B       |             0
```

So the under-reserving order is not merely "the likely one". It is terminal.

**And the race needs no `expiry_reversal` at all.** An ordinary incremental reproduces it, because
the sweep's predicate is `EXISTS (… hold_expires_at < now())` — *any* past-due event, not the
group's latest deadline:

```
 group_key | live_exposure_from_the_scenario | reported_held | latest_deadline_is_in_the_future
 G-C       |                           15000 |             0 | t
```

15000 of live exposure, 0 held, and the group's own latest deadline in the future. **The bug is
the sweep's predicate, and `expiry_reversal` was only the way it was found.**

## 3. The decreasing restatement is not correctable order-independently

Reproduced exactly — ADR-0001's "60.00 held against 90.00 real":

```
 auth_100        ok delta=10000
 reversal_40     ok delta=-4000
 restate_to_90   REFUSED: ck_auth_events__sign (delta -1000 for kind incremental)

 true_live_exposure_from_the_scenario | reported_held | high_water_base
                                 9000 |          6000 |           10000
```

Sticky, as recorded: 9500 and 9900 are refused too, and **only 2 of the 5 messages ever reach the
log**.

The obvious fix — base the conversion on the authorized subtotal *net* of reversals, since a
cumulative total already nets them — repairs this arrival order and **breaks another**. Measured
across all six orders of the same three messages, that rule produced four different holds from
6000 to 14000. The reason is not a bug in the rule:

> **A cumulative total is a snapshot, and nothing on the wire says whether this snapshot is before
> or after that reversal.** Reading 90.00 as "already net of the 40.00" gives 90.00; reading it as
> a stale pre-reversal figure gives 60.00. Both are consistent with the log, and the log is all
> there is.

So the honest close is not a number, it is a state: the group is **quarantined** and held at the
largest reading the log admits. Measured across all six arrival orders, before and after:

```
 arrival_order | true_exposure | held_today | held_after
 {1,2,3}       |          9000 |       6000 |      10000
 {1,3,2}       |          9000 |       6000 |      10000
 {2,1,3}       |          9000 |       6000 |      10000
 {2,3,1}       |          9000 |       6000 |      10000
 {3,1,2}       |          9000 |       6000 |      10000
 {3,2,1}       |          9000 |       6000 |      10000

 distinct_today | today_ever_UNDER_reserves | distinct_after | after_ever_UNDER_reserves
              1 | t                         |              1 | f
```

Order-independent both before and after; the difference is the direction of the error. Today every
order under-reserves by 30.00; after, every order over-reserves by 10.00 **and says so**.

**And the ambiguity is avoidable at the boundary for most processors.** Where the message carries
an explicit incremental amount beside the cumulative total — Stripe's `pending_request.amount`,
Increase's `card_increment.amount`, Galileo's *"the incremental amount will be present in the local
amount fields"*, Unit's `oldAmount`/`newAmount` — the adapter reads the delta off the wire and
never enters this path. The same three facts, ingested that way:

```
 distinct_holds | min_held | max_held | true_exposure | ever_UNDER_reserves
              3 |     9000 |    13000 |          9000 | f
```

Exact in the natural order, and the spread is the residue rule of §5 doing its job, never below
the truth.

**A narrower quarantine than "any lower total".** An out-of-order totals pair with no reversal in
it is not ambiguous — the maximum wins and is right — so it is stored at delta zero and
quarantines nothing:

```
 total_150         ok group=H2 delta=15000
 stale_total_100   ok group=H2 delta=0
 reported_held     15000
```

## 4. The convention mix: 10000 or 12000, and one of the two messages destroyed

```
 order 1 -- delta first:  delta_100 ok;  total_120 REFUSED: convention mix
 order 2 -- total first:  total_120 ok;  delta_100 REFUSED: convention mix

 group_key | reported_held | total_convention | events_in_the_log
 M1        |         10000 | delta            |                 1
 M2        |         12000 | total            |                 1

 card_hold_drift_rows        0
 largest reading the log admits (every increase read as a delta):  M1 10000  M2 12000
```

Order-dependent, as recorded — and note the third column. **Only one of the two messages is in the
log at all**, so even the pessimistic reading is computed from half the evidence. That is why
ADR-0002 stores the refused message. With both stored, both orders agree:

```
 group_key | reported_held | quarantine_reason | quarantine_hold_minor | events_stored
 M1        |         22000 | convention_mix    |                 22000 |             2
 M2        |         22000 | convention_mix    |                 22000 |             2

 card_hold_drift_rows        2
```

22000 is ADR-0001's own "220.00 in the other order" — the largest reading the two messages admit.

## 5 and 6. The self-healing alarm and the hiding clamp are one defect

`05-residue.sql`. Two reversals against one authorization, then an ordinary incremental:

```
 -- the precursor state
 total_minor | held_minor | low_water_minor | overcaptured | drift_rows
      -10000 |          0 |          -10000 | t            |          1

 -- ...one message later
 live_exposure | total_minor | reported_held | low_water_minor | overcaptured | drift_rows
         10000 |           0 |             0 |          -10000 | f            |          0
```

100.00 live, 0.00 held, 0.00 posted, drift back to zero rows, and `overcaptured_at` **erased by the
very message that hid the money**. The clearing variant is the same shape with 100.00 posted
alongside it. *(One correction, to `parked/card/schema.sql` rather than to ADR-0001, which has this right: the
schema comment on `card_hold_drift` says this case shows "drift 0 rows at every step". Measured on
the file as it stands, drift reports **1 row** at the spurious reversal and then self-heals,
because the `total_minor < 0 AND bloodless_decreases > 0` disjunct the comment goes on to add is
in the view. The self-heal is real; "at every step" describes the version before that disjunct.)*

ADR-0001 frames the choice as *model the reversal-to-authorization linkage, or latch the alarm*.
**Neither is necessary.** The log cannot decide which reversal is spurious — that much is true —
but it does not have to, because **the question only matters if a later increase is allowed to net
against the residue**. Forbid that and the ambiguity stops costing money:

```
 -- finding 5, after
 live_exposure | total_minor | unexplained_minor | reported_held |  quarantine_reason  | drift_rows
         10000 |           0 |            -10000 |         10000 | unexplained_residue |          1

 -- finding 6, after
 un_cleared_live | total_minor | unexplained_minor | reported_held |  quarantine_reason  | drift_rows
           10000 |           0 |            -10000 |         10000 | unexplained_residue |          1
```

Neither case can self-heal, because `unexplained_minor` only ever decreases.

**Two no-regression controls.** A genuine over-capture — a $1 authorization clearing at $95 — must
still clamp to zero silently, because a clearing posts:

```
 total_minor | unexplained_minor | held_minor | low_water_minor | drift_rows | overcapture_rows
       -9400 |                 0 |          0 |           -9400 |          0 |                1
```

Zero drift rows, and one row in the new over-capture queue — which is `overcaptured_at` and
`low_water_minor` finally being read by something. And spike 001's case G, a clearing arriving
before its authorization:

```
 spike001_case_G_expected | reported_held | unexplained_minor | quarantine_reason
                    20000 |         20000 |                 0 |
```

Untouched, because a clearing never creates a residue.

**The cost, measured rather than argued.** A *reversal* that legitimately arrives before its
authorization now over-reserves:

```
 true_exposure_from_the_scenario | over_reserved | unexplained_minor |  quarantine_reason
                               0 |         10000 |            -10000 | unexplained_residue
```

100.00 held against nothing live. That is the trade: the same three columns that hid 100.00 now
reserve 100.00 too much, visibly and resolvably, instead of losing it silently.

## 7. The emptied group is a pure materialisation

Reproduced — the EUR message is refused and **never stored at all**:

```
 group_key | currency | live_members | expired_at | low_water_minor | overcaptured_at
 P1        | USD      |            0 |            |               0 |

 eur_auth            REFUSED: group currency USD <> EUR
 rows_stored_for_p2  0
```

ADR-0001's own rule decides this: *"Materialisations may be rewritten; state that is not a
materialisation may not be removed."* A group with no live members, no expiry, no low-water mark
and no residue carries nothing that is not a materialisation. After:

```
 eur_auth   ok group=P1 delta=5000 [emptied group re-denominated]
 group_key | currency | held_minor | p2_stored
 P1        | EUR      |       5000 |         1
```

And the rule is precise, not a blanket permission — a group that *does* carry non-derivable state
stays pinned:

```
 over_reversal   ok group=P2 delta=-20000 residue=-10000
 eur_auth        REFUSED: group currency USD <> EUR
```

## 8. The deadlock, re-measured

ADR-0001's 91-deadlocks-under-mixed-load figure came from a deleted PL/pgSQL suite and cannot be
re-run. The *class* reproduces in eight lines of shell against the parked schema — a re-grouping
sorting its two locks by `group_key` against a batch taking the same two in call order:

```
=== unsorted: re-grouping (AAA then ZZZ) against a batch in call order (ZZZ then AAA) ===
[batch] ERROR:  deadlock detected
unsorted: 6 deadlocks in 6 trials
=== sorted: BOTH transactions take their locks in ascending group_key order ===
sorted: 0 deadlocks in 6 trials
```

6 of 6 against 0 of 6. The ratio is the finding; two sessions on localhost is not a load test.

## 9. The round-15 items

**`card_hold_drift` has eight disjuncts, and the ADR's prose lists five.** Counted from the source
rather than asserted (`09-count-disjuncts.sh`):

```
1:WHERE g.total_minor IS DISTINCT FROM COALESCE(l.recomputed, 0)
2:   OR g.authorized_minor IS DISTINCT FROM COALESCE(l.recomputed_auth, 0)
3:   OR EXISTS (                                        -- currency
9:   OR (g.expired_at IS NOT NULL                       -- exposure after expiry
12:   OR l.bloodless_decreases > l.increases
13:   OR (g.total_minor < 0 AND l.bloodless_decreases > 0)
14:   OR (l.any_total AND l.any_delta)
15:   OR g.total_convention IS DISTINCT FROM
```

Both omitted disjuncts fire under a positive control — a second currency forced into one group,
and a `total_convention` set to `'total'` on a group whose log is all deltas.

**`open_events` is dead.** One occurrence in the whole repository, its own declaration: zero in
`migrations/`, zero in `src/`, and zero references from any view, index or constraint
(`pg_depend`). `last_event_seq` is the same — one occurrence, its declaration; the expiry disjunct
keys on `expired_authorized`/`expired_total`, not on a counter. `low_water_minor` and
`overcaptured_at` appear only in comments, the declaration and the writer; **neither appears in any
predicate of either view.**

## What this does not settle

- **`hold_expires_at` is still written by nothing**, so the corrected sweep predicate is as inert
  as the old one until a processor's deadline is modelled at ingest. The predicate is the shape;
  the parameter is missing.
- **The 0.05 jobs/s figure turns out to be sourceable, and 0001 does not cite its source.**
  [0002](/decisions/0002-scaling) derives **30k–150k transactions per month** for the reference
  product. One expiry timer per authorization puts the top of that band at
  150,000 ÷ 2,630,016 s = **0.057 jobs/s**, and the bottom at 0.011. So 0.05 is the top of this
  project's own sizing band, not a measurement and not a fabrication — it needs a citation, not a
  strike.
- **Localhost is not a benchmark**, and none of this is one. Every number here is a count or a
  balance, not a latency.
- **The residue rule's cost is not sized.** How often a reversal legitimately precedes its
  authorization is unknown; [spike 002](/card/spikes/002-processor-hold-semantics) documents
  out-of-order *clearings* as routine and says nothing about reversals.
- The harness in `00-harness.sql` is this spike's reading of ADR-0001's prose, because the writer
  does not exist. Where the prose is ambiguous the harness took the ADR's own reproduction as the
  target, and hit it to the digit in findings 1, 2 and 3 — which is the check on that reading.

## Reproduce

```sh
cd spikes/017-hold-corrections && ./run.sh
```
