"use client";

import type { EntryAxis } from "@/components/entries/use-account-entries";
import { cn } from "@/lib/utils";

const CHOICES: { axis: EntryAxis; label: string; wire: string }[] = [
  { axis: "recorded", label: "in the order we recorded them", wire: "recorded" },
  { axis: "effective", label: "in the order they happened", wire: "effective" },
];

/**
 * The two orders, in plain words.
 *
 * This is the most interesting control on the page: the two axes answer the
 * same SET of entries and disagree only about where a backdated one sits. Flip
 * it on a book that has one and the row moves — out of its own past on the
 * recorded axis, back into it on the effective one.
 *
 * The API refuses to choose for a caller who names neither, and so does this
 * dashboard: one of the two is always selected, and neither is a default that
 * hides the question.
 */
export function AxisToggle({
  axis,
  onChange,
  busy,
}: {
  axis: EntryAxis;
  onChange: (axis: EntryAxis) => void;
  busy: boolean;
}) {
  return (
    <div className="flex flex-col gap-1">
      <div
        role="radiogroup"
        aria-label="The order to read these entries in"
        className="flex flex-wrap gap-px border border-edge p-px"
      >
        {CHOICES.map((choice) => {
          const active = choice.axis === axis;
          return (
            <button
              key={choice.axis}
              type="button"
              role="radio"
              aria-checked={active}
              disabled={busy}
              onClick={() => onChange(choice.axis)}
              className={cn(
                "px-3 py-1.5 text-left text-[0.74rem] transition-colors",
                active
                  ? "bg-peach text-ground"
                  : "text-dim hover:bg-surface hover:text-ink"
              )}
            >
              {choice.label}
              <span
                className={cn(
                  "ml-2 font-mono text-[0.64rem]",
                  active ? "text-ground/70" : "text-dim"
                )}
              >
                axis={choice.wire}
              </span>
            </button>
          );
        })}
      </div>
      <p className="max-w-prose text-[0.68rem] leading-relaxed text-dim">
        The same entries, in two orders. One is the order the ledger learnt
        them in; the other is the order they happened in the business. An entry
        dated back to last week is at the end of the first and in the middle of
        the second, and neither is more true than the other — which is why the
        API will not pick one for you.
      </p>
    </div>
  );
}
