"use client";

import { useState } from "react";
import { PlusIcon, RefreshCwIcon } from "lucide-react";

import { Trouble, WriteOutcome } from "@/components/answer-view";
import { Choice, TextField } from "@/components/field";
import { Identifier, Mono } from "@/components/mono";
import { Panel } from "@/components/panel";
import { Button } from "@/components/ui/button";
import {
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
 * The answer carries the whole account (ADR-0022), so what the server derived
 * is on screen from the response this panel already has: one request, no
 * listing, no client-side scan. The `200` that replays the key re-renders the
 * identical account.
 */
/** The rule the writer enforces (`metadata must be a JSON object`), as a type
 * predicate: a bare `typeof x === "object"` narrows `unknown` to `{}`, which is
 * not the record the generated `AccountBody` asks for. */
function isJsonObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

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
  const [badMetadata, setBadMetadata] = useState<string | null>(null);

  async function submit() {
    // Minted on send rather than on mount: a key generated while rendering
    // would differ between the server pass and hydration. It stays in the
    // field afterwards, so sending again is the replay — 200, not 201.
    const key = idempotencyKey.trim() === "" ? freshKey() : idempotencyKey.trim();
    setIdempotencyKey(key);
    setBusy(true);
    setBadMetadata(null);

    let parsedMetadata: Record<string, unknown> | undefined;
    if (metadata.trim() !== "") {
      let parsed: unknown;
      try {
        parsed = JSON.parse(metadata);
      } catch (cause) {
        setBadMetadata(cause instanceof Error ? cause.message : String(cause));
        setBusy(false);
        return;
      }
      if (!isJsonObject(parsed)) {
        setBadMetadata("metadata must be a JSON object.");
        setBusy(false);
        return;
      }
      parsedMetadata = parsed;
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
    }
    setBusy(false);
  }

  return (
    <Panel title="Open an account" route="POST /v1/accounts">
      <div className="grid gap-3 sm:grid-cols-2">
        <TextField
          label="purpose"
          value={purpose}
          onChange={setPurpose}
          placeholder="customer_wallet"
          hint="A chart code this deployment carries."
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
            ownerType === "house" ? "Not sent — a house account has no owner." : "Required except for house."
          }
        />
        <TextField
          label="currency"
          value={currency}
          onChange={setCurrency}
          placeholder="USD"
          hint="One account, one currency."
        />
        <TextField
          label="stripe_count"
          value={stripeCount}
          onChange={setStripeCount}
          inputMode="numeric"
          placeholder="empty — one stripe"
          hint="1–1024, a hint to the writer."
        />
        <TextField
          label="metadata"
          value={metadata}
          onChange={setMetadata}
          placeholder={`{"note":"opened from the dashboard"}`}
          hint="Your own JSON object, stored as given."
        />
      </div>

      <div className="mt-3 flex flex-wrap items-end gap-2">
        <TextField
          className="min-w-[18rem] flex-1"
          label="idempotency_key"
          value={idempotencyKey}
          onChange={setIdempotencyKey}
          placeholder="minted when you send"
          hint="Same key, same body: 200, not 201."
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
              <Identifier value={answer.body.account.account_id} />
            </dd>
            <dt className="text-dim">event_id</dt>
            <dd>
              <Identifier value={answer.body.event_id} />
            </dd>
          </dl>
          <TheAccountItOpened account={answer.body.account} />
        </WriteOutcome>
      ) : null}

    </Panel>
  );
}

/** The account the answer carried — what the caller sent, and what it did not. */
function TheAccountItOpened({ account }: { account: AccountRead }) {
  const metadata = JSON.stringify(account.metadata);

  return (
    <div className="mt-3 border border-rule px-3 py-2">
      <p className="text-[0.72rem] text-dim">
        Derived by the server from <code>{account.purpose}</code>.
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
      <dl className="mt-2 grid gap-x-4 gap-y-1 text-[0.75rem] sm:grid-cols-[8rem_1fr]">
        <dt className="text-dim">created_at</dt>
        <dd>
          <Mono>{account.created_at}</Mono>{" "}
          <span className="text-[0.7rem] text-dim">the database&rsquo;s clock</span>
        </dd>
        <dt className="text-dim">metadata</dt>
        <dd>
          <Mono className="break-words">{metadata}</Mono>{" "}
          {metadata === "{}" ? (
            <span className="text-[0.7rem] text-dim">none given</span>
          ) : null}
        </dd>
      </dl>
    </div>
  );
}
