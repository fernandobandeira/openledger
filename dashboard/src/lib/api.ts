/**
 * The typed edge of the dashboard.
 *
 * Every request and response type on this file is an indexed lookup into
 * `api-types.ts`, which `npm run generate:api-types` writes from
 * `crates/api/openapi.json` — the committed, snapshot-tested spec. Nothing
 * here restates a wire shape by hand, which is the whole point: rename a field
 * in the handler, regenerate the spec, and the component that reads it stops
 * compiling.
 *
 * Requests go to `/v1/...` on this app's own origin; `next.config.ts` rewrites
 * that to the ledger. There is no CORS layer on the ledger and none is coming
 * (ADR-0017), so the proxy is not a convenience — it is the only way a browser
 * reaches this API.
 */
import type { components, paths } from "./api-types";

/* ---- the wire vocabulary, all of it borrowed ---------------------------- */

export type ErrorBody = components["schemas"]["ErrorBody"];
export type AccountBody = components["schemas"]["AccountBody"];
export type AccountCreated = components["schemas"]["AccountCreated"];
export type AccountRead = components["schemas"]["AccountRead"];
export type AccountListRead = components["schemas"]["AccountListRead"];
export type AccountBalanceRead = components["schemas"]["AccountBalanceRead"];
export type TransactionBody = components["schemas"]["TransactionBody"];
export type TransactionCreated = components["schemas"]["TransactionCreated"];
export type TransactionRead = components["schemas"]["TransactionRead"];
export type EntryRead = components["schemas"]["EntryRead"];
export type PostingBody = components["schemas"]["PostingBody"];
export type OwnerType = components["schemas"]["OwnerTypeBody"];
export type Status = components["schemas"]["StatusBody"];
export type TrialBalanceRead = components["schemas"]["TrialBalanceRead"];
export type TrialBalanceRowRead = components["schemas"]["TrialBalanceRowRead"];
export type StatementRead = components["schemas"]["StatementRead"];
export type StatementLineRead = components["schemas"]["StatementLineRead"];

export type ListAccountsQuery = NonNullable<
  paths["/v1/accounts"]["get"]["parameters"]["query"]
>;
export type AccountBalanceQuery = NonNullable<
  paths["/v1/accounts/{account_id}/balance"]["get"]["parameters"]["query"]
>;
export type TransactionQuery = NonNullable<
  paths["/v1/transactions/{transaction_id}"]["get"]["parameters"]["query"]
>;
export type TrialBalanceQuery = NonNullable<
  paths["/v1/reports/trial-balance"]["get"]["parameters"]["query"]
>;
export type BalanceSheetQuery = NonNullable<
  paths["/v1/reports/balance-sheet"]["get"]["parameters"]["query"]
>;
export type IncomeStatementQuery = NonNullable<
  paths["/v1/reports/income-statement"]["get"]["parameters"]["query"]
>;

/* ---- what an answer can be ---------------------------------------------- */

/**
 * Four outcomes, kept apart on purpose.
 *
 * `refused` is the only one that carries the API's own `type` and `detail`,
 * and the UI renders those two strings verbatim. The other three are the
 * dashboard's own failures — a dead proxy, a body that is not an `ErrorBody` —
 * and they are labelled as such so nothing that did not come off the wire is
 * ever displayed as though it did.
 */
export type Answer<T> =
  | { outcome: "answered"; status: number; body: T; headers: Headers }
  | { outcome: "refused"; status: number; error: ErrorBody }
  | { outcome: "unreadable"; status: number; text: string }
  | { outcome: "unreachable"; detail: string };

type QueryValues = {
  [key: string]: string | number | boolean | undefined | null;
};

function withQuery(path: string, query: QueryValues): string {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(query)) {
    if (value === undefined || value === null || value === "") continue;
    search.set(key, String(value));
  }
  const rendered = search.toString();
  return rendered ? `${path}?${rendered}` : path;
}

function looksLikeErrorBody(value: unknown): value is ErrorBody {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as Record<string, unknown>;
  return (
    typeof candidate.type === "string" && typeof candidate.detail === "string"
  );
}

async function sendToLedger<T>(
  path: string,
  init?: RequestInit
): Promise<Answer<T>> {
  let response: Response;
  try {
    response = await fetch(path, init);
  } catch (cause) {
    return {
      outcome: "unreachable",
      detail: cause instanceof Error ? cause.message : String(cause),
    };
  }

  const text = await response.text();
  let parsed: unknown;
  try {
    parsed = text.length === 0 ? null : JSON.parse(text);
  } catch {
    return { outcome: "unreadable", status: response.status, text };
  }

  if (response.ok) {
    return {
      outcome: "answered",
      status: response.status,
      body: parsed as T,
      headers: response.headers,
    };
  }
  if (looksLikeErrorBody(parsed)) {
    return { outcome: "refused", status: response.status, error: parsed };
  }
  return { outcome: "unreadable", status: response.status, text };
}

function postJson<T>(path: string, body: unknown): Promise<Answer<T>> {
  return sendToLedger<T>(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

/**
 * `Idempotency-Replayed` as the write path means it: `true` re-rendered a
 * stored result, `false` claimed the key. `null` means the header was absent,
 * which is never assumed to mean `false` — that would report a replay as a
 * fresh write.
 */
export function replayedHeader(headers: Headers): boolean | null {
  const raw = headers.get("idempotency-replayed");
  if (raw === null) return null;
  if (raw === "true") return true;
  if (raw === "false") return false;
  return null;
}

/* ---- the eight routes ---------------------------------------------------- */

export function openAccount(body: AccountBody): Promise<Answer<AccountCreated>> {
  return postJson<AccountCreated>("/v1/accounts", body);
}

export function listAccounts(
  query: ListAccountsQuery
): Promise<Answer<AccountListRead>> {
  return sendToLedger<AccountListRead>(withQuery("/v1/accounts", query));
}

export function readAccountBalance(
  accountId: string,
  query: AccountBalanceQuery
): Promise<Answer<AccountBalanceRead>> {
  const path = `/v1/accounts/${encodeURIComponent(accountId)}/balance`;
  return sendToLedger<AccountBalanceRead>(withQuery(path, query));
}

export function postTransaction(
  body: TransactionBody
): Promise<Answer<TransactionCreated>> {
  return postJson<TransactionCreated>("/v1/transactions", body);
}

export function readTransaction(
  transactionId: string,
  query: TransactionQuery
): Promise<Answer<TransactionRead>> {
  const path = `/v1/transactions/${encodeURIComponent(transactionId)}`;
  return sendToLedger<TransactionRead>(withQuery(path, query));
}

export function runTrialBalance(
  query: TrialBalanceQuery
): Promise<Answer<TrialBalanceRead>> {
  return sendToLedger<TrialBalanceRead>(
    withQuery("/v1/reports/trial-balance", query)
  );
}

export function runBalanceSheet(
  query: BalanceSheetQuery
): Promise<Answer<StatementRead>> {
  return sendToLedger<StatementRead>(
    withQuery("/v1/reports/balance-sheet", query)
  );
}

export function runIncomeStatement(
  query: IncomeStatementQuery
): Promise<Answer<StatementRead>> {
  return sendToLedger<StatementRead>(
    withQuery("/v1/reports/income-statement", query)
  );
}
