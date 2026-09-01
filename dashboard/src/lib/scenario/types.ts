/**
 * A scenario is DATA.
 *
 * Each step is a record — a label, one line on what it demonstrates, the steps
 * it needs first, and a function that makes the calls. The strip is rendered
 * from the list; nothing about a step is spelled in JSX. That is the point:
 * the period-close steps being built alongside this dashboard get appended to
 * a list, and the UI does not change to receive them.
 *
 * A step body never handles a refusal. It asks the context to post, and the
 * context throws `StepHalted` carrying the ledger's own answer, which the
 * runner renders verbatim. So a step reads like the trace it came from.
 */
import type { Answer } from "@/lib/ledger";
import type { ChartPurpose } from "./chart";

/**
 * The roster. `requires` names these, so a prerequisite that does not exist is
 * a compile error rather than a step that is silently never blocked. Appending
 * a step adds its id here and its definition to a list — and nothing else.
 */
export type StepId =
  | "authorized"
  | "cleared_300"
  | "revenue_share"
  | "cleared_200"
  | "facility_draw"
  | "settled"
  | "facility_repaid"
  | "disputed"
  | "reversed"
  | "sent_twice";

/** One movement: the amount leaves `from` and arrives at `to`. */
export interface PostingIntent {
  from: ChartPurpose;
  to: ChartPurpose;
  /** Minor units, an exact-integer decimal string — never a number. */
  minor: string;
}

/**
 * One `POST /v1/transactions`, named the way the card trace names its events.
 *
 * `key` is the idempotency key and it is DETERMINISTIC — `evt_clear_1:revshare`
 * and the rest are the event names the lifecycle document itself uses. Keys are
 * unique per book, and the reset control mints a new book, so a deterministic
 * key is safe and is what makes "send it twice" a replay of a real earlier
 * write rather than a staged one.
 */
export interface PostIntent {
  key: string;
  /** What this call wrote, in business terms. Shown in the step's report. */
  wrote: string;
  /** Omitted only on a reversal, where the target's own date is taken. */
  effectiveAt?: string;
  status?: "pending";
  resolves?: string;
  reverses?: string;
  postings?: readonly PostingIntent[];
}

/** One accepted write, as the step's report shows it. */
export interface StepWrite {
  route: string;
  wrote: string;
  status: number;
  /** `true` re-rendered a stored result; `null` means the header was absent. */
  replayed: boolean | null;
  eventId: string;
  transactionId: string | null;
}

/** A number the step read back afterwards, so its copy is checkable. */
export interface StepObservation {
  route: string;
  /** What was read: "customer_receivable, posted balance". */
  what: string;
  minor: string;
  currency: string;
  /** What the number means here. */
  reading: string;
}

/** Everything a run accumulated, or the answer that stopped it. */
export type StepResult =
  | { kind: "wrote"; writes: StepWrite[]; observations: StepObservation[] }
  | {
      kind: "halted";
      /** The call that did not go through, in the API's own route. */
      at: string;
      answer: Answer<unknown>;
      writes: StepWrite[];
    };

/**
 * Thrown by the context when a call is not answered. It carries the ledger's
 * own answer so the runner can render `type` and `detail` unedited.
 */
export class StepHalted extends Error {
  constructor(
    readonly at: string,
    readonly answer: Answer<unknown>
  ) {
    super(`${at} did not go through`);
    this.name = "StepHalted";
  }
}

/** What a step is handed. Every method may throw `StepHalted`. */
export interface ScenarioContext {
  readonly tenantId: string;
  /** The account for this chart code on this book, opened if it is not there. */
  account(purpose: ChartPurpose): Promise<string>;
  /** Opens every account the trace needs, in one pass. */
  openTheChart(): Promise<void>;
  post(intent: PostIntent): Promise<string | null>;
  /** Reads a posted balance back and records it in the step's report. */
  observe(
    purpose: ChartPurpose,
    what: string,
    reading: string
  ): Promise<void>;
  remember(name: string, transactionId: string | null): void;
  /** The id an earlier step remembered, or `null`. */
  recall(name: string): string | null;
  /** The trace's own calendar: day 0 is the authorization. */
  at(day: number, hour: number): string;
}

export interface ScenarioStep {
  id: StepId;
  /** The business event, as an operator would say it. */
  label: string;
  /** One line on what this shows about the ledger. */
  teaches: string;
  /** Steps whose writes this one needs. */
  requires: readonly StepId[];
  run(context: ScenarioContext): Promise<void>;
}
