"use client";

import { CheckIcon, LockIcon, PlayIcon, TriangleAlertIcon } from "lucide-react";

import { cn } from "@/lib/utils";
import type { ScenarioStep } from "@/lib/scenario/types";
import type { StepState } from "@/components/scenario/use-scenario";

/**
 * One step of the walk: what happened, in an operator's words, and one line on
 * what it shows about the ledger.
 *
 * The tile is the button. Clicking it runs the step — and clicking a step that
 * already ran sends the identical body under the identical key again, which is
 * a replay and not a second write. That is true of every step here, not just
 * the one that is about it.
 */
export function StepTile({
  ordinal,
  step,
  state,
  blocked,
  running,
  showing,
  onRun,
}: {
  ordinal: number;
  step: ScenarioStep;
  state: StepState;
  /** Why it cannot run yet, or `null`. */
  blocked: string | null;
  running: boolean;
  showing: boolean;
  onRun: () => void;
}) {
  const halted = state.result?.kind === "halted";
  const disabled = blocked !== null || running;

  return (
    <button
      type="button"
      disabled={disabled}
      aria-describedby={blocked === null ? undefined : `${step.id}-blocked`}
      onClick={onRun}
      className={cn(
        "group flex h-full w-full min-w-0 flex-col items-start gap-1 border px-3 py-2.5 text-left transition-colors",
        "disabled:cursor-not-allowed",
        showing ? "border-peach bg-surface" : "border-rule hover:border-line",
        blocked !== null && "opacity-55",
        halted && "border-credit"
      )}
    >
      <span className="flex w-full items-center gap-2">
        <Ordinal value={ordinal} done={state.ran} halted={halted} />
        <span className="min-w-0 flex-1 text-[0.82rem] leading-tight font-medium">
          {step.label}
        </span>
        <Glyph
          running={running}
          done={state.ran}
          halted={halted}
          blocked={blocked !== null}
        />
      </span>
      <span className="text-[0.7rem] leading-snug text-dim">{step.teaches}</span>
      {blocked === null ? null : (
        <span
          id={`${step.id}-blocked`}
          className="text-[0.68rem] leading-snug text-peach"
        >
          {blocked}
        </span>
      )}
    </button>
  );
}

function Ordinal({
  value,
  done,
  halted,
}: {
  value: number;
  done: boolean;
  halted: boolean;
}) {
  return (
    <span
      aria-hidden
      className={cn(
        "grid size-5 shrink-0 place-items-center border font-mono text-[0.65rem] tabular-nums",
        halted
          ? "border-credit text-credit"
          : done
            ? "border-ok text-ok"
            : "border-line text-dim"
      )}
    >
      {value}
    </span>
  );
}

function Glyph({
  running,
  done,
  halted,
  blocked,
}: {
  running: boolean;
  done: boolean;
  halted: boolean;
  blocked: boolean;
}) {
  if (running) {
    return <span className="text-[0.68rem] text-peach">running…</span>;
  }
  if (halted) {
    return (
      <TriangleAlertIcon className="size-3.5 shrink-0 text-credit" aria-label="refused" />
    );
  }
  if (done) {
    return <CheckIcon className="size-3.5 shrink-0 text-ok" aria-label="ran" />;
  }
  if (blocked) {
    return <LockIcon className="size-3.5 shrink-0 text-dim" aria-label="blocked" />;
  }
  return (
    <PlayIcon
      className="size-3 shrink-0 text-dim group-hover:text-peach"
      aria-hidden
    />
  );
}
