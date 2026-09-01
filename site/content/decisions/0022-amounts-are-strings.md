# 0022 — Every amount on the wire is an exact-integer string, and a client found out why

**Status:** accepted (ruled 2026-09-01). It **completes [0019](/decisions/0019-read-path)'s amount
rule**, whose aggregate-only form left a reachable hole, and **amends
[0021](/decisions/0021-accounts-over-http)** and [0019](/decisions/0019-read-path)'s cursor refusal on
two smaller points.
**Evidence:** the shipped API, probed directly — every figure below was produced by a request, not
derived.

## The decision

**All three fixes here came from building a real consumer, and none from re-reading the
specification.** That is the argument [0014](/decisions/0014-http-api) makes for the HTTP boundary
existing at all — *"the HTTP boundary is what makes the e2e tests caller-shaped"* — and this is the
first time the claim has been tested by an actual client rather than by a test written alongside the
handler.

### 1 · A single amount is a string, because `bigint` reaches past 2⁵³ and JSON has no integer type

[0019](/decisions/0019-read-path) gave report **aggregates** exact-integer strings, on the correct
reasoning that a numeric total above 2⁵³ is silently rounded by any consumer parsing JSON numbers
into IEEE-754 doubles. It left **single** amounts — `PostingBody.amount_minor` on the way in,
`EntryRead.amount_minor` on the way out — as JSON numbers, reasoning that one posting is bounded by
its column.

**That is right about the column and wrong about the wire.** `ledger_entries.amount_minor` is
`bigint`, which reaches to 9,223,372,036,854,775,807 — three orders of magnitude past 2⁵³ — and JSON
itself has no integer type at all: RFC 8259 leaves precision beyond a double to the implementation,
so this is not a JavaScript quirk but the interchange format's own latitude.

Reproduced against the shipped API rather than argued:

| | |
| --- | --- |
| posted | `9007199254740993` — a legal `i64`, above the schema's own `minimum: 1`, **accepted** |
| read back, through `JSON.parse` | `9007199254740992` |

**Silently off by one, before any client code exists to defend itself**, and in both directions for
such a consumer: a client that cannot represent the value cannot send it either. So every amount on
the wire is now an exact-integer string, in **both** directions, and the asymmetry
[0019](/decisions/0019-read-path) chose is gone. Parsing on the way in refuses a non-integer, an
out-of-range value, a leading `+` and surrounding whitespace, each as `422 invalid_request` naming
the field.

**This is a breaking wire change and it is taken deliberately.** Nothing outside this repository
consumes the API, the alternative is a contract that is quietly wrong at the top of its own declared
range, and *"correctness is never configurable"* is on the non-negotiable list. **No migration**:
the column was never the problem.

### 2 · `POST /v1/accounts` returns the account it created

[0021](/decisions/0021-accounts-over-http)'s central design is that the caller names a `purpose` and
the server **derives** `category`, `normal_balance` and `counterparty_scope`. The endpoint then
returned two UUIDs — so seeing what was derived took a second call to the listing **plus a
client-side scan**, because there is no `GET /v1/accounts/{id}` and the listing's equality filters
cover `purpose` and `owner_id` but not `account_id`. "Show me the account I just opened" was a paged
search for the thing the design exists to demonstrate.

The `201`, and the `200` that replays it, now carry the full account representation. `event_id` stays
alongside it: it is the event-log spine, and a caller should be able to see the event its account
opening was.

**`metadata` joins the account representation**, in the listing too. A caller could set it and had no
route that read it back. [0021](/decisions/0021-accounts-over-http) said the listing returns
*"identity plus `stripe_count`"*; the load-bearing half of that sentence was **and not balances**,
which is unchanged — balances are per currency and per stripe, and a balance per row would be N+1.

### 3 · `GET /v1/cursor` answers the horizon without running a report

[0019](/decisions/0019-read-path) refused a cursor-minting endpoint because *"every report already
returns the cursor it used"*. True, and incomplete: it makes asking for the horizon **alone** cost a
whole report. The dashboard's "refresh the horizon" was a trial balance over
`0001-01-01`…`9999-12-31` — a full scan run to obtain one scalar, which on a million-entry book is
the **~28-second** query [0019](/decisions/0019-read-path)'s own cost list records.

One statement (`SELECT report_cursor()`), on the read path, inside the same bracket every other read
uses. It takes a `tenant_id` like its neighbours for consistency of scoping, and the annotation says
plainly that the horizon is **cluster-wide** rather than per tenant, so nobody infers otherwise from
the parameter.

## What we considered

| | Why not |
| --- | --- |
| **Leaving single amounts as numbers and documenting the ceiling** | The ceiling is inside the range the column and the schema's own `minimum: 1` advertise. A documented trap is still a trap, and this one returns a plausible wrong number rather than an error. |
| **A string only on the way out** | A consumer that cannot parse the value cannot produce it either. Half the fix leaves the write path wrong. |
| **Capping `amount_minor` at 2⁵³ in the schema** | It makes the wire's limitation the ledger's, forever, to avoid changing a serialization. The column is not the thing that is broken. |
| **`GET /v1/accounts/{id}`** (for fix 2) | A whole route to recover what the creating call already knew. Returning the representation costs nothing and removes the round trip entirely. A single-account read may still earn its place later; this did not need it. |
| **Adding an `account_id` filter to the listing** | Same objection: a search to find one row the caller just created. |
| **Letting the dashboard cache the horizon** | It would paper over a contract gap with client state, and every other consumer would meet the same 28-second scan. |
| **Returning balances in the account representation** | Unchanged from [0021](/decisions/0021-accounts-over-http): per currency and per stripe, N+1, and the balance route answers it precisely. |

## What it costs

- **It is a breaking change with no deprecation path**, taken while there are no external consumers.
  The next such change will not be free, and this decision spends that freedom knowingly.
- **A string amount is more work for every caller**, including the ones for whom a number would have
  been fine. That cost is paid by everyone to protect the callers who would otherwise be silently
  wrong, which is the same trade [0019](/decisions/0019-read-path) already made for aggregates —
  it is now applied consistently instead of at one end.
- **`GET /v1/cursor` is a fourth route added since the surface was declared**, and every route under
  [0014](/decisions/0014-http-api)'s machine-checked table is permanent. It is one statement, but it
  is one more thing that must keep working.
- **The parse is now a refusal surface.** `amount_minor` can fail for reasons it previously could
  not — a float, an empty string, a leading `+` — and each is a `422` a caller has to handle. The
  alternative was accepting them and guessing.
- **This decision was written after a client found the defects, not before.** The three of them sat
  in an accepted, adversary-audited decision log and in a passing test suite, and what surfaced them
  was somebody trying to display a number. Worth recording as a method result: **an e2e suite written
  beside the handler shares the handler's assumptions**, and the consumer that does not is the one
  that finds the hole.
