# 0014 — The HTTP API is the adoption surface, and the spec is a committed artifact

**Status:** accepted — and it **reverses** the roadmap's original "no API in v0.1" answer.
**Evidence:** [spike 017](/spikes/017-openapi-tooling) for the tooling verdicts;
`crates/api` and the e2e suite in `crates/e2e` for what shipped.

## The decision

**The writer ships behind an HTTP API, and never as a library crate.** A crate is callable from
exactly one language, and the adopter this project wants is anyone who can speak HTTP. The original
answer — v0.1 as `openledger migrate` plus a Rust crate, the `sqlx-ledger`/`pgledger` shape — was
recorded on the roadmap with its own revisit condition, and the condition fired early because the
deciding argument changed: a writer only Rust code can call is not a deliverable, and the HTTP
boundary is what makes the e2e tests **caller-shaped** — the suite spawns the compiled binary, talks
to it over real HTTP against a real PostgreSQL, and reads `SELECT * FROM reconciliation` as its
oracle, which is exactly what an adopter's first hour looks like. One endpoint shipped with
[M3](/roadmap#m3--the-posting-engine)'s lean writer as one vertical slice: `POST /v1/transactions`,
the writer behind it, and the pipeline that verifies both.

**What survives of the old reasoning is the part that was never about transport.**
[0005](/decisions/0005-event-log-and-write-path)'s refusal — checking balance at the API boundary
*"is a check, not a shape"* — still binds: balance lives in the posting type the handlers
deserialize into (`ledger::Posting` has no one-legged form), so the API is a thin mapping over the
error types the writer names, and grows no judgement of its own.
[0003](/decisions/0003-migrations)'s half is also unchanged: the service runs against a database the
operator already has and migrates ahead of, and you cannot hide a schema that is the product. What
the reversal *adds* is the surface [0013](/decisions/0013-write-path-contract) §2 specified before
it existed — and those wire semantics are now implemented, not promised: **422** for the poisoned
replay (a distinct `idempotency_key_reused` error, nothing written), **`Idempotency-Replayed`** on
both accepted responses — `false` on the 201 that claimed the key, `true` on the 200 that re-renders
the stored result — and **no invented 409**, because a concurrent duplicate blocks on the key claim
and finds a durable result. Each of those sentences is an e2e test in
`crates/e2e/tests/e2e/endpoints/transactions/post.rs`.

**The stack is tokio + axum, and the OpenAPI layer is `utoipa` core ONLY.**
[Spike 017](/spikes/017-openapi-tooling) built the same two-endpoint surface three times — `utoipa`,
`aide`, and bare axum as the cost baseline — and its measured recommendation was `utoipa` **plus
`utoipa-axum`**, whose `routes!` macro makes path drift structurally impossible. **We take the core
crate and refuse the axum binding, overriding the spike's own recommendation on its own health
data**: `utoipa-axum`'s last release is 19 months old and still ships `paste` —
RUSTSEC-2024-0436, unmaintained — which is a `cargo deny check` failure on day one under
[0015](/decisions/0015-workspace-enforcement)'s advisories policy, and an ignore entry to adopt a
convenience macro is the wrong direction for that list's first entry. The fix (`pastey`) merged
upstream on 2026-06-11 and is unreleased; **revisit when `utoipa-axum` ships it**. `aide` is refused
outright: its last stable release is 12.3 months old and pins a superseded `schemars`, its single
active maintainer has said in public he lacks time (the crate has already been handed off once), its
naive failure mode is *worse* — a handler written the ordinary axum way yields an endpoint with
**no `responses` at all**, silently, zero diagnostics — and documenting one response header cost
**73 lines** against utoipa's 3.

**The spec is a committed artifact, not a runtime behaviour.** `crates/api/openapi.json` is
generated from the annotations, committed, and snapshot-tested: `cargo test -p api --test spec`
regenerates and compares bytes, and rewrites the file only under an explicit
`OPENLEDGER_WRITE_SPEC=1` opt-in (`make openapi` / `make openapi-check`) — so a normal test run can
only ever *fail* on drift, never paper over it. Emission is byte-deterministic, measured in the
spike across five processes and a clean rebuild, and utoipa's sorted output is insensitive even to
reordering the route declarations — the property a committed diff wants. This is
[0007](/decisions/0007-schema-conventions-and-chart) §2's schema-snapshot instinct applied to the
API surface: the contract is a file in review, and drift is a failed build.

**The route table is exported, the router is built from it, and the e2e conformance test is the
working replacement for the `routes!` guarantee the refused crate would have given.** With a plain
`axum::Router`, the path in an annotation and the path in the router are two strings nothing
compares (spike 017 D1 — the classic silent utoipa failure). The router's side of that gap is now
closed structurally: `api::ROUTES` and the router's registrations expand from one list, so a table
entry is a live route by construction — no hand copy exists anywhere. The conformance test
(`crates/e2e/tests/e2e/conformance.rs`) holds the annotation side: the committed spec's
(method, path) set must **equal** `ROUTES` — both directions, so a route the spec forgot fails as
loudly as a route the router lost — and each table entry is probed on the wire, telling a missing
path from a missing method: the documented method must answer neither 404 nor 405, and an
undocumented method on the same path must answer exactly 405, which is what catches a route mounted
under the wrong verb.

**Each endpoint documents only the errors it can actually return.** Both candidate libraries fan a
shared error enum across every endpoint that names it — the spike's surface documented a 404 one
endpoint cannot return and a 422 the other cannot — and **neither library can attach a subset of an
error type's responses to one operation**. So the rule is set now, while there is one endpoint and
changing it costs nothing: responses are declared per endpoint, and the three 422 `type`s on
`POST /v1/transactions` are the three the writer can produce there, not an enum's worth.

## What we considered

| | Why not |
| --- | --- |
| **The writer as a Rust crate** (the roadmap's original answer) | A crate is callable from one language, and the e2e tests against it would be Rust-shaped, not caller-shaped. Reversed — with the "a check, not a shape" and operator-owns-the-database halves of its reasoning kept, above. |
| **`utoipa` + `utoipa-axum`** (the spike's recommendation) | 19 months without a release; ships `paste` (RUSTSEC-2024-0436, unmaintained), a `cargo deny` failure on day one. The merged `pastey` fix is unreleased — revisit when it ships. What `routes!` protected against (path drift) is covered by the conformance test instead. |
| **`aide`** | Single-author maintenance with a public "no time" statement and a 12.3-month-old stable pinning a superseded `schemars`; the ordinary-axum failure mode is an endpoint with no `responses` at all, silently (spike 017 D7); and the one header ADR-0013 requires costs 73 hand-written lines that drift exactly like an annotation (D6). |
| **A hand-maintained `openapi.json`** | A second copy of every wire type with no comparison to the code. Deriving the schema from the handler's own types makes body drift structurally impossible (D8) — the whole point of paying for a generator. |
| **Serving the spec from the binary at runtime** | Nothing would diff it. A committed file is reviewable, snapshot-tested, and renderable into the docs site statically; nothing about the spec needs to run at request time. |
| **One shared error enum fanned across endpoints** | Documents statuses an endpoint cannot return, and neither library can narrow it per operation later — the surface would have to be re-typed under every consumer. Decided while the cost is one endpoint's worth of annotations. |

## What it costs

- **No authentication, and the tenant is named in the request body.** The trust boundary is the
  deployment perimeter's until an auth ADR exists — stated in `crates/api/src/lib.rs` rather than
  implied. This is the largest honest gap in the surface, and it is why the endpoint count is being
  held down while the structure is under review.
- **`utoipa` annotations can drift from handler behaviour, and only the test layers catch it.** The
  spike measured the exposed class precisely: a status code or header set in `IntoResponse` moves
  and the spec stays byte-identical (D3, D6) — **and that class is uncovered by BOTH candidate
  libraries**, which is why the response-level e2e tests are not optional under either choice. The
  guarantee is the test suite, not the generator.
- **The route table is one more exported surface.** The hand copy the conformance test once
  restated is gone — `api::ROUTES` drives the router and the test consumes it, so a new route is a
  two-place change (table entry with its handler, annotation) — but the table is public API of the
  `api` crate now, and the e2e suite depends on that crate to read it where it previously read
  nothing but the wire.
- **The conformance bar per route proves routing, not behaviour.** The probes tell a missing path
  (404) from a missing method (405) in both directions, so a route mounted under the wrong verb
  fails; what they still do not prove is that the documented statuses and headers are what the wire
  carries. That half lives in the per-endpoint e2e files, which grow with the surface rather than
  for free.
- **The API is a second surface whose correctness is a mapping, not a guarantee.** The invariants
  live in the posting type and the writer ([0005](/decisions/0005-event-log-and-write-path),
  [0013](/decisions/0013-write-path-contract)); what this layer can get wrong is the translation —
  which status, which header, which error `type` — and the spec, the snapshot test and the e2e suite
  exist because a mapping is exactly the kind of code that drifts politely.
- **Regeneration is a deliberate step.** `OPENLEDGER_WRITE_SPEC=1` means an annotation change is a
  two-commit motion (change, regenerate) collapsed only by remembering `make openapi` — the same
  trade every committed artifact in this repository makes, accepted knowingly.
