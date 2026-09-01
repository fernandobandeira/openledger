# The operator dashboard

A browser front end for the OpenLedger HTTP API: open an account, post a
transaction, read the book back, and re-run any report at a cursor you pinned.
Next.js 16 (App Router), TypeScript strict, Tailwind v4, shadcn/ui on Base UI.
Dark only, in the docs site's palette — Vesper has no light variant, so neither
does this.

## The shape of the page

Accounts down the left, the walk and the selected account's entries in the
middle, the composer underneath.

* **The sidenav** is `GET /v1/accounts`, grouped by the chart's own roll-up
  order, with one `GET /v1/accounts/{id}/balance` per row. That is N+1 and it
  is the API's shape rather than an oversight in it: a balance is per currency
  and per stripe, so a balance on every listing row would be the same N+1 one
  level in and ambiguous besides. **Start a fresh book** switches `tenant_id`
  to a new one — the book is per tenant, so a fresh one costs a state update
  and destroys nothing.
* **The main panel** is `GET /v1/accounts/{account_id}/entries`, with the axis
  toggle on the table because it is the most interesting control on the page.
  Flip it on a book carrying a backdated entry and the row moves: at the end of
  the recorded order, in the middle of the effective one. The row that moved is
  tagged where it sits — `dated back` on one axis, `recorded late` on the other
  — and the tag is computed from the page in hand, not asserted. A transaction
  id opens the rest of its legs, and any other leg's account is one click away.
* **The composer** is the point, and it is unchanged: every route spelled out,
  in the API's own field names, with nothing filled in that you did not fill in
  on purpose.

## The walk is data

`src/lib/scenario/` is the card lifecycle from `site/content/card/index.md` as
a **list of step definitions** — `{ id, label, teaches, requires, run(ctx) }` —
and `ScenarioStrip` renders the list. A step never handles a refusal: it asks
the context to post, and the context throws with the ledger's own answer, which
the runner renders `type` and `detail` verbatim. **A new step is a record
appended to `steps.ts` and nothing else** — no component changes to receive it,
which is what the period-close steps are being built against.

Two places the ledger argued with the document, and the copy says so rather
than papering over it. **A hold has exactly one fate**: a pending transaction is
superseded once, so the trace's two captures cannot both carry `resolves_id` —
the first posts on its own and the last one resolves the hold. And **the
customer's repayment is not on this walk**, so operating cash ends below zero;
an overdrawn account is a legal state here, and the step says so.

The idempotency keys are the document's own event names — `evt_clear_1:revshare`
and the rest — which is what makes "send it twice" a replay of a real earlier
write rather than a staged one.

## Running it

```sh
# 1. the database and the ledger
make up                                    # from the repository root
cargo build -p openledger
DATABASE_URL="postgres://openledger:openledger@localhost:5433/openledger?sslmode=disable" \
  ./target/debug/openledger serve          # binds 127.0.0.1:8080

# 2. the dashboard
cd dashboard && npm install && npm run dev # http://localhost:3000
```

`next.config.ts` rewrites `/v1/:path*` to the ledger, so the browser talks
same-origin. The ledger carries no CORS layer and is not getting one
(ADR-0017), which makes this proxy the only way a browser reaches the API.
Point it somewhere else with `OPENLEDGER_API_ORIGIN`.

## The client comes from the spec

`src/lib/api/` is **generated** from `crates/api/openapi.json` — the committed
artifact a snapshot test regenerates and compares byte for byte, so drift there
is already a failed build. `@hey-api/openapi-ts` carries that guarantee into
this app, and carries it further than a types-only generator could: the request
URL, the path and query parameters, the body and every response shape all come
out of one generator pass. A hand-written URL string sitting *beside* a type
lookup can type-check against `/v1/accounts` while fetching something else;
there is no such string left in this app.

```sh
npm run generate:api-client   # writes src/lib/api/ -- type this on purpose
npm run check:api-client      # fails if what is committed is not what the
                              # spec generates; also runs as predev/prebuild
```

The generated directory is committed on purpose, so a reviewer sees the wire
shape change in the same diff as the code that answers to it. **Regenerating
and checking are separate commands, deliberately.** `make openapi-check` and
`make schema-snapshot-check` are gates whose whole value is that a normal run
can only ever fail on drift, never paper over it by rewriting the file it was
about to compare; `make api-client-check` is the third of them, and it
regenerates into a throwaway directory and diffs. Rename `pinned_cursor` in a
handler and the two failures are different and both wanted: CI's
`api-client-check` fails until the client is regenerated, and once it is, the
four report panels stop compiling.

`src/lib/ledger.ts` is what the generator does *not* own: the four outcomes an
answer can have, the verbatim reading of a refusal's `type` and `detail`, the
`Idempotency-Replayed` header, and the one client instance — pointed at this
app's own origin (`baseUrl: ""`), so the `next.config.ts` rewrite stays in the
path. Nothing in it restates a wire shape by hand.

Two things about the generated output worth knowing. Its bundled HTTP runtime
(`src/lib/api/client/`, `core/`, `client.gen.ts`) is vendored code carrying
four `any`s of its own, so `eslint.config.mjs` ignores those three paths and
nothing else — `types.gen.ts` and `sdk.gen.ts` come from our spec and stay
linted. And the generator types every operation's `error` as `ErrorBody`,
which the runtime does not honour: the same field carries a raw string when a
refusal's body is not JSON and `fetch`'s own `TypeError` when nothing
answered. `ledger.ts` reads it as `unknown` and re-establishes what it is,
which is what keeps `refused` meaning *the ledger refused*.

## Two rules the UI obeys that are easy to get wrong

1. **The horizon mark advances only on a report answered without a supplied
   cursor** (plus an explicit refresh, and after a successful write). A report
   re-run *at* a pin returns that pin as its `pinned_cursor`, so taking every
   answer at face value drags the horizon backwards. The explicit refresh is
   `GET /v1/cursor` — one statement, not a report over the widest range.
2. **Report panels never auto-fill their inputs from the last answer.** Pin the
   cursor, then re-run at it: both are things you do on purpose.

## Money

**Every** amount on the wire is an exact-integer decimal **string** — a report
total, a posting on the way in, an entry on the way out (ADR-0022). A `bigint`
column reaches far past 2^53 and JSON has no integer type, so nothing in
`src/lib/amount.ts` goes near `Number`: formatting is string surgery and
subtotals are `BigInt`.

The posting form applies the API's own grammar before sending — `-?[0-9]+`,
then the `i64` range, then strictly positive — and says so in the API's own
words, so `25.00` and `2,500` never leave the page. A refusal that does come
back is still rendered verbatim, `type` and `detail` unedited.
