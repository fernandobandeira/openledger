# The design questions the measurements do not answer

Kept beside the harness because ADR-0018 has to answer them and the spike's numbers only decide
some of them. Each one names the accepted decision it touches, because several sit against
something already written down.

**This document was reviewed adversarially on 2026-08-31 and five of its claims did not survive.**
The corrections are inline and marked, not silently patched — a document that quietly fixes its own
errors teaches nobody what to distrust next time.

## 1 · Where the batcher lives — a decorator, and three candidate homes

The `Ledger` port is one method (`crates/ledger/src/port.rs`), and `api` is generic over it
(`crates/api/src/lib.rs`: `router<L> where L: Ledger + Clone`). So an accumulating writer is
**another implementation of the same port**, wired by the composition root, and the HTTP surface
never learns it exists. That is the shape ADR-0015's hexagon already pays for.

What it cannot be is a *pure* decorator over `Ledger`, because a batch is one statement, not N
calls: the batcher needs a **new `Repository` method** (`claim_and_append_batch`) beside the
existing one. So the split is:

- `Repository` — one more method, implemented in `ledger-postgres` where the SQL lives. One
  statement per method still holds.
- the accumulator — `post` enqueues its command and awaits its own slot; a drain task assembles a
  batch, runs the one statement, and fans each member's answer back by ordinal.
- `Ledger`, `api`, the wire contract, the OpenAPI spec — unchanged.

**Correction.** An earlier version of this section said the alternative was *"a sixth crate holding
the accumulator, which ADR-0015 already refused for the ports crate on the same grounds: a manifest
to hold one type."* That misreads the ADR. Its actual words (0015, *What we considered*): *"A sixth
manifest to hold one trait and one enum. The port lives in the domain crate it constrains; nothing
consumes the trait without the types it mentions, **so the split buys a boundary nothing crosses.**"*
The operative reason is the last clause, and it does **not** transfer: an accumulator crate *would*
buy a boundary something crosses — it keeps `tokio` out of `crates/ledger`, which is the one
property `deny.toml`'s capability map exists to machine-check.

So there are three candidate homes, not one:

| where | what it costs |
| --- | --- |
| **`crates/ledger`** (the domain) | puts `tokio` in a crate that today depends only on `serde_json`, `sha2`, `time`, `uuid` — no async runtime at all. Not banned by `deny.toml`, which is exactly why it would have to be argued rather than discovered in a diff |
| **a new `ledger-batch` crate** | a seventh manifest, but it buys a boundary that something crosses — the `tokio` ban on the domain crate becomes machine-checkable |
| **`crates/openledger`** (the composition root) | already depends on `tokio`, `axum` and `clap`; already the one place `PgRepository` is wired into `LedgerService`. Adds no dependency anywhere, and puts no timer in ADR-0002's layer 1 |

**The composition root is the recommendation**, because it dissolves §2's problem as well as this
one. Against it: ADR-0015 describes `openledger` as "clap's derive, the exit codes, and the
composition root", and an accumulator is real logic rather than composition — so the ADR must
either accept that the root grows a component, or take the `ledger-batch` crate.

## 2 · A batch window is a timer in the core — and this is an amendment to ADR-0002, not a reading of it

> **Correction: this section's premise dissolved, and the whole of it is now moot.** It argues about
> where a batch **window** may live. **No window shipped.** ADR-0018 §2 refuses the fixed
> accumulation window outright, on measurement: a 25 ms window costs 10× the median latency at
> 50 TPS to collect 2.26 members, and dispatch-on-completion is indistinguishable from not batching
> at all across ADR-0002's whole derived range and forty times past it. **There is no timer to place
> anywhere** — the shipped accumulator reads no clock, and each dispatcher forms, posts and answers
> in one turn of its own loop.
>
> The section is kept because its *second* recommendation is what shipped for an unrelated reason:
> the accumulator lives outside `crates/ledger`, in the binary, and ADR-0002's scheduler sentence is
> untouched rather than amended (ADR-0018 §5, §6). The "amend ADR-0002" branch below was never
> taken. **What ADR-0018 does amend in ADR-0002 is rule 3** — "batching and randomly chosen stripes
> cancel each other … or key the stripe on the tenant" — which this section never discusses and
> which is corrected in place there.
>
> The clock-ban paragraph at the end also survives on its own terms, but its conclusion is stronger
> than stated: `tokio::time::Instant::now` does not need to join the `disallowed-methods` list,
> because nothing on the write path calls it.

ADR-0002, verbatim: **"The core needs no scheduler, ever — every timer belongs to a rail."** Its
layer table answers "needs a scheduler?" with a flat **no** for layer 1, unqualified. A batch window
is a timer, and it is in the core.

**Correction.** An earlier version of this section proposed a *qualification*: that ADR-0002's claim
was "really" about **durable** timers, since its examples are hold expiry and the ACH return window.
That does not hold up, on three counts, and the honest word is **amendment**:

- The word "durable" appears nowhere in ADR-0002's scheduler discussion. The sentence is universal.
- The examples used to define the qualification are imported from **M8**, a later document. Reading
  a rule's scope off a later document's examples is the move that lets any timer in — every future
  timer will also be able to say "mine drives nothing and stores nothing."
- **The roadmap already argues the other side, and the earlier version did not cite it.** M8,
  verbatim: *"A scheduler is not a throughput mechanism… Its place is owning the sweep… **and
  draining events in batches.**"* The project has already placed "draining events in batches" *with*
  a scheduler, *in a rail*. That sentence has to be engaged, not stepped around.

Two ways out, and the ADR must pick one in the open: **amend ADR-0002** to say layer 1 owns no
*durable* scheduler while a bounded in-process dispatch window is permitted, naming this as the
change it is — or **put the accumulator outside the core** (§1's composition-root option), where
ADR-0002's sentence is untouched and needs no amendment at all. The second is cheaper and is
recommended.

**And the clock argument was toothless.** An earlier version said the `clippy.toml` clock ban would
be "adjacent to a `tokio::time` call for the first time." It would not fire at all:
`disallowed-methods` lists only `std::time::SystemTime::now` and `std::time::Instant::now`.
`tokio::time::Instant::now` and `tokio::time::sleep` are not on it. The substantive point survives —
a batch window is a **scheduling duration**, never a timestamp, and no value derived from it is ever
written to `recorded_at` or `effective_at` — but if that distinction is to be enforced rather than
merely stated, `tokio::time::Instant::now` has to join the list, with an `#[expect]` at the batcher
the way `crates/db/src/migrate.rs` does it.

## 3 · Per-member isolation is what makes batching legal — and it takes more than the account gate

Every `WriteError` variant except `Storage` promises **"nothing was written"**, and the service
keeps that promise by rolling back (`crates/ledger/src/service.rs`). In a batch, a rollback destroys
every innocent member, so the promise has to be kept a different way: **refusal by withholding,
inside the statement, per member.**

**Correction — the gate must sit above the claim, not below it.** An earlier version of this section
claimed the admissibility gate made the per-member promise "literally true." It did not, because
`claimed` inserted events for *all* members and the gate filtered downstream. The refused member's
`ledger_events` row therefore committed and its idempotency key was **permanently burned**: on
retry, the claim conflicts, the replay lookup finds the event, joins to no transaction, and answers
`transaction_id: null, replayed: true` — which ADR-0013 says is the legitimate shape for the
majority of operations, which write no transaction. **A refusal was laundered into an
indistinguishable success.** Fixed by hoisting `admissible` above `claimed`; measured before and
after — 25 events / 24 transactions became 24 / 24.

**And the oracle could not see it.** None of the ten reconciliation checks reads `ledger_events`, so
an orphaned event is invisible to `SELECT * FROM reconciliation` by construction. The gate went
green on a book carrying the defect. Any claim that "both paths leave ten zeros" has to be read
against that blind spot; the harness now asserts the transaction count against the book directly.

Three siblings, all of which the ADR must rule on:

- **Supersession refusals have the same hole, and only half a fix.** The shipped statement withholds
  `txn` while `claimed` still fires — its own comment says *"which is why the service rolls back
  BEFORE answering the refusal"* — and a batch has no rollback available for one member. Hoisting
  the supersede predicates above `claimed`, as with admissibility, closes the case where the target
  is a **pre-existing** transaction. It cannot close the case of **two members of one batch
  superseding the same target**: same-statement snapshot invisibility means neither sees the other,
  `uq_txn__one_supersession` raises, and the whole batch aborts where today the loser gets a clean
  named refusal.
- **Cross-member overflow is a new failure mode with no gate.** `plan_append` refuses overflow in
  Rust with `checked_add` before any SQL. The batched statement re-does the coalesce in SQL at
  `bigint`, so a **cross-member** sum can overflow where no individual member does — `22003`, and
  the whole batch dies. Untested by a workload with fixed amounts.
- **Two members sharing one idempotency key abort the batch.** `ON CONFLICT DO NOTHING` suppresses
  the intra-command duplicate and claims **one** event; joining `claimed` back to `member` by key
  fans that row to both ordinals; two transactions against one `event_id` hit
  `uq_txn__one_per_event` (a `UNIQUE INDEX` at `migrations/00001_baseline.sql:581`) and the
  statement raises `23505`. **Measured: 0 events, 0 transactions, 0 entries** — it fails closed,
  which is the good news. The bad news is that a client retrying its own request is the single most
  likely thing a batch window collects, and today that pair produces a clean replay.

  > **Correction: this is closed, and it is no longer a hazard the ADR "must rule on".** It was worse
  > than this bullet estimated before it was fixed: routing every post through one queue makes the
  > pair the *common* case, and built naively it reproduced immediately — **40 concurrent posts of
  > one key gave 1 × 201, 33 × 200 and 6 × 500**, breaking a committed end-to-end test that pins
  > ADR-0013 §2's guarantee of no invented 409 and no 500. **The fix is in the drain, not the
  > statement:** a key already present in the batch being formed is not taken; it waits, and on its
  > next turn it is ADR-0013's ordinary race — block on the in-flight claim, then read the committed
  > result from the separate lookup. Re-measured: **1 × 201, 39 × 200, zero 500s**, and pinned by
  > `crates/e2e/.../batched.rs`. The `23505` stays as a backstop for anything reaching the statement
  > another way; the accumulator is what means nothing does (ADR-0018 §3).

And the residual that stays whatever the ADR decides: **a storage failure mid-batch fails every
member**, including ones that would have succeeded. Their keys were never claimed, so retry is safe.
`Storage` was always the one variant promising nothing; batching widens its blast radius from one
caller to B.

## 4 · Head-of-line blocking, and whether a batch may span tenants

`INSERT … ON CONFLICT DO NOTHING` waits on a concurrent uncommitted insert of the same key.
**Measured: a 1,500 ms held claim stalled a batch of 25 for 1,519.5 ms** *(three committed passes at
1,519.4 / 1,520.4 / 1,519.5; an earlier version of this line said 1,521 ms, which is neither the
median nor any pass value)*. So one caller's in-flight retry stalls every member sharing its batch.

Whether that may cross tenants is a live question — the batched statement binds a **per-member
tenant array**, so a batch spanning tenants is expressible and `--tenant-homogeneous` is a real
choice rather than a property of the SQL. Three things point toward homogeneity:

- **Fairness.** A tenant-homogeneous batch confines a tenant's stall to its own writes.
- **ADR-0013's open option stays open.** Its cost list records that tightening the writer's RLS
  policy to `WITH CHECK (tenant_id = current_setting('app.tenant_id'))` would make a cross-tenant
  write structurally impossible — and notes the cost, that it *"binds a transaction to one tenant,
  which the treasury due-from/due-to pair would then have to be written to honour."* A cross-tenant
  batch closes that door; a homogeneous one leaves it ajar.
- **The whale fills its own batches.** Batching pays most where traffic concentrates, and that is
  where homogeneity costs least.

Against it, measured at whale 0.9, closed-loop: spanning batches filled 16.11 at 1.29 ms wait;
tenant-homogeneous filled 7.30 at 4.64 ms. **Those figures are closed-loop and therefore ceilings**
(§6) — the open-loop rerun at a fixed offered rate is what the decision should rest on.

> **Correction, and the argument against homogeneity is withdrawn entirely.** **Neither 16.11 nor
> 7.30 appears in either committed results file.** They come from a smoke run this document was
> written against and were never reproduced; the committed whale cells at B=25 are spanning
> **25.00** fill against homogeneous **6.22** (worker) and **5.55** (tenant). More to the point,
> **fill was the wrong metric and this bullet is the proof of it**: on the committed run the
> homogeneous arm collects a quarter of the members and is **8% faster** — 2,350 against 2,177
> clearings/s. What pays is *account overlap inside the batch*, not batch size. Six members sharing
> one tenant's house pair coalesce to one upsert; twenty-five spread across tenants coalesce to
> nothing and pay a statement twenty-five times longer.
>
> **Tenant-homogeneous batching is what shipped** (ADR-0018 §3), taken on throughput, with the three
> arguments above coming along for free. Settling this on fill rate — which this section proposed —
> would have chosen wrong.

## 5 · The walk-back arithmetic leaves Rust

`offsets_back_from_last_seq` (`crates/ledger/src/postings.rs`) counts each leg's later siblings in
pure Rust. Across a batch that computation is no longer client-side: **which members proceed is only
known after the claim and the gate**, both server-side, and a dropped member would leave holes that
`uq_entries__account_seq` would refuse or `recon_balance_breaks` would find later as a gap. So the
batched path numbers with a window function over the proceeding legs, partitioned by
`(tenant, account, currency, stripe)` — the counter's own grain, since `pk_balances` carries the
stripe and ADR-0013 records that "gaplessness becomes per (account, stripe)."

The precedent is already in the tree: `mirror_leg` numbers the server-derived reversal exactly this
way, for exactly this reason. **But note what `mirror_leg` silently depends on** — it partitions on
`(account_id, currency)` alone, which is sound only because one transaction contributes to at most
one stripe per account. That invariant should be stated in the ADR rather than left implicit,
because per-member stripe selection is the first thing that could break it.

**Correction.** An earlier version justified the client-side alternative — a warm account cache
making admissibility client-side — on the grounds that *"accounts are append-only, so a cached
positive is permanently valid."* **That is false.** `ledger_accounts` carries no append-only
trigger; ADR-0009's freeze *keys* exist precisely because the row is updatable, and ADR-0002 calls
`stripe_count` *"an operator's write-side tuning knob."* The cache argument may still hold — a stale
positive fails closed on `fk_entries__account` — but it has to be argued from the freeze keys, not
from a property the schema does not have.

Worth recording beside this: the harness's original clearing was three hand-built legs, which made
**every walk-back offset zero**. The shipped API cannot express three legs at all — `expand_postings`
emits two legs per `source → destination` posting, so leg counts are always even. Correcting the
workload to 2 postings / 4 legs is what first exercised this arithmetic against a real database.

## 6 · What the batched path does not do — and the measurement that matters most

**The batched statement carries no supersessions and no pending.** It hardcodes
`'posted'::ledger_txn_status` and binds neither `resolves_id` nor `reverses_id`. The shipped writer
supports all four member kinds on one endpoint. So the ADR must rule explicitly on scope: either the
batched path is for plain posted postings only and everything else falls back to the single path —
which is defensible, and makes §3's supersession sibling moot — or the batched statement grows the
gate, the mirror derivation and per-member status, with the pending rule (`input`/`output` withheld,
`last_seq` advanced) reapplied per member inside SQL rather than in `plan_append`.

**And the knob has no evidence behind it yet.** A batch window is a *latency* knob, and a closed-loop
harness always fills its batches, so every throughput figure here is a ceiling. At the load ADR-0002
itself derives — *"under 1 TPS average, and maybe 20–50 TPS at a Monday-morning peak"* against a
~671 clearings/s baseline — a 25-member window essentially never fills. **Measured open-loop at
50 TPS offered, B=25, 25 ms window: true batch fill 2.21, achieved 47.0/s, p95 30.9 ms.** Two
members, not twenty-five.

> **Correction: every number in that sentence is a smoke run's, and none of them is what the
> committed run says.** The single-write baseline is **623** clearings/s at 32 writers and **660** at
> 8 — **671 matches no cell in either results file**. The 25 ms window at 50 TPS offered committed at
> fill **2.26**, achieved **48.1/s**, p95 **42.87 ms**. The conclusion is unchanged and if anything
> firmer, which is why it is worth correcting rather than deleting: the window collects two members
> and charges 10× the median latency for them. **Quote the committed figures.** The smoke run's
> results file was not kept, which is the reason these survived unchecked into the ADR.

That is the number the ADR has to answer to. It does not say batching is worthless — it says
batching buys nothing at the reference product's own sizing, and its value appears only as offered
load approaches the ceiling. An ADR that sets a window default without that distinction is sizing a
latency knob with throughput data.
