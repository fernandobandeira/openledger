# 0021 — An account is opened over HTTP, and accounts are listed

**Status:** accepted (ruled 2026-09-01). It **partially reverses
[0019](/decisions/0019-read-path)**, which refused "any listing, search or filter endpoint".
**Evidence:** the schema itself (`migrations/00001_baseline.sql`, `ledger_accounts` and its six
constraints), [0005](/decisions/0005-event-log-and-write-path) for the mechanism creation reuses, and
[0014](/decisions/0014-http-api) for the surface it has to satisfy.

## The decision

**`POST /v1/accounts` and `GET /v1/accounts` ship.** Until now there was **no way to open an account
over HTTP at all** — accounts were seeded by SQL, which is what the e2e suite does and what the
reference chart does. That is a hole in the claim [0014](/decisions/0014-http-api) makes: *"a writer
only Rust code can call is not a deliverable"* is the same argument against a ledger you cannot open
an account in without a `psql` session. The adoption surface was one operation short of usable.

**[0019](/decisions/0019-read-path)'s refusal was scoped reasoning presented as a principle, and it
is withdrawn for accounts.** Its stated ground was that a listing *"needs an ordering and a page key
this spike did not design"*. That is a *not yet*, not a *never* — and for accounts the ordering
already exists: `pk_accounts` is `(tenant_id, id)` and `id` is `uuidv7()`, which is time-ordered and
total. Keyset pagination on it is a solved problem, not an open question. **What is not withdrawn is
the refusal of a *transaction* listing**, and the distinction is the point: a transaction listing has
to choose between the recorded axis and the effective axis, and that choice is exactly the bitemporal
trap [0006](/decisions/0006-time-and-as-of) exists to document. Accounts have one axis. Transactions
have two, and a listing that picks the wrong one is a wrong answer nobody can see.

**Opening an account is an *event*, and it reuses the idempotency spine rather than inventing one.**
[0005](/decisions/0005-event-log-and-write-path)'s whole argument for `ledger_events` is that *"most
accepted operations write NO ledger transaction … so idempotency cannot live on the transactions
table"*. Opening an account is precisely that operation: accepted, recorded, and it moves no money.
So `POST /v1/accounts` claims its idempotency key and writes a `ledger_events` row **in the same
database transaction** as the `ledger_accounts` insert, and inherits
[0013](/decisions/0013-write-path-contract) §2's replay contract unchanged — the same key with the
same body replays the stored result under `Idempotency-Replayed: true`, and the same key with a
different body is `422 idempotency_key_reused`. Nothing new is designed here; an existing mechanism
is used for the case it was justified by.

**The caller names a purpose. The server derives the rest of the chart triple.** `ledger_accounts`
carries `category`, `normal_balance` and `counterparty_scope` as *copies* of the chart row, held
honest by `fk_accounts__type` and `fk_accounts__scope`. A caller must **not** supply them: a body
that states a triple disagreeing with the chart would earn a foreign-key error rather than an answer,
and the API would be handing back the database's diagnostics instead of its own. So the request body
is `tenant_id`, `idempotency_key`, `purpose`, `owner_type`, `owner_id`, `currency`, and optionally
`stripe_count` and `metadata` — and the writer reads `account_types` to fill in the other three. That
makes a whole class of refusals **unreachable** rather than merely reported, which is this project's
stated preference ([0004](/decisions/0004-where-logic-lives): *prefer a constraint that makes a state
unreachable to a check that looks for it afterwards*).

**Every remaining refusal is named, and each one is a constraint the schema already holds.** The
grammar is [0014](/decisions/0014-http-api)'s — subject first, condition second:

| `type` | the constraint behind it |
| --- | --- |
| `account_type_unknown` | `purpose` names no row in `account_types` |
| `account_exists` | `uq_accounts__owned` (one account per owner, purpose and currency) or `uq_accounts__house` (one house account per purpose and currency, **per tenant**) |
| `account_owner_mismatched` | `ck_accounts__house_has_no_owner` — a house account has no owner and an owned account must have one |
| `account_type_requires_an_owner` | `ck_accounts__per_shard_is_owned` — a `per_shard` type in a house account nets every counterparty at write time and **no report can recover it** ([0012](/decisions/0012-chart-governance)) |
| `invalid_request` | a `stripe_count` outside 1–1024, a currency that is not three uppercase letters, an empty tenant |
| `idempotency_key_reused` | shared with the posting endpoint, deliberately: it is the same spine and the same contract |

**`GET /v1/accounts` is keyset-paginated and returns identity, not money.** `limit` with a stated
default and maximum, and `after` carrying the last `id` seen; the page is ordered by `id`, which is
`uuidv7` and therefore creation-ordered. Optional equality filters on `purpose` and `owner_id` —
**equality, not search**: no pattern matching, no free text, nothing that needs an index this schema
does not have. It returns each account's identity and its `stripe_count`, and **not its balance**:
balances are per currency and per stripe, a balance per row would be N+1, and
`GET /v1/accounts/{id}/balance` already answers that question one account at a time. It runs on the
read path — its own pool, its own login, RLS-scoped — like every other read
([0019](/decisions/0019-read-path)).

## What we considered

| | Why not |
| --- | --- |
| **Leaving account creation to SQL** (the status quo) | It makes `psql` a required part of onboarding, which contradicts the reason the HTTP surface exists at all. It is also the only operation in the system with no API, which is an accident of build order rather than a decision. |
| **Letting the caller supply `category` / `normal_balance` / `counterparty_scope`** | They are copies held honest by composite foreign keys. A caller that disagrees with the chart would get a foreign-key violation — the database's error, not the API's. Deriving them makes the disagreement unconstructible. |
| **Creating an account as a `ledger_transactions` row** | It moves no money and has no legs. [0005](/decisions/0005-event-log-and-write-path) already ruled that operations like this belong on the event log, which is why the event log exists. |
| **Creating an account with no idempotency key** | Every other accepted operation in this system is replay-safe. A retry that silently opens a second account — or that fails on `uq_accounts__owned` and leaves the caller unable to tell "already yours" from "someone else's" — is the failure the spine prevents. |
| **Offset pagination (`?page=`)** | An offset shifts under concurrent inserts, so a caller paging through a growing book silently skips rows. Keyset on a `uuidv7` primary key has neither problem. |
| **Returning balances in the listing** | Per currency and per stripe, that is N+1 and a different question. The balance route answers it precisely. |
| **A transaction listing, while we are here** | Refused, and this decision is careful to keep that refusal: it must choose between the recorded and effective axes, which is the one place a listing can be confidently wrong. It needs its own decision, not a paragraph in this one. |
| **A search or filter surface** | Equality on `purpose` and `owner_id` is what a caller needs to find an account it already knows about. Pattern matching is a different feature with different indexes behind it. |

## What it costs

- **`ledger_accounts` still carries no `xact_id`, and this endpoint makes that reachable by every
  caller.** It is why an issued report's *row set* is not reproducible while its amounts are
  ([0019](/decisions/0019-read-path)): opening an account adds lines to a balance sheet re-run at a
  fixed cursor. Until now that took database access; now it takes an HTTP request. **This raises the
  priority of the deferred `xact_id` column on the account register** — it does not create the hole,
  it widens the door to it.
- **An account opened for a perimeter type fires `chart_lint.perimeter_unattested` immediately**,
  because the attestation feed does not exist ([0012](/decisions/0012-chart-governance)). That is a
  standing, known condition rather than a new one, but a caller who opens perimeter accounts through
  the API will meet it sooner than one who did not.
- **The listing's page size is a cost surface.** A tenant with many accounts pays per page, and the
  maximum is a number chosen rather than measured — no book here has enough accounts for that number
  to have been earned by evidence.
- **`account_exists` cannot distinguish "yours" from "another owner's".** `uq_accounts__owned` is per
  `(tenant, owner_type, owner_id, purpose, currency)`, so within one tenant a collision is always the
  caller's own account; the refusal says the account exists and does not say more. That is the same
  fail-closed silence [0019](/decisions/0019-read-path) records for tenants, and it is deliberate.
- **This is the second decision to add routes since the surface was declared**, and each route is
  permanent under [0014](/decisions/0014-http-api)'s machine-checked route table. Two more is two
  more forever.
