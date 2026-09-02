"use client";

import { ChevronDownIcon, PlusIcon, RefreshCwIcon, RotateCcwIcon } from "lucide-react";

import { Amount } from "@/components/amount";
import { GuideLink } from "@/components/guide-link";
import { Trouble } from "@/components/answer-view";
import { TextField } from "@/components/field";
import { Mono } from "@/components/mono";
import { Button } from "@/components/ui/button";
import type { AccountRegister } from "@/components/read/use-account-register";
import type { AccountBalances } from "@/components/accounts/use-account-balances";
import { isNegativeMinor } from "@/lib/amount";
import { ownerOf } from "@/lib/owner";
import type { AccountRead } from "@/lib/ledger";
import { cn } from "@/lib/utils";

/** The chart's own roll-up order, so the column reads like a balance sheet. */
const CATEGORY_ORDER = [
  "asset",
  "liability",
  "equity",
  "revenue",
  "expense",
] as const;

/**
 * Every account on the book, always on screen, with what it holds.
 *
 * This IS the account register — `GET /v1/accounts`, keyset-paginated, plus one
 * balance call per row — moved out of a panel and into the spine of the page,
 * because choosing an account is the first thing an operator does and the last
 * thing they should have to paste a UUID for.
 */
export function AccountSidenav({
  register,
  balances,
  selected,
  onSelect,
  onOpenComposer,
  onReset,
}: {
  register: AccountRegister;
  balances: AccountBalances;
  selected: string | null;
  onSelect: (account: AccountRead) => void;
  onOpenComposer: () => void;
  onReset: () => void;
}) {
  const grouped = CATEGORY_ORDER.map((category) => ({
    category,
    accounts: register.accounts.filter(
      (account) => account.category === category
    ),
  })).filter((group) => group.accounts.length > 0);

  const ungrouped = register.accounts.filter(
    (account) =>
      !CATEGORY_ORDER.some((category) => category === account.category)
  );

  return (
    <nav aria-label="Accounts" className="flex min-w-0 flex-col gap-3">
      <div className="flex flex-col gap-0.5">
        <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
          <h2 className="text-[0.8rem] tracking-[0.14em] text-peach uppercase">
            Accounts
          </h2>
          <p className="text-[0.68rem] text-dim">
            {register.accounts.length} on this book
          </p>
        </div>
        {/* The routes, named the way every panel names its own: these
            figures came off the wire. There is no separate balance form any
            more — it asked you to paste an account_id to read a number this
            column already has. */}
        <Mono className="text-[0.62rem] leading-relaxed text-dim">
          GET /v1/accounts · /{"{account_id}"}/balance
        </Mono>
      </div>

      {register.accounts.length === 0 ? (
        <p className="border border-dashed border-rule px-3 py-4 text-[0.75rem] leading-relaxed text-dim">
          {register.hasListed
            ? "No accounts yet. Run the first step of the walk, or open one from the bar above."
            : "Listing…"}
        </p>
      ) : null}

      <ul className="flex flex-col gap-3">
        {grouped.map((group) => (
          <li key={group.category}>
            <CategoryHeading category={group.category} />
            <ul className="mt-1 flex flex-col">
              {group.accounts.map((account) => (
                <AccountRow
                  key={account.account_id}
                  account={account}
                  posted={balances.of(account.account_id)}
                  selected={account.account_id === selected}
                  onSelect={() => onSelect(account)}
                />
              ))}
            </ul>
          </li>
        ))}
        {ungrouped.length > 0 ? (
          <li>
            <CategoryHeading category="other" />
            <ul className="mt-1 flex flex-col">
              {ungrouped.map((account) => (
                <AccountRow
                  key={account.account_id}
                  account={account}
                  posted={balances.of(account.account_id)}
                  selected={account.account_id === selected}
                  onSelect={() => onSelect(account)}
                />
              ))}
            </ul>
          </li>
        ) : null}
      </ul>

      <Trouble answer={register.answer} />

      <div className="flex flex-wrap items-center gap-2 border-t border-rule pt-3">
        <Button size="xs" variant="secondary" onClick={onOpenComposer}>
          <PlusIcon aria-hidden /> Open an account
        </Button>
        <Button
          size="xs"
          variant="ghost"
          disabled={register.busy}
          onClick={() => void register.list()}
        >
          <RefreshCwIcon aria-hidden /> {register.busy ? "Listing…" : "Refresh"}
        </Button>
        {register.nextAfter === null ? null : (
          <Button
            size="xs"
            variant="ghost"
            disabled={register.busy}
            onClick={() => void register.loadNextPage()}
          >
            <ChevronDownIcon aria-hidden /> Next page
          </Button>
        )}
        <Button size="xs" variant="ghost" onClick={onReset}>
          <RotateCcwIcon aria-hidden /> Start a fresh book
        </Button>
      </div>

      <Filters register={register} />

      <p className="flex flex-wrap items-baseline gap-x-2 text-[0.66rem] leading-relaxed text-dim">
        <span>
          Posted, <span className="text-ink">debit-positive</span>, summed
          across stripes — no stripe appears in the answer.
        </span>
        <GuideLink>reading a balance&rsquo;s sign</GuideLink>
      </p>
    </nav>
  );
}

function CategoryHeading({ category }: { category: string }) {
  return (
    <h3 className="text-[0.62rem] tracking-[0.16em] text-dim uppercase">
      {category}
    </h3>
  );
}

/**
 * One account. The purpose is the name an operator knows it by; the owner is
 * beside it because two accounts can share a purpose and differ only there.
 */
function AccountRow({
  account,
  posted,
  selected,
  onSelect,
}: {
  account: AccountRead;
  posted: string | null;
  selected: boolean;
  onSelect: () => void;
}) {
  return (
    <li>
      <button
        type="button"
        aria-current={selected ? "true" : undefined}
        onClick={onSelect}
        className={cn(
          "flex w-full min-w-0 items-baseline gap-2 border-l-2 py-1 pr-1 pl-2 text-left transition-colors",
          selected
            ? "border-peach bg-surface"
            : "border-transparent hover:border-line hover:bg-surface/60"
        )}
      >
        <span className="min-w-0 flex-1">
          <Mono
            className={cn(
              "block truncate text-[0.74rem]",
              selected ? "text-peach" : "text-ink"
            )}
          >
            {account.purpose}
          </Mono>
          <Mono className="block truncate text-[0.64rem] text-dim">
            {account.currency} · {ownerOf(account)}
          </Mono>
        </span>
        {posted === null ? (
          <Mono className="text-[0.7rem] text-dim">—</Mono>
        ) : (
          <Amount
            minor={posted}
            currency={account.currency}
            className={cn(
              "text-[0.74rem]",
              isNegativeMinor(posted) ? "text-credit" : "text-ink"
            )}
          />
        )}
      </button>
    </li>
  );
}

/**
 * The listing's own filters, where they belong: on the listing. `purpose` and
 * `owner_id` are equality, not search, and a `limit` outside 1–1000 is refused
 * rather than clamped.
 */
function Filters({ register }: { register: AccountRegister }) {
  return (
    <details className="border-t border-rule pt-3">
      <summary className="cursor-pointer text-[0.7rem] text-dim hover:text-peach">
        Filter the listing
      </summary>
      <div className="mt-2 flex flex-col gap-2">
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
          hint="No house accounts — they have no owner."
        />
        <TextField
          label="limit"
          value={register.limit}
          onChange={register.setLimit}
          inputMode="numeric"
          placeholder="100"
          hint="1–1000, refused not clamped."
        />
        <Button
          size="xs"
          variant="secondary"
          disabled={register.busy}
          onClick={() => void register.list()}
        >
          Apply
        </Button>
      </div>
    </details>
  );
}
