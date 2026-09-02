"use client";

import { useCallback, useMemo, useRef, useState } from "react";

import { specFor, TRACE_CHART, type ChartPurpose } from "@/lib/scenario/chart";
import { CARD_LIFECYCLE } from "@/lib/scenario/steps";
import {
  StepHalted,
  type PostIntent,
  type ScenarioContext,
  type ScenarioStep,
  type StepId,
  type StepObservation,
  type StepResult,
  type StepWrite,
} from "@/lib/scenario/types";
import {
  openAccount,
  postTransaction,
  readAccountBalance,
  replayedHeader,
  type AccountRead,
  type PostingBody,
  type TransactionBody,
} from "@/lib/ledger";

const CURRENCY = "USD";

/**
 * The trace's calendar: day 0 is the first of LAST month, in UTC.
 *
 * Last month rather than this one so the whole thirty-day walk — the draw, the
 * accrual, the repayment — is behind us, and `effective_at` is a business date
 * that has happened rather than one that has not.
 *
 * It has to be the SAME instant on every visit to one book, because the
 * idempotency keys are deterministic: a step re-run with a drifting date is
 * the same key with a different body, which the ledger refuses as
 * `idempotency_key_reused` — correctly. A month boundary is stable across
 * reloads, and starting a fresh book mints new keys anyway.
 */
function traceEpoch(): number {
  const now = new Date();
  return Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1);
}

const DAY_MS = 86_400_000;
const HOUR_MS = 3_600_000;

export interface StepState {
  ran: boolean;
  result: StepResult | null;
}

/**
 * One run of one step, kept.
 *
 * The walk used to show the report of whichever step ran last and throw the
 * rest away, so ten steps left one paragraph and no trail: what the sixth
 * step wrote was gone by the time the seventh answered. A walk is a sequence
 * of writes to a real book and the record of it is the point, so every run is
 * appended here — the calls it made, the status each was answered with, and
 * the one line saying what it wrote.
 *
 * `seq` is monotonic rather than the step's id, so a step run twice is two
 * entries. Re-running IS a thing this walk teaches — the last step is a
 * deliberate replay — and a log that collapsed the second run into the first
 * would hide the header that makes it a replay.
 */
export interface LoggedRun {
  seq: number;
  stepId: StepId;
  /** The step's place in the walk, so the log reads in the walk's numbers. */
  ordinal: number;
  /** When this dashboard recorded it. */
  at: string;
  result: StepResult;
}

export interface Scenario {
  steps: readonly ScenarioStep[];
  stateOf(id: StepId): StepState;
  /** Why this step cannot run yet, in the words of the steps it waits on. */
  blockedBecause(step: ScenarioStep): string | null;
  running: StepId | null;
  /** The step whose tile is lit — the last one run. */
  showing: StepId | null;
  /** Every run, newest first. The record of the walk. */
  log: readonly LoggedRun[];
  run(step: ScenarioStep): Promise<void>;
  /** Forget every run. The book itself is discarded by switching tenant. */
  forget(): void;
}

/** Everything one book's walk has produced, and which book that is. */
interface Walk {
  tenant: string;
  results: Partial<Record<StepId, StepResult>>;
  /** The step whose run is highlighted — the last one to start. */
  showing: StepId | null;
  /** Newest first. */
  log: readonly LoggedRun[];
}

function nothingRunYet(tenant: string): Walk {
  return { tenant, results: {}, showing: null, log: [] };
}

/**
 * Runs one step at a time and keeps what each one wrote.
 *
 * The step bodies never see a refusal: `post` and `account` throw `StepHalted`
 * carrying the ledger's own answer, and it is caught here so the strip can
 * render `type` and `detail` unedited. Nothing is retried and nothing is
 * rolled back — a halted step leaves whatever it had already written, and its
 * report lists it, because that is what actually happened to the book.
 */
export function useScenario(
  tenant: string,
  accounts: readonly AccountRead[],
  onWrote: () => void
): Scenario {
  const [walk, setWalk] = useState<Walk>(() => nothingRunYet(tenant));
  const [running, setRunning] = useState<StepId | null>(null);

  /**
   * The walk belongs to ONE book, and it is shown only while it still
   * describes the book on screen — the same rule the entries panel keeps
   * about its page. Switching tenant therefore forgets every run without an
   * effect that blanks state on the way past, and without a render in which
   * a new book briefly wears the old book's record.
   */
  const current = walk.tenant === tenant ? walk : nothingRunYet(tenant);
  const { results, showing, log } = current;

  /** Every update starts from the walk that belongs to THIS book. */
  const amend = useCallback(
    (change: (previous: Walk) => Walk) => {
      setWalk((previous) =>
        change(previous.tenant === tenant ? previous : nothingRunYet(tenant))
      );
    },
    [tenant]
  );

  /**
   * What the walk learnt about ONE book: the accounts it opened, and the
   * transaction ids one step leaves for another. A new book has neither, so
   * this is re-made when the tenant changes rather than carried across — a
   * stale account id would be a `tenant_mismatch` on the next posting.
   */
  const memory = useRef({
    tenant,
    accounts: new Map<ChartPurpose, string>(),
    transactions: new Map<string, string>(),
  });

  const memoryForThisBook = useCallback(() => {
    if (memory.current.tenant !== tenant) {
      memory.current = {
        tenant,
        accounts: new Map<ChartPurpose, string>(),
        transactions: new Map<string, string>(),
      };
    }
    return memory.current;
  }, [tenant]);

  const registered = useMemo(() => {
    const byPurpose = new Map<string, string>();
    for (const account of accounts) {
      if (!byPurpose.has(account.purpose) && account.currency === CURRENCY) {
        byPurpose.set(account.purpose, account.account_id);
      }
    }
    return byPurpose;
  }, [accounts]);

  const run = useCallback(
    async (step: ScenarioStep) => {
      const writes: StepWrite[] = [];
      const observations: StepObservation[] = [];
      const book = memoryForThisBook();

      async function accountFor(purpose: ChartPurpose): Promise<string> {
        const cached = book.accounts.get(purpose) ?? registered.get(purpose);
        if (cached !== undefined) return cached;

        const spec = specFor(purpose);
        const answer = await openAccount({
          tenant_id: tenant,
          idempotency_key: `open:${purpose}`,
          purpose,
          owner_type: spec.ownerType,
          owner_id: spec.ownerId,
          currency: CURRENCY,
        });
        if (answer.outcome !== "answered") {
          throw new StepHalted(`POST /v1/accounts — ${purpose}`, answer);
        }
        const id = answer.body.account.account_id;
        book.accounts.set(purpose, id);
        writes.push({
          route: "POST /v1/accounts",
          wrote: `${purpose} — ${spec.gloss}`,
          status: answer.status,
          replayed: replayedHeader(answer.headers),
          eventId: answer.body.event_id,
          transactionId: null,
        });
        return id;
      }

      const context: ScenarioContext = {
        tenantId: tenant,
        account: accountFor,
        async openTheChart() {
          for (const spec of TRACE_CHART) {
            await accountFor(spec.purpose);
          }
        },
        async post(intent: PostIntent) {
          const postings: PostingBody[] = [];
          for (const posting of intent.postings ?? []) {
            postings.push({
              source: await accountFor(posting.from),
              destination: await accountFor(posting.to),
              amount_minor: posting.minor,
              currency: CURRENCY,
            });
          }
          const body: TransactionBody = {
            tenant_id: tenant,
            idempotency_key: intent.key,
            ...(intent.effectiveAt === undefined
              ? {}
              : { effective_at: intent.effectiveAt }),
            ...(intent.status === undefined ? {} : { status: intent.status }),
            ...(intent.resolves === undefined
              ? {}
              : { resolves_id: intent.resolves }),
            ...(intent.reverses === undefined
              ? { postings }
              : { reverses_id: intent.reverses }),
          };
          const answer = await postTransaction(body);
          if (answer.outcome !== "answered") {
            throw new StepHalted(`POST /v1/transactions — ${intent.key}`, answer);
          }
          writes.push({
            route: `POST /v1/transactions · ${intent.key}`,
            wrote: intent.wrote,
            status: answer.status,
            replayed: replayedHeader(answer.headers),
            eventId: answer.body.event_id,
            transactionId: answer.body.transaction_id,
          });
          return answer.body.transaction_id;
        },
        async observe(purpose, what, reading) {
          const accountId = await accountFor(purpose);
          const answer = await readAccountBalance(accountId, {
            tenant_id: tenant,
            currency: CURRENCY,
          });
          if (answer.outcome !== "answered") {
            throw new StepHalted(
              `GET /v1/accounts/{account_id}/balance — ${purpose}`,
              answer
            );
          }
          observations.push({
            route: "GET /v1/accounts/{account_id}/balance",
            what,
            minor: answer.body.posted_minor,
            currency: answer.body.currency,
            reading,
          });
        },
        remember(name, transactionId) {
          if (transactionId !== null) book.transactions.set(name, transactionId);
        },
        recall(name) {
          return book.transactions.get(name) ?? null;
        },
        at(day, hour) {
          return new Date(
            traceEpoch() + day * DAY_MS + hour * HOUR_MS
          ).toISOString();
        },
      };

      /** Both outcomes are kept, and both are logged: a halt is what happened. */
      function record(result: StepResult) {
        const ordinal =
          CARD_LIFECYCLE.findIndex((candidate) => candidate.id === step.id) + 1;
        const at = new Date().toISOString();
        amend((previous) => ({
          ...previous,
          results: { ...previous.results, [step.id]: result },
          log: [
            {
              seq: previous.log.length === 0 ? 1 : previous.log[0].seq + 1,
              stepId: step.id,
              ordinal,
              at,
              result,
            },
            ...previous.log,
          ],
        }));
      }

      setRunning(step.id);
      amend((previous) => ({ ...previous, showing: step.id }));
      try {
        await step.run(context);
        record({ kind: "wrote", writes, observations });
      } catch (cause) {
        if (!(cause instanceof StepHalted)) throw cause;
        record({
          kind: "halted",
          at: cause.at,
          answer: cause.answer,
          writes,
        });
      } finally {
        setRunning(null);
        onWrote();
      }
    },
    [amend, memoryForThisBook, onWrote, registered, tenant]
  );

  const stateOf = useCallback(
    (id: StepId): StepState => {
      const result = results[id] ?? null;
      return { ran: result?.kind === "wrote", result };
    },
    [results]
  );

  const blockedBecause = useCallback(
    (step: ScenarioStep): string | null => {
      const waiting = step.requires.filter(
        (id) => results[id]?.kind !== "wrote"
      );
      if (waiting.length === 0) return null;
      const names = waiting.map(
        (id) =>
          CARD_LIFECYCLE.find((candidate) => candidate.id === id)?.label ?? id
      );
      return `needs ${names.map((name) => `“${name}”`).join(" and ")}`;
    },
    [results]
  );

  const forget = useCallback(() => {
    setWalk(nothingRunYet(tenant));
    memory.current = {
      tenant: memory.current.tenant,
      accounts: new Map<ChartPurpose, string>(),
      transactions: new Map<string, string>(),
    };
  }, [tenant]);

  return {
    steps: CARD_LIFECYCLE,
    stateOf,
    blockedBecause,
    running,
    showing,
    log,
    run,
    forget,
  };
}
