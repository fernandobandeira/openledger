"use client";

import { PinIcon, PlayIcon, RotateCcwIcon } from "lucide-react";

import { Mono } from "@/components/mono";
import { TextField } from "@/components/field";
import { Button } from "@/components/ui/button";

/**
 * The cursor a report will run at. Left empty, the read path pins one and
 * says which — that is the answer that moves the horizon.
 *
 * This field is never filled in from a previous answer. Silently pinning the
 * next run to the last result is a surprise; the pin and the re-run below are
 * the designed way to reproduce a report, and they are both something you do
 * on purpose.
 */
export function CursorField({
  value,
  onChange,
}: {
  value: string;
  onChange: (value: string) => void;
}) {
  return (
    <TextField
      label="cursor"
      value={value}
      onChange={onChange}
      inputMode="numeric"
      placeholder="empty — the read path pins one"
      hint={
        <>
          An <code>xid8</code>. Empty means the server pins the current horizon
          and answers with it.
        </>
      }
    />
  );
}

export function RunRow({
  busy,
  onRun,
  runLabel,
  pinned,
  onRunAtPin,
}: {
  busy: boolean;
  onRun: () => void;
  runLabel: string;
  pinned: string | null;
  onRunAtPin: (pinned: string) => void;
}) {
  return (
    <div className="flex flex-wrap items-center gap-2">
      <Button size="sm" onClick={onRun} disabled={busy}>
        <PlayIcon aria-hidden />
        {busy ? "Running…" : runLabel}
      </Button>
      <Button
        size="sm"
        variant="outline"
        disabled={busy || pinned === null}
        onClick={() => {
          if (pinned !== null) onRunAtPin(pinned);
        }}
        title={
          pinned === null
            ? "Pin a cursor from any report first"
            : `Run this report at ${pinned}`
        }
      >
        <RotateCcwIcon aria-hidden /> Re-run at the pinned cursor
      </Button>
    </div>
  );
}

/**
 * Every report answers with the cursor it ran at, including when the caller
 * supplied none (ADR-0019). This strip is where that value is offered back:
 * pin it, and every other report can be re-run at the same commit position.
 * That pairing is the reproducibility demonstration.
 */
export function PinnedCursor({
  cursor,
  pinned,
  onPin,
}: {
  cursor: string;
  pinned: string | null;
  onPin: (cursor: string) => void;
}) {
  const alreadyPinned = pinned === cursor;
  return (
    <div className="mt-3 flex flex-wrap items-center justify-between gap-x-4 gap-y-2 border border-rule px-3 py-2">
      <p className="flex flex-wrap items-baseline gap-2">
        <span className="text-[0.72rem] text-dim">pinned_cursor</span>
        <Mono className="text-[0.8rem] text-peach">{cursor}</Mono>
      </p>
      <Button
        size="xs"
        variant={alreadyPinned ? "ghost" : "secondary"}
        disabled={alreadyPinned}
        onClick={() => onPin(cursor)}
      >
        <PinIcon aria-hidden />
        {alreadyPinned ? "Pinned" : "Pin this cursor"}
      </Button>
    </div>
  );
}

/**
 * What a stored cursor does and does not buy back, said where the amounts are.
 * The AMOUNTS at a cursor are reproducible; the ROW SET is not — the lines are
 * enumerated from tables that carry no commit position, so an account opened
 * afterwards adds lines to a report re-run at a fixed cursor (ADR-0019).
 */
export function ReproducibilityNote({
  kind,
}: {
  kind: "trial-balance" | "balance-sheet" | "income-statement";
}) {
  return (
    <p className="mt-2 max-w-prose text-[0.7rem] leading-relaxed text-dim">
      Re-running at this cursor reproduces the amounts, not the row set: the
      lines come from the chart and the account register, which carry no commit
      position, so an account opened since will add a row here at the same
      cursor.
      {kind === "income-statement"
        ? " An income statement carries one more hole: a period close recorded after this answer removes its transactions from a re-run at this very cursor."
        : ""}
    </p>
  );
}
