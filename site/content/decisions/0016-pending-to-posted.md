# 0016 — Pending → posted is a new transaction, on the same endpoint

**Status:** accepted 2026-08-31 — the surface is built, tested and documented below; the API
*shape* (two optional fields on `POST /v1/transactions` rather than a second endpoint) was this
ADR's own call, made because no earlier ADR specified it, and Fernando ratified it on review.
**Evidence:** [ADR-0004](/decisions/0004-where-logic-lives)'s counterexample table (the −49,223
revenue reached through an unguarded `resolves_id`); `recon_pending_bridge` and
`recon_journal_to_reports` in `migrations/00001_baseline.sql`;
`crates/e2e/tests/e2e/endpoints/transactions/pending.rs` for the contract held on the wire.

## The decision

**A caller can post a transaction as `pending`, and later resolve it — and the resolution is a NEW
posted transaction carrying `resolves_id`, never an UPDATE to the original.** That sentence is the
roadmap's M3 contract verbatim, and the schema has carried its whole shape since the baseline:
`ledger_transactions.status` never mutates, `resolves_id` points a resolution at its target,
`uq_txn__one_supersession` (migration 00003, replacing the baseline's two per-pointer indexes)
allows the target exactly one supersession, and the reconciliation views already name
the pending population (`recon_pending_bridge`) and its retirement (`superseded` in
`recon_journal_to_reports`). What this ADR decides is the *surface* and the *writer semantics* —
the two things the schema deliberately left to the Rust.

**The surface is the same endpoint grown by two optional fields, not a second endpoint.**
`POST /v1/transactions` accepts:

- `status`: `"pending"` or `"posted"`, defaulting to `"posted"` — omitting it keeps yesterday's
  requests byte-for-byte valid and meaning what they meant.
- `resolves_id`: the id of the pending transaction this one resolves. A resolving transaction is
  posted; the pair `status: "pending"` + `resolves_id` is refused by the command's constructor,
  because a claim that "resolves" a claim would retire the target from the pending population
  while its replacement is still not on the books — a state no bridge could foot.

Why not a route of its own: a resolution *is* a transaction — it carries postings, an idempotency
key, an effective date, and lands through the identical claim-and-append statement — so a
`/resolve` route would restate the entire body schema to add one field, and there is nothing else a
caller can do to a pending transaction that would ever share that route. The thinnest extension is
two columns the schema already owns, surfaced under their schema names.

**The writer semantics were already decided elsewhere; this ADR applies them and cites the owner:**

| question | answer | decided by |
| --- | --- | --- |
| Does a pending transaction move the balance cache? | **No.** `input`/`output` accumulate POSTED transactions only; the plan withholds a pending transaction's balance movement in the pure math (`plan_append`), so the upsert needs no branch | [ADR-0010](/decisions/0010-reconciliation)'s ruling, restated on `ledger_account_balances` in the baseline |
| Does it advance `account_seq` / `last_seq`? | **Yes, both** — a pending entry still needs its `account_seq` issued under the same lock, so `last_seq` advances by the leg count while the balance stands | the same ruling, same comment |
| What does a replay return for a pending or resolving key? | The stored `(event_id, transaction_id)`, re-rendered — the replay contract is status-blind and nothing about it changes | [ADR-0013](/decisions/0013-write-path-contract) §2 |
| Must a resolution mirror the pending amounts? | **No.** A pending transaction is retired *by reference* — the bridge and the `superseded` bucket test `resolves_id`, never amounts — so a partial capture resolves with less and the cache moves by what actually posted. Amount policy belongs to the rail ([card 0001](/card/decisions/0001-authorization-holds): clearings routinely differ from the hold) | the baseline's own views |
| What may a resolution target? | **A pending, unresolved transaction on the caller's own tenant — enforced by the writer.** The foreign key holds existence and nothing declarative holds the semantics: ADR-0004 reproduced a posted transaction "resolved" by another posted one taking revenue to **−49,223** with drift at 0. The single-call statement reads the target and gates the transaction insert on `status = 'pending'` and no existing supersession — since the reversal slice the gate tests BOTH pointers, so a voided pending refuses a resolution too; a failed gate comes back as a diagnosis and the service refuses by name — `resolve_target_unknown`, `resolve_target_not_pending`, `target_already_superseded`, each a 422 with nothing written | [ADR-0004](/decisions/0004-where-logic-lives); the gate is Rust-side logic in the adapter's one statement, **no trigger** |
| Two resolutions racing one target? | The gate reads committed state, so the race falls through to **`uq_txn__one_supersession`** — the loser blocks on the winner's uncommitted index tuple and, when it commits, is refused; the adapter maps that one constraint by name onto the same `target_already_superseded` refusal the sequential case gets, never a 500. Since the reversal slice the same index referees the resolve-vs-reverse twin in both directions | the supersession index as backstop; the mapping is pinned by the **uncommitted-rival** e2e tests — resolve racing resolve, a void racing an uncommitted resolution, a resolution racing an uncommitted void — each holding a rival open on a second connection until the API call is provably blocked on it (polled in `pg_stat_activity`), then committing; the eight-racer test holds the *gate* under concurrency, whose losers typically arrive after the winner commits |

**The canonical hash and the stored payload cover every semantic field** — `status` and
`resolves_id` included, unconditionally, so absence can never be confused with a value. This is
load-bearing, not bookkeeping: strip either field from the byte form and a same-key retry that
changed only its status silently REPLAYS instead of being refused as a reused key — money moving
twice behind a 200 — and the e2e reuse tests hold exactly that red. The layout stays under the
`openledger.post.v1` tag and the payload's `"version": 1` marker: pre-v0.1 the canonical layout
changes freely under the one tag, because no kept database exists to hold bytes an older binary
wrote — versioning ceremony begins at launch, the same license the ADR-0003 baseline freeze took.

**`kind` stays `'posting'`** for pending transactions and resolutions alike. The reconciliation
family keys on `status` and `resolves_id`, and the only kind any view treats specially is
`period_close` (ADR-0011); inventing `'hold'`/`'capture'` kinds here would be the card rail's
vocabulary leaking into the core.

## What we considered

| | Why not |
| --- | --- |
| **`POST /v1/transactions/{id}/resolve`** | A second route whose body restates the whole posting schema to avoid one field. The resolution is not an action *on* the pending row — nothing about that row changes — it is a transaction of its own, and the endpoint for posting transactions already exists. |
| **`PATCH /v1/transactions/{id}` to `status: posted`** | An UPDATE — the exact thing the roadmap contract forbids, `refuse_mutation()` refuses, and the ADR-0007 rule-14 scar (a pending authorization recognised as revenue, then counted again at resolution) exists to prevent. Not considered long. |
| **Require the resolution to mirror the pending amounts** | Refused. Retirement is by reference in the schema, and the first real consumer (the card rail) needs the amounts to differ — partial capture, over-capture. A mirror rule here would be configurable correctness one ADR later. |
| **Let the unique index alone refuse the double resolution** | Then the sequential case — the common one — surfaces as a constraint violation dressed as a 500. The gate diagnoses and names all three refusals; the index stays what it is everywhere else in this design: the backstop for the race the gate cannot see. |
| **A `voids` / expiry surface in the same change** | Deferred out of the resolution slice — and since built: the void is the zero-posting reversal in [Reversals and the void](#reversals-and-the-void--built-2026-08-31), landed 2026-08-31. Expiry stays M8's. |

## What it costs

- **A pending transaction nobody acts on still stays pending.** Voiding is built — the
  zero-posting reversal in
  [Reversals and the void](#reversals-and-the-void--built-2026-08-31) — but it is caller-invoked:
  hold EXPIRY, the timer that fires a void unprompted, stays M8's durable timers, so the bridge's
  `oldest_pending_effective_at` remains the aging alarm ADR-0010 put there for exactly this.
- **The canonical layout is mutable until launch, by policy.** The hash bytes and payload grew
  fields under the unchanged v1 tag, so any event stored before this change would replay-refuse
  its own retry under today's binary. Free while no kept database exists; the day one exists, that
  license ends and the tag starts versioning.
- **The race refusal hangs on a constraint name.** The adapter maps `uq_txn__one_supersession` by
  its catalog name; rename the index — or the match string — and every genuinely-blocked case
  silently degrades to a 500. The **uncommitted-rival** e2e tests are what fail when that happens
  (proven by mutation, re-proven when the name moved from `uq_txn__one_resolution` in migration
  00003 — the migration and the renamed mapping shipped as one slice, closing the sequencing
  hazard this ADR recorded); the eight-racer test cannot catch it, because its losers arrive after
  the winner commits and are refused by the gate.
- **The gate/schema coupling on retirement is CLOSED** (it once read: the gate tests
  `resolves_id` only while the schema retires on resolved OR reversed). The reversal slice widened
  the gate to both pointers, and `uq_txn__one_supersession` referees the race the two per-pointer
  indexes never could. Stated precisely, because a mutation run disproved the looser sentence that
  stood here: **the wire answer for resolve-after-void is guaranteed by the index backstop plus
  the constraint-name mapping** — revert the gate's read to `resolves_id` only and the insert
  trips the index, the mapping names it, and the caller sees the identical 422, so the entire
  suite stays green. The gate's both-pointer read is a deliberately redundant **fast path**: it
  answers the sequential case from the diagnosis instead of falling to the constraint, and being
  wire-indistinguishable from the backstop it cannot be pinned red in isolation. Redundant in
  answer is not redundant in mechanism — the gate is what keeps the common case an ordinary
  refusal rather than an aborted transaction — but no test claims to hold that half alone.
- **The endpoint's 422 family grew from three types to eight.** Each is real and reachable
  (ADR-0014's per-endpoint rule), but the surface a caller must parse is larger.
- **The gate adds one committed-state read to every RESOLVING post** — inside the same single
  statement, so the round-trip count is unchanged: three, same as any post.

## Reversals and the void — built 2026-08-31

**Status of this section: ratified by Fernando on 2026-08-31, after an adversarial review with
prior-art research, and BUILT the same day — accepted with the rest of this ADR.** The
rulings below are the reversal slice's contract; where the review produced a worked failure mode,
it is cited the way the rest of this file cites spike measurements. The three changes the design
forced on existing machinery were recorded here as **implementation requirements** before the
slice, and each now holds — the text below marks where.

**A reversal is a NEW posted transaction carrying `reverses_id` — operational undo, nothing else.**
The same never-an-UPDATE contract as resolution, on the same endpoint, with one deliberate
asymmetry: **a reversal request carries NO postings array** (a body with both `reverses_id` and
`postings` is a 422). A full-mirror reversal's legs are fully determined by its target — same legs,
directions flipped — so caller-restated postings are pure failure surface: nothing they could add,
every divergence a bug the writer would then have to adjudicate. The server derives the mirror from
the target inside the single statement. This is what the field does: Modern Treasury, Formance,
blnk and Midaz all take a reversal request with no postings in it. Stated honestly: this section's
surface does NOT inherit the resolution's same-endpoint argument — that argument was "a resolution
IS a transaction, carrying the posting schema anyway", and a reversal's body is precisely not the
posting schema. The endpoint stays for API-surface economy: one write route, three request shapes,
against a second route whose entire distinct content would be one field.

**Reversing a pending IS the void, and it ships in this slice** (Fernando: *"void now"*). The
design is the **zero-posting marker**: a POSTED transaction carrying `reverses_id` and NO entries.
The cache is untouched because there is nothing to withhold — the pending never moved it — the
trial balance stays clean, and the bridge already retires resolved-OR-reversed, so the pending
leaves the population the moment the marker commits. A reversal of a POSTED target, by contrast, is
an ordinary mirror posting that moves the cache back. The marker's three named costs are this
slice's implementation requirements:

1. **`recon_transaction_breaks` flags `no_entries`** — the ADR-0004 `TRUNCATE` scar's own class —
   so the view needs a carve-out for a transaction carrying `reverses_id` whose target is pending.
   **Held**: migration `00003_one_supersession_and_the_void_carve_out.sql` replaces the view
   (the set is append-only: 00001 and 00002 stay frozen; the schema snapshot moved with it), and
   the carve-out is exactly that narrow — an entryless transaction with no `reverses_id`, or one
   whose target is posted, stays a break.
2. **ADR-0005's primitive grows a stated exception.** "A transaction is a list of postings" is that
   ADR's load-bearing sentence; the void is a transaction that is deliberately not one. **Held**:
   the exception is recorded in [ADR-0005](/decisions/0005-event-log-and-write-path) itself, dated
   and cross-referenced, not discovered in the schema.
3. **`claim_and_append`'s answer must anchor on the claimed row before this ships.** The
   adversary's failure mode #1, recorded as a requirement: the statement's final `SELECT` answered
   one row per delta (`CROSS JOIN delta`), and a zero-entry void has **zero deltas** — so a
   successful void would have returned zero rows, the replay signal: the first void would claim
   its key, write its marker, and be answered as a replay of itself (statement B inside the same
   open transaction finds the uncommitted claim, hash matching) — whose closing rollback then
   DISCARDS the marker. **Held**: the final `SELECT` now anchors on `claimed` (`LEFT JOIN` onto
   the deltas), so rows come back whenever the claim inserted, deltas or none; the
   void-is-its-own-creation e2e test is the pin.

**Legal targets — the gate, widened.** A reversal's target must: exist on the caller's tenant; be
`kind = 'posting'` (reversing a `period_close` would un-close retained earnings while the
checkpoint rows and the close's cursor still stand — a statement of changes in equity contradicted
by its own period record); be status posted OR pending (pending = the void); and **carry neither
pointer itself and not already be superseded** — no reversal of reversals, no reversal of
resolutions, no second supersession of anything. The worked failure that rules out reversing a
resolution: reverse resolution R of pending P, and P is stranded forever — the bridge retires P
because R *exists*, not because R is live, so P never rejoins the pending population, and
`uq_txn__one_resolution` keeps P's resolution slot occupied eternally; the books show a hold that
can neither post nor age. Midaz refuses reversal-of-reversal flatly; Formance answers
`ErrAlreadyReverted`. **Recovery from a mistaken reversal is a fresh ordinary posting** — the same
recovery as every other mistake on an append-only book. A mistaken *resolution* recovers the same
way (ruled 2026-08-31): undoing it in place would violate the book's immutability, so correcting
it means writing a new transaction that moves the money where it should have gone. And `status: "pending"` + `reverses_id` in
one request is a constructor refusal, the twin of the pending-resolution refusal above: a pending
"reversal" would retire its target from the pending population while its own legs join it — one
request moving the population twice, a book no bridge could foot.

**One supersession index replaces the two partial ones.** The resolve-vs-reverse race has a twin
the two per-pointer indexes cannot see: `uq_txn__one_resolution` and `uq_txn__one_reversal` are
never unique *against each other*, so a pending could be resolved AND voided — two writers, one
committing each pointer — with no arithmetic witness anywhere (the bridge retires the pending
either way; nothing counts twice; nothing breaks). The declarative backstop is one index:

```sql
CREATE UNIQUE INDEX uq_txn__one_supersession
    ON ledger_transactions (tenant_id, COALESCE(resolves_id, reverses_id))
    WHERE resolves_id IS NOT NULL OR reverses_id IS NOT NULL;
```

`ck_txn__not_both` is what makes the `COALESCE` sound — a superseding transaction carries exactly
one pointer, so the expression names the sole target. This subsumed both per-pointer indexes and
**landed as migration 00003** (the set is append-only), in the same slice as the adapter's renamed
constraint mapping — shipping either half alone would regress the race to a 500, the sequencing
hazard this ADR recorded. The uncommitted-rival e2e pins extend to the new name and to both
directions of the resolve-vs-reverse twin; the mutation discipline above applies verbatim, one
name over.

**Effective date: a soft convention, no refusal** (Fernando explicitly rejected erroring). When the
reversal omits `effective_at`, it defaults to the TARGET's — Modern Treasury's behavior, and the
date on which the mirror cancels its original in every as-of view. A caller-supplied date is
accepted as given, **including one below the target's**, with the cost stated honestly: an as-of
window falling between the two dates shows the mirror without its original — money un-moved before
it moved. Convention plus documented cost, open to hardening later if the window is ever hit in
practice.

**Contra, not storno.** The mirror flips DIRECTIONS; `ck_entries__amount_positive`'s
`amount_minor > 0` stands. This is the peer consensus — Formance, TigerBeetle (structurally:
amounts are unsigned), Modern Treasury, Stripe, blnk and Midaz all book contra — against the
classical storno alternative (negative amounts on the original side), and the cost is recorded
verbatim: **every reversal inflates gross `input`/`output` turnover on both sides, forever, with no
break anywhere** — the schema's "gross turnover is free" claim (the balance table's own comment)
degrades to "gross turnover includes reversal noise". Storno exists in classical practice precisely
to keep turnover clean; Microsoft Dynamics' storno documentation carries exactly this
turnover-inflation point. Mitigation is report-layer filtering, which is possible *because*
`reverses_id` is queryable — a report that wants reversal-free turnover joins it out.

**Scope guard: `reverses_id` is operational undo — "this posting should not have happened."**
Everything that is business reality rather than bookkeeping error is an ordinary posting: refunds
and every chargeback-stage movement post to contra-revenue accounts the chart already anticipates
(`chart_presentation`'s own comment: refunds/chargebacks are revenue-category with DEBIT normal
balance), and the chargeback LIFECYCLE stays in the product layer, per
[card 0001](/card/decisions/0001-authorization-holds)'s dispute bet. **Partial anything is never a
reversal** — a partial refund is an ordinary posting for the partial amount. Named cost: nothing
reads `external_ref`, so the linkage between a partial refund and its original is invisible to
reconciliation — real, and accepted until something needs to read it.

**Prior art**, as surveyed in the review:

| system | linked new transaction | partials | void distinct from reversal | one reversal only | reversal of a reversal |
| --- | --- | --- | --- | --- | --- |
| Formance | yes — `revert` posts the mirror, linked to its target | no — full revert only | no two-phase in the core model | yes | refused (`ErrAlreadyReverted`) |
| TigerBeetle | yes — a compensating transfer is a new transfer (contra structurally: amounts unsigned) | pending posts may settle partial; compensations are caller-authored | **yes** — `void_pending_transfer` is its own primitive | structural: one void/post per pending | not modeled — any transfer can be compensated again, caller's judgment |
| Modern Treasury | yes — `POST …/reversals`, **no postings in the request**, `effective_at` defaults to the original's | no — partials are ordinary transactions | pending ledger transactions are archived, not reversed | yes — the target records its reversal | not surfaced |
| Increase | no first-class reversal on the bookkeeping surface — compensating entries by hand | caller-authored | n/a | n/a | n/a |
| Stripe Treasury | yes — reversal objects linked to the received debit/credit | no | canceling a hold is distinct from reversing a posting | yes | no |
| blnk | yes — refund creates the inverse transaction, linked, **no postings in the request** | yes — partial refunds are supported | no | not enforced | not refused |
| Midaz | yes — revert is a linked new operation | no | no | yes | **refused flatly** |
| classical storno vs contra | contra: new entries, flipped side; storno: negative amounts, same side | n/a | n/a | n/a | n/a — storno's point is turnover-neutral correction; contra (this design) trades turnover noise for never writing a negative amount |

**What this section deliberately does not decide:** hold *expiry* (a timer-driven void — M8 owns
the timer, and the void it will fire is the one specified here), any reversal of `period_close`
(refused above; un-closing is its own future problem with the checkpoint in the room), and any
storno mode (refused, not deferred).
