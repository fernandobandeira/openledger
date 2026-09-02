# 0025 — A shortfall is a receivable, not a negative balance — and that is what makes a floor possible

**Status:** accepted (ruled 2026-09-01) for the modelling rule; the **balance floor is designed and
deliberately unbuilt**, pending the spike named at the end.
**Evidence:** [0012](/decisions/0012-chart-governance)'s contra routing, which already presents the
state this decision is about; the chart's own `customer_receivable` and
`allowance_for_credit_losses`; and [0013](/decisions/0013-write-path-contract) §4 for why the
obvious enforcement does not fit.

## The decision

**When money leaves an account that does not have it — a chargeback against a spent wallet, a
refund after withdrawal, a fee on an empty balance — book the shortfall as a *receivable*, not as a
negative balance.** The wallet goes to zero, an asset account records what the customer owes, and
your own operating account funds the gap.

**A liability in a debit position is not a liability.** `customer_wallet` is a liability with a
credit normal balance: a positive balance means *you owe them*. Swing it debit and the economics
invert — **they owe you**, which is an asset. The number is not wrong, it is *filed under the wrong
kind of thing*.

**The schema already refuses to let that hide, and that is not the same as endorsing it.**
[0012](/decisions/0012-chart-governance) routes a swung position to its declared `fs_line_contra`
and presents it **gross**, precisely so one customer in debit cannot net against another in credit
and disappear. So a negative wallet is *presentable* here. What it is not is *complete*.

**Two things a negative balance cannot do, and both of them matter.**

1. **You cannot reserve against it.** Expected credit losses are booked against a financial
   **asset**. There is no way to hold an allowance against a liability account that happens to be in
   a debit position — the chart's own `allowance_for_credit_losses` has nothing to attach to. A book
   full of negative wallets cannot answer *"how much of what customers owe us do we expect to
   collect?"*, which is not an exotic question.
2. **It collapses two different events into one.** A customer owing you money and your doubting you
   will collect it are separate facts, arriving at different times, on different evidence, with
   different reversibility. The receivable records the first; the allowance and eventually a
   write-off record the second. One account carrying both loses the distinction permanently.

A negative balance is therefore an **implicit receivable** — unaged, unreserved, and invisible to
any collections process. Modelling it explicitly costs one more transaction and buys back the entire
credit-loss vocabulary the chart was built with.

### The floor, and why the modelling rule is its precondition

**A per-account balance floor is the only shape of "this may not go negative" that fits this ledger.
A per-transaction one does not, and never will.**

The distinction is one a real operator hits immediately: *"I do not want to allow withdrawals below
zero, but I do want to allow this chargeback."* That is a rule about the **operation**, not the
account. By the time the writer sees it, both are a posting moving money out of a wallet, and
nothing in the command distinguishes them — the write primitive is a `Posting`
([0005](/decisions/0005-event-log-and-write-path)): source, destination, amount, currency. There is
nowhere to say it.

Expressing per-send intent is exactly what a transaction DSL is for — Formance's Numscript writes
`source = @alice allowing overdraft up to [USD/2 100]` — and this project **refuses a scripting
language and configurable correctness in any form** (roadmap, *Deliberately not now*). That refusal
stands, and it is what forecloses the per-transaction floor.

**So the modelling rule above is not merely advice; it is what makes a floor viable.** Book the
shortfall as a receivable and the wallet never *needs* to go below zero — so a floor on it never
needs an exception, and never has to tell a withdrawal from a chargeback. The floor stops being a
restriction and becomes a **forcing function**: it makes the writer say where the shortfall went,
instead of leaving a negative number nobody ages.

**A floor would be declared on the account, and declaring it forbids striping.** The writer's
statement upserts one `(account, currency, stripe)` row and gets that row's new balance back. On a
striped account that number is not the account's balance — checking the account would mean summing
every stripe, reintroducing the contention striping exists to remove
([0013](/decisions/0013-write-path-contract) §4). At `stripe_count = 1` the returned balance **is**
the account's, and the check is one comparison, exact and atomic, inside the statement that already
runs. That trade is naturally acceptable: the accounts that want floors are customer wallets, and
the accounts that need striping are the hot house accounts.

**The floor is checked against *posted*, and *available* stays the caller's composition.** A hold is
already expressible — post the reservation as `pending`, which sequences entries without moving the
posted balance ([0016](/decisions/0016-pending-to-posted)) — and `recon_pending_bridge` exists to
bridge the two numbers. The ledger does not know what a hold *means* to a product, so it will not
guess at available.

## What we considered

| | Why not |
| --- | --- |
| **Let the wallet go negative and rely on the contra presentation** | It presents correctly and accounts incompletely: nothing to reserve against, no aging, no write-off, and two events collapsed into one. Fine when you are certain of collection; that is the case this ledger cannot verify for you. |
| **A per-transaction overdraft allowance** (Numscript's shape) | Needs a way to state per-send intent, which is a DSL or a much richer command type. The roadmap refuses both, and this decision does not reopen it. |
| **A floor enforced by summing the account's stripes** | Reintroduces exactly the contention striping removes. The floor is affordable only where the balance is one row. |
| **A floor on *available* rather than posted** | The ledger does not know what a pending transaction means to a product — a hold, a scheduled payout, an unsettled capture. Guessing would enforce the wrong number confidently. |
| **Enforcing the floor in the API rather than the writer** | *"A check, not a shape"* ([0005](/decisions/0005-event-log-and-write-path)). Check-then-post is not atomic: two concurrent withdrawals both read a sufficient balance and both post. Only the writer can close that. |
| **A reconciliation check instead of a refusal** | Worth having *as well* — it is the only thing that covers accounts opened before a floor existed — but detection after the fact does not stop the second concurrent withdrawal. |

## What it costs

- **The receivable treatment is more work for the caller.** A chargeback becomes two transactions
  with an asset in between, and somebody has to run collections and write-offs against it. The
  negative-balance version is genuinely cheaper right up until you are asked what you expect to
  collect.
- **This decision does not build the floor.** It rules out the per-transaction form permanently and
  specifies the per-account one; whether the constraint earns its throughput cost is unmeasured.
  **The spike that would settle it**: implement the floor on the unstriped path, measure clearings/s
  against an unfloored control, and — the part where a bug is most likely — prove that the *batched*
  writer's cross-request coalesce cannot smuggle a member past the check, since a batch's members
  are summed into one delta before the upsert sees them.
- **A floor declared on an account with history could already be violated.** Enforcement is at the
  tip; nothing re-examines the past. The reconciliation check is what covers that, and it does not
  exist yet either.
- **Backdating is unresolved.** An entry effective in the past can push a *historical* balance below
  a floor while the current one is fine. The upsert sees only the tip, so the tip is what a floor
  can hold — and this decision does not claim more.
- **The guidance is a convention, not an invariant.** Nothing refuses a book that lets wallets go
  negative, and the reporting layer will present it honestly if you do. This ADR names the better
  shape; it does not enforce it.
