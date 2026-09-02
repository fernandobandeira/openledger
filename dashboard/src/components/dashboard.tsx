"use client";

import { useCallback, useMemo, useState } from "react";
import { PanelLeftIcon } from "lucide-react";

import { AccountSidenav } from "@/components/accounts/account-sidenav";
import { useAccountBalances } from "@/components/accounts/use-account-balances";
import { ComposerBar, type ComposerAction } from "@/components/composer/composer-bar";
import { CursorRail, type Horizon } from "@/components/cursor/cursor-rail";
import { useBookCommits } from "@/components/cursor/use-book-commits";
import { AccountPanel } from "@/components/entries/account-panel";
import { useAccountEntries } from "@/components/entries/use-account-entries";
import { useAccountRegister } from "@/components/read/use-account-register";
import { ScenarioStrip } from "@/components/scenario/scenario-strip";
import { useScenario } from "@/components/scenario/use-scenario";
import { GuideLink } from "@/components/guide-link";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { emptyLeg, type Leg } from "@/components/write/post-transaction";
import { isBehind } from "@/lib/cursor";
import { readCursor } from "@/lib/ledger";

/** A book nobody has written to yet. Minted on click, never while rendering. */
function freshBook(): string {
  return `book-${crypto.randomUUID().slice(0, 8)}`;
}

/**
 * The operator's page.
 *
 * Four things, in this order: what book you are on, where the cursor is,
 * every account on the book beside the walk and the selected account's
 * entries — and the composer, which is a bar of seven actions and a drawer
 * behind each one.
 *
 * The composer used to be seven forms expanded down the page, and the page
 * was mostly them. Nothing about it was deleted: the drawers hold the same
 * fields under the same names with the same explanation under each. What
 * moved is the wall — the book is now what the page shows, and a form appears
 * over it when you ask for one.
 */
export function Dashboard() {
  const [tenant, setTenant] = useState("t1");

  const [horizon, setHorizon] = useState<Horizon | null>(null);
  const [pinned, setPinned] = useState<string | null>(null);
  const [probing, setProbing] = useState(false);

  const [legs, setLegs] = useState<Leg[]>([emptyLeg()]);
  const [activeLeg, setActiveLeg] = useState(0);
  const [transactionId, setTransactionId] = useState("");

  const [selectedAccount, setSelectedAccount] = useState<string | null>(null);
  const [openTransaction, setOpenTransaction] = useState<string | null>(null);
  const [navOpen, setNavOpen] = useState(false);
  const [composing, setComposing] = useState<ComposerAction | null>(null);

  /** Bumped whenever the book may have moved on, so the rail re-walks it. */
  const [bookMoved, setBookMoved] = useState(0);

  const register = useAccountRegister(tenant);
  const balances = useAccountBalances(tenant, register.accounts);

  /**
   * Rule 1, and the whole reason the horizon is not just "the last cursor
   * seen": a read RE-RUN at a pin answers with that pin, so taking every
   * answer at face value drags the horizon backwards. Only an answer that
   * supplied no cursor moves the mark.
   */
  const noteAnswer = useCallback(
    (cursor: string, ranWithoutCursor: boolean, from: string) => {
      if (!ranWithoutCursor) return;
      setHorizon((previous) => ({
        cursor,
        observedAt: new Date().toISOString(),
        from,
        regressed: previous !== null && isBehind(cursor, previous.cursor),
      }));
    },
    []
  );

  /**
   * The account on screen: the one you chose, for as long as it is still on
   * this book's page, and otherwise the first. A chosen account that belongs
   * to a book you have left is not an account at all, and an empty panel is a
   * worse landing place than a real one.
   */
  const account = useMemo(() => {
    const chosen = register.accounts.find(
      (candidate) => candidate.account_id === selectedAccount
    );
    return chosen ?? register.accounts[0] ?? null;
  }, [register.accounts, selectedAccount]);

  const entries = useAccountEntries(
    tenant,
    account?.account_id ?? null,
    noteAnswer
  );

  /**
   * The commits this book actually made, for the rail to draw as ticks. It is
   * a read of its own and it never moves the horizon: every page after the
   * first supplies a cursor, and a background walk is not the deliberate
   * unpinned answer rule 1 lets move the mark.
   */
  const book = useBookCommits(tenant, account?.account_id ?? null, bookMoved);

  /**
   * One statement, not a report. `GET /v1/cursor` answers the horizon alone
   * (ADR-0022); this used to be a trial balance over 0001-01-01…9999-12-31 —
   * a full scan run for one scalar, which on a large book is the ~28-second
   * query ADR-0019's own cost list records.
   *
   * It supplies no cursor, so it is exactly the kind of answer rule 1 lets
   * move the mark.
   */
  const refreshHorizon = useCallback(async () => {
    setProbing(true);
    const result = await readCursor({ tenant_id: tenant });
    if (result.outcome === "answered") {
      noteAnswer(result.body.cursor, true, "GET /v1/cursor");
    }
    setProbing(false);
  }, [noteAnswer, tenant]);

  /** Everything downstream of a write, in one place. */
  const afterAWrite = useCallback(() => {
    void register.list();
    void balances.refresh();
    entries.reload();
    void refreshHorizon();
    setBookMoved((previous) => previous + 1);
  }, [balances, entries, refreshHorizon, register]);

  const scenario = useScenario(tenant, register.accounts, afterAWrite);

  const selectAccount = useCallback((accountId: string) => {
    setSelectedAccount(accountId);
    setOpenTransaction(null);
    setNavOpen(false);
  }, []);

  /**
   * A fresh book is a new `tenant_id` and nothing else. The book is per
   * tenant, so this costs one state update and destroys nothing: the old
   * book is still there, and typing its name back brings it up.
   */
  function startAFreshBook() {
    setTenant(freshBook());
    setSelectedAccount(null);
    setOpenTransaction(null);
    setTransactionId("");
    setLegs([emptyLeg()]);
    setActiveLeg(0);
    scenario.forget();
  }

  return (
    <main className="flex min-h-full flex-col">
      <header className="border-b border-rule px-4 py-3 sm:px-6">
        <div className="mx-auto flex max-w-[110rem] flex-wrap items-end justify-between gap-4">
          <div>
            <h1 className="text-lg font-medium tracking-tight">
              OpenLedger operator
            </h1>
            <p className="mt-0.5 text-[0.75rem] text-dim">
              Write to a book, read it back, pin a cursor.
            </p>
          </div>
          <div className="flex flex-wrap items-end gap-2">
            <div className="flex flex-col gap-1">
              <Label
                htmlFor="tenant"
                className="text-[0.72rem] tracking-wide text-dim"
              >
tenant_id
              </Label>
              <Input
                id="tenant"
                value={tenant}
                spellCheck={false}
                onChange={(event) => setTenant(event.target.value)}
                className="h-8 w-56 rounded-sm border-edge bg-surface font-mono text-[0.78rem]"
              />
            </div>
            <Button size="sm" variant="outline" onClick={startAFreshBook}>
              Start a fresh book
            </Button>
          </div>
        </div>
      </header>

      {/* The bar and the rail travel together: what you can do to the book,
          and where the book is. Both stay on screen while you read it. */}
      <div className="sticky top-0 z-20">
        <ComposerBar
          tenant={tenant}
          accounts={register.accounts}
          open={composing}
          onOpen={setComposing}
          legs={legs}
          setLegs={setLegs}
          activeLeg={activeLeg}
          setActiveLeg={setActiveLeg}
          transactionId={transactionId}
          setTransactionId={setTransactionId}
          pinned={pinned}
          onPin={setPinned}
          onAnswer={noteAnswer}
          afterAWrite={afterAWrite}
        />
        <CursorRail
          horizon={horizon}
          pinned={pinned}
          book={book}
          busy={probing}
          onRefresh={() => void refreshHorizon()}
          onUnpin={() => setPinned(null)}
        />
      </div>

      <div className="mx-auto w-full max-w-[110rem] px-4 py-5 sm:px-6">
        <Button
          size="sm"
          variant="outline"
          className="lg:hidden"
          aria-expanded={navOpen}
          aria-controls="accounts-sidenav"
          onClick={() => setNavOpen((open) => !open)}
        >
          <PanelLeftIcon aria-hidden />
          {navOpen ? "Hide accounts" : `Accounts (${register.accounts.length})`}
        </Button>

        <div className="mt-4 grid gap-8 lg:mt-0 lg:grid-cols-[16rem_minmax(0,1fr)] lg:gap-0">
          <div
            id="accounts-sidenav"
            className={`${navOpen ? "block" : "hidden"} lg:block lg:pr-6`}
          >
            <AccountSidenav
              register={register}
              balances={balances}
              selected={account?.account_id ?? null}
              onSelect={(chosen) => selectAccount(chosen.account_id)}
              onOpenComposer={() => setComposing("open-account")}
              onReset={startAFreshBook}
            />
          </div>

          <div className="flex min-w-0 flex-col gap-6 border-rule lg:border-l lg:pl-6">
            <ScenarioStrip
              scenario={scenario}
              onOpenTransaction={setOpenTransaction}
            />
            <AccountPanel
              tenant={tenant}
              account={account}
              accounts={register.accounts}
              entries={entries}
              openTransaction={openTransaction}
              onOpenTransaction={setOpenTransaction}
              onCloseTransaction={() => setOpenTransaction(null)}
              onSelectAccount={selectAccount}
              activeLeg={activeLeg}
              onFillSource={(accountId) =>
                setLegs(
                  legs.map((leg, index) =>
                    index === activeLeg ? { ...leg, source: accountId } : leg
                  )
                )
              }
              onFillDestination={(accountId) =>
                setLegs(
                  legs.map((leg, index) =>
                    index === activeLeg
                      ? { ...leg, destination: accountId }
                      : leg
                  )
                )
              }
              onComposePosting={() => setComposing("post-transaction")}
            />
          </div>
        </div>
      </div>

      <Footnotes />
    </main>
  );
}

/**
 * One line, and a way out to the guide.
 *
 * This was three paragraphs — minor units, reconciliation, authentication —
 * and `site/content/bookings.md` now carries all three properly. The page
 * shows; the guide explains.
 */
function Footnotes() {
  return (
    <footer className="mt-auto border-t border-rule px-4 py-3 text-[0.7rem] text-dim sm:px-6">
      <p className="mx-auto flex max-w-[110rem] flex-wrap items-baseline gap-x-3 gap-y-1">
        <span>
          Minor units, two decimals · hover for the exact integer · no
          authentication
        </span>
        <GuideLink>Booking a payment</GuideLink>
      </p>
    </footer>
  );
}
