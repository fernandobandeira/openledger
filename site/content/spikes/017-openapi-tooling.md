# Spike 017 — `aide` or `utoipa` for the write path's OpenAPI spec?

**Status:** closed. **Both libraries can state the whole contract, so fidelity decided nothing; the
spike recommended `utoipa` + `utoipa-axum`'s `routes!` macro, and
[ADR-0014](/decisions/0014-http-api) took `utoipa` but refused `utoipa-axum` — on this
spike's own RUSTSEC finding.** Both halves are recorded below, because a spike page reports what the
spike found and, separately, what the decision took from it.

**Question.** The writer ships behind an HTTP API (tokio + axum), and the API's OpenAPI document must
be *generated from the code* and rendered statically into this docs site. Two crates claim to do this
for axum: `utoipa` (attribute macros beside the handler) and `aide` (extraction from the axum
router). Which one can state [ADR-0013](/decisions/0013-write-path-contract) §2's replay contract
without lying about it, emit a byte-stable `openapi.json` a CI snapshot test can diff, and still be
maintained in a year?

**Ran** 2026-08-27 · rustc 1.97.1, axum 0.8.9, `utoipa` 5.5.0 + `utoipa-axum` 0.2.0, `aide` 0.15.1
(its latest stable), every version pinned with `=`. The same minimal surface was built **twice**, as
two standalone cargo projects, plus a third with no OpenAPI crate at all as the cost baseline. No
database — every handler is a stub, because the question is spec generation, not the writer. The
modelled surface is ADR-0013 §2 verbatim: `POST /v1/transactions` answering **201** with
`{event_id, transaction_id|null}` and a documented `Idempotency-Replayed` header, or **422** with
`{type, detail}` for the poisoned replay, plus `GET /v1/accounts/{id}/balance` to exercise a path
parameter. Everything below reproduces from `spikes/021-openapi-tooling/RUN.sh` — the spike
directories carry their own numbering, which diverged from this site's sequence some pages ago.

---

## The answer

**Fidelity was NOT the discriminator.** Both libraries express every clause of the contract — the
documented `Idempotency-Replayed` header on the 201, the genuinely nullable `transaction_id` (a 3.1
type union, `["string", "null"]`, with `event_id` required and `transaction_id` not), the 422 problem
body, and one Rust error enum fanning out to two documented responses. Both emit OpenAPI 3.1.0, and
both emit it **byte-identically across five separate processes and across a `cargo clean`**. The
decision turned on four things that were measured instead:

**1 · The documented response header costs 3 lines in utoipa and 73 in aide.** utoipa declares it
inline in the `#[utoipa::path]` attribute. aide's `TransformResponse` has no `header()` method at
all, so the header means a hand-written wrapper type with an `OperationOutput` impl that constructs
the `openapi::Header` by hand — 73 lines, disconnected from `IntoResponse`, so it drifts exactly
like a utoipa annotation does (verified, D6 below). Total source for an identical spec: bare axum
**105** lines, utoipa **233**, aide **380**.

**2 · Both are deterministic; only utoipa is *insensitive*.** utoipa sorts `paths` and `responses`;
aide keeps registration and insertion order. Swapping the two route declarations — a pure refactor —
changed **0 lines** of the committed utoipa spec and **104 lines** of the aide one. For a snapshot
test in CI, insensitivity is the property you want.

**3 · aide's structural drift immunity does not cover the part ADR-0013 cares about, and its naive
failure mode is the worst thing measured here.** aide cannot drift on path or method. It *can* drift
on status code and header name, silently. And handlers written the ordinary axum way —
`(StatusCode, [header], Json<T>)` and `Path<Uuid>` — produce an endpoint with **no `responses` key
at all** and a path parameter that does not appear, with zero compile errors and zero diagnostics
even with aide's error hook installed. The root cause is in aide itself: its `OperationOutput` impl
for tuples is **empty**, so the ordinary return shape contributes nothing to the spec.

**4 · The maintenance asymmetry is not close, but utoipa carries one liability.** aide's last stable
release is 12.3 months old and pins a `schemars` version superseded two months after it shipped; its
current maintainer wrote 86% of the last year's commits and said in public he does not have time.
utoipa's last commit was three days before this spike ran. utoipa's liability is **`utoipa-axum`**:
no release in 19.4 months, and therefore still shipping `paste` 1.0.15 — **RUSTSEC-2024-0436,
unmaintained** — even though the fix was merged upstream on 2026-06-11 and never released.

**The spike's recommendation, verbatim:** adopt `utoipa` + `utoipa-axum`, use the `routes!` macro
(never a bare `axum::Router`), and add a CI test that hits every documented response and asserts the
status code and headers. `routes!` removes path drift structurally; nothing in either library removes
status/body/header drift, so the test is not optional under either choice — and once you are writing
it anyway, aide's structural advantage mostly evaporates.

## The amendment — what ADR-0014 actually took

[ADR-0014](/decisions/0014-http-api) adopted `utoipa` and the response-level test, and
**refused `utoipa-axum`** on finding 4: a 19.4-month-unreleased binding crate that is a
`cargo deny` finding (`paste`, RUSTSEC-2024-0436) on day one, with the fix merged but unshipped, is
the exact shape of dependency this spike marked aide down for. Refusing it reintroduces the drift
that `routes!` made structurally impossible — a plain `axum::Router` can route `/v1/txns` while the
annotation still documents `/v1/transactions` (D1 below, measured). The decision replaces that
structural guarantee with a **committed-spec conformance test**: the emitted `openapi.json` is
committed, CI re-emits and diffs it, and the response-level test asserts what the spec claims
against the running router. The spike's own conclusion — *"neither library protects the response
contract; a response-level test does"* — is what makes the substitution honest rather than hopeful.

---

# The evidence

## 1 · Contract fidelity — both pass

The header, in utoipa, is three lines of attribute:

```rust
(status = 201, description = "…", body = TransactionAccepted,
 headers(("Idempotency-Replayed" = bool, description = "`true` when this call replayed …")))
```

In aide it is the 73-line `CreatedWithReplayHeader` wrapper, because `TransformResponse` has
`description`, `example`, `hidden`, `inner()` — and no `header()`. The output is equivalent (aide's
is slightly richer: `style` and `required` populated). The 422 in utoipa is
`#[derive(IntoResponses)]` on the error enum, one attribute per variant; in aide it is a 43-line
hand-written `OperationOutput` returning `vec![(Some(422), …), (Some(404), …)]`.

What did **not** survive contact, one wart per library and one shared:

- **utoipa inlines the error schema.** `#[to_schema]` on an `IntoResponses` variant inlines
  `ProblemDetail` in full at every use site — **4 copies** in a 2-endpoint spec, 315 lines against
  aide's 298 for the same content (aide `$ref`s it). `#[to_response]`/`#[ref_response]` fix it at
  the cost of a second derive.
- **utoipa emits `"license": {"name": ""}`** when no license is declared — visible in the rendered
  Redoc page as a bare `License:` heading with nothing after it, in a committed artifact.
- **aide needs a named struct for a path parameter** — `Path<Uuid>` produces no parameter at all —
  and that struct then leaks into `components/schemas` as a public model.
- **Both fan the error enum out over-broadly.** The enum carries 422 *and* 404, so the POST
  documents a 404 it cannot return and the GET documents a 422 it cannot return. Neither library can
  attach a *subset* of an error type's responses to one operation; the fix in both is a second,
  narrower error type — a design decision worth taking once, before the surface grows.

## 2 · Determinism

| check | utoipa | aide |
| --- | --- | --- |
| 5 separate processes, same binary | **5/5 byte-identical** | **5/5 byte-identical** |
| across `cargo clean` + full rebuild | identical | identical |
| `paths` / `responses` order | **sorted** / **sorted** | registration / insertion order |
| swapping the two routes in the source | **spec unchanged** | **104 changed lines** |

Five processes is the check that catches a hash-seeded map; the clean rebuild catches proc-macro and
build-order effects. Neither project *documents* a stability guarantee — this is measured behaviour
on these versions, and the snapshot test is what makes it a promise.

## 3 · Drift — nine experiments, one edit each

`RUN.sh drift` copies a project, makes **one** edit without touching the other side of the contract,
rebuilds, re-emits, diffs. ~90 s for the full log.

| | edit | result |
| --- | --- | --- |
| D1 | utoipa on a plain `axum::Router`: route the wrong paths, keep the annotations | **compiles clean; the spec documents two endpoints that do not exist** |
| D2 | utoipa with `routes!`: change `path = …` in the annotation only | spec *and* live route both moved — **path drift structurally impossible** |
| D3 | utoipa: handler returns 200, annotation says 201 | **spec byte-identical.** Silent drift |
| D4 | utoipa: extractor changed, annotation's `request_body` kept | spec unchanged. Silent drift |
| D5 | aide: change the route string | spec followed the router — **aide cannot drift on path or method** |
| D6 | aide: header renamed and status changed **in `IntoResponse`** | **spec byte-identical** — still 201, still `Idempotency-Replayed`. Silent drift, in the exact place ADR-0013 §2 cares about |
| D7 | aide: handlers written the ordinary axum way | **no `responses` key, no path parameter, zero diagnostics** even with `generate::on_error` installed |
| D8 | both: rename a field | both regenerated — field-level drift impossible in either |
| D9 | aide: describe a response aide already inferred | warning routed through `generate::on_error`, **off by default**; build succeeds |

The shape of it: aide moves drift from *"the annotation is a second copy of the route"* (which
`routes!` also fixes) to *"the type you return is the documentation"* — genuinely better, until the
thing to document is not expressible as a return type, at which point you hand-write an
`OperationOutput` that drifts identically (D6) and whose absence is invisible (D7). ADR-0013's
contract needs exactly that: a status code and a response header that axum carries in a tuple.

## 4 · Crate health — crates.io and the GitHub API, 2026-08-27

| | **utoipa** | **aide** |
| --- | --- | --- |
| latest stable | 5.5.0, 2026-05-04 | 0.15.1, 2025-08-19 — **12.3 months old** |
| last commit | **2026-08-24** (3 days before this ran) | 2026-04-14 (**4.4 months of silence**) |
| commits, trailing 12 months | 45 | 29, 86% by one person |
| downloads, 90 days | **13.5M** (+2.7M `utoipa-axum`) | 692K |
| crates.io owners | **1** | 4 |

aide has **already been handed off once** — issue #55, *"Looking for maintainers"*, opened by the
original author in 2023, closed 20 months later when the current maintainers were added. The current
maintainer, 2026-02-24: *"As it stands I don't have much time for open source in general, but this
is one of my higher priorities for when I get some focus time again."* He is responsive on issues —
and has shipped no code in 4.4 months. The consequence you actually feel: aide 0.15.1 pins
`schemars ^0.9.0`, superseded by schemars 1.0.0 on **2025-06-23**; the only aide that speaks
schemars 1.x is `0.16.0-alpha.4`, in alpha for 9.6 months with no beta, 92K downloads against
stable's 902K. Today the choice is *stable aide on a superseded schemars* or *a prerelease*.

utoipa's side, stated with the same candour: bus factor on crates.io is **1**; it had a ~7-month
near-dormancy before the 2026-05 revival, so "actively maintained" is a statement about now, not a
trend line; and `utoipa-axum` 0.2.0 (2025-01-16, **19.4 months**, no release even staged in-tree)
still ships `paste` 1.0.15 — RUSTSEC-2024-0436, unmaintained — with the `pastey` replacement merged
upstream on 2026-06-11 and unreleased. That row is what ADR-0014's amendment stands on.

## 5 · Static rendering — verified over `file://`

`render/build.py` reads the emitted spec and generates two self-contained pages, each embedding the
JSON in a `<script type="application/json">` block rather than fetching it. Both were rendered in
headless Chrome — over `http://` *and* over `file://` with no server at all — and the DOM searched
for the contract's own strings (`Idempotency-Replayed`, `transaction_id`, `422`): all present, both
viewers, both transports. Inlining is the one decision that matters for a static host: a page that
does `fetch('openapi.json')` is one `basePath` change or one CORS rule away from an empty shell.

What remains third-party: the viewer bundle itself — **Redoc 2.5.3 at 1.10 MB, Scalar 1.66.1 at
3.80 MB**, both from a pinned CDN URL at view time. Both are single-file UMD builds, so vendoring
them is a copy, not a build step. Scalar buys 3.5× the bundle for the same page. Not verified: how a
raw `.html` interacts with this site's routing and the Pages workflow — the integration step is
open, and small.

## 6 · Cost over bare axum

| | unique deps | Δ | clean debug build (median) | binary |
| --- | --- | --- | --- | --- |
| `bare-axum` | 56 | — | 7.45 s | 29.7 MB |
| `utoipa-api` | 68 | +12 | **+1.24 s (+17%)** | 39.6 MB |
| `aide-api` | 70 | +14 | **+2.51 s (+34%)** | 41.1 MB |

utoipa's +12 includes a full regex engine (pulled by `utoipa-gen` at build time) and `paste`. aide's
+14 includes `schemars` and its derive stack. Runtime cost of either is zero: the spec is built once
at startup — or, as here, in a separate `emit` run — and neither library is on the request path.

---

## What this does not answer

- **Nothing here touched `site/`.** The path into the docs site is proven (a self-contained HTML
  file that renders from `file://`), not integrated.
- **Whether `utoipa-axum` has shipped since.** The RUSTSEC finding disappears the moment it cuts a
  release; ADR-0014's refusal was made against the 2026-08-27 state and says what would reopen it.
- **Only two endpoints were modelled.** The all-or-nothing error-enum fan-out is annoying at two and
  would be a design problem at twenty. Neither library was pushed on nesting, security schemes,
  `oneOf` bodies, or multipart.
- **aide 0.16.0-alpha.4 was not built.** The comparison is stable-to-stable; if the recommendation
  were reversed, the alpha is what one would actually want, and it is a prerelease.
- **No load, no database, no real writer.** Every handler is a stub.

## Reproduce

```sh
cd spikes/021-openapi-tooling
./RUN.sh            # build all three projects, emit the specs, rebuild the
                    # static pages, re-verify the determinism claim
./RUN.sh drift      # also run the nine drift experiments (~90 s)
```

The three emitted specs are committed under `spec/`, the generated pages under `render/`, and
`render/redoc-screenshot.png` shows the whole contract — the 201 with its header row,
`transaction_id` as `string or null <uuid>`, the 422 with `type`/`detail` — rendered from the
generated file.
