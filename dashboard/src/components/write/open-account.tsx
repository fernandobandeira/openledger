"use client";

import { useState } from "react";
import { PlusIcon, RefreshCwIcon } from "lucide-react";

import { Trouble, WriteOutcome } from "@/components/answer-view";
import { Choice, TextField } from "@/components/field";
import { Identifier, Mono } from "@/components/mono";
import { Panel, PanelNote } from "@/components/panel";
import { Button } from "@/components/ui/button";
import {
  listAccounts,
  openAccount,
  replayedHeader,
  type AccountBody,
  type AccountCreated,
  type AccountRead,
  type Answer,
  type OwnerType,
} from "@/lib/ledger";

const OWNER_TYPES: { value: OwnerType; label: string }[] = [
  { value: "company", label: "company" },
  { value: "platform", label: "platform" },
  { value: "bank_account", label: "bank_account" },
  { value: "house", label: "house" },
];

function freshKey(): string {
  return `open-${crypto.randomUUID()}`;
}

/**
 * The caller names a purpose. The server reads the chart and derives
 * `category`, `normal_balance` and `counterparty_scope` — so this form offers
 * no fields for those three, because a body that stated them would earn a
 * foreign-key error instead of an answer (ADR-0021).
 *
 * The derived triple is NOT in the opening response, which carries two ids and
 * nothing else. So the panel reads the account back from `GET /v1/accounts`
 * and shows what the server decided; that second call is labelled where it
 * happens rather than hidden.
 */
export function OpenAccount({
  tenant,
  onOpened,
}: {
  tenant: string;
  onOpened: () => void;
}) {
  const [idempotencyKey, setIdempotencyKey] = useState("");
  const [purpose, setPurpose] = useState("customer_wallet");
  const [ownerType, setOwnerType] = useState<OwnerType>("company");
  const [ownerId, setOwnerId] = useState("co_1");
  const [currency, setCurrency] = useState("USD");
  const [stripeCount, setStripeCount] = useState("");
  const [metadata, setMetadata] = useState("");

  const [busy, setBusy] = useState(false);
  const [answer, setAnswer] = useState<Answer<AccountCreated> | null>(null);
  const [replayed, setReplayed] = useState<boolean | null>(null);
  const [derived, setDerived] = useState<AccountRead | null>(null);
  const [derivedMissing, setDerivedMissing] = useState<string | null>(null);
  const [badMetadata, setBadMetadata] = useState<string | null>(null);

  async function submit() {
    // Minted on send rather than on mount: a key generated while rendering
    // would differ between the server pass and hydration. It stays in the
    // field afterwards, so sending again is the replay — 200, not 201.
    const key = idempotencyKey.trim() === "" ? freshKey() : idempotencyKey.trim();
    setIdempotencyKey(key);
    setBusy(true);
    setDerived(null);
    setDerivedMissing(null);
    setBadMetadata(null);

    let parsedMetadata: unknown;
    if (metadata.trim() !== "") {
      try {
        parsedMetadata = JSON.parse(metadata);
      } catch (cause) {
        setBadMetadata(cause instanceof Error ? cause.message : String(cause));
        setBusy(false);
        return;
      }
      if (typeof parsedMetadata !== "object" || parsedMetadata === null || Array.isArray(parsedMetadata)) {
        setBadMetadata("metadata must be a JSON object — the column stores a bare number just as happily, and a field that is sometimes a scalar is a shape every reader has to defend against.");
        setBusy(false);
        return;
      }
    }

    const body: AccountBody = {
      tenant_id: tenant,
      idempotency_key: key,
      purpose,
      owner_type: ownerType,
      owner_id: ownerType === "house" ? null : ownerId,
      currency,
      ...(stripeCount.trim() === "" ? {} : { stripe_count: Number(stripeCount) }),
      ...(parsedMetadata === undefined ? {} : { metadata: parsedMetadata }),
    };

    const result = await openAccount(body);
    setAnswer(result);
    setReplayed(
      result.outcome === "answered" ? replayedHeader(result.headers) : null
    );

    if (result.outcome === "answered") {
      onOpened();
      await readBackWhatTheServerDerived(result.body.account_id);
    }
    setBusy(false);
  }

  async function readBackWhatTheServerDerived(accountId: string) {
    const page = await listAccounts({
      tenant_id: tenant,
      purpose,
      limit: 1000,
    });
    if (page.outcome !== "answered") {
      setDerivedMissing(
        "The read-back listing did not answer, so the derived triple is not shown."
      );
      return;
    }
    const found = page.body.accounts.find(
      (account) => account.account_id === accountId
    );
    if (found) {
      setDerived(found);
    } else {
      setDerivedMissing(
        "The account is not on the first 1000 rows for this purpose. There is no GET /v1/accounts/{id}, so the register has to be paged to find it."
      );
    }
  }

  return (
    <Panel title="Open an account" route="POST /v1/accounts">
      <div className="grid gap-3 sm:grid-cols-2">
        <TextField
          label="purpose"
          value={purpose}
          onChange={setPurpose}
          placeholder="customer_wallet"
          hint="A chart code this deployment carries. Anything else is account_type_unknown."
        />
        <Choice
          label="owner_type"
          value={ownerType}
          options={OWNER_TYPES}
          onChange={setOwnerType}
        />
        <TextField
          label="owner_id"
          value={ownerId}
          onChange={setOwnerId}
          placeholder="co_1"
          hint={
            ownerType === "house"
              ? "Not sent: a house account is the ledger's own side and has no owner."
              : "Required for every owner_type except house."
          }
        />
        <TextField
          label="currency"
          value={currency}
          onChange={setCurrency}
          placeholder="USD"
          hint="Three uppercase letters. One account holds one currency."
        />
        <TextField
          label="stripe_count"
          value={stripeCount}
          onChange={setStripeCount}
          inputMode="numeric"
          placeholder="empty — one stripe"
          hint="1–1024. A hint to the writer, not an invariant; no stripe value appears in any response."
        />
        <TextField
          label="metadata"
          value={metadata}
          onChange={setMetadata}
          placeholder={`{"note":"opened from the dashboard"}`}
          hint="Your own JSON object, stored as given. Optional."
        />
      </div>

      <div className="mt-3 flex flex-wrap items-end gap-2">
        <TextField
          className="min-w-[18rem] flex-1"
          label="idempotency_key"
          value={idempotencyKey}
          onChange={setIdempotencyKey}
          placeholder="minted when you send"
          hint="Sending the same key with the same body again replays the stored result: 200, not 201."
        />
        <Button
          variant="outline"
          size="sm"
          onClick={() => setIdempotencyKey(freshKey())}
        >
          <RefreshCwIcon aria-hidden /> New key
        </Button>
        <Button size="sm" onClick={() => void submit()} disabled={busy}>
          <PlusIcon aria-hidden />
          {busy ? "Opening…" : "Open account"}
        </Button>
      </div>

      {badMetadata ? (
        <div className="mt-3 border-l-2 border-credit bg-credit-bg/55 px-3 py-2">
          <p className="text-[0.75rem] text-credit">
            The dashboard refused this before sending it — not the API.
          </p>
          <Mono className="mt-1 block text-[0.72rem] text-ink">
            {badMetadata}
          </Mono>
        </div>
      ) : null}

      <Trouble answer={answer} />

      {answer?.outcome === "answered" ? (
        <WriteOutcome
          status={answer.status}
          replayed={replayed}
          wrote="the account and its event"
        >
          <dl className="mt-2 grid gap-x-4 gap-y-1 text-[0.75rem] sm:grid-cols-[8rem_1fr]">
            <dt className="text-dim">account_id</dt>
            <dd>
              <Identifier value={answer.body.account_id} />
            </dd>
            <dt className="text-dim">event_id</dt>
            <dd>
              <Identifier value={answer.body.event_id} />
            </dd>
          </dl>
        </WriteOutcome>
      ) : null}

      {derived ? <DerivedTriple account={derived} /> : null}
      {derivedMissing ? <PanelNote>{derivedMissing}</PanelNote> : null}

      <PanelNote>
        Opening an account writes an event and no ledger transaction — the case
        the event log exists for. It shares one idempotency namespace with{" "}
        <code>POST /v1/transactions</code>, deliberately: it is the same spine.
      </PanelNote>
    </Panel>
  );
}

/** What the caller did NOT send, and the server worked out from the chart. */
function DerivedTriple({ account }: { account: AccountRead }) {
  return (
    <div className="mt-3 border border-rule px-3 py-2">
      <p className="text-[0.72rem] text-dim">
        The first three were derived by the server from{" "}
        <code>{account.purpose}</code>; the stripe count is the hint you sent,
        echoed. All four are read back from <code>GET /v1/accounts</code>,
        because the opening response carries only the two ids above.
      </p>
      <dl className="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-[0.78rem] sm:grid-cols-4">
        <div>
          <dt className="text-[0.68rem] text-dim">category</dt>
          <dd>
            <Mono className="text-peach">{account.category}</Mono>
          </dd>
        </div>
        <div>
          <dt className="text-[0.68rem] text-dim">normal_balance</dt>
          <dd>
            <Mono className="text-peach">{account.normal_balance}</Mono>
          </dd>
        </div>
        <div>
          <dt className="text-[0.68rem] text-dim">counterparty_scope</dt>
          <dd>
            <Mono className="text-peach">{account.counterparty_scope}</Mono>
          </dd>
        </div>
        <div>
          <dt className="text-[0.68rem] text-dim">stripe_count</dt>
          <dd>
            <Mono>{account.stripe_count}</Mono>
          </dd>
        </div>
      </dl>
      <p className="mt-2 text-[0.68rem] text-dim">
        <code>normal_balance</code> is not derivable from <code>category</code>:
        a loss allowance is an asset with a credit normal balance, which is why
        the schema stores both.
      </p>
    </div>
  );
}
