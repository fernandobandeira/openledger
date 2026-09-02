"use client";

import {
  ArrowRightIcon,
  ListTreeIcon,
  PlusIcon,
  ScaleIcon,
  SearchIcon,
  TrendingUpIcon,
  type LucideIcon,
} from "lucide-react";

import {
  ComposerDrawer,
  type DrawerWidth,
} from "@/components/composer/composer-drawer";
import { BalanceSheet } from "@/components/read/balance-sheet";
import { IncomeStatement } from "@/components/read/income-statement";
import { TrialBalance } from "@/components/read/trial-balance";
import { Button } from "@/components/ui/button";
import type { AccountRead } from "@/lib/ledger";
import { OpenAccount } from "@/components/write/open-account";
import { PostTransaction, type Leg } from "@/components/write/post-transaction";
import { ReadTransaction } from "@/components/write/read-transaction";

/** The six things this dashboard can do to a book, by name. */
export type ComposerAction =
  | "open-account"
  | "post-transaction"
  | "read-transaction"
  | "trial-balance"
  | "balance-sheet"
  | "income-statement";

/**
 * The two ports, and what each costs. This is the copy the composer's spine
 * headings carried when the forms were stacked down the page; it now sits in
 * the header of every drawer that talks to that port, which is where a reader
 * meets it at the moment it applies.
 */
const PORTS = {
  Write: "the Ledger port — a refusal here wrote nothing",
  Read: "the Reports port — its own pool, its own login, RLS-scoped",
} as const;

interface ActionSpec {
  id: ComposerAction;
  /** The button, in an operator's words. */
  label: string;
  /** The drawer's accessible name and the panel's own heading. */
  title: string;
  route: string;
  side: keyof typeof PORTS;
  /** How much room its panel needs — a face is not a six-field form. */
  width: DrawerWidth;
  icon: LucideIcon;
}

/**
 * The bar is rendered from a LIST, the way the walk is: an action is a
 * record, and its button, its drawer and its accessible name all come from
 * the one entry.
 */
const ACTIONS: readonly ActionSpec[] = [
  {
    id: "open-account",
    label: "Open an account",
    title: "Open an account",
    route: "POST /v1/accounts",
    side: "Write",
    width: "form",
    icon: PlusIcon,
  },
  {
    id: "post-transaction",
    label: "Post a transaction",
    title: "Post a transaction",
    route: "POST /v1/transactions",
    side: "Write",
    width: "wide-form",
    icon: ArrowRightIcon,
  },
  {
    id: "read-transaction",
    label: "Read a transaction",
    title: "Read a transaction back",
    route: "GET /v1/transactions/{id}",
    side: "Write",
    width: "wide-form",
    icon: SearchIcon,
  },
  {
    id: "trial-balance",
    label: "Trial balance",
    title: "Trial balance",
    route: "GET /v1/reports/trial-balance",
    side: "Read",
    width: "ledger",
    icon: ListTreeIcon,
  },
  {
    id: "balance-sheet",
    label: "Balance sheet",
    title: "Balance sheet",
    route: "GET /v1/reports/balance-sheet",
    side: "Read",
    width: "statement",
    icon: ScaleIcon,
  },
  {
    id: "income-statement",
    label: "Income statement",
    title: "Income statement",
    route: "GET /v1/reports/income-statement",
    side: "Read",
    width: "statement",
    icon: TrendingUpIcon,
  },
];

/**
 * The composer, and still the point of the page: every route spelled out, in
 * the API's own field names, with nothing filled in that you did not fill in
 * on purpose.
 *
 * What changed is that it is a BAR and six drawers rather than seven forms
 * expanded down the page — six, because the standalone balance form went: it
 * asked you to paste an `account_id` to read a number the sidenav already
 * has on screen, off the same route. What it taught — that no stripe appears
 * in the answer, and that these figures are `GET /v1/accounts/{account_id}/balance`
 * rather than the page's own arithmetic — moved to the sidenav, where the
 * balances are. Nothing was deleted — each drawer holds the same
 * panel, the same fields and the same explanation under each one. The page
 * underneath is now the book: the rail, the accounts, the walk and the
 * selected account's entries, readable without scrolling past a form wall.
 */
export function ComposerBar({
  tenant,
  accounts,
  open,
  onOpen,
  legs,
  setLegs,
  activeLeg,
  setActiveLeg,
  transactionId,
  setTransactionId,
  pinned,
  onPin,
  onAnswer,
  afterAWrite,
}: {
  tenant: string;
  /** The register, for the reports that must name an account's owner. */
  accounts: readonly AccountRead[];
  open: ComposerAction | null;
  onOpen: (action: ComposerAction | null) => void;
  legs: Leg[];
  setLegs: (legs: Leg[]) => void;
  activeLeg: number;
  setActiveLeg: (index: number) => void;
  transactionId: string;
  setTransactionId: (value: string) => void;
  pinned: string | null;
  onPin: (cursor: string) => void;
  onAnswer: (cursor: string, ranWithoutCursor: boolean, from: string) => void;
  afterAWrite: () => void;
}) {
  function bodyOf(action: ComposerAction) {
    switch (action) {
      case "open-account":
        return <OpenAccount tenant={tenant} onOpened={afterAWrite} />;
      case "post-transaction":
        return (
          <PostTransaction
            tenant={tenant}
            legs={legs}
            setLegs={setLegs}
            activeLeg={activeLeg}
            setActiveLeg={setActiveLeg}
            onPosted={(id) => {
              if (id !== null) setTransactionId(id);
              afterAWrite();
            }}
          />
        );
      case "read-transaction":
        return (
          <ReadTransaction
            tenant={tenant}
            transactionId={transactionId}
            setTransactionId={setTransactionId}
          />
        );
      case "trial-balance":
        return (
          <TrialBalance
            tenant={tenant}
            accounts={accounts}
            pinned={pinned}
            onPin={onPin}
            onAnswer={onAnswer}
          />
        );
      case "balance-sheet":
        return (
          <BalanceSheet
            tenant={tenant}
            pinned={pinned}
            onPin={onPin}
            onAnswer={onAnswer}
          />
        );
      case "income-statement":
        return (
          <IncomeStatement
            tenant={tenant}
            pinned={pinned}
            onPin={onPin}
            onAnswer={onAnswer}
          />
        );
    }
  }

  return (
    <>
      <div className="border-b border-rule bg-ground px-4 py-2 sm:px-6">
        <div className="mx-auto flex max-w-[110rem] flex-wrap items-center gap-x-4 gap-y-2">
          {(["Write", "Read"] as const).map((side) => (
            <div key={side} className="flex flex-wrap items-center gap-1.5">
              <span
                title={PORTS[side]}
                className="text-[0.66rem] tracking-[0.14em] text-peach uppercase"
              >
                {side}
              </span>
              {ACTIONS.filter((action) => action.side === side).map((action) => (
                <Button
                  key={action.id}
                  size="xs"
                  variant={open === action.id ? "secondary" : "outline"}
                  aria-haspopup="dialog"
                  aria-expanded={open === action.id}
                  onClick={() => onOpen(action.id)}
                >
                  <action.icon aria-hidden />
                  {action.label}
                </Button>
              ))}
            </div>
          ))}
        </div>
      </div>

      {ACTIONS.map((action) => (
        <ComposerDrawer
          key={action.id}
          open={open === action.id}
          onOpenChange={(next) => onOpen(next ? action.id : null)}
          title={action.title}
          route={action.route}
          side={action.side}
          port={PORTS[action.side]}
          width={action.width}
        >
          {bodyOf(action.id)}
        </ComposerDrawer>
      ))}
    </>
  );
}
