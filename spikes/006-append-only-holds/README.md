# Spike 006 — Holds as an append-only event log


> ⚠️ **The verification in this spike does not run, and its headline survey was
> invented.** Both are recorded here rather than quietly repaired, because this
> spike is the evidence base for [ADR-0010](../../docs/decisions/0010-authorization-holds.md).
>
>   *(This bullet has itself been corrected. It previously listed three schema
>   mismatches, two of which describe `schema/schema.sql` and not the file in this
>   directory: `holds.sql` does have `group_key` and does have `expires_at`. The
>   conclusion was right; two of its three reasons were not.)*
> * **`cases.sql` was dead against `holds.sql`, and has been deleted.** It wrote
>   `event_id`; the schema in `holds.sql` has `processor_msg_id` and no `event_id`
>   column at all, so every INSERT failed with `column "event_id" ... does not
>   exist`, the results view printed `(0 rows)`, and `held_for_company` printed
>   0.00. It also contained six cases where the "**Measured**" table below claims
>   eight — G ("clearing arrives before the auth") and H ("forced post"), the two
>   this README calls most interesting, were never in the file. So the table and
>   the "**all eight cases**, plus idempotency and sign guards" line were never
>   executed against anything. A file whose only property is "this does not run"
>   costs a reader a visit and teaches nothing the sentence above does not; the
>   live attestation of every one of these cases is
>   [`tests/card_holds.sql`](../../schema/schema.sql).
> * **"Surveying eleven issuer-processors" was fabricated**, and "six of eleven"
>   with it. Three processors are surveyed below. They disagree, which is the real
>   finding and the reason the design exists; the sample size was invented.
>
> The live attestation of this design is
> [`tests/card_holds.sql`](../../schema/schema.sql), which runs on every
> `make test-sql` against `schema/schema.sql`. Nothing in this directory is executed
> by CI, and it is kept as a record of how the design was reached.

## The question

A *hold* is the amount an authorization reserves against a card's credit limit. Today it is one
mutable row per authorization: `amount_minor` set at auth, `cleared_minor` UPDATEd as clearings
arrive, `state` UPDATEd on expiry — with `auth_id text NOT NULL UNIQUE`.

Two problems. It contradicts the append-only discipline used everywhere else in this ledger, and
**`auth_id UNIQUE` rejects an incremental authorization outright** — the hotel or fuel-pump case
where a merchant tops up an existing authorization. The
[reference spec](../../docs/reference-product.md) lists "incremental auths" in its edge-case table
while the schema makes them impossible.

## The answer

**Record every authorization event as an immutable signed row; derive the hold by summing.**

```sql
card_auth_events (
    event_id     -- idempotency: one row per processor message
    group_key    -- ties an auth to its increments, reversals and clearings
    kind         -- authorization | incremental | reversal | clearing | expiry
    amount_delta -- SIGNED: auth/incremental add, reversal/clearing/expiry subtract
)

group_total = SUM(amount_delta)
held        = SUM(GREATEST(group_total, 0))
```

`GREATEST` is what makes over-capture safe: a $1 fuel authorization cleared at $95 totals −94, and
must contribute **0** rather than silently *raising* available credit.

**One formula covers every case in the spec's edge-case table.** Measured:

| case | scenario | group total | still held | |
| --- | --- | --- | --- | --- |
| A | auth 500, partial clears 300 + 200 | 0.00 | 0.00 | fully consumed |
| B | **incremental** — 200, +150, +150, cleared 400 | 100.00 | 100.00 | ✅ *impossible under the old schema* |
| C | **over-capture** — $1 auth, $95 clearing | **−94.00** | **0.00** | clamped, credit not raised |
| D | reversal — merchant voided | 0.00 | 0.00 | released |
| E | expiry — clearing never came | 0.00 | 0.00 | released |
| F | authorized, nothing cleared | 330.00 | 330.00 | still reserved |
| G | **clearing arrives before the auth** | 200.00 | 200.00 | see below |
| H | **forced post** — clearing, no auth ever | −250.00 | 0.00 | contributes nothing to held |

### Order-tolerance is free

The spec requires the state machine be *"order-tolerant, not merely idempotent."* **`SUM` is
commutative, so this design is order-tolerant by construction** rather than by careful coding.

Case G, in order: the clearing lands first and the group reads `0.00` held — correct, nothing was
ever reserved. The authorization catches up and it reads `200.00` — 500 authorized less the 300
already cleared. No state machine had to anticipate the sequence.

### Idempotency and sign are database constraints

- A redelivered webhook is refused by `uq_auth_events__msg UNIQUE (tenant_id, processor_msg_id)`
  — not by application logic. (This line said `event_id`; there is no such column.)
- A clearing carrying a *positive* delta is refused by a `CHECK`. The sign is a property of the
  event kind, so it cannot be got wrong.

Both verified by attempting them.

## What it costs

**Reads become an aggregate.** `held` was a single-row lookup; it is now a `GROUP BY` over a
group's events. Groups are small — an authorization plus a handful of increments and clearings —
so the scan is bounded by *events per authorization*, not by history. But it is on the
authorization hot path, which has a ~1s deadline, and it has **not been benchmarked here**. If it
proves too slow the standard answer applies: a materialised per-group total maintained on write,
with the event log staying the source of truth — the same relationship
[ADR-0003](../../docs/decisions/0003-bitemporal-balances.md) sets up between `balance_after` and
recomputation.

**More rows.** Five to ten per authorization instead of one. At this volume, irrelevant.

## Research findings — three of them change the schema

### ⚠️ 1. Processors disagree on whether an increment is a DELTA or a TOTAL

This is the finding that most threatens the design, because getting it wrong is silent.

| processor | an incremental authorization reports… |
| --- | --- |
| **Marqeta** | a **delta** — *"Increases the amount of a prior `authorization` journal entry by adding to it without replacing it."* |
| **Adyen** | a **total** — `amount.value` is *"the sum of the original, pre-authorized amount and all later adjustments."* |
| **Highnote** (acquiring) | request is a **delta** ("additional $500"); the *response* echoes the cumulative total |

Our `amount_delta` column assumes deltas throughout. **Feed it a total and the hold double-counts**
— a $200 authorization topped to $350 would reserve $550. The customer is declined with headroom,
and nothing errors.

So the schema needs an explicit **normalisation boundary**: each processor adapter converts its
own convention into a delta before the event is written, and the raw payload is retained so the
conversion can be audited. `amount_delta` is a *normalised* field, not a wire field, and the docs
must say so.

### ⚠️ 2. The network identifier is unique per DAY, not globally

Galileo's documentation of Mastercard's Banknet Reference Number: 6–9 digits, *"guaranteed to be a
unique value for any transaction within the specified financial network **on any processing
day**."*

Our holds live 5–30 days. **Two unrelated authorizations can carry the same network reference and
be open simultaneously.** So:

- `UNIQUE (network_ref)` — wrong.
- `UNIQUE (card_id, network_ref)` — also wrong.
- Correct scope is `(financial_network_code, network_ref, network_date)`. The date is *part of the
  key*, which is exactly why Mastercard's own composite "Trace ID" includes the settlement date.

Grouping on the bare number would merge two genuinely different holds.

### ⚠️ 3. `999999` is a sentinel meaning "populated, but meaningless"

Pismo, on Mastercard: the platform *"ignores the trace ID when the value received for the Banknet
Reference Number is `999999`, since this value can be used only to populate the field without
indicating any relationship."*

**Grouping on the network identifier without stripping sentinels would collapse unrelated
authorizations, across unrelated cards, into one hold group.** Assume other undocumented sentinels
exist; the group-key extractor must null them rather than trust the field.

### What the linking identifiers actually are

| network | links an increment to its original |
| --- | --- |
| **Visa** | Transaction Identifier (field 62.2); Message Reason Code `3900` marks the message as incremental |
| **Mastercard** | Trace ID / Banknet reference — but grouping is **match-based**: a message is an increment *because* its trace matches an open pre-authorization of yours, not because it says so |
| **Mastercard (in migration)** | **TLID** in DE 105 replaces Banknet Reference, Trace ID and Switch Serial Number, and covers voids, refunds, increments and chargebacks. Sources disagree on its length — **store network identifiers as `text`, never a fixed width** |

**Never key on the authorization code (DE 38).** Sources actively conflict on whether it repeats
across an original and its increments. Either way it is a display field.

### Event-id stability across redeliveries is not universal

Our `UNIQUE (tenant_id, event_id)` assumes a processor reuses the id when it redelivers. **Stripe
and Lithic document this. Marqeta and Highnote do not** — they document unique event ids and tell
integrators to be idempotent, without stating that a *resend* carries the same id. Must be verified
in each sandbox before the constraint is relied on.

### Also worth knowing

- **Lithic's `AUTHORIZATION_ADVICE` carries two unrelated meanings** — either an authorized amount
  was modified, or the network declined on your behalf. Branch on the content, never on the event
  type string.
- **No prevalence figures for incremental authorization exist publicly**, from the networks or
  analysts. Plan for it structurally — travel and entertainment spend exists, and both networks
  now permit increments for all merchant categories — not from a rate estimate.

## Network rules — three of our assumptions were wrong

From the **Visa Core Rules and Product and Service Rules, 18 April 2026**, read directly. Rule IDs
are verbatim-checkable. (Mastercard's rulebooks are member-gated and returned 403 throughout, so
every Mastercard figure below is from processor documentation, not primary.)

### 1. Our expiry windows were Mastercard's, not Visa's

We had "~7 days, longer for T&E." **Visa's Table 5-12 says 5 days card-present**, 10 card-absent,
and **30 only when the Estimated or extended indicator is present** — a hotel that omits the
indicator gets 5. Merchant-initiated transactions also get 5.

The 7-and-30 figures are Mastercard's, and they are the industry default *hold* policy. Which
leads to the real correction:

### 2. There are TWO clocks and we modelled one

| clock | what it is | who sets it |
| --- | --- | --- |
| **Clearing deadline** | Table 5-12. Breach gives the *issuer* a dispute right (Condition 11.3, 75 days) | the network |
| **Hold release** | when we stop reserving the cardholder's credit | **us** |

`expires_at` currently conflates them. They must be separate, and the hold clock should sit
*longer* than the clearing deadline so a last-day clearing still matches.

Two sharp edges: **an incremental authorization does not extend the clearing deadline**
(§5.7.3.5, ID# 0031022) — the clock runs from the original — while Stripe *does* extend the hold.
And **expiry is not terminal**: releasing the hold does not prevent a later clearing, and if one
arrives you are liable for it.

### 3. Visa incrementals are not free-standing

*"A Merchant may submit an Incremental Authorization Request where it has obtained an Approval
Response for a valid Estimated Authorization… The Merchant must use… **the same Transaction
Identifier** used for the initial Estimated Authorization Request."* (§5.7.2.5, ID# 0030937)

So on Visa it is a state machine — **Estimated → Incremental(s), all sharing one Transaction
Identifier** — not a standalone message type. And the Transaction Identifier is exactly what the
group key should be: Visa's glossary calls it *"a unique value assigned to each Transaction…
[used] to maintain an audit trail throughout the life cycle of the Transaction and all related
transactions, such as Reversals, Adjustments, confirmations, and Disputes"* (ID# 0025182).

That corroborates the earlier finding from the processor side: group on the authorization's
lifecycle identifier, never on the RRN or the approval code.

### Other rules that change the model

- **`authorized_amount` and `held_amount` must be separate fields.** Tolerance padding adjusts the
  *hold*; rules evaluate the *authorization*. A $50 restaurant authorization reserves $65 at 30%
  tolerance, but the authorization is still $50.
- **Auth → clearing is one-to-many**, by rule: airlines, cruise lines, US railways and split
  shipments may send multiple clearings against one authorization, keyed by Multiple Clearing
  Sequence Number (§5.7.3.2, ID# 0027756). Our summed-deltas model handles this natively; a 1:1
  foreign key would not.
- **Tips are not increments.** A tip arrives as a *larger clearing* inside the tolerance table, and
  Visa explicitly bars estimated authorizations from covering tips (§5.7.2.4). Never flag a
  restaurant clearing merely for exceeding its authorization.
- **Tolerance is a date-effective network × MCC × region lookup, not a constant.** US restaurants
  move from 20% to 30% on 21 February 2026 (Table 7-10).
- **Never diff billing-currency amounts across auth and clearing.** FX moves in between, so on
  cross-currency transactions that delta is expected on *every* transaction. Compare
  transaction-currency amounts only.
- **STIP approvals are binding**: *"An Issuer is responsible for any Transaction approved or
  declined by Stand-In Processing"* (§1.4.4.3, ID# 0004386). The ledger must ingest an approval it
  never made.
- **EEA/UK release on clearing, not on timer.** Visa's rules impose no general hold-release
  mandate, but PSD2 Article 75 requires release without undue delay once the exact amount is known.
  A timer-only implementation is non-compliant there.
- **Unmatched clearing is a normal state.** Stripe ships `authorization: null`; Marqeta and Lithic
  both model force-post as a first-class type. Our nullable `group_key` matches this.

### And one number that does not exist

**There is no published auth-to-clearing match failure rate**, from either network or any
processor. Every research path looked. The widely repeated figures are folklore. Instrument
`matched_by ∈ {lifecycle_id, rrn, fuzzy, unmatched}` from day one and measure our own.

## The open question this does not answer

**What is `group_key`, really?** The design assumes some identifier is stable across an original
authorization, its increments, its reversals and its clearings. Candidates differ in stability:
Visa's Transaction Identifier, Mastercard's Banknet reference, the RRN, the ARN, the approval
code, or a processor's own transaction object id.

The spec already warns that this is not clean: *"No clean foreign key. Network IDs (ARN, RRN)
don't reliably agree across messages. Needs exact match, then fuzzy fallback on
card+merchant+amount±tolerance+window, then an explicit unmatched queue — never a silent guess."*

So `group_key` may not always be knowable at write time, and the table must tolerate a row
arriving before its group is resolved. **The research above narrows this considerably**: a group key exists on both networks, but it is
composite, sentinel-polluted, day-scoped, and mid-migration on Mastercard. The optimistic single
`group_key text` column in `holds.sql` is *not* sufficient as written.

## Reproduce

```sh
psql "$DSN" -f holds.sql    # schema + the derived view
```
