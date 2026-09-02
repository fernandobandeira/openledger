# The operator dashboard

A browser front end for the OpenLedger HTTP API: open an account, post a
transaction, read the book back, and re-run any report at a cursor you pinned.
Next.js 16 (App Router), TypeScript strict, Tailwind v4, shadcn/ui on Base UI.
Dark only, in the docs site's palette — Vesper has no light variant, so neither
does this.

## The shape of the page

Header, then the action bar and the cursor rail together in one sticky strip,
then accounts down the left with the walk and the selected account's entries
beside them. **The composer is six drawers behind a bar, not seven forms
down the page** — it used to render ~2900px tall and mostly be forms.

* **The action bar** is six buttons in two groups, `Write` and `Read`, each
  opening its form in a drawer over the page. The panels themselves did not
  change: same fields, same API names, same refusal rendering. A drawer keeps
  its form MOUNTED when it closes, so the key you minted and the answer you
  got back are still there when you open it again.
  Drawer widths are per action, set as an inline `--drawer-content-width`
  because Base UI declares its own under a `data-[swipe-axis=x]` selector that
  outranks any utility class: `min(94vw, 38rem)` for a short form,
  `50rem` for the posting form, `54rem` for a statement face and `68rem`
  for the trial balance. **A figure is never the element that scrolls away** —
  every table pins its amount columns (`w-px`, `whitespace-nowrap`) and lets
  the caption take the slack, and where three figure columns will not fit at
  all the trial balance moves its gross pair under the account rather than
  behind a scrollbar.
* **The sidenav** is `GET /v1/accounts`, grouped by the chart's own roll-up
  order, with one `GET /v1/accounts/{id}/balance` per row. That is N+1 and it
  is the API's shape rather than an oversight in it: a balance is per currency
  and per stripe, so a balance on every listing row would be the same N+1 one
  level in and ambiguous besides. **Start a fresh book** switches `tenant_id`
  to a new one — the book is per tenant, so a fresh one costs a state update
  and destroys nothing. There is no separate balance form: it asked you to
  paste an `account_id` to read a number this column already has, so its two
  facts — the route, and that no stripe appears in the answer — live here.
* **The owner is a field, not a footnote.** `uq_accounts__owned` is per
  `(tenant, owner_type, owner_id, purpose, currency)`, so three
  `customer_wallet` liabilities in USD are legal and differ only by owner. The
  trial balance's row carries no owner — it is `(account, currency)` — so
  `src/lib/owner.ts` joins it in from the register this page already listed,
  and the transaction's other legs name it too. Without it those rows are
  identical except for a UUID. The statement faces are chart LINES rather than
  accounts, so there is no owner to name there.
* **The main panel** is `GET /v1/accounts/{account_id}/entries`, with the axis
  toggle on the table because it is the most interesting control on the page.
  Flip it on a book carrying a backdated entry and the row moves: at the end of
  the recorded order, in the middle of the effective one. The row that moved is
  tagged where it sits — `dated back` on one axis, `recorded late` on the other
  — and the tag is computed from the page in hand, not asserted. A transaction
  id opens the rest of its legs, and any other leg's account is one click away.

## The rail is a sequence, not a scale

It used to plot `xid8` values on a linear scale. **There is no such distance.**
`report_cursor()` is `pg_snapshot_xmin` and the counter behind it is
cluster-global, so the values between two of this book's commits were spent on
transactions in other databases: `242924 ——— 243768` drew a gap that measured
the rest of the cluster, and a pin one commit back landed on the horizon's own
pixel. An `xid8` is a total ORDER; the interval between two of them carries no
information, and a ruler is a promise that it does.

So the rail draws **one tick per commit this book actually made**, evenly
spaced, with the horizon and the pin placed among them by RANK — "the pin is
three commits back" is three ticks you can count.

The ticks come from the account on screen. No response carries an entry's
commit position as a field, but `next_after` does: the recorded axis's page key
is `xact_id,entry_id`, so a page of ONE entry answers with that entry's own
commit position, and walking the axis reads them all (`useBookCommits`, capped
at 48, riding the first page's cursor and never moving the horizon). Ticks are
FEWER than entries whenever the writer batched — which is the truth, and worth
seeing.

**Where the commits are not known it says so.** A fresh page, an account never
written to, or a walk the ledger refused leaves two points and a drawn break
between them — "nothing known between" — rather than a scale interpolated over
values that carry none.

## The walk is data, and the walk is kept

`src/lib/scenario/` is the card lifecycle from `site/content/card/index.md` as
a **list of step definitions** — `{ id, label, teaches, requires, run(ctx) }` —
and `ScenarioStrip` renders the list. A step never handles a refusal: it asks
the context to post, and the context throws with the ledger's own answer, which
the runner renders `type` and `detail` verbatim. **A new step is a record
appended to `steps.ts` and nothing else** — no component changes to receive it,
which is what the period-close steps are being built against.

**Every run is kept.** The strip used to show the report of whichever step ran
last and throw the rest away, so ten steps left one paragraph and no trail.
`WalkLog` is the record — newest first, every call, its status and the one line
saying what it wrote — and it scrolls rather than growing the page. `seq` is
monotonic, so a step run twice is two entries; the last step is a deliberate
replay and collapsing it into the first would hide the header that makes it one.

Two places the ledger argued with the document, and the copy says so rather
than papering over it. **A hold has exactly one fate**: a pending transaction is
superseded once, so the trace's two captures cannot both carry `resolves_id` —
the first posts on its own and the last one resolves the hold. And **the
customer's repayment is not on this walk**, so operating cash ends below zero;
an overdrawn account is a legal state here, and the step says so.

The idempotency keys are the document's own event names — `evt_clear_1:revshare`
and the rest — which is what makes "send it twice" a replay of a real earlier
write rather than a staged one.

## The UI shows; the guide explains

The page used to carry the explanations: a paragraph under the rail, another
under the axis toggle, a note under every field and a three-paragraph footer.
`site/content/bookings.md` now teaches all of it properly and at length, so
what is left here is a link (`GuideLink`, `src/lib/docs.ts`) put where the
paragraph used to be — near the rail, the axis toggle, the sidenav's balances,
the posting form and the reports. Nothing that is a number, a label, an
endpoint name, a refusal message or a step title was touched. The rendered
prose is roughly a third of what it was.

The docs site and this app are separate Next apps. Served from one origin the
default `/bookings` is already right; otherwise name the docs origin in
`NEXT_PUBLIC_OPENLEDGER_DOCS_ORIGIN`.

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
