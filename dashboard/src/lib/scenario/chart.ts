/**
 * The slice of the chart this walk needs, and the owner each account must
 * carry.
 *
 * The owner is not a preference: `counterparty_scope` decides it. A
 * `per_shard` type may not live in a house account —
 * `ck_accounts__per_shard_is_owned` — because a single house row would have
 * netted every counterparty's position at write time and no report could
 * recover it. A `none` type on an owner-keyed account is the mirror mistake.
 * So `customer_receivable` is keyed to the cardholder, the platform's share is
 * keyed to the platform, and everything else is the house's own side.
 *
 * `category`, `normal_balance` and `counterparty_scope` are absent on purpose:
 * the caller names a `purpose` and the server reads the rest off the chart. A
 * body that stated them could disagree with it.
 */
import type { OwnerType } from "@/lib/ledger";

/** The ten chart codes this trace posts to. */
export type ChartPurpose =
  | "customer_receivable"
  | "operating_cash"
  | "network_settlement_payable"
  | "facility_borrowings"
  | "accrued_interest_payable"
  | "platform_rev_share_payable"
  | "platform_rev_share_expense"
  | "interchange_revenue"
  | "interest_expense"
  | "paid_in_capital";

export interface AccountSpec {
  purpose: ChartPurpose;
  ownerType: OwnerType;
  /** `null` for a house account, which is the ledger's own side. */
  ownerId: string | null;
  /** What the account is, in a card programme's words. */
  gloss: string;
}

const CARDHOLDER = "co_1";
const PLATFORM = "pf_1";

export const TRACE_CHART: readonly AccountSpec[] = [
  {
    purpose: "customer_receivable",
    ownerType: "company",
    ownerId: CARDHOLDER,
    gloss: "what the cardholder owes us",
  },
  {
    purpose: "operating_cash",
    ownerType: "house",
    ownerId: null,
    gloss: "our own bank balance",
  },
  {
    purpose: "network_settlement_payable",
    ownerType: "house",
    ownerId: null,
    gloss: "owed to the card network",
  },
  {
    purpose: "facility_borrowings",
    ownerType: "house",
    ownerId: null,
    gloss: "drawn on the warehouse line",
  },
  {
    purpose: "accrued_interest_payable",
    ownerType: "house",
    ownerId: null,
    gloss: "interest accrued, not yet paid",
  },
  {
    purpose: "platform_rev_share_payable",
    ownerType: "platform",
    ownerId: PLATFORM,
    gloss: "owed to the platform partner",
  },
  {
    purpose: "platform_rev_share_expense",
    ownerType: "house",
    ownerId: null,
    gloss: "interchange shared with the platform",
  },
  {
    purpose: "interchange_revenue",
    ownerType: "house",
    ownerId: null,
    gloss: "interchange we keep",
  },
  {
    purpose: "interest_expense",
    ownerType: "house",
    ownerId: null,
    gloss: "interest on the facility",
  },
  {
    purpose: "paid_in_capital",
    ownerType: "house",
    ownerId: null,
    gloss: "the equity the book opened with",
  },
];

export function specFor(purpose: ChartPurpose): AccountSpec {
  const found = TRACE_CHART.find((spec) => spec.purpose === purpose);
  if (found === undefined) {
    throw new Error(`no chart entry for ${purpose}`);
  }
  return found;
}
