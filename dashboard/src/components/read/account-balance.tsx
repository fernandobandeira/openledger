"use client";

import { useState } from "react";
import { ScaleIcon } from "lucide-react";

import { Amount } from "@/components/amount";
import { Trouble } from "@/components/answer-view";
import { TextField } from "@/components/field";
import { Mono } from "@/components/mono";
import { Panel, PanelNote } from "@/components/panel";
import { Button } from "@/components/ui/button";
import { isNegativeMinor } from "@/lib/amount";
import {
  readAccountBalance,
  type AccountBalanceRead,
  type Answer,
} from "@/lib/api";

/**
 * Posted, now. This route takes no cursor and that is the contract: it reads
 * the balance cache, and pinning it would be a second definition of a balance.
 * The journal-based answer is the trial balance below.
 */
export function AccountBalance({
  tenant,
  accountId,
  setAccountId,
  currency,
  setCurrency,
}: {
  tenant: string;
  accountId: string;
  setAccountId: (value: string) => void;
  currency: string;
  setCurrency: (value: string) => void;
}) {
  const [busy, setBusy] = useState(false);
  const [answer, setAnswer] = useState<Answer<AccountBalanceRead> | null>(null);

  async function read() {
    if (accountId.trim() === "") return;
    setBusy(true);
    setAnswer(
      await readAccountBalance(accountId.trim(), {
        tenant_id: tenant,
        currency: currency.trim(),
      })
    );
    setBusy(false);
  }

  const balance = answer?.outcome === "answered" ? answer.body : null;

  return (
    <Panel
      title="One account's posted balance"
      route="GET /v1/accounts/{id}/balance"
    >
      <div className="flex flex-wrap items-end gap-2">
        <TextField
          className="min-w-[18rem] flex-1"
          label="account_id"
          value={accountId}
          onChange={setAccountId}
          placeholder="click balance on a register row"
        />
        <TextField
          className="w-24"
          label="currency"
          value={currency}
          onChange={setCurrency}
        />
        <Button size="sm" onClick={() => void read()} disabled={busy}>
          <ScaleIcon aria-hidden />
          {busy ? "Reading…" : "Read the balance"}
        </Button>
      </div>

      <Trouble answer={answer} />

      {balance ? (
        <div className="mt-3 border border-rule px-3 py-3">
          <p className="flex flex-wrap items-baseline justify-between gap-2">
            <Amount
              minor={balance.posted_minor}
              currency={balance.currency}
              className={`text-2xl ${
                isNegativeMinor(balance.posted_minor) ? "text-credit" : ""
              }`}
            />
            <Mono className="text-[0.75rem] text-dim">
              {balance.currency} · as_of {balance.as_of}
            </Mono>
          </p>
          <p className="mt-2 text-[0.72rem] text-dim">
            Debit-positive: a credit-normal account reads negative here, and the
            presentation flip is the reader&rsquo;s. An account that exists and
            has never been written answers{" "}
            <Mono className="text-ink">0</Mono> — which is why this endpoint
            reads the account register and not only the balance cache.
          </p>
        </div>
      ) : null}

      <PanelNote>
        No stripe appears in this answer. The read is a sum over the stripe rows
        that exist, which is what stops an integrator writing the single-row
        read that under-reports.
      </PanelNote>
    </Panel>
  );
}
