"use client";

import { ChevronDownIcon, ListIcon } from "lucide-react";

import { Trouble } from "@/components/answer-view";
import { TextField } from "@/components/field";
import { Identifier, Mono } from "@/components/mono";
import { Empty, Panel, PanelNote } from "@/components/panel";
import { Button } from "@/components/ui/button";
import type { AccountRegister } from "@/components/read/use-account-register";
import type { AccountRead } from "@/lib/ledger";

/**
 * The register is a READ — it runs on the read pool, like every other read —
 * but it sits on the write side of the spine because it is what fills the id
 * fields beside it. Nobody should be pasting a UUID by hand.
 */
export function AccountRegisterPanel({
  register,
  activeLeg,
  onFillSource,
  onFillDestination,
  onFillBalance,
}: {
  register: AccountRegister;
  activeLeg: number;
  onFillSource: (accountId: string) => void;
  onFillDestination: (accountId: string) => void;
  onFillBalance: (accountId: string, currency: string) => void;
}) {
  const filtered =
    register.purpose.trim() !== "" || register.ownerId.trim() !== "";

  return (
    <Panel title="The account register" route="GET /v1/accounts">
      <div className="grid gap-3 sm:grid-cols-3">
        <TextField
          label="purpose"
          value={register.purpose}
          onChange={register.setPurpose}
          placeholder="any"
          hint="Equality, not search."
        />
        <TextField
          label="owner_id"
          value={register.ownerId}
          onChange={register.setOwnerId}
          placeholder="any"
          hint="Selects no house accounts — they have no owner."
        />
        <TextField
          label="limit"
          value={register.limit}
          onChange={register.setLimit}
          inputMode="numeric"
          placeholder="100"
          hint="1–1000. Outside that it is refused, not clamped."
        />
      </div>

      <div className="mt-3 flex flex-wrap items-center gap-2">
        <Button
          size="sm"
          onClick={() => void register.list()}
          disabled={register.busy}
        >
          <ListIcon aria-hidden />
          {register.busy ? "Listing…" : "List accounts"}
        </Button>
        <Button
          size="sm"
          variant="outline"
          disabled={register.busy || register.nextAfter === null}
          onClick={() => void register.loadNextPage()}
        >
          <ChevronDownIcon aria-hidden /> Load the next page
        </Button>
        {register.hasListed ? (
          <p className="text-[0.7rem] text-dim">
            {register.accounts.length} account
            {register.accounts.length === 1 ? "" : "s"} over{" "}
            {register.pages} page{register.pages === 1 ? "" : "s"} ·{" "}
            {register.nextAfter === null ? (
              <>
                <code>next_after</code> is null, so this page did not fill and
                there is no more
              </>
            ) : (
              <>
                <code>next_after</code>{" "}
                <Mono className="text-ink">{register.nextAfter}</Mono> — a full
                page means there may be more, never that there is
              </>
            )}
          </p>
        ) : null}
      </div>

      <Trouble answer={register.answer} />

      {register.hasListed && register.accounts.length === 0 ? (
        <div className="mt-3">
          <Empty>
            {filtered
              ? "No accounts match these filters on this book."
              : "No accounts yet — open one above."}
          </Empty>
        </div>
      ) : null}

      {register.accounts.length > 0 ? (
        <div className="mt-3 overflow-x-auto">
          <table className="w-full min-w-[64rem] border-collapse text-[0.75rem]">
            <thead>
              <tr className="border-b border-line text-[0.68rem] tracking-wide text-dim">
                <th className="w-px py-1 pr-3 text-left font-medium whitespace-nowrap">
                  fill
                </th>
                <th className="py-1 pr-3 text-left font-medium">account_id</th>
                <th className="py-1 pr-3 text-left font-medium">purpose</th>
                <th className="py-1 pr-3 text-left font-medium">derived</th>
                <th className="py-1 pr-3 text-left font-medium">owner</th>
                <th className="py-1 pr-3 text-left font-medium">ccy</th>
                <th className="py-1 pr-3 text-right font-medium">stripes</th>
                <th className="py-1 pr-3 text-left font-medium">opened</th>
              </tr>
            </thead>
            <tbody>
              {register.accounts.map((account) => (
                <Row
                  key={account.account_id}
                  account={account}
                  activeLeg={activeLeg}
                  onFillSource={onFillSource}
                  onFillDestination={onFillDestination}
                  onFillBalance={onFillBalance}
                />
              ))}
            </tbody>
          </table>
        </div>
      ) : null}

      <PanelNote>
        The listing returns identity, never money: a balance is per currency and
        per stripe, and one per row would be N+1. The balance route answers that
        question one account at a time.
      </PanelNote>
    </Panel>
  );
}

function Row({
  account,
  activeLeg,
  onFillSource,
  onFillDestination,
  onFillBalance,
}: {
  account: AccountRead;
  activeLeg: number;
  onFillSource: (accountId: string) => void;
  onFillDestination: (accountId: string) => void;
  onFillBalance: (accountId: string, currency: string) => void;
}) {
  return (
    <tr className="border-b border-rule align-top">
      <td className="w-px py-1.5 pr-3 text-left whitespace-nowrap">
        <Button
          size="xs"
          variant="ghost"
          title={`Fill leg ${activeLeg + 1} source`}
          onClick={() => onFillSource(account.account_id)}
        >
          source
        </Button>
        <Button
          size="xs"
          variant="ghost"
          title={`Fill leg ${activeLeg + 1} destination`}
          onClick={() => onFillDestination(account.account_id)}
        >
          destination
        </Button>
        <Button
          size="xs"
          variant="ghost"
          title="Fill the balance lookup"
          onClick={() => onFillBalance(account.account_id, account.currency)}
        >
          balance
        </Button>
      </td>
      <td className="max-w-[15rem] py-1.5 pr-3">
        <Identifier value={account.account_id} truncate />
      </td>
      <td className="py-1.5 pr-3">
        <Mono>{account.purpose}</Mono>
      </td>
      <td className="py-1.5 pr-3 whitespace-nowrap">
        <Mono className="text-dim">
          {account.category} · {account.normal_balance} ·{" "}
          {account.counterparty_scope}
        </Mono>
      </td>
      <td className="py-1.5 pr-3 whitespace-nowrap">
        <Mono className="text-dim">
          {account.owner_type}
          {account.owner_id === null ? "" : ` · ${account.owner_id}`}
        </Mono>
      </td>
      <td className="py-1.5 pr-3">
        <Mono className="text-dim">{account.currency}</Mono>
      </td>
      <td className="py-1.5 pr-3 text-right">
        <Mono className="text-dim">{account.stripe_count}</Mono>
      </td>
      <td className="py-1.5 pr-3 whitespace-nowrap">
        <Mono className="text-[0.7rem] text-dim">
          {account.created_at.slice(0, 19).replace("T", " ")}
        </Mono>
      </td>
    </tr>
  );
}
