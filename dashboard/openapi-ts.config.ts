import { defineConfig } from "@hey-api/openapi-ts";

/**
 * The dashboard's client is generated, not written.
 *
 * `crates/api/openapi.json` is the committed artifact a snapshot test
 * regenerates and compares byte for byte, so drift between the annotations
 * and the spec is already a failed build. This config carries that guarantee
 * one hop further: the request URL, the path and query parameters, the
 * request body and every response shape all come out of the same generator
 * pass, so a handler rename cannot survive as a URL string that still
 * type-checks against the type of a different route. That was the one class
 * of mistake the previous types-only generator could not see.
 *
 * `src/lib/api/` is committed, and `npm run check:api-client` fails the build
 * if what is committed is not what this config produces — the same contract
 * `make openapi-check` and `make schema-snapshot-check` hold over their own
 * generated artifacts.
 *
 * The plain fetch client, and deliberately nothing else. No react-query, no
 * axios: every read in this app is explicit-run, and a report pinned AT a
 * cursor is exactly the kind of answer an implicit cache would serve stale
 * under a key that does not mention the cursor.
 *
 * No `baseUrl` here and no `runtimeConfigPath`: the client this app actually
 * calls is built in `src/lib/ledger.ts`, pointed at this app's own origin so
 * `next.config.ts`'s `/v1/*` rewrite stays the only way to the ledger
 * (ADR-0017 — there is no CORS layer). Keeping that out of the generated
 * output is also what lets `check:api-client` regenerate into any temporary
 * directory and compare: nothing in `src/lib/api/` depends on where it sits.
 */
export default defineConfig({
  input: "../crates/api/openapi.json",
  output: "./src/lib/api",
  plugins: ["@hey-api/client-fetch", "@hey-api/typescript", "@hey-api/sdk"],
});
