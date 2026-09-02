"use client";

import { ChevronDownIcon, RefreshCwIcon } from "lucide-react";

import { Trouble } from "@/components/answer-view";
import { AxisToggle } from "@/components/entries/axis-toggle";
import { EntriesTable } from "@/components/entries/entries-table";
import { TransactionLegs } from "@/components/entries/transaction-legs";
import type { AccountEntries } from "@/components/entries/use-account-entries";
import { Identifier, Mono } from "@/components/mono";
import { Empty } from "@/components/panel";
import { Button } from "@/components/ui/button";
import type { AccountRead } from "@/lib/ledger";

/**
 * The selected account's own page: what it is, its entries in either order,
 * and the transaction any one of them belongs to.
 */
export function AccountPanel({
  tenant,
  account,
  accounts,
  entries,
  openTransaction,
  onOpenTransaction,
  onCloseTransaction,
  onSelectAccount,
  activeLeg,
  onFillSource,
  onFillDestination,
  onComposePosting,
}: {
  tenant: string;
  account: AccountRead | null;
  accounts: readonly AccountRead[];
  entries: AccountEntries;
  openTransaction: string | null;
  onOpenTransaction: (transactionId: string) => void;
  onCloseTransaction: () => void;
  onSelectAccount: (accountId: string) => void;
  activeLeg: number;
  onFillSource: (accountId: string) => void;
  onFillDestination: (accountId: string) => void;
  /** Open the posting drawer over the page, with the legs as they stand. */
  onComposePosting: () => void;
}) {
  if (account === null) {
    return (
      <section aria-label="Entries" className="flex flex-col gap-3">
        <SectionHeading />
        <Empty>Pick an account on the left, or run the first step of the walk.</Empty>
      </section>
    );
  }

  return (
    <section aria-label="Entries" className="flex min-w-0 flex-col gap-3">
      <SectionHeading />
      <AccountHeader
        account={account}
        activeLeg={activeLeg}
        onFillSource={onFillSource}
        onFillDestination={onFillDestination}
        onComposePosting={onComposePosting}
      />

      <AxisToggle
        axis={entries.axis}
        onChange={entries.setAxis}
        busy={entries.busy}
      />

      <Trouble answer={entries.answer} />

      {entries.entries.length === 0 && !entries.busy ? (
        <Empty>No entries at this commit position — an empty page, never a 404.</Empty>
      ) : (
        <EntriesTable
          entries={entries.entries}
          axis={entries.axis}
          onOpenTransaction={onOpenTransaction}
          openTransaction={openTransaction}
        />
      )}

      <PageFooter entries={entries} />

      {openTransaction === null ? null : (
        <TransactionLegs
          tenant={tenant}
          transactionId={openTransaction}
          accounts={accounts}
          currentAccount={account.account_id}
          onSelectAccount={onSelectAccount}
          onClose={onCloseTransaction}
        />
      )}
    </section>
  );
}

function SectionHeading() {
  return (
    <div className="flex flex-wrap items-baseline gap-x-3 border-b border-line pb-2">
      <h2 className="text-[0.8rem] tracking-[0.14em] text-peach uppercase">
        Entries
      </h2>
      <Mono className="text-[0.68rem] text-dim">
        GET /v1/accounts/{"{account_id}"}/entries
      </Mono>
    </div>
  );
}

/** What the account is — the triple the server derived, and its identity. */
function AccountHeader({
  account,
  activeLeg,
  onFillSource,
  onFillDestination,
  onComposePosting,
}: {
  account: AccountRead;
  activeLeg: number;
  onFillSource: (accountId: string) => void;
  onFillDestination: (accountId: string) => void;
  onComposePosting: () => void;
}) {
  return (
    <div className="flex flex-col gap-2">
      <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h3 className="font-mono text-[1rem] tracking-tight">
          {account.purpose}
        </h3>
        <Mono className="text-[0.72rem] text-dim">
          {account.category} · {account.normal_balance} ·{" "}
          {account.counterparty_scope} · {account.currency} ·{" "}
          {account.owner_id === null
            ? "house"
            : `${account.owner_type} ${account.owner_id}`}{" "}
          · {account.stripe_count} stripe{account.stripe_count === 1 ? "" : "s"}
        </Mono>
      </div>
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
        <Identifier value={account.account_id} truncate />
        <span className="flex flex-wrap gap-1">
          <Button
            size="xs"
            variant="ghost"
            onClick={() => onFillSource(account.account_id)}
          >
            Use as leg {activeLeg + 1} source
          </Button>
          <Button
            size="xs"
            variant="ghost"
            onClick={() => onFillDestination(account.account_id)}
          >
            …as destination
          </Button>
          <Button size="xs" variant="ghost" onClick={onComposePosting}>
            Open the posting form
          </Button>
        </span>
      </div>
    </div>
  );
}

/**
 * The page, the cursor it was pinned at, and the key of the next one. A full
 * page means "there may be more", never "there is".
 */
function PageFooter({ entries }: { entries: AccountEntries }) {
  return (
    <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
      <Button
        size="xs"
        variant="ghost"
        disabled={entries.busy}
        onClick={() => void entries.reload()}
      >
        <RefreshCwIcon aria-hidden />
        {entries.busy ? "Reading…" : "Read it again"}
      </Button>
      {entries.nextAfter === null ? null : (
        <Button
          size="xs"
          variant="secondary"
          disabled={entries.busy}
          onClick={() => void entries.loadNextPage()}
        >
          <ChevronDownIcon aria-hidden /> Next page
        </Button>
      )}
      <p className="text-[0.68rem] text-dim">
        {entries.entries.length} entr
        {entries.entries.length === 1 ? "y" : "ies"} · {entries.pages} page
        {entries.pages === 1 ? "" : "s"}
        {entries.pinnedCursor === null ? null : (
          <>
            {" "}
            · pinned at <Mono className="text-peach">{entries.pinnedCursor}</Mono>
          </>
        )}
        {entries.nextAfter === null ? " · next_after is null" : ""}
      </p>
    </div>
  );
}
