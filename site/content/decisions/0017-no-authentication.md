# 0017 — No authentication: the deployment perimeter is the trust boundary

**Status:** accepted — ruled by Fernando on 2026-08-31, answering the question
[ADR-0014](/decisions/0014-http-api)'s cost list left open ("until an auth ADR exists" — this is
that ADR).

## The decision

**The ledger deploys internally only, and carries no authentication of its own.** The adoption
surface ([0014](/decisions/0014-http-api)) is an internal service behind the deployer's perimeter —
the same trust stance as the operator's own database, which this service fronts — and
authenticating callers is the deployer's layer: the service mesh, the gateway, mTLS, whatever that
deployment already uses to authenticate its internal calls. The ledger will not ship a second,
ledger-shaped copy of that machinery.

**`tenant_id` in the request body is data scoping, not an auth claim — by design, not by omission.**
It names which book a posting lands on; it asserts nothing about who the caller is, and nothing in
the service pretends otherwise. The docs and the API description have said this since the first
endpoint ("the trust story is the deployment perimeter's"); what changes today is that the sentence
is a decision rather than a placeholder.

What stands unchanged: row-level security scopes the **read** role per tenant and fails closed
([0013](/decisions/0013-write-path-contract) §5). That is a data-scoping fence for analysts, BI
tools and reporting connections — not authentication — and the writer remains admitted across
tenants, exactly as 0013 records.

## What we considered

| | Why not |
| --- | --- |
| **Per-tenant API keys** | Invents an identity system the deployer already has, plus a secret store to keep it in, plus rotation — all of it security the perimeter was already providing, now duplicated and divergeable. |
| **Requiring a gateway and documenting it** | That *is* this decision, minus the honesty: the gateway is the deployer's, configured to the deployer's identity model, and pretending to own its requirements from here adds words and no protection. |
| **Binding `tenant_id` to an authenticated principal** | Needs the identity layer this ADR declines to own. The mapping from principal to tenant belongs where the principals live; the day a deployment wants it, it is a gateway rewrite rule, not a ledger feature. |

## What it costs

- **An exposed deployment has no protection at all.** "Internal only" is a stated deployment
  requirement, not an enforced one — the binary cannot verify its own network position. A
  deployment that puts `POST /v1/transactions` on the public internet is out of contract, and the
  docs must keep saying so as loudly as this sentence does.
- **Inside the perimeter, any caller can write to any tenant's book.** Cross-tenant misuse by an
  internal caller is an application bug on the caller's side; the event log (`source`, the stored
  payload) is the audit trail for tracing it, not an authenticator for preventing it.
- **This is the decision to reverse if a public-facing deployment ever becomes a goal** — and the
  write surface was held to one route partly so that reversal stays cheap.
