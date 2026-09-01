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

## The types come from the spec

`src/lib/api-types.ts` is **generated** from `crates/api/openapi.json` — the
committed artifact a snapshot test regenerates and compares byte for byte, so
drift there is already a failed build. `openapi-typescript` carries that
guarantee into this app:

```sh
npm run generate:api-types   # also runs as predev and prebuild
```

The file is committed on purpose, so a reviewer sees the wire shape change in
the same diff as the code that answers to it. `src/lib/api.ts` is a thin typed
wrapper whose every request and response type is an indexed lookup into that
file; nothing restates a wire shape by hand. Rename `pinned_cursor` in a
handler, regenerate, and the four report panels stop compiling — which is the
whole point of paying for a generator.

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
