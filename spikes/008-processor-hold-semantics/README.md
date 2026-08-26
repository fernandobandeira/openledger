# Spike 008 — what card processors and ledger APIs actually do

**Status:** closed
**Supersedes** the processor survey in [spike 006](../006-append-only-holds/README.md), which was
fabricated by an earlier agent and struck. **Nothing here is reused from it.**

**Question.** [ADR-0010](../../docs/decisions/0010-authorization-holds.md) makes claims about how
processors behave — delta versus cumulative totals, what an authorization does to a ledger, what
reversal and expiry mean, what ordering is promised. Every one was asserted without a source. Are
they true?

**Method.** Thirteen systems, read from their own published API references. Where a vendor serves
Markdown source (Modern Treasury, Lithic, Marqeta, Stripe, Increase, Adyen, Galileo, Pismo) that
was read directly; otherwise HTML with tags stripped.

**Six URLs are cited in this document.** An earlier version of this line said "all 51 cited URLs
returned HTTP 200 when checked" — 51 pages were *read*; six were *cited*. That is exactly the
distinction this spike exists to police, missed by the spike itself: a claim about work a reader
cannot repeat is not a source, and this document's entire reason for existing is that an earlier
agent claimed a survey nobody could repeat. **Treat every quote below that carries no link as
unverified.** The six that are linked have been independently re-fetched and confirmed verbatim by a
second reviewer — who also found two of them overstated, which is what checking is for. **No search results, no blogs, no third-party summaries** — with one labelled exception
(Fragment's storage layer, which only appears on their blog).

---

## The headline: our central claim needs narrowing, not retracting

ADR-0010 says **an authorization writes no ledger entry; only a clearing posts.**

That is **true of every posted balance surveyed** and **wrong as a blanket statement**. Roughly half
of these systems write a durable, balance-affecting row at authorization time, into the same log as
postings:

| Writes a row at authorization | Keeps the hold outside the ledger |
| --- | --- |
| Stripe — `issuing_authorization_hold` balance transaction | Increase — `PendingTransaction`, a separate object |
| Treasury Prime — a `hold` Transaction row | Marqeta — `available_balance` vs `ledger_balance` |
| Highnote — posts to an `AUTHORIZATION` ledger | Galileo — pending vs ledger balance |
| Adyen — a Received→Reserved register movement | Lithic — `amounts.hold` on the transaction |
| Moov — `issuing-auth-hold` wallet transaction | Unit — a mutable `Authorization` object |
| Column — you write a real book transfer in `hold` state | |

And it is **flatly wrong for single-message transactions**, which are a real part of the domain:

> "Approving an SMS transaction triggers immediate financial impact"
> — [Lithic, transaction flow](https://docs.lithic.com/docs/transaction-flow)

> "the account is immediately debited for the full amount of the transaction with no prior hold"
> — Treasury Prime, `auth-clear-request`

Marqeta's `auth_plus_capture` family is marked *"Final transaction type"* with an explicit *"Ledger
impact"*. **Our `auth_event_kind` has no value for any of these.** An adapter would have to forge a
same-instant authorization-plus-clearing pair.

---

## Delta versus cumulative total — the question ADR-0010 was right to refuse to answer

This is the finding that most vindicates the design. There is **no convention**, and one vendor
contradicts itself on a single page.

| Vendor | Convention | Evidence |
| --- | --- | --- |
| **Adyen** | **delta** | A GBP 1.50 increment on a GBP 4.00 order emits an `authAdjustmentAuthorised` row carrying **-1.67 EUR** (the increment); the later capture row carries -6.13 (the total). [payment-lifecycle](https://docs.adyen.com/issuing/report-types/balance-platform-accounting-report/payment-lifecycle) |
| **Pismo** | **delta** | *"the issued events have the amounts and information of the incremental operation, but the identifiers … are the same as the original one"* — [incremental-authorization](https://developers.pismo.io/pismo-docs/docs/incremental-authorization) |
| **Lithic** | **cumulative** | An `AUTHORIZATION` at 1000 followed by `AUTHORIZATION_ADVICE` at **2000**; *"an Authorization Advice has augmented the authorization amount from \$10 to \$20"* |
| **Galileo** | **cumulative, restated** | *"SoFi Tech Solutions immediately combines the incremental amount with the previous amount and presents the **cumulative amount** as the transaction amount in external data"* — [authorization](https://docs.tech.sofi.com/pro/docs/authorization) |
| **Column** | **cumulative** | A \$100 → \$300 re-auth is `PATCH … -d amount=30000` — the new total, not `+20000` |
| **Unit** | **cumulative** | `authorization.amountChanged` carries `"oldAmount": 2000, "newAmount": 1500` |
| **Stripe** | **both, labelled** | `pending_request.amount` is *"the requested incremental amount"*; top-level `amount` is the running total |
| **Increase** | **both, labelled** | `card_increment.amount` (delta) alongside `updated_authorization_amount` (total) |
| **Marqeta** | **contradicts itself** | `authorization.advice` is *"Decreases the amount of an existing authorization journal entry"* in two tables and *"**Replaces** the amount"* in a third — [on the same page](https://www.marqeta.com/docs/core-api/event-types) |

**Sum Galileo's amounts as deltas and you over-count. Sum Adyen's as totals and you over-count.**
Same conceptual event, opposite arithmetic. `raw_amount` + `raw_is_total` + `total_convention` is
the right shape, and Marqeta's self-contradiction is the argument for storing the wire value verbatim
rather than trusting any vendor's prose.

---

## What else is confirmed

- **`held_minor = GREATEST(total_minor, 0)`.** *"It is also possible for the reversed amount to be
  greater than the authorized amount… if there is an over-reversal, Lithic will cap the
  `amounts.hold.amount` to \$0."* — Lithic.
- **Grouping is a revisable inference.** *"Highnote does not force-link events when the network
  identifiers do not align."* / *"**Do not rely solely on network reference IDs** to correlate
  authorization and clearing events. Network identifiers are not guaranteed to be consistent across
  the lifecycle of a transaction."* — [transaction-lifecycle](https://docs.highnote.com/docs/issuing/transactions/transaction-lifecycle).
  That is `card_auth_event_group` and `regroup_auth_event`, justified by a processor.
- **Out-of-order clearing is a named, routine sequence,** not an edge case: Highnote's message table
  lists `AUTHORIZE → CLEAR (final) → CLEAR (1st)` as *"Multiple clearing – out of order"*.
- **Negative available credit is legal and unavoidable.** *"the account may be debited for the full
  clearing amount and the balance may become negative"* (Unit); *"Adyen cannot decline forced
  captures"*; *"you can't block these transactions"* (Stripe); Pismo posts forced clearings
  *"without any additional validations"*.
- **Closing the hold and raising posted must be one transaction.** Galileo says it outright:
  *"the ledger is locked during the time that the backout and settlement/completion are posted, so
  the backed-out amount cannot be spent."*
- **Ordering is promised by nobody, and denied by five.** Stripe: *"Stripe doesn't guarantee the
  delivery of events in the order that they're generated."* Column: *"does **NOT** guarantee that
  events will be delivered in the same order as they are created."* Galileo: *"Event messages will
  likely not arrive on your system in the same order they were generated"* — with retries defaulting
  to **zero**. Highnote goes furthest: notifications *"are not authoritative"* and *"Do not use
  webhook arrival order to drive money movement."* Modern Treasury, Lithic, Marqeta, Increase and
  Moov publish **no ordering statement at all** — an absence of documentation, not a guarantee.
- **Stripe's two-event-ids caveat, which ADR-0010 already cites, is real:** *"In some cases, two
  separate Event objects are generated and sent. To identify these duplicates, use the ID of the
  object in `data.object` along with the `event.type`."*

## What is contradicted

1. **"An authorization writes no ledger entry"** — narrow to *no **posted** entry*, and say the
   separate-table choice is ours, not the field's.
2. **"Increase ships the same clamp as `pending_transaction.held_amount`"** — a misreading.
   `held_amount` is a *credit-direction* guard (*"This is usually the same as `amount`, but will
   differ if the amount is positive"*) so a pending refund does not raise spending power. It is not
   an over-capture floor. Cite Lithic's cap-to-zero instead.
3. **"Expiry is a flag, not an event carrying −remaining."** Defensible on commutativity grounds,
   but **we are alone**: Treasury Prime writes `hold_release`, Highnote runs an expiration job that
   emits a REVERSAL, Moov writes `issuing-auth-release`, Adyen writes an `expired` register row,
   Galileo writes a backout, Stripe writes `issuing_authorization_release`. TigerBeetle is the one
   ally. State the divergence rather than implying agreement.
4. **`total_convention` fixed by the first increase-side message** discards free disambiguation:
   Stripe, Increase and Treasury Prime send delta *and* total on the same message.

## Three things the model cannot express

- **A single-message transaction.** No enum value; it authorises and clears at once.
- **An end-of-sequence indicator.** Lithic: *"the clearing is not marked as `FINAL`, so additional
  clearing may still arrive."* Galileo: *"an indicator in the clearing message says that there are
  no more clearings to come."* Both terminate a group without waiting for expiry. We can only expire.
- **A hold that differs from the authorized amount.** Lithic's hold-adjustment rules change *"only
  the hold … the cardholder and merchant amounts continue to reflect the original authorization
  amount."* Stripe holds a **\$100 default** on a \$1 fuel status check. `held_minor` is derived from
  the sum of authorization deltas and cannot diverge from it.

## Two places we are ahead of the field

- **Nobody enforces "debits equal credits" at the storage layer.** Modern Treasury asserts it as an
  API rule (*"The total balance of all Entries on a single Ledger Transaction must have equal debits
  and credits"*) with a 422. Fragment makes it unrepresentable at *schema-compile* time — *"Ledger
  Entries must be balanced by the Accounting Equation. If they are not, the Ledger designer throws
  an error."* Column, Unit, Moov, Treasury Prime, Stripe and Galileo do not expose entries at all.
- **Accounting semantics are rare, and a trial balance is unheard of.** Only **Highnote** (category +
  `normalBalance` + `journalEntry { credits debits }`, and a chart that nearly matches ours account
  for account), **Pismo** (accounting scripts, COSIF) and **Fragment** (four account types,
  balance-sheet recipes) expose any. **Not one of the thirteen publishes a trial balance.**

---

## Worth stealing

- **Galileo's "bookkeeping authorization".** On a partial clearing they write *"a new entry in its
  ledger for the remaining preauthorization amount, and when the next clearing arrives it is matched
  to the new entry."* A synthetic row instead of a mutable remainder.
- **Column's four balances**, which separate two things we conflate: `holding_amount` (auth holds)
  and `pending_amount` (unsettled inbound) are different quantities.
- **Modern Treasury's `partial_post`**, and its constraint: each posted entry must be strictly *less*
  than the pending one, so their model cannot express over-capture at all.
- **Unit's per-endpoint delivery guarantee** — the caller chooses at-most-once or at-least-once.

## Anti-patterns observed

- **Moov deletes failed pending transactions**: *"If a pending transaction results in a failure,
  we'll simply omit it from the transaction list."* A reconciliation hazard.
- **Unit's `Canceled` conflates merchant reversal and expiry** — indistinguishable from status alone.
- **Column's `PATCH` and `clear` are not idempotent endpoints**, a direct consequence of
  mutate-in-place.
- **Treasury Prime publishes no webhook dedup key** — payload is `event`, `op`, `id`(object), `url`,
  so a retry and a genuine second update are indistinguishable. Their partial-authorization table
  also does not balance (hold `-10` against `hold_release 25`, prose says \$25).

## What could not be verified

Recorded rather than guessed. **Highnote's issuing-side incremental amount semantics are entirely
undocumented** — the biggest hole; the delta definition that exists is from their *acquiring* API and
must not be generalised. **Moov's delta-versus-cumulative is genuinely ambiguous** and was not
guessed. **Pismo documents no expiry window, job or release event.** **Column documents no hold
expiry at all** and over-capture behaviour is unstated. Marqeta's two contradictory `advice`
definitions were not resolved — the docs simply disagree. Adyen publishes no Balance-Platform
duplicate-detection rule; `data.events[].id` as the dedup key is an inference from payloads.
Ordering is undocumented for Modern Treasury, Lithic, Marqeta, Increase and Moov. No storage-layer
evidence was obtained for any commercial vendor.
