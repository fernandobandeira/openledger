import type { AccountRead } from "@/lib/ledger";

/**
 * Who an account belongs to, in the one form this app spells it.
 *
 * **It is the field that tells two accounts of the same purpose apart.**
 * `uq_accounts__owned` is per `(tenant, owner_type, owner_id, purpose,
 * currency)`, so three `customer_wallet` liabilities in USD are legal and
 * differ only here — a row that names the purpose and not the owner leaves a
 * reader comparing UUIDs.
 */
export function ownerOf(account: AccountRead): string {
  return account.owner_id ?? "house";
}

/** The owner of an account by id, when the register in hand carries it. */
export function ownerById(
  accounts: readonly AccountRead[],
  accountId: string
): string | null {
  const found = accounts.find(
    (account) => account.account_id === accountId
  );
  return found === undefined ? null : ownerOf(found);
}
