"use client";

import { useCallback, useState } from "react";

import { CursorRail, type Horizon } from "@/components/cursor-rail";
import { AccountBalance } from "@/components/read/account-balance";
import { AccountRegisterPanel } from "@/components/read/account-register";
import { BalanceSheet } from "@/components/read/balance-sheet";
import { IncomeStatement } from "@/components/read/income-statement";
import { TrialBalance } from "@/components/read/trial-balance";
import { useAccountRegister } from "@/components/read/use-account-register";
import { OpenAccount } from "@/components/write/open-account";
import {
  emptyLeg,
  PostTransaction,
  type Leg,
} from "@/components/write/post-transaction";
import { ReadTransaction } from "@/components/write/read-transaction";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { runTrialBalance } from "@/lib/api";
import { isBehind } from "@/lib/cursor";
import { EARLIEST, LATEST } from "@/lib/time";

/**
 * The spine: writes on the left, reads on the right, the cursor rail across
 * the top of both. It is the architecture as much as it is a layout — the two
 * columns are two ports on two pools, and the rail is the commit position they
 * meet at.
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

  const register = useAccountRegister(tenant);

  /**
   * Rule 1, and the whole reason the horizon is not just "the last cursor
   * seen": a report RE-RUN at a pin answers with that pin, so taking every
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
   * There is no cursor-minting endpoint — ADR-0019 refused one, because every
   * report already returns the cursor it used. So reading the horizon means
   * running a report without one, and the trial balance over the widest range
   * is the cheapest of the three.
   */
  const refreshHorizon = useCallback(async () => {
    setProbing(true);
    const result = await runTrialBalance({
      tenant_id: tenant,
      effective_from: EARLIEST,
      effective_to: LATEST,
    });
    if (result.outcome === "answered") {
      noteAnswer(result.body.pinned_cursor, true, "an explicit refresh");
    }
    setProbing(false);
  }, [noteAnswer, tenant]);

  return (
    <main className="flex min-h-full flex-col">
      <header className="border-b border-rule px-4 py-4 sm:px-6">
        <div className="mx-auto flex max-w-[100rem] flex-wrap items-end justify-between gap-4">
          <div>
            <h1 className="text-lg font-medium tracking-tight">
              OpenLedger operator
            </h1>
            <p className="mt-0.5 text-[0.75rem] text-dim">
              Open an account, post a transaction, and read the book back at a
              cursor you pinned.
            </p>
          </div>
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

      <div className="mx-auto grid w-full max-w-[100rem] flex-1 gap-10 px-4 py-8 sm:px-6 lg:grid-cols-2 lg:gap-0">
        <section className="flex min-w-0 flex-col gap-8 lg:pr-10">
          <SpineHeading
            side="Write"
            port="the Ledger port — a refusal here wrote nothing"
          />
          <OpenAccount
            tenant={tenant}
            onOpened={() => {
              void register.list();
              void refreshHorizon();
            }}
          />
          <AccountRegisterPanel
            register={register}
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
                  index === activeLeg ? { ...leg, destination: accountId } : leg
                )
              )
            }
            onFillBalance={(accountId, currency) => {
              setBalanceAccount(accountId);
              setBalanceCurrency(currency);
            }}
          />
          <PostTransaction
            tenant={tenant}
            legs={legs}
            setLegs={setLegs}
            activeLeg={activeLeg}
            setActiveLeg={setActiveLeg}
            onPosted={(id) => {
              if (id !== null) setTransactionId(id);
              void refreshHorizon();
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
            onPin={setPinned}
            onAnswer={noteAnswer}
          />
          <BalanceSheet
            tenant={tenant}
            pinned={pinned}
            onPin={setPinned}
            onAnswer={noteAnswer}
          />
          <IncomeStatement
            tenant={tenant}
            pinned={pinned}
            onPin={setPinned}
            onAnswer={noteAnswer}
          />
        </section>
      </div>

      <Footnotes />
    </main>
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
      <div className="mx-auto grid max-w-[100rem] gap-6 sm:grid-cols-3">
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
