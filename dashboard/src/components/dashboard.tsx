"use client";

import { useCallback, useMemo, useState } from "react";
import { PanelLeftIcon } from "lucide-react";

import { AccountSidenav } from "@/components/accounts/account-sidenav";
import { useAccountBalances } from "@/components/accounts/use-account-balances";
import { CursorRail, type Horizon } from "@/components/cursor-rail";
import { AccountPanel } from "@/components/entries/account-panel";
import { useAccountEntries } from "@/components/entries/use-account-entries";
import { AccountBalance } from "@/components/read/account-balance";
import { BalanceSheet } from "@/components/read/balance-sheet";
import { IncomeStatement } from "@/components/read/income-statement";
import { TrialBalance } from "@/components/read/trial-balance";
import { useAccountRegister } from "@/components/read/use-account-register";
import { ScenarioStrip } from "@/components/scenario/scenario-strip";
import { useScenario } from "@/components/scenario/use-scenario";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { OpenAccount } from "@/components/write/open-account";
import {
  emptyLeg,
  PostTransaction,
  type Leg,
} from "@/components/write/post-transaction";
import { ReadTransaction } from "@/components/write/read-transaction";
import { isBehind } from "@/lib/cursor";
import { readCursor } from "@/lib/ledger";

/** A book nobody has written to yet. Minted on click, never while rendering. */
function freshBook(): string {
  return `book-${crypto.randomUUID().slice(0, 8)}`;
}

/**
 * The operator's page.
 *
 * Accounts down the left, the walk and the selected account's entries in the
 * middle, and the composer underneath — where every route is spelled out, in
 * its own words, with every field the API takes. The walk is an on-ramp into a
 * live book and not a demo mode: it posts through the same routes the composer
 * does, and everything it writes shows up in the panels below.
 */
export function Dashboard() {
  const [tenant, setTenant] = useState("t1");

  const [horizon, setHorizon] = useState<Horizon | null>(null);
  const [pinned, setPinned] = useState<string | null>(null);
  const [observed, setObserved] = useState<string[]>([]);
  const [probing, setProbing] = useState(false);

  const [legs, setLegs] = useState<Leg[]>([emptyLeg()]);
  const [activeLeg, setActiveLeg] = useState(0);
  const [balanceAccount, setBalanceAccount] = useState("");
  const [balanceCurrency, setBalanceCurrency] = useState("USD");
  const [transactionId, setTransactionId] = useState("");

  const [selectedAccount, setSelectedAccount] = useState<string | null>(null);
  const [openTransaction, setOpenTransaction] = useState<string | null>(null);
  const [navOpen, setNavOpen] = useState(false);

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
      setObserved((previous) =>
        previous.includes(cursor) ? previous : [...previous, cursor]
      );
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
    setBalanceAccount("");
    setLegs([emptyLeg()]);
    setActiveLeg(0);
    scenario.forget();
  }

  function goToTheComposer() {
    const target = document.getElementById("open-account");
    if (target === null) return;
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    target.scrollIntoView({ behavior: reduced ? "auto" : "smooth", block: "start" });
  }

  return (
    <main className="flex min-h-full flex-col">
      <header className="border-b border-rule px-4 py-4 sm:px-6">
        <div className="mx-auto flex max-w-[110rem] flex-wrap items-end justify-between gap-4">
          <div>
            <h1 className="text-lg font-medium tracking-tight">
              OpenLedger operator
            </h1>
            <p className="mt-0.5 text-[0.75rem] text-dim">
              Walk a card through the book, read any account back, and re-run
              any report at a cursor you pinned.
            </p>
          </div>
          <div className="flex flex-wrap items-end gap-2">
            <div className="flex flex-col gap-1">
              <Label
                htmlFor="tenant"
                className="text-[0.72rem] tracking-wide text-dim"
              >
                tenant_id — the book every request below names
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

      <div className="sticky top-0 z-10">
        <CursorRail
          horizon={horizon}
          pinned={pinned}
          observed={observed}
          busy={probing}
          onRefresh={() => void refreshHorizon()}
          onUnpin={() => setPinned(null)}
        />
      </div>

      <div className="mx-auto w-full max-w-[110rem] px-4 py-6 sm:px-6">
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
              onOpenComposer={goToTheComposer}
              onReset={startAFreshBook}
            />
          </div>

          <div className="flex min-w-0 flex-col gap-8 border-rule lg:border-l lg:pl-6">
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
              onFillBalance={(accountId, currency) => {
                setBalanceAccount(accountId);
                setBalanceCurrency(currency);
              }}
            />
          </div>
        </div>
      </div>

      <Composer
        tenant={tenant}
        legs={legs}
        setLegs={setLegs}
        activeLeg={activeLeg}
        setActiveLeg={setActiveLeg}
        balanceAccount={balanceAccount}
        setBalanceAccount={setBalanceAccount}
        balanceCurrency={balanceCurrency}
        setBalanceCurrency={setBalanceCurrency}
        transactionId={transactionId}
        setTransactionId={setTransactionId}
        pinned={pinned}
        onPin={setPinned}
        onAnswer={noteAnswer}
        afterAWrite={afterAWrite}
      />

      <Footnotes />
    </main>
  );
}

/**
 * The composer, and the point of the page: every route spelled out, in the
 * API's own field names, with nothing filled in for you that you did not fill
 * in on purpose. The walk above is a fast way into a book with something in
 * it; this is where you write the next thing yourself.
 */
function Composer({
  tenant,
  legs,
  setLegs,
  activeLeg,
  setActiveLeg,
  balanceAccount,
  setBalanceAccount,
  balanceCurrency,
  setBalanceCurrency,
  transactionId,
  setTransactionId,
  pinned,
  onPin,
  onAnswer,
  afterAWrite,
}: {
  tenant: string;
  legs: Leg[];
  setLegs: (legs: Leg[]) => void;
  activeLeg: number;
  setActiveLeg: (index: number) => void;
  balanceAccount: string;
  setBalanceAccount: (value: string) => void;
  balanceCurrency: string;
  setBalanceCurrency: (value: string) => void;
  transactionId: string;
  setTransactionId: (value: string) => void;
  pinned: string | null;
  onPin: (cursor: string) => void;
  onAnswer: (cursor: string, ranWithoutCursor: boolean, from: string) => void;
  afterAWrite: () => void;
}) {
  return (
    <div className="border-t border-rule">
      <div className="mx-auto grid w-full max-w-[110rem] gap-10 px-4 py-8 sm:px-6 lg:grid-cols-2 lg:gap-0">
        <section
          id="open-account"
          className="flex min-w-0 scroll-mt-24 flex-col gap-8 lg:pr-10"
        >
          <SpineHeading
            side="Write"
            port="the Ledger port — a refusal here wrote nothing"
          />
          <OpenAccount tenant={tenant} onOpened={afterAWrite} />
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
          <ReadTransaction
            tenant={tenant}
            transactionId={transactionId}
            setTransactionId={setTransactionId}
          />
        </section>

        <section className="flex min-w-0 flex-col gap-8 border-rule lg:border-l lg:pl-10">
          <SpineHeading
            side="Read"
            port="the Reports port — its own pool, its own login, RLS-scoped"
          />
          <AccountBalance
            tenant={tenant}
            accountId={balanceAccount}
            setAccountId={setBalanceAccount}
            currency={balanceCurrency}
            setCurrency={setBalanceCurrency}
          />
          <TrialBalance
            tenant={tenant}
            pinned={pinned}
            onPin={onPin}
            onAnswer={onAnswer}
          />
          <BalanceSheet
            tenant={tenant}
            pinned={pinned}
            onPin={onPin}
            onAnswer={onAnswer}
          />
          <IncomeStatement
            tenant={tenant}
            pinned={pinned}
            onPin={onPin}
            onAnswer={onAnswer}
          />
        </section>
      </div>
    </div>
  );
}

function SpineHeading({ side, port }: { side: string; port: string }) {
  return (
    <div className="flex flex-wrap items-baseline gap-x-3 border-b border-line pb-2">
      <h2 className="text-[0.8rem] tracking-[0.14em] text-peach uppercase">
        {side}
      </h2>
      <p className="text-[0.72rem] text-dim">{port}</p>
    </div>
  );
}

/** The three things an operator has to know that no panel owns. */
function Footnotes() {
  return (
    <footer className="border-t border-rule px-4 py-6 text-[0.72rem] leading-relaxed text-dim sm:px-6">
      <div className="mx-auto grid max-w-[110rem] gap-6 sm:grid-cols-3">
        <p>
          <span className="text-ink">Minor units, shown at two decimals.</span>{" "}
          The wire carries no currency exponent, so two is this dashboard&rsquo;s
          assumption rather than the ledger&rsquo;s statement. Every figure keeps
          its exact minor-unit integer in its <code>title</code> — hover any
          amount to read it unrounded.
        </p>
        <p>
          <span className="text-ink">Reconciliation is not on this page.</span>{" "}
          The reconciliation views are cross-tenant on a service with no
          authentication, so they are deliberately not exposed over HTTP. The
          sweep is <code>openledger reconcile</code>, run and scheduled by an
          operator.
        </p>
        <p>
          <span className="text-ink">There is no authentication.</span>{" "}
          <code>tenant_id</code> is data scoping, never an identity claim: the
          trust boundary is the deployment perimeter. Anyone who can reach this
          page can name any book.
        </p>
      </div>
    </footer>
  );
}
