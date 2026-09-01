# The operator dashboard

A browser front end for the OpenLedger HTTP API: open an account, post a
transaction, read the book back, and re-run any report at a cursor you pinned.
Next.js 16 (App Router), TypeScript strict, Tailwind v4, shadcn/ui on Base UI.
Dark only, in the docs site's palette — Vesper has no light variant, so neither
does this.

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
   answer at face value drags the horizon backwards.
2. **Report panels never auto-fill their inputs from the last answer.** Pin the
   cursor, then re-run at it: both are things you do on purpose.

## Money

A report amount is an exact-integer decimal **string** and can exceed 2^53, so
nothing in `src/lib/amount.ts` goes near `Number` — formatting is string
surgery and subtotals are `BigInt`. A single posting or entry amount is a JSON
number bounded by its own column; that asymmetry is ADR-0019's, and the one
place it bites is marked in the UI rather than smoothed over.
