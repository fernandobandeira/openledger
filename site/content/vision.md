# Vision — why this exists

An open-source **double-entry ledger**. Postgres for storage, Rust for the service.

**The whole project is about correctness**, not throughput: every cent accounted for, the books
balanced at every instant, any number reproducible as of any date, and no manual fixes ever. All
four are cheap to design in and painful to retrofit.

## Why this exists when Formance already does

**If you need a ledger in production, use [Formance](https://github.com/formancehq/ledger).** It is
mature, it has been run against real money, and it has production scar tissue this project has not
earned: fifty-four migrations with names like `27-fix-invalid-pcv` record failures we have not had
yet. It ships Numscript, a real DSL for posting rules — a problem we still have open — plus
ClickHouse replication, import/export by log replay, and a multi-ledger deployment model. [Spike 001](/spikes/001-formance)
read its source and all fifty-four migrations, and the answer was: take it seriously before building
anything.

**This is a personal project. Nobody has run it in production, and it is not asking to be.** What it
is good for is reading — every decision written down with its evidence and what it cost — if you are
implementing your own, or deciding what to demand of someone else's.

**Where it differs is one opinion, held consistently: accounting semantics belong in the database,
not in a layer beside it.** Accounts carry a category and a normal balance, and every account type
declares its financial-statement line, so
`assets = liabilities + equity + (revenue − expenses)` is expressible *from* the schema rather than
reconstructed beside it. Formance leaves
that to you — there is no normal balance anywhere in its schema, a balance is `input - output` so a
liability reads negative. It *does* have a chart — a versioned `schemas(chart jsonb)` table since
v2.3, typed account patterns in v3 — but it is an address *naming grammar*, and its rules type is
literally `struct{}`. The differentiator is normal balance and the equation, not the chart. Either
way you cannot get a trial balance or a balance sheet out of it without writing a mapping layer
first. Two smaller consequences of the same opinion:
[0006](/decisions/0006-time-and-as-of) refuses a running balance on the business-date axis, where
Formance keeps a mutable one and pays for it in three data-repair migrations; and pending state is
first-class here, where Formance has none and you model a hold by moving money to a hold account.

**The invariant Formance does enforce is the interesting one**, and this project does not have it:
it refuses a negative account balance by default, per source account per asset. It also declines to
enforce that transactions balance — which is a legitimate design and not an oversight, because its
primitive is a `Posting{Source, Destination, Amount, Asset}` that cannot express one leg.
[0005](/decisions/0005-event-log-and-write-path) takes the same bet.

Building a ledger is also how you find out what a ledger actually is — a sufficient reason, and
dressing it up as a market gap would be worse.

## What the core is

Accounts typed by category and normal balance, multi-tenant and multi-currency. Transactions as the
unit of atomicity, whose status never mutates. Immutable append-only entries, balanced per currency.
A current balance in one index lookup, and as-of reads on two time axes. An event log that is both
the idempotency spine and the audit trail.

That is the whole of it. Anything built *on* it — a card rail, a wallet, an ACH rail — is a
replaceable layer with a deliberately narrow coupling to the core.

## What it guarantees

Four properties. None is a setting.

- **Append-only.** Triggers refuse `UPDATE`, `DELETE` and `TRUNCATE` on the journal outright, for
  *every* role including the owner. The narrow grant matters too but is not the mechanism: a
  `REVOKE` is undone by one later `GRANT ALL` ([0004](/decisions/0004-where-logic-lives)).
- **Balanced per currency**, by construction in the writer rather than by a check in the database:
  the primitive a caller can reach for is a *posting* — a source, a destination, an amount — so one
  leg is not expressible ([0005](/decisions/0005-event-log-and-write-path)).
- **Bitemporal.** Every transaction carries when it happened and when it was learned about. These
  differ constantly: a clearing's business date belongs to the network, not to the webhook.
- **Event-logged.** Every accepted external event is recorded, including the many that write no
  ledger transaction at all — an account opened, a limit changed, a posting rejected. That is what
  gives a retry contract somewhere to live
  ([0005](/decisions/0005-event-log-and-write-path)).

**Correctness is never configurable** — a ledger that makes historization optional returns empty
results to point-in-time queries, a wrong answer that looks like an answer. Two consequences are
counter-intuitive. **Balanced books do not mean correct reports:** drop a whole *balanced* slice —
a tenant, a currency, a range of whole transactions — and the accounting equation still holds while
revenue is understated, so the balance sheet is built by enumerating the chart of accounts, never
by listing whatever accounts have entries ([0007](/decisions/0007-schema-conventions-and-chart)). And
**each tenant's slice must balance on its own**, so no transaction may span tenants: cross-scope
movements split into two, joined by clearing accounts. Tenant-locality is correctness, not
optimization.

## Performance

**No number in this repository is a benchmark.** Everything measured so far ran on localhost, where
a round trip costs 0.05 ms against roughly ten times that on managed Postgres — which *reorders*
the tuning levers rather than scaling the result down. No throughput figure is published until one
is measured over a real network. What a balance read costs at a million entries is **unmeasured**;
what is structural is that it is a *lookup* — every entry carries its account's running balance, so
the current balance is one index hit, not a scan.

The ceiling is set by **contention, not hardware**. Every clearing writes the same
`network_settlement_payable` row — a *hot account* — and Postgres holds that row's lock until the
transaction commits, so those clearings queue behind one another. The lock is not incidental: the
same statement that adds the amounts also issues the account's next sequence number, so it is what
keeps the running balance correct ([0002](/decisions/0002-scaling)).
[Spike 003](/spikes/003-throughput-ceiling) measured that row at 872 clearings/s and, **striped** 64
ways, at 6,970 — but the same contended configuration re-measured at 833 and then 482 purely from
machine load, so the ratio is the finding, not the number.

Next: [the decisions](/decisions) for why each piece is what it is,
[the card rail](/card) for the reference product it is designed against, and
[the roadmap](/roadmap) for the build order — including what exists today and what does not.
