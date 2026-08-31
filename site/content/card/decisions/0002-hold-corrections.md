# 0002 — Never refuse a message you cannot reconcile: quarantine the number instead

**Status:** accepted, and **scoped as future work** like the ADR it corrects. Every schema change
below is **proposed DDL against [`parked/card/schema.sql`](/card/parked)**, which is applied by no
migration; nothing here is deployed, and the built binary (`crates/openledger`) still carries the
core ledger's `migrate`, `serve` and `reconcile` and nothing card-shaped.
This ADR closes the findings the card rail's [authorization-holds decision](/card/decisions/0001-authorization-holds) records and declines
to fix, and closes the open question [spike 001](/card/spikes/001-append-only-holds) leaves about
what `group_key` is.
**Evidence:** [spike 004](/card/spikes/004-hold-corrections), and
[001](/card/spikes/001-append-only-holds), [002](/card/spikes/002-processor-hold-semantics)
for the processor behaviour it rests on.

## The decision

The card rail's [authorization-holds decision](/card/decisions/0001-authorization-holds) records nine defects it will not fix, and
[the parked-card page](/card/parked) says at least four of them under-reserve credit — the failure
this project calls the cardinal sin. Reproduced one at a time in
[spike 004](/card/spikes/004-hold-corrections), four of them turn out to be the same defect:

**The writer refuses, or silently absorbs, a processor message it cannot convert — and the number
that comes out is smaller than the group's live exposure.** A refused message is a financial fact
we destroyed. The processor does not resend it. Every watcher then agrees with a log that has
already lost the money, which is exactly why 0001 says of its first finding that *what is missing
is anything that notices*.

So the rule that runs through every decision below:

> **Never refuse a processor message you cannot reconcile. Store it, and quarantine the number.**
> A quarantined group reports the **largest** hold its own log admits, appears in the alarm, and
> does not expire. Where the design must choose a direction to be wrong in, it over-reserves.

**When a processor sends something we cannot cleanly fit into the model, the safe move is to keep it
and flag it — never to reject it or quietly swallow it.** That message is a real financial fact, and
the processor will not send it again, so dropping it leaves our records permanently showing less
exposure than truly exists — the one direction a credit product must never be wrong in. So an
unconvertible message is always stored, and where the arithmetic genuinely cannot be resolved the
group is quarantined: it reports the largest hold its own messages could justify, shows up in the
alarm, and does not expire. Given a choice of which way to be wrong, it over-reserves.

Nine decisions. Each is proved on a scratch database in
[spike 004](/card/spikes/004-hold-corrections); the schema changes are collected as exact hunks at
the end.

| | |
| --- | --- |
| **D1. A fuzzy match may not attach an increase-side message to a group that already has one** | It opens a new group instead, where a cumulative total converts exactly — `delta = raw_amount − 0`, which is 0001's own narrowing applied at ingest rather than at repair. Fuzzy stays what Highnote uses it for: attaching **decrease-side** messages to an open authorization. |
| **D2. The expiry sweep keys on the group's latest live deadline, and `expiry_reversal` is deleted** | `MAX(hold_expires_at)` over the group's live events, never `EXISTS (… < now())`. And no processor sends an un-expiry, so the kind goes. |
| **D3. A cumulative total is never refused. A totals group holding both a restatement and a bloodless decrease is quarantined** | Below the high-water mark it is stored at delta zero — the maximum-total-seen resolution, which is right when nothing has decreased. When something has, no arrival order can resolve it, and the group holds the largest total ever restated. |
| **D4. A convention mix quarantines the GROUP, and both messages are stored** | The hold is every increase read as a delta — 0001's own 220.00 reading — so both arrival orders agree. |
| **D5 + D6. A bloodless decrease that drives a group below zero leaves a residue no later increase may absorb** | One column, `unexplained_minor`, monotone non-increasing. It replaces both self-healing drift disjuncts and needs neither the reversal-to-authorization linkage nor a latch on the low-water mark. |
| **D7. A group with no live members and no state that is not a materialisation may be rewritten, currency included** | 0001's own rule, applied. |
| **D8. Two group locks may only be taken through a batch API that sorts them, and a single-group ingest may not compose** | A design constraint on any future adapter, not code. |
| **D9. `open_events` is deleted; `overcaptured_at` and `low_water_minor` get a consumer** | And `card_hold_drift` goes from eight disjuncts to eleven. |
| **D10. `group_key` is a surrogate we mint. It is never a network field** | The answer [spike 001](/card/spikes/001-append-only-holds) leaves open, and the design already assumes it. |

**No trigger is proposed by this ADR, and none is needed.** Every guard here is a column, a
`CHECK`, a `GENERATED` expression, a view, or a rule the writer obeys and a view verifies. The two
existing append-only triggers on `card_auth_events` are untouched.

### D1 — the mis-grouped cumulative total, and the noticer that is not arithmetic

Reproduced to the digit: two equal authorizations fuzzy-matched into one totals group, the second
stored at delta zero, **20000 live and 10000 held, with both watchers at zero rows.**

**No arithmetic over the log can notice this**, and spike 004 tried the obvious candidates. A
second authorization for an equal amount and a restatement to an unchanged total produce the same
wire amount, the same computed delta and the same recomputed aggregates —
`authorized_minor = MAX(raw_amount)` holds, and so does `amount_delta = raw_amount − base` even
with the base recorded. **The information that distinguishes them is not in the amounts. It is in
the `kind` and in the match `method`, and nothing reads either.**

So the fix is at the matcher, and the check is on shape:

**The rule.** An increase-side message joins an existing group only on the processor's own
lifecycle linkage or an explicit human decision. Under `fuzzy` it opens a new group. This is not a
preference — on Visa an incremental *must* carry its original's Transaction Identifier
(*"The Merchant must use… the same Transaction Identifier used for the initial Estimated
Authorization Request"*, §5.7.2.5 ID# 0030937, [spike 001](/card/spikes/001-append-only-holds)), so
**an increment that needs fuzzy matching is precisely the case where the fuzzy signals — card,
merchant, amount, window — are also what a second, separate authorization at that merchant
produces.** Matching on amount is what makes an equal-amount second authorization
indistinguishable, by construction.

**The noticer.** A group with two live `authorization` events is a mis-grouping on every processor
[spike 002](/card/spikes/002-processor-hold-semantics) read — a restatement arrives as
`incremental` or `advice`, never as a second `authorization` — and `uq_auth_events__msg` removes
the only false positive, a redelivery under the same object id. It becomes a disjunct of
`card_hold_drift` and a row of the new `card_auth_review`. Forced against the same scenario, drift
goes from 0 rows to 1.

Measured: 20000 live, **20000 held**, across two groups.

### D2 — the sweep predicate was the defect; `expiry_reversal` was how it was found

**No card processor publishes an event that restores a hold it has already released.** Eight
vendors' own references were read; the two candidates whose names suggest otherwise are both
something else, and both were re-fetched directly rather than taken from a summary. Marqeta's
`authorization.reversal.issuerexpiration` is *"Reverses or drops an `authorization` journal entry
due to elapsed time. Initiated by Marqeta"* — a release. Galileo's `BEXR: auth_exp_reversal` is
*"If this authorization was reversed, the reversal expires at the same time"* — the reversal record
expiring, not the expiry being reversed. Stripe's status enum has no path back to `pending`.
Increase, Column and Pismo were not checked, and that is stated rather than assumed.

**A kind with no wire event is not a modelling gap, it is a modelling error.** It is deleted. The
`ck_auth_events__sign` whitelist keeps its property: a value added to the enum later matches no
arm and can carry no delta at all.

That closes the race as recorded. It does not close the class, and spike 004 found two things 0001
does not record:

- **The favourable order does not survive the next pass of the same job.** The sweep is recurring;
  running it once more against the group that held 10000 takes it to 0, because the original
  event's `hold_expires_at` is past due forever. The under-reserving order is not "the likely one",
  it is terminal.
- **An ordinary incremental reproduces the whole race, with no `expiry_reversal` anywhere.**
  15000 live, 0 held, and the group's own latest deadline in the future.

**Because the sweep asks the wrong question.** `EXISTS (… hold_expires_at < now())` is true of any
group that has ever held a past-due event, forever. The deadline is a property of the *group*, and
the group's deadline is its latest one:

```sql
AND (SELECT max(e.hold_expires_at)
       FROM card_auth_event_group m
       JOIN card_auth_events e ON e.tenant_id = m.tenant_id AND e.id = m.event_id
      WHERE m.tenant_id = g.tenant_id AND m.group_key = g.group_key
        AND m.superseded_at IS NULL) < now()
```

Both orders then yield **15000 held against 15000 live**, and a group genuinely past its latest
deadline still expires to 0. This **removes the qualification D2 puts on 0001's property 1**: with
the deadline derived from the log rather than from arrival order, `held_minor` is a `SUM` gated by
a flag the log itself determines.

A quarantined group is excluded from the sweep. Expiry releases a hold; a hold we cannot compute
must not be released by a timer.

### D3 — a decreasing restatement is representable, and not resolvable

Reproduced as 0001 records it: **6000 held against 9000 live**, sticky, with **only 2 of 5 messages
ever reaching the log**.

The obvious fix is to base the conversion on the authorized subtotal net of reversals, since a
cumulative total already nets them. It repairs this arrival order and breaks others — across the
six orders of the same three messages it produced four different holds, from 6000 to 14000. The
reason is not a bug in the rule:

**A cumulative total is a snapshot, and nothing on the wire says whether this snapshot is before or
after that reversal.** Reading 90.00 as already-net gives 90.00; reading it as a stale pre-reversal
figure gives 60.00. Both are consistent with the log, and the log is all there is. This is the same
shape as the mixed convention 0001 calls irreconcilable, and it has the same answer.

So the decision is in three parts:

1. **A cumulative total below the high-water mark is never refused.** It is stored with
   `amount_delta = 0` and its wire value preserved. That is the maximum-total-seen resolution 0001
   already specifies, and it is *correct* where nothing has decreased — an out-of-order totals pair
   with no reversal in it holds 15000 and quarantines nothing.
2. **A totals group holding both a restatement and a bloodless decrease is quarantined** and held
   at the largest cumulative total ever restated. This is declarative — it is read off the live
   log, so it fires in every arrival order, not only the one that happened to trip the conversion.
3. **The ambiguity is avoidable at the boundary and the adapter must avoid it.** Where the message
   carries an explicit incremental amount beside the total — Stripe's `pending_request.amount`,
   Increase's `card_increment.amount`, Galileo's *"the incremental amount will be present in the
   local amount fields"*, Unit's `oldAmount`/`newAmount` — the adapter reads the delta off the wire
   and never enters this path. **An adapter that infers a delta it was handed is a defect in the
   adapter.**

Measured over all six arrival orders:

```
 arrival_order | true_exposure | held_today | held_after
 {1,2,3}       |          9000 |       6000 |      10000
 {1,3,2}       |          9000 |       6000 |      10000
 {2,1,3}       |          9000 |       6000 |      10000
 {2,3,1}       |          9000 |       6000 |      10000
 {3,1,2}       |          9000 |       6000 |      10000
 {3,2,1}       |          9000 |       6000 |      10000

 today_ever_UNDER_reserves  t        after_ever_UNDER_reserves  f
```

Order-independent before and after. **The difference is the direction of the error**: today every
order under-reserves by 30.00; after, every order over-reserves by 10.00 and says so.

**This is what "representing a decreasing authorized subtotal" turns out to mean.** The decrease is
represented — in `raw_amount`, in the review queue, and in the hold, which stops pretending to a
precision the messages do not carry. What is not on offer is a *correct number*, because there
isn't one.

### D4 — quarantine the group, and keep both messages

Reproduced: 10000 in one order, 12000 in the other, drift silent — and **one of the two messages
destroyed in each**, so even a pessimistic reading would have had half the evidence.

Both messages are stored. The one that cannot be converted carries `amount_delta = 0`, keeping
`total_minor` a faithful `SUM` and leaving the wire value in `raw_amount`, where the mix is exactly
what `any_total AND any_delta` already looks for. The group is quarantined and held at every
increase read as a delta — 0001's own *"220.00 in the other order"*. Both orders then report
**22000 held with 2 events stored**, and drift reports both groups.

### D5 + D6 — neither the linkage nor a latch: make the residue unabsorbable

0001 frames this as a choice between modelling the reversal-to-authorization linkage and latching
the alarm. **Both are refused, and the third option is better than either.**

The linkage is refused because it is the same unreliable identifier this design is built on
refusing. Highnote: *"Do not rely solely on network reference IDs to correlate authorization and
clearing events."* Modelling the linkage would reintroduce the assumption the central argument of the card rail's
[authorization-holds decision](/card/decisions/0001-authorization-holds) rejects, to decide a question
that only matters once.

The latch is refused for the reason 0001 gives — it fires on a decrease-first group, which is the
order tolerance the design exists to provide.

**The observation both options miss is that the log does not have to decide which reversal was
spurious. It only has to stop a later increase netting against the residue.** So:

**A bloodless decrease — a reversal, or negative advice — that drives a group below zero writes the
shortfall to `unexplained_minor`, and no later increase may absorb it.** A clearing does not,
because a clearing posts: exposure is posted plus held, which is the argument 0001 uses to decline
the over-capture report, and it covers `clearing` and nothing else.

`held_minor` adds the residue back rather than netting it away, so the two measured failures both
report correctly:

| | before | after |
| --- | --- | --- |
| two reversals, then an incremental (100.00 live) | 0 held, drift **0** | **10000 held**, drift 1, quarantined |
| authorization, clearing, spurious reversal, incremental (100.00 un-cleared live) | 0 held, drift **0** | **10000 held**, drift 1, quarantined |

Neither can self-heal, because `unexplained_minor` only ever decreases.

Two controls hold. A genuine over-capture — a $1 authorization clearing at $95 — still clamps to
zero with **zero drift rows**, and appears in the new over-capture queue. Spike 001's case G, a
clearing arriving before its authorization, is untouched at 20000.

### D7 — an emptied group is a materialisation

0001's own rule decides it: *"Materialisations may be rewritten; state that is not a materialisation
may not be removed."* A group with no live members, no `expired_at`, no residue, no `overcaptured_at`
and a zero low-water mark carries nothing that is not a materialisation, so its currency and
convention may be rewritten. A group carrying any of them stays pinned — verified both ways.

0001 records this as unrealistic. **It is more reachable than it was**, because D1 makes splitting
an event to a new group a routine ingest-time operation rather than a rare repair, and a
fully-emptied `group_key` is a normal consequence of our own correction.

### D8 — the batch API's lock contract

The deadlock class re-measured on the parked schema: **6 deadlocks in 6 trials unsorted, 0 in 6
sorted.** (0001's 91-under-mixed-load figure came from a deleted suite and is not re-checkable;
this is a different, smaller measurement of the same class.) The contract any future adapter must
meet:

| | |
| --- | --- |
| **Sort, then act** | A transaction touching more than one group takes every group lock it will need, up front, in ascending `(tenant_id, company_id, group_key)` order, before any other work. |
| **No lock after the first event row** | The membership insert takes an implicit `FOR KEY SHARE` on the event through `fk_event_group__event`, so a lock-ordering argument counting only the locks written in the function is not an argument. That is 0001's most expensive trap and it constrains the *order of the whole transaction*, not just its explicit locks. |
| **Composition is forbidden, in the type system** | A single-group ingest cannot sort a lock it does not know about, so two single-group calls must not be composable inside one transaction. In Rust the ingest takes a lock token obtainable only from the batch acquirer — the same shape as [0005](/decisions/0005-event-log-and-write-path)'s posting, where one leg is unconstructible. |
| **No advisory lock over the message key space** | Refused with 0001's measurement: 6 deadlocks in 6 trials where the unmodified code produced 0, because a lock taken before the natural one adds an ordering rather than removing one. |
| **This is availability, not correctness** | Deadlocks abort cleanly. Violating the contract degrades; it does not corrupt. It is a design constraint, not an invariant, and it is stated here so the first adapter does not have to rediscover it. |

### D9 — the dead columns, and the prose

**`open_events` is deleted.** One occurrence in the whole repository — its own declaration. Zero in
`migrations/`, zero in `src/`, and zero references from any view, index or constraint. It has no
defined semantics anywhere to preserve.

**`overcaptured_at` and `low_water_minor` get their consumer**, `card_hold_overcapture`: the queue
of every group that has ever dipped below zero, which is the alarmable state 0001 says these
columns make possible and which nothing has ever read. `overcaptured_at` also becomes latching —
written once, with `COALESCE`, rather than recomputed on every event, because spike 004 measured it
being erased by the very message that hid the money. It is still not unerasable: the app role holds
`UPDATE` on this table, so this is "cannot be erased by the writer", which is not the same thing,
and `low_water_minor` remains the durable evidence.

**`last_event_seq` keeps its declaration and stays unread.** It is not deleted, because D2 makes
the sweep read the log rather than a counter, and a monotone per-group counter is the natural key
for the ingest cursor a batch API will need. **Recorded as unread, deliberately** — the difference
between this and `open_events` is that this one has a named future consumer.

**`card_hold_drift` goes from eight disjuncts to eleven.** Counted from the source, not asserted.
It loses the two self-healing ones (`bloodless > increases`, and `total < 0 AND bloodless > 0`) and
gains: the unresolvable-totals state, the residue, the quarantine, the conversion identity
`amount_delta = raw_amount − base_minor`, and the two-authorizations noticer. The currency and
stored-convention disjuncts — the two 0001's prose omits — survive unchanged, and both fire under a
positive control.

### D10 — what `group_key` is

[Spike 001](/card/spikes/001-append-only-holds) leaves this open: *"What is `group_key`, really?"*

**It is a surrogate we mint, and it is never a network field.** Every candidate fails as a key, and
each failure is documented:

| candidate | why it is not the key |
| --- | --- |
| Mastercard Banknet reference | *"guaranteed to be a unique value… on any processing day"* — day-scoped, against holds that live 5–30 days. Two unrelated live authorizations can carry the same one. |
| …and it is sentinel-polluted | Pismo ignores it when it is `999999`, *"since this value can be used only to populate the field without indicating any relationship."* Assume other sentinels exist. |
| …and mid-migration | TLID in DE 105 replaces it, with sources disagreeing on its length. |
| Visa Transaction Identifier | The best *matching input* there is — §5.7.2.5 requires an incremental to carry its original's — but it is one network's field, and STIP produces authorizations we never saw. |
| RRN, ARN, approval code | Highnote: *"Do not rely solely on network reference IDs to correlate."* The approval code (DE 38) is a display field and sources conflict on whether it repeats. |

**So the design already answers its own question**, and this ADR only makes it explicit: the reason
there is deliberately no `group_key` column on `card_auth_events` is that `group_key` is not a wire
value at all. It is our identifier for a family of messages, minted on the first message that
matches nothing, and the network identifiers are *inputs to the matcher*, recorded in `method` and
— new here — in `matched_on`, which stores the value that was matched. On Mastercard that value is
the triple `(financial_network_code, network_ref, network_date)` with sentinels nulled, because the
date is part of the key. **`method` says how we guessed; `matched_on` says what we guessed from;
`card_auth_event_group` says that the guess is revisable.** That is the whole answer.

## The DDL

Proposed against `parked/card/schema.sql`. **Applied by nothing** — the parked file is not edited
by this ADR; these are the hunks, and `spikes/017-hold-corrections/20-proposed-ddl.sql` is the
executable form, verified to load on top of the parked schema and drive every scenario.

```sql
-- 1. expiry_reversal is deleted. No processor sends an un-expiry.
CREATE TYPE auth_event_kind AS ENUM (
    'authorization','incremental','advice','reversal','clearing','expiry');
CONSTRAINT ck_auth_events__sign CHECK (
    kind = 'advice' OR
    (kind IN ('authorization','incremental') AND amount_delta >= 0) OR
    (kind IN ('reversal','clearing')  AND amount_delta <= 0))

-- 2. card_hold_groups
    -- open_events                       DROPPED: read by nothing, no semantics to keep
    unexplained_minor bigint NOT NULL DEFAULT 0
        CONSTRAINT ck_hold_groups__unexplained_sign CHECK (unexplained_minor <= 0),
    quarantined_at        timestamptz,
    quarantine_reason     text CONSTRAINT ck_hold_groups__quarantine_reason
        CHECK (quarantine_reason IN ('convention_mix','unorderable_total','unexplained_residue')),
    quarantine_hold_minor bigint,
    CONSTRAINT ck_hold_groups__quarantine CHECK (
        (quarantined_at IS NULL     AND quarantine_reason IS NULL)
     OR (quarantined_at IS NOT NULL AND quarantine_reason IS NOT NULL)),
    CONSTRAINT ck_hold_groups__quarantine_hold CHECK (
        quarantine_hold_minor IS NULL OR quarantine_hold_minor >= 0),
    held_minor bigint GENERATED ALWAYS AS (
        GREATEST(
            CASE WHEN expired_at IS NOT NULL AND quarantined_at IS NULL
                                             AND unexplained_minor = 0 THEN 0
                 ELSE total_minor - unexplained_minor END,   -- the residue is added back
            COALESCE(quarantine_hold_minor, 0),
            0)) STORED

-- 3. card_auth_event_group -- the inference becomes auditable
    base_minor bigint,   -- what a cumulative total was converted against
    matched_on text      -- the network value the matcher matched on

-- 4. the index the quarantine predicate needs
CREATE INDEX ix_hold_groups__quarantined ON card_hold_groups (tenant_id, company_id)
    WHERE quarantined_at IS NOT NULL;

-- 5. card_auth_review (new), card_hold_overcapture (new), card_hold_drift (rewritten)
```

The two new views and the eleven-disjunct `card_hold_drift` are in
`spikes/017-hold-corrections/20-proposed-ddl.sql` in full.

## What we considered

| | Why not |
| --- | --- |
| **Keep recording the findings** | The position 0001 takes, and it was right at the time: the core ledger ships first. It stops being right once the list is the reason the DDL cannot ship — [the parked-card page](/card/parked) says the findings are why the file must stay editable, and a file that stays editable forever is a file that never ships. |
| **Model the reversal-to-authorization linkage** | It is the same identifier this design refuses to trust — Highnote's *"do not rely solely on network reference IDs"* is the sentence `card_auth_event_group` exists because of. Buying one alarm with the assumption the whole model rejects is a bad trade, especially when the residue rule needs no linkage at all. |
| **Latch the drift alarm on `low_water_minor`** | 0001's own counter-example stands: a decrease-first group legitimately dips below any clearing so far, so the latch fires on the order tolerance the design exists to provide. |
| **Base a cumulative total's conversion on the subtotal net of reversals** | The obvious repair for D3, and it was measured: it fixes one arrival order and produces four different holds across six. A cumulative total is a snapshot with no ordering information on it. |
| **Resolve a decreasing restatement by `occurred_at`** | The alternative 0001 already refused for the whole model: processor timestamps are second-granularity and unordered, so ties fall through to which webhook's TCP connection finished first. Using them to *release* an over-reservation is the same mistake pointed at a smaller target. |
| **Quarantine on any cumulative total below the high-water mark** | Too broad. An out-of-order totals pair with no decrease in it is unambiguous — the maximum wins and is right — and quarantining routine traffic makes the queue useless. Measured: that group holds 15000 and is not quarantined. |
| **Let a quarantined group hold zero** | It would under-reserve by the whole group, which is the failure this ADR exists to remove. A group we cannot compute must hold the largest reading its log admits. |
| **Refuse the second message of a convention mix** | What 0001 does, and it destroys one of the two facts needed to compute even the pessimistic hold. Measured: 1 event in the log where there should be 2. |
| **An append-only trigger to make `unexplained_minor` unerasable** | A trigger needs a justification and this one does not have one. The app role holds `UPDATE` on `card_hold_groups` because the writer maintains it, so a trigger would have to distinguish the writer's write from an operator's — which it cannot. The honest position is 0001's: monotone *through the writer*, with the drift view as the independent check. |
| **Keep `expiry_reversal` in the enum, unusable** | The treatment `expiry` gets, and defensible there: `expiry` is a *concept* the model implements as a flag, so a reader looking for it finds it refused for a stated reason. `expiry_reversal` is not a concept — it is a message nobody sends. Leaving it invites an adapter author to map something to it. |
| **Drop `last_event_seq` with `open_events`** | Both are unread today. `last_event_seq` has a named consumer coming — the ingest cursor a batch API (D8) needs — and a monotone per-group counter is not reconstructible after the fact. `open_events` has neither a consumer nor a definition. |

## What it costs

| | |
| --- | --- |
| **The design now over-reserves in three places, on purpose** | A quarantined totals group holds the largest total ever restated: measured at **10000 against 9000 live**. A convention mix holds every increase as a delta: **22000 against 12000**. And a reversal that legitimately arrives *before* its authorization leaves a residue: **10000 held against nothing live**. Each is visible, alarmed and human-resolvable. The trade is explicit — today all three under-reserve silently, which is the cardinal sin, and the replacement is a cost a cardholder can feel. |
| **A fuzzy-matched increment that genuinely belonged to an existing group now double-counts** | D1's rule sends it to a new group, so a legitimate increment the matcher could only place fuzzily is held twice. It is recorded in `card_auth_review` as `fuzzy_increase_split` so a human merges it back — the *"explicit unmatched queue — never a silent guess"* the spec asks for, applied to the increase side for the first time. How often this happens is unknown: [spike 001](/card/spikes/001-append-only-holds) found **no published auth-to-clearing match failure rate**, from any network or processor, and instrumenting `matched_by` from day one is how we would find out. |
| **The review queue is now a staffed thing, not a table** | 0001's queue held unmatched events, which are rare. This one holds mis-groupings, split increases, convention mixes, unresolvable restatements and residues — states that resolve only by a human decision recorded as a re-grouping. **A queue nobody works is a worse failure than the one it replaced**, because the money is over-reserved rather than lost and everything looks fine. Nothing in this design sizes that queue. |
| **Nothing writes `hold_expires_at`** | D2 corrects the sweep's predicate, but the sweep still matches nothing, because no ingest path writes the deadline — the card rail's authorization-holds decision records the same gap. The corrected predicate is the shape; modelling the processor's deadline is the missing parameter, out of scope here. |
| **Un-quarantining is a rule, not a mechanism** | A group leaves quarantine when a human resolves it *and* the live log no longer satisfies the predicate that quarantined it — which is checkable, because it is a `card_hold_drift` disjunct. The writer enforces it and the view verifies it; there is no operator interface for it. |
| **`total_minor` is no longer the whole story** | It stays a faithful `SUM` over the log — drift's first disjunct is untouched — but `held_minor` is now `total_minor − unexplained_minor` clamped, floored by the quarantine hold. Two numbers where 0001 had one, and anyone reading `total_minor` alone to mean exposure will be wrong. |
| **Five of the nine fixes are enforced by the writer, not the schema** | D1's matcher rule, D3's quarantine, D4's storing-the-refused-message, D5's residue and D7's re-denomination are all rules the writer obeys, verified by views. Only the deletions, the columns, the constraints and the sweep predicate are enforceable by the schema alone. This is the same standing problem [0004](/decisions/0004-where-logic-lives) creates by design, and it is worth naming: **the schema cannot make most of this ADR true.** |
| **Every number here is from localhost, and none is a benchmark** | The deadlock ratio is 6-of-6 against 0-of-6 on two `psql` sessions. The permutation results are exhaustive over six orders of three messages, which is a proof about those three messages and not about traffic. |
| **The harness is a reading of prose** | The card writer does not exist, so [spike 004](/card/spikes/004-hold-corrections) had to re-implement 0001's ingest rules to reproduce anything. Where the prose was ambiguous it took 0001's own reproductions as the target and hit them to the digit in findings 1, 2 and 3 — which is the check on that reading, not a guarantee. |
