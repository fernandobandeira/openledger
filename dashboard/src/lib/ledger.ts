/**
 * The typed edge of the dashboard.
 *
 * Everything on the wire — the URL, the path and query parameters, the
 * request body, every response shape — comes out of `src/lib/api/`, which
 * `npm run generate:api-client` writes from `crates/api/openapi.json`, the
 * committed and snapshot-tested spec. Nothing here restates any of it by
 * hand. That is stronger than a types-only generator was: a hand-written URL
 * string sitting *beside* a type lookup can type-check against one route
 * while fetching another, and there is no such string left in this file.
 *
 * What IS written here is the part no generator owns: the four outcomes an
 * answer can have, the verbatim reading of a refusal's `type` and `detail`,
 * and the `Idempotency-Replayed` header the write path means literally.
 *
 * Requests go to `/v1/...` on this app's own origin; `next.config.ts`
 * rewrites that to the ledger. There is no CORS layer on the ledger and none
 * is coming (ADR-0017), so the proxy is not a convenience — it is the only
 * way a browser reaches this API.
 */
import * as generated from "./api";
import { createClient, createConfig } from "./api/client";
import type {
  ErrorBody,
  GetAccountBalanceData,
  GetAccountStatementData,
  GetBalanceSheetData,
  GetCursorData,
  GetIncomeStatementData,
  GetTransactionData,
  GetTrialBalanceData,
  ListAccountsData,
} from "./api";

/* ---- the wire vocabulary, all of it borrowed ---------------------------- */

export type {
  AccountBalanceRead,
  AccountBody,
  AccountCreated,
  AccountListRead,
  AccountRead,
  AccountStatementRead,
  CursorRead,
  EntryRead,
  ErrorBody,
  PostingBody,
  StatementEntryRead,
  StatementLineRead,
  StatementRead,
  TransactionBody,
  TransactionCreated,
  TransactionRead,
  TrialBalanceRead,
  TrialBalanceRowRead,
} from "./api";

// Two the UI reads as vocabularies rather than as bodies, named for what they
// are at the call site. The spec's suffix says where they came from.
export type OwnerType = generated.OwnerTypeBody;
export type Status = generated.StatusBody;

// The query of each read, taken from the operation's own request type rather
// than restated. Every one of these is required on the wire (`tenant_id`
// alone makes it so), so none needs unwrapping.
export type ListAccountsQuery = ListAccountsData["query"];
export type CursorQuery = GetCursorData["query"];
export type AccountBalanceQuery = GetAccountBalanceData["query"];
export type AccountStatementQuery = GetAccountStatementData["query"];
export type TransactionQuery = GetTransactionData["query"];
export type TrialBalanceQuery = GetTrialBalanceData["query"];
export type BalanceSheetQuery = GetBalanceSheetData["query"];
export type IncomeStatementQuery = GetIncomeStatementData["query"];

/* ---- the one client, pointed at this app's own origin -------------------- */

/**
 * An instance of our own rather than the generated singleton, and passed
 * explicitly to every call below: a module that mutates a shared client at
 * import time works only for as long as nothing else imports the SDK first.
 *
 * `baseUrl: ""` makes every request path-relative — `/v1/accounts`, on
 * whatever origin the page was served from — which is what keeps the
 * `next.config.ts` rewrite in the path and the browser same-origin.
 *
 * `parseAs: "json"` overrides the client's default of inferring the parse
 * from `Content-Type`. Under the default, a 200 carrying `text/html` (a proxy
 * error page, say) would be handed back as a *successful* answer whose body
 * is a string, and this app would render it as one. Forcing JSON turns that
 * into the parse failure it is, which `answerFrom` reports as `unreadable`.
 */
const throughTheProxy = createClient(
  createConfig({ baseUrl: "", parseAs: "json" })
);

/* ---- what an answer can be ---------------------------------------------- */

/**
 * Four outcomes, kept apart on purpose.
 *
 * `refused` is the only one that carries the API's own `type` and `detail`,
 * and the UI renders those two strings verbatim. The other three are the
 * dashboard's own failures — a dead proxy, a body that is not an `ErrorBody`
 * — and they are labelled as such so nothing that did not come off the wire
 * is ever displayed as though it did.
 */
export type Answer<T> =
  | { outcome: "answered"; status: number; body: T; headers: Headers }
  | { outcome: "refused"; status: number; error: ErrorBody }
  | { outcome: "unreadable"; status: number; text: string }
  | { outcome: "unreachable"; detail: string };

/**
 * What a generated SDK call resolves to, widened on purpose.
 *
 * The generator types `error` as `ErrorBody` on every operation, because that
 * is what the spec documents. The client does not honour that: the same field
 * carries a raw string when a refusal's body is not JSON, and `fetch`'s own
 * `TypeError` when the request never reached a server. So this file reads it
 * as `unknown` and re-establishes what it is below, which is also what keeps
 * `refused` meaning *the ledger refused* and nothing else.
 */
type ClientFields<T> = {
  data?: T;
  error?: unknown;
  response?: Response;
};

function looksLikeErrorBody(value: unknown): value is ErrorBody {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as Record<string, unknown>;
  return (
    typeof candidate.type === "string" && typeof candidate.detail === "string"
  );
}

/** Whatever came back, rendered for a human, without pretending it is a body. */
function asText(value: unknown): string {
  if (typeof value === "string") return value;
  if (value instanceof Error) return value.message;
  return JSON.stringify(value) ?? String(value);
}

async function answerFrom<T>(
  pending: Promise<ClientFields<T>>
): Promise<Answer<T>> {
  const { data, error, response } = await pending;

  // No response at all: the request never completed. The client funnels
  // `fetch`'s rejection into the same `error` field as a refusal body, so a
  // missing `response` is the only thing that tells a dead proxy apart from
  // a ledger that answered.
  if (response === undefined) {
    return { outcome: "unreachable", detail: asText(error) };
  }

  if (response.ok) {
    // A 2xx whose body did not parse. The client has already consumed the
    // body to try, so the parser's message is what is left of it — said as
    // the dashboard's own failure, which is what `unreadable` is for.
    if (data === undefined) {
      return {
        outcome: "unreadable",
        status: response.status,
        text: asText(error),
      };
    }
    return {
      outcome: "answered",
      status: response.status,
      body: data,
      headers: response.headers,
    };
  }

  if (looksLikeErrorBody(error)) {
    return { outcome: "refused", status: response.status, error };
  }
  return { outcome: "unreadable", status: response.status, text: asText(error) };
}

/**
 * A blank field is not a filter.
 *
 * The generated query serializer drops `undefined` and `null` and sends
 * everything else, so an untouched text input would go out as `purpose=` —
 * an equality filter on the empty string, which is a question nobody asked.
 * This is the dashboard's policy about its own form state, not a wire
 * concern, which is why it lives here and not in the generated client.
 */
function withoutBlanks<Q extends object>(query: Q): Q {
  return Object.fromEntries(
    Object.entries(query).filter(([, value]) => value !== "")
  ) as Q;
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

/* ---- the ten routes ------------------------------------------------------ */

export function openAccount(
  body: generated.AccountBody
): Promise<Answer<generated.AccountCreated>> {
  return answerFrom(generated.openAccount({ client: throughTheProxy, body }));
}

export function listAccounts(
  query: ListAccountsQuery
): Promise<Answer<generated.AccountListRead>> {
  return answerFrom(
    generated.listAccounts({
      client: throughTheProxy,
      query: withoutBlanks(query),
    })
  );
}

export function readAccountBalance(
  accountId: string,
  query: AccountBalanceQuery
): Promise<Answer<generated.AccountBalanceRead>> {
  return answerFrom(
    generated.getAccountBalance({
      client: throughTheProxy,
      path: { account_id: accountId },
      query: withoutBlanks(query),
    })
  );
}

/**
 * One page of one account's entries, in one axis's order.
 *
 * `axis` is REQUIRED and this function will not default it either: the two
 * axes answer the same set in different orders, and whichever one were chosen
 * for a caller who named none is the axis they did not think about. The
 * refusal the API gives for a missing `axis` is a good refusal, and hiding it
 * behind a default here would be the dashboard undoing the decision.
 *
 * `after` is the previous page's `next_after` and belongs to ONE axis: sending
 * a recorded key while paging the effective axis is refused rather than used
 * as a bound of an order it does not name. The panel that calls this drops the
 * page key whenever the axis changes, which is why that refusal is unreachable
 * from the UI rather than merely handled.
 */
export function readAccountEntries(
  accountId: string,
  query: AccountStatementQuery
): Promise<Answer<generated.AccountStatementRead>> {
  return answerFrom(
    generated.getAccountStatement({
      client: throughTheProxy,
      path: { account_id: accountId },
      query: withoutBlanks(query),
    })
  );
}

export function postTransaction(
  body: generated.TransactionBody
): Promise<Answer<generated.TransactionCreated>> {
  return answerFrom(
    generated.postTransaction({ client: throughTheProxy, body })
  );
}

export function readTransaction(
  transactionId: string,
  query: TransactionQuery
): Promise<Answer<generated.TransactionRead>> {
  return answerFrom(
    generated.getTransaction({
      client: throughTheProxy,
      path: { transaction_id: transactionId },
      query: withoutBlanks(query),
    })
  );
}

export function runTrialBalance(
  query: TrialBalanceQuery
): Promise<Answer<generated.TrialBalanceRead>> {
  return answerFrom(
    generated.getTrialBalance({
      client: throughTheProxy,
      query: withoutBlanks(query),
    })
  );
}

export function runBalanceSheet(
  query: BalanceSheetQuery
): Promise<Answer<generated.StatementRead>> {
  return answerFrom(
    generated.getBalanceSheet({
      client: throughTheProxy,
      query: withoutBlanks(query),
    })
  );
}

export function runIncomeStatement(
  query: IncomeStatementQuery
): Promise<Answer<generated.StatementRead>> {
  return answerFrom(
    generated.getIncomeStatement({
      client: throughTheProxy,
      query: withoutBlanks(query),
    })
  );
}

/**
 * The commit horizon on its own, without running a report.
 *
 * `tenant_id` is required for the scoping every other read has, and the
 * horizon it answers is the CLUSTER's — `report_cursor()` is
 * `pg_snapshot_xmin`, so every book is told the same number (ADR-0022).
 */
export function readCursor(
  query: CursorQuery
): Promise<Answer<generated.CursorRead>> {
  return answerFrom(generated.getCursor({ client: throughTheProxy, query }));
}
