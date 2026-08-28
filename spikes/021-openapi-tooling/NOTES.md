# 021 — `aide` or `utoipa` for the write path's OpenAPI spec?

**Question.** The writer ships behind an HTTP API (tokio + axum), and the API's OpenAPI document must
be *generated from the code* and rendered statically into the docs site. Two crates claim to do this
for axum: `utoipa` (attribute macros beside the handler) and `aide` (extraction from the axum
router). Which one can state [ADR-0013](/decisions/0013-write-path-contract) §2's replay contract
without lying about it, emit a byte-stable `openapi.json` a CI snapshot test can diff, and still be
maintained in a year?

**Ran.** 2026-08-27. Both libraries were used to build the **same** minimal API surface twice, as two
standalone cargo projects in this directory, plus a third with no OpenAPI crate at all as the cost
baseline. No database: the handler bodies are stubs, because the question is spec generation, not the
writer. Everything in this document is reproduced by `./RUN.sh` and `./RUN.sh drift`.

---

## The answer

**`utoipa` 5.5.0 + `utoipa-axum` 0.2.0.** Both libraries can express the whole ADR-0013 contract —
the documented `Idempotency-Replayed` header on the 201, the genuinely nullable `transaction_id`, the
422 problem body, and one Rust error enum fanning out to two documented responses. Both emit a
byte-identical spec across five processes and across a `cargo clean`. So the decision does not turn
on capability; it turns on three things that were measured here:

1. **The header costs 3 lines in utoipa and 73 in aide.** aide's `OperationOutput` impl for tuples is
   empty, so the ordinary axum way of attaching a response header — `(StatusCode, [(HeaderName,
   HeaderValue); 1], Json<T>)` — contributes **nothing at all** to the spec, silently. Getting the
   header documented means hand-writing a wrapper type and an `OperationOutput` impl that constructs
   the `Header` object by hand. That hand-written impl is disconnected from `IntoResponse`, so it
   drifts exactly like a utoipa annotation does — verified.
2. **aide's drift immunity is real but does not cover the part ADR-0013 cares about.** aide cannot
   drift on path or method (measured, D5). It *can* drift on status code and header name (measured,
   D6), and its failure mode when a handler is written naturally is worse than utoipa's: an endpoint
   with **no responses at all** and a path parameter that does not appear, with zero compile errors
   and zero diagnostics (measured, D7).
3. **aide is one person who has said in public he does not have time.** aide's last stable release is
   2025-08-19 (12.3 months old) and pins `schemars ^0.9.0`, a version schemars superseded on
   2025-06-23. Its 0.16 line has been in alpha for 9.6 months with no beta. Its last commit is
   2026-04-14 — 4.4 months of silence. utoipa's last commit is 2026-08-24, three days ago.

**utoipa's own liability is `utoipa-axum`**, which has had no release since 2025-01-16 (19.4 months)
and therefore still ships `paste` 1.0.15 — **RUSTSEC-2024-0436, unmaintained** — even though the
replacement landed upstream on 2026-06-11. That is a `cargo deny` finding on day one and it is the
one thing that should be re-checked before adopting.

**Recommendation: adopt `utoipa` + `utoipa-axum`, use the `routes!` macro (never a bare
`axum::Router`), and add a CI test that hits every documented response and asserts the status code
and headers.** The `routes!` macro removes path drift, which is the drift utoipa is usually blamed
for. It does not remove status/body/header drift, and neither does aide — so the test is not
optional under either choice, and once you are writing it anyway, aide's structural advantage mostly
evaporates.

---

## What was built

```
spikes/021-openapi-tooling/
  bare-axum/          the cost baseline: same handlers, same types, no OpenAPI crate
  utoipa-api/         utoipa 5.5.0 + utoipa-axum 0.2.0
  aide-api/           aide 0.15.1 (src/main.rs = aide's way; src/bin/naive.rs = the plain axum way)
  spec/               the three emitted openapi.json files, committed
  render/             build.py + the two generated static pages
  drift/              nine drift experiments, each one edit to a scratch copy
  RUN.sh              regenerates everything and re-checks the determinism claim
```

The modelled surface is ADR-0013 §2 verbatim: `POST /v1/transactions` taking `{idempotency_key,
effective_at, postings[{source, destination, amount, currency}]}`, answering **201** with
`{event_id, transaction_id|null}` and a documented `Idempotency-Replayed: true|false` header, or
**422** with `{type, detail}` for the poisoned replay; plus `GET /v1/accounts/{id}/balance` to
exercise a path parameter.

### Versions (all pinned with `=` so the emitted spec is reproducible)

| | |
| --- | --- |
| toolchain | `rustc 1.97.1 (8bab26f4f 2026-07-14)`, `cargo 1.97.1`, edition 2024 |
| axum | 0.8.9 (2026-04-14, current) |
| utoipa | 5.5.0 (2026-05-04) |
| utoipa-axum | 0.2.0 (2025-01-16) |
| aide | 0.15.1 (2025-08-19) — latest **stable**; 0.16.0-alpha.4 (2026-04-14) is the newest publish |
| schemars | 0.9.0 (2025-05-26), forced by aide 0.15.1's `^0.9.0` |
| tokio / serde / serde_json / uuid / chrono / indexmap | 1.53.1 / 1.0.229 / 1.0.151 / 1.26.0 / 0.4.45 / 2.14.0 |
| Redoc / Scalar | 2.5.3 / 1.66.1, both from a CDN at view time |
| host | 16 cores, Linux 7.1.6, warm cargo registry |

---

## 1 · Contract fidelity — VERIFIED, both pass

Both emit OpenAPI **3.1.0**. Every clause of the contract landed in both specs. Fragments below are
copied out of `spec/openapi.utoipa.json` and `spec/openapi.aide.json` as generated.

### The documented custom response header on the 201

**utoipa** — declared inline in the `#[utoipa::path]` attribute, three lines:

```rust
(status = 201, description = "…", body = TransactionAccepted,
 headers(("Idempotency-Replayed" = bool, description = "`true` when this call replayed …")))
```

```json
"201": {
  "description": "Accepted, or replayed with the original stored result.",
  "headers": {
    "Idempotency-Replayed": {
      "schema": { "type": "boolean" },
      "description": "`true` when this call replayed an existing event rather than claiming the key. …"
    }
  },
  "content": { "application/json": { "schema": { "$ref": "#/components/schemas/TransactionAccepted" } } }
}
```

**aide** — `TransformResponse` has `description`, `example`, `hidden` and `inner()`, and **no
`header()` method** (aide 0.15.1, `src/transform.rs`). The header has to be built as an
`openapi::Header` value inside a hand-written `OperationOutput` impl on a wrapper type. That is
`CreatedWithReplayHeader` in `aide-api/src/main.rs`: **73 lines** against utoipa's 3. It works, and
the output is slightly richer (`style`/`required` are populated):

```json
"201": {
  "description": "Accepted, or replayed with the original stored result.",
  "headers": {
    "Idempotency-Replayed": {
      "description": "`true` when this call replayed an existing event rather than claiming the key. …",
      "style": "simple", "required": true,
      "schema": { "type": "boolean" }
    }
  },
  "content": { "application/json": { "schema": { "$ref": "#/components/schemas/TransactionAccepted" } } }
}
```

### The nullable field

Identical in both, and correct for OpenAPI 3.1 (a type union, not the 3.0 `nullable: true`):

```json
"transaction_id": {
  "description": "The transaction the event caused. **`null` for the majority of accepted\noperations, which write no transaction at all** (ADR-0013 §2).",
  "type": ["string", "null"],
  "format": "uuid"
}
```

`event_id` is in `required` and `transaction_id` is not, in both.

### The 422 body, and one Rust enum → two documented responses

**utoipa** — `#[derive(IntoResponses)]` on the enum, one attribute per variant, and the enum name
dropped into the path's `responses(...)` list:

```rust
#[derive(Debug, IntoResponses)]
pub enum ApiError {
    #[response(status = 422)] PoisonedReplay(#[to_schema] ProblemDetail),
    #[response(status = 404)] UnknownAccount(#[to_schema] ProblemDetail),
}
```

**aide** — no derive; `impl OperationOutput for ApiError` with an `inferred_responses` returning
`vec![(Some(422), …), (Some(404), …)]`. 43 lines including the shared `problem_response` helper.

Both produce a 422 whose schema is `ProblemDetail` with `type` and `detail` both required, and the
`#[serde(rename = "type")]` is honoured by both.

### Fidelity warts, one per library

- **utoipa inlines the error schema; aide `$ref`s it.** `#[to_schema]` on the `IntoResponses` variant
  inlines `ProblemDetail` in full at every use site — **4 copies** in a 2-endpoint spec (315 lines vs
  aide's 298 for the same content). `#[to_response]`/`#[ref_response]` move it to
  `components/responses` instead, at the cost of a second derive on the type.
- **utoipa emits `"license": {"name": ""}`** when `info(license(...))` is absent. It is visible in the
  rendered Redoc page as a bare `License:` heading with nothing after it. Cosmetic, but it is in a
  committed artifact.
- **Both fan the error enum out over-broadly.** `ApiError` carries 422 *and* 404, so `POST
  /v1/transactions` documents a 404 it cannot return and `GET …/balance` documents a 422 it cannot
  return. Neither library has a way to attach a *subset* of an error type's responses to one
  operation; the fix in both is a second, narrower error type. This is a property of the design, not
  of either crate — worth deciding once, before the surface grows.
- **aide needs a named struct for a path parameter.** `Path<Uuid>` produces no parameter at all
  (`OperationInput for Path<T>` runs `parameters_from_schema`, which wants an object's properties).
  `aide-api/src/contract.rs` therefore carries an `AccountPath { id: Uuid }` struct, and that struct
  then **leaks into `components/schemas`** as a public model. utoipa takes `params(("id" = Uuid, Path,
  …))` and emits nothing extra.
- **aide's example syntax is `#[schemars(example = &"USD")]`.** A bare string literal is rejected —
  *"`example` value must be an expression, and string literals that may be interpreted as function
  paths are currently disallowed"*. utoipa takes `#[schema(example = "USD")]`. Also: schemars emits
  the JSON-Schema `examples: ["USD"]` array; utoipa emits OpenAPI's `example: "USD"`, which 3.1
  deprecates in favour of the former. Both render.

---

## 2 · Deterministic spec emission — VERIFIED, both pass

Neither library is runtime-only: both hand back a plain serializable `OpenApi` value, so a
`main` that takes `emit <path>` and writes the file is ~10 lines in each. `utoipa` has
`OpenApi::to_pretty_json()`; with `aide` it is `serde_json::to_string_pretty(&api)`. Both projects
here expose the same CLI shape, which is the CI artifact path.

| check | utoipa | aide |
| --- | --- | --- |
| 5 separate processes, same binary | **5/5 byte-identical** (`48102f1122863e51…`) | **5/5 byte-identical** (`4c6042c64d479969…`) |
| across `cargo clean` + full rebuild | **identical** | **identical** |

Both depend on `indexmap` for their object maps, and `serde_json`'s default `Map` is a `BTreeMap`, so
key order is fixed rather than hash-seeded. Five processes is the check that catches a hash-seeded
map (Rust reseeds `RandomState` per process); the clean rebuild is the check that catches proc-macro
or build-order effects. Both are in `RUN.sh` and both pass.

**But their orderings differ in a way that matters for a committed artifact.** Measured by swapping
the two route registrations in each project and re-emitting:

| | utoipa | aide |
| --- | --- | --- |
| `paths` order | **sorted** (`/v1/accounts/…`, `/v1/transactions`) | **registration order** (`/v1/transactions`, `/v1/accounts/…`) |
| `responses` order | **sorted** (201, 404, 422) | **insertion order** (201, 422, 404) |
| schema `properties` order | sorted | sorted |
| swapping the two routes in the source | **spec UNCHANGED** | **104 changed lines** |

So a pure refactor — moving a route declaration — produces a 104-line diff in the committed aide spec
and no diff at all in the utoipa one. Neither is *nondeterministic*; utoipa's is simply insensitive
to more of the code. For a snapshot test in CI, insensitivity is the property you want.

> Not verified: neither project *documents* a stability guarantee. This is measured behaviour on
> these versions, not a promise. The snapshot test is what makes it a promise.

---

## 3 · Drift risk — measured, nine experiments

`./drift/RUN-drift.sh` copies a project, makes **one** edit without touching the other side of the
contract, rebuilds, re-emits and diffs. Full log reproduces in ~90s. Verdicts:

| | edit | result |
| --- | --- | --- |
| **D1** | utoipa on a **plain `axum::Router`**: routes `/v1/txns` + `{account_id}`, annotations still say `/v1/transactions` + `{id}` | **compiles clean; the spec documents two endpoints that do not exist.** Silent drift — the classic utoipa failure |
| **D2** | utoipa with **`utoipa-axum`'s `routes!`**: change `path = …` in the annotation only | **spec *and* live route both moved.** `POST /v1/txns → 201`, `POST /v1/transactions → 404` against the running server. Path drift is structurally impossible |
| **D3** | utoipa: handler returns `StatusCode::OK` instead of `CREATED` | **spec byte-identical, still says 201; server returns 200.** Silent drift |
| **D4** | utoipa: handler's extractor becomes `Json<Posting>`, annotation still `request_body = CreateTransactionRequest` | **spec still `$ref`s `CreateTransactionRequest`.** Silent drift |
| **D5** | aide: change the `api_route("/v1/transactions", …)` string | **spec followed the router.** aide cannot drift on path or method |
| **D6** | aide: change the header name to `x-replayed` and the status to `OK` **in `IntoResponse`** | **spec byte-identical — still 201, still `Idempotency-Replayed`.** Silent drift, in the exact place ADR-0013 §2 cares about |
| **D7** | aide: handlers written the ordinary axum way (`(StatusCode, [header], Json<T>)` and `Path<Uuid>`) — `src/bin/naive.rs` | **`POST /v1/transactions` gets `requestBody` and *no `responses` key at all*; `GET …/{id}/balance` gets *no `parameters`*.** Zero compile errors, zero stderr diagnostics even with `generate::on_error` installed |
| **D8** | both: rename `Posting.currency` → `ccy` | both regenerated. Field-level drift is impossible in either — the schema is derived from the type |
| **D9** | aide: describe a 200 aide already inferred | aide reports *"the response for status \"200\" already exists for the operation"*, **keeps your version**, and routes the message through `generate::on_error` — **off by default**. The build succeeds |

**The shape of the finding.** aide moves drift from *"the annotation is a second copy of the route"*
(which `utoipa-axum` also fixes) to *"the type you return is the documentation"* — which is genuinely
better, until the thing you need to document is not expressible as a return type, at which point you
are hand-writing an `OperationOutput` that drifts identically (D6) and whose absence is invisible
(D7). ADR-0013's contract needs exactly that: a status code and a response header that axum carries
in a tuple.

**Neither library protects the response contract. A response-level test does.** That is the same
conclusion ADR-0013 reaches about the replay contract itself: *"the contract binds the writer, not
the schema."*

---

## 4 · Crate health — verified against crates.io and the GitHub API, 2026-08-27

| | **utoipa** | **aide** |
| --- | --- | --- |
| latest stable | **5.5.0**, 2026-05-04 | **0.15.1**, 2025-08-19 — **12.3 months old** |
| newest publish of any kind | 5.5.0 | 0.16.0-alpha.4, 2026-04-14 (alpha for 9.6 months, no beta/rc) |
| last commit on default branch | **2026-08-24** (3 days ago) | **2026-04-14** (4.4 months ago) |
| commits, trailing 6 / 12 months | **41 / 45** | 18 / 29 (none in the last 4.4 months) |
| open issues / open PRs | 162 / 71 | 35 / 13 |
| oldest open PR | 2023-06-12 (3y2m) | 2024-07-09 (2y2m) |
| stars | 4,056 | 670 |
| downloads, 90 days | **13.5M** (+2.7M `utoipa-axum`) | **692K** |
| crates.io owners | **1 — `juhaku`** | 4 (`jplatte` active) |
| dominant author, 12 months | Juha Kukkonen 11/45 (24%) | **Jonas Platte 25/29 (86%)** |
| archived | no | **no** |
| examples in repo | **21 dirs, 5 axum-specific** | 2 dirs, ~5.9 KB total |
| crate-level docs (docs.rs) | 9,279 chars, **3 runnable code blocks** | 3,181 chars, **0 code blocks** |
| book / guide site | none | none |

**aide's maintenance status, verified rather than assumed.** The repo is *not* archived and there is
no deprecation notice. But:

- aide has **already been handed off once** after ~20 months of drift. Issue
  [#55 "Looking for maintainers"](https://github.com/tamasfe/aide/issues/55), opened by the original
  author `tamasfe` on 2023-04-30: *"It seems I cannot dedicate any time to OSS currently, so I'm
  looking for maintainers … so that people who rely on this library do not have to wait months for
  responses/fixes/features."* Closed 2024-12-23 when `jplatte` and `JakkuSakura` were added.
- The current maintainer said the same thing on
  [#270](https://github.com/tamasfe/aide/issues/270#issuecomment-3953919487), **2026-02-24**:
  *"As it stands I don't have much time for open source in general, but this is one of my higher
  priorities for when I get some focus time again."*
- He is nonetheless **responsive**: on 2026-08-24 (three days ago) he replied to a volunteer offering
  to help ship 0.16 by pointing at a PR *"abandoned by its author"* that needs a test. Responsive on
  issues, no code in 4.4 months, delegating.
- PR [#300](https://github.com/tamasfe/aide/pull/300) (2026-08-13) has sat two weeks with no review.

**The version consequence is concrete and is what you actually feel.** aide 0.15.1 pins
`schemars ^0.9.0`. schemars 0.9.0 shipped 2025-05-26; schemars **1.0.0 shipped 2025-06-23** and the
current release is 1.2.2 (2026-07-27). The only aide release that speaks schemars 1.x is
`0.16.0-alpha.4`, which also bumps `axum-extra` 0.10→0.12 and `serde_qs` 0.14→1.1.1 — both breaking
downstream. So today the choice is *stable aide on a superseded schemars* or *a prerelease*. The
alpha has 92K downloads against 0.15.1's 902K: the ecosystem has not moved.

**utoipa's liability is the axum binding, and it is a real one.**

- `utoipa-axum` `max_version` is still **0.2.0, published 2025-01-16 — 19.4 months.** The in-tree
  `Cargo.toml` on master still reads `version = "0.2.0"`, so no release is even staged.
- Consequently the published crate still depends on **`paste` 1.0.15**, and `cargo tree` here confirms
  it: `paste v1.0.15 (proc-macro)` appears in `utoipa-api` and not in `bare-axum`. `paste` is
  **RUSTSEC-2024-0436**, `informational = "unmaintained"`, `patched = []`, dated 2024-10-07 —
  dtolnay archived the repo. utoipa merged the switch to `pastey` in
  [#1452 on 2026-06-11](https://github.com/juhaku/utoipa/pull/1452); it is **unreleased**.
- utoipa itself had a **~7-month near-dormancy** (2025-07 → 2026-01, one commit) before the 2026-05
  revival, so "actively maintained" is a statement about now, not a trend line.
- Bus factor on crates.io is **1**.

**axum compatibility: a wash.** `utoipa-axum` 0.2.0 requires `axum ^0.8.0`; aide requires
`axum ^0.8.1`. Both resolve cleanly against the current axum 0.8.9, verified by building both
projects against exactly `=0.8.9`. `utoipa` core has no axum dependency at all — the coupling lives
entirely in `utoipa-axum`, which is the crate that is stale.

**Docs quality is not close.** utoipa's docs.rs landing page is 2.9× longer and has runnable
examples; aide's has none and defers to `github.com/tamasfe/aide/tree/**master**/examples` — a link
that is wrong in the shipped 0.15.1 rustdoc, because aide's default branch is `main` (302, not 200).
Working against aide in this spike meant reading `src/transform.rs`, `src/operation.rs` and
`src/impls/mod.rs` directly to find out that `TransformResponse` has no `header()` and that the
tuple impls are empty. Neither fact is discoverable from the docs.

---

## 5 · Static rendering for GitHub Pages — VERIFIED

`render/build.py` reads `spec/openapi.utoipa.json` and generates two self-contained pages. Both were
rendered in headless Chrome and the rendered DOM was searched for the contract's own strings:

| | over `http://` | over `file://`, no server at all |
| --- | --- | --- |
| `render/redoc.html` (Redoc 2.5.3) | 44,830 B DOM · `createTransaction` ×3 · `Idempotency-Replayed` ×4 · `transaction_id` ×3 · `422` ×7 | 44,785 B DOM · same hits |
| `render/scalar.html` (Scalar 1.66.1) | 430,027 B DOM · `createTransaction` ×1 · `Idempotency-Replayed` ×3 | 411,204 B DOM · same hits |

`render/redoc-screenshot.png` is that page as rendered: the 201 with its `Idempotency-Replayed`
header row, `transaction_id` shown as `string or null <uuid>`, and the 422 with its `type`/`detail`
schema — the whole contract, from the generated file. It also shows utoipa's empty `license` object
as a bare `License:` heading with nothing under it.

**The one decision that matters for a static host: inline the spec, do not fetch it.** Both pages
embed the JSON in a `<script type="application/json">` block and hand the parsed object to
`Redoc.init(spec, …)` / `Scalar.createApiReference('#app', { content: spec })`. A page that does
`fetch('openapi.json')` instead is one `basePath` change, one CORS rule or one local `file://`
preview away from rendering an empty shell; inlining removes the request. This is why both pages work
over `file://` — which is also the cheapest possible smoke test for "will this survive a static
host".

**What would break, and what it costs:**

- **The viewer bundle is still a CDN request** — `cdn.redoc.ly` (1.10 MB) or `cdn.jsdelivr.net`
  (3.80 MB). On GitHub Pages that is fine, but it is a third-party runtime dependency on a docs page
  and a CSP entry. Removing it means vendoring the bundle into the site's static assets; both are
  plain single-file UMD builds, so this is a copy, not a build step. **Scalar's bundle is 3.5× the
  size of Redoc's** for the same page.
- **The CDN version must be pinned.** `redoc/latest/` and `@scalar/api-reference` (no version)
  both resolve, and both mean the rendered page can change without a commit. The generated pages pin
  `v2.5.3` and `@1.66.1`.
- **`</` inside a description would end the `<script>` block.** `build.py` escapes it. The spec has no
  such string today; some description will.
- **Do not hand-edit the pages** — they are generated, so the spec has no third copy. `RUN.sh`
  regenerates them.
- **Not verified:** how a raw `.html` in `site/public/` interacts with Nextra's routing and the
  Pages workflow added in `7f2f280`. Nothing here touched `site/`. That is the remaining integration
  step and it is small.

---

## 6 · Cost over bare axum — measured

Same handlers, same types, same axum, three projects. Clean debug build ×3, warm cargo registry,
16 cores.

| | unique normal deps | Δ | clean `cargo build` (3 reps) | Δ (median) | debug binary |
| --- | --- | --- | --- | --- | --- |
| `bare-axum` | **56** | — | 7.45 / 7.43 / **7.72** s | — | 29.7 MB |
| `utoipa-api` | **68** | **+12** | 8.67 / 8.69 / **9.13** s | **+1.24 s (+17%)** | 39.6 MB |
| `aide-api` | **70** | **+14** | 10.10 / 9.96 / **10.21** s | **+2.51 s (+34%)** | 41.1 MB |

What each pulls in that bare axum does not:

- **utoipa (+12):** `utoipa`, `utoipa-gen`, `utoipa-axum`, `indexmap`, `equivalent`, `hashbrown`,
  `syn 2`, **`paste` (RUSTSEC-2024-0436)**, and `regex` + `regex-automata` + `regex-syntax` +
  `aho-corasick` — a full regex engine, pulled by `utoipa-gen` at build time.
- **aide (+14):** `aide`, `schemars` + `schemars_derive`, `indexmap`, `equivalent`, `hashbrown`,
  `syn 2`, `dyn-clone`, `ref-cast` + `ref-cast-impl`, `serde_derive_internals`, `thiserror` +
  `thiserror-impl`, `tracing-attributes`.

Source cost for the same surface: `bare-axum` 105 lines, `utoipa-api` **233**, `aide-api`
**380** (303 + a 77-line `contract.rs`) — of which 73 lines are the response-header wrapper and 43
are the error-enum `OperationOutput`. aide is +147 lines over utoipa for an identical spec.

Emitted spec: utoipa 315 lines / 10,330 B; aide 298 lines / 8,943 B (aide `$ref`s the error schema
utoipa inlines four times).

---

## What this does not answer

- **Nothing here touched `site/`.** The path into the docs site is proven (a self-contained HTML file
  that renders from `file://`), not integrated. The Nextra/`public/` question is open.
- **`utoipa-axum` 0.2.0's `paste` dependency is a `cargo deny` finding today.** It is informational,
  not a vulnerability, and it disappears the moment `utoipa-axum` cuts a release. Check before
  adopting; if it still has not shipped, the options are an allow-list entry, a git dependency on
  utoipa master, or dropping `utoipa-axum` for a plain router — the last of which reintroduces D1.
- **Only two endpoints were modelled.** The all-or-nothing error-enum behaviour (§1) is annoying at
  two endpoints and would be a design problem at twenty. Neither library was pushed on nesting,
  security schemes, `oneOf` request bodies, or multipart.
- **aide 0.16.0-alpha.4 was not built.** The comparison is stable-to-stable. If the recommendation
  were reversed, the alpha (schemars 1.x) is what one would actually want, and it is a prerelease.
- **`preserve_order` was not enabled on schemars or serde_json.** With it, object key order follows
  declaration order rather than sorting; that would make aide's spec even more sensitive to source
  layout, and utoipa's schema properties sensitive where they currently are not.
- **No load, no database, no real writer.** Every handler is a stub. This spike says nothing about
  the runtime cost of either crate, which for both is zero: the spec is built once at startup (or, as
  here, in a separate `emit` run) and neither library is on the request path.
