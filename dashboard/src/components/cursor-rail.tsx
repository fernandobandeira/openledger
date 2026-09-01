"use client";

import { RefreshCwIcon, XIcon } from "lucide-react";

import { Mono } from "@/components/mono";
import { Button } from "@/components/ui/button";
import { commitsBetween, isBehind, railOver } from "@/lib/cursor";

export interface Horizon {
  cursor: string;
  /** When this dashboard observed it. */
  observedAt: string;
  /** Which unpinned answer carried it. */
  from: string;
  /** True when the newly observed horizon was BELOW the previous one. */
  regressed: boolean;
}

/**
 * The cursor rail — a commit-position ruler carrying two marks: the cluster
 * horizon, and the cursor you pinned.
 *
 * The horizon advances only on an answer that supplied NO cursor (plus an
 * explicit refresh, and after a successful write). A report re-run AT a pin
 * returns that pin as its `pinned_cursor`, so taking every answer at face
 * value would drag the horizon backwards — which is the one thing this rail
 * must never do on its own.
 *
 * The scale is the observed range, not the type's: an `xid8` is a 64-bit
 * unsigned commit position, and two cursors a hundred commits apart would land
 * on the same pixel of a 0…2^64 rail. Everything here is `BigInt`.
 */
export function CursorRail({
  horizon,
  pinned,
  observed,
  busy,
  onRefresh,
  onUnpin,
}: {
  horizon: Horizon | null;
  pinned: string | null;
  observed: string[];
  busy: boolean;
  onRefresh: () => void;
  onUnpin: () => void;
}) {
  const rail = railOver(observed);
  const horizonAt = horizon && rail ? rail.place(horizon.cursor) : null;
  const pinnedAt = pinned && rail ? rail.place(pinned) : null;
  const behind =
    horizon && pinned ? commitsBetween(pinned, horizon.cursor) : null;
  const pinIsBehind =
    horizon && pinned ? isBehind(pinned, horizon.cursor) : false;

  return (
    <section
      aria-label="Cursor rail"
      className="border-y border-rule bg-surface px-4 py-3 sm:px-6"
    >
      <div className="mx-auto flex max-w-[100rem] flex-col gap-3">
        <div className="flex flex-wrap items-center justify-between gap-x-6 gap-y-2">
          <div className="flex flex-wrap items-baseline gap-x-6 gap-y-1">
            <Legend
              swatch="bg-peach"
              name="Cluster horizon"
              value={horizon?.cursor ?? "not observed"}
            />
            <Legend
              swatch="bg-ok"
              name="Pinned cursor"
              value={pinned ?? "nothing pinned"}
            />
            {behind !== null ? (
              <p className="text-[0.72rem] text-dim">
                {behind === "0" ? (
                  <>The pin is at the horizon.</>
                ) : (
                  <>
                    The pin is <Mono className="text-ink">{behind}</Mono> commit
                    {behind === "1" ? "" : "s"}{" "}
                    {pinIsBehind
                      ? "behind the horizon."
                      : "ahead of the last horizon this dashboard observed."}
                  </>
                )}
              </p>
            ) : null}
          </div>

          <div className="flex items-center gap-2">
            {pinned ? (
              <Button variant="ghost" size="xs" onClick={onUnpin}>
                <XIcon aria-hidden /> Unpin
              </Button>
            ) : null}
            <Button
              variant="outline"
              size="xs"
              onClick={onRefresh}
              disabled={busy}
            >
              <RefreshCwIcon aria-hidden />
              {busy ? "Reading the horizon…" : "Refresh the horizon"}
            </Button>
          </div>
        </div>

        <div className="relative h-14 select-none">
          {/* the ruler */}
          <div className="absolute inset-x-0 top-7 h-px bg-line" aria-hidden />
          <div className="absolute top-6 left-0 h-3 w-px bg-line" aria-hidden />
          <div className="absolute top-6 right-0 h-3 w-px bg-line" aria-hidden />

          {rail === null ? (
            <p className="absolute inset-x-0 top-[1.1rem] text-center text-[0.75rem] text-dim">
              No commit position observed yet. Refresh the horizon, or run any
              report.
            </p>
          ) : (
            <>
              <Mono className="absolute top-9 left-0 text-[0.66rem] text-dim">
                {rail.low.toString()}
              </Mono>
              <Mono className="absolute top-9 right-0 text-[0.66rem] text-dim">
                {rail.high.toString()}
              </Mono>
            </>
          )}

          {horizonAt !== null && horizon ? (
            <Mark
              at={horizonAt}
              tone="peach"
              label="horizon"
              value={horizon.cursor}
              placement="above"
            />
          ) : null}
          {pinnedAt !== null && pinned ? (
            <Mark
              at={pinnedAt}
              tone="ok"
              label="pinned"
              value={pinned}
              placement="below"
            />
          ) : null}
        </div>

        <p className="text-[0.7rem] leading-relaxed text-dim">
          {horizon ? (
            <>
              The horizon came from{" "}
              <span className="text-ink">{horizon.from}</span>, answered without
              a cursor at{" "}
              <Mono className="text-ink">
                {new Date(horizon.observedAt).toLocaleTimeString()}
              </Mono>
              . A report re-run at a pin answers with that pin, so only an
              unpinned answer moves this mark.
              {horizon.regressed ? (
                <span className="text-credit">
                  {" "}
                  This horizon read BELOW the previous one — the cluster horizon
                  is lagging, which is exactly what ADR-0019 returns the pinned
                  cursor to let you notice.
                </span>
              ) : null}
            </>
          ) : (
            <>
              There is no cursor-minting endpoint (ADR-0019 refused one), so the
              only way to read the cluster horizon over HTTP is to run a report
              without a cursor. Refreshing runs the trial balance over the
              widest range.
            </>
          )}
        </p>
      </div>
    </section>
  );
}

function Legend({
  swatch,
  name,
  value,
}: {
  swatch: string;
  name: string;
  value: string;
}) {
  return (
    <p className="flex items-baseline gap-2">
      <span className={`inline-block size-2 shrink-0 ${swatch}`} aria-hidden />
      <span className="text-[0.72rem] text-dim">{name}</span>
      <Mono className="text-[0.78rem]">{value}</Mono>
    </p>
  );
}

/**
 * One mark. The stem transitions when it moves so an advancing horizon is
 * visibly an advance; `prefers-reduced-motion` cuts that to nothing in
 * `globals.css`.
 */
function Mark({
  at,
  tone,
  label,
  value,
  placement,
}: {
  at: number;
  tone: "peach" | "ok";
  label: string;
  value: string;
  placement: "above" | "below";
}) {
  const colour = tone === "peach" ? "bg-peach" : "bg-ok";
  const text = tone === "peach" ? "text-peach" : "text-ok";
  return (
    <div
      className="absolute top-0 h-full transition-[left] duration-500 ease-out"
      style={{ left: `${at * 100}%` }}
    >
      <div className="relative -translate-x-1/2">
        <span
          className={`absolute top-3 left-0 block h-8 w-px ${colour}`}
          aria-hidden
        />
        <span
          className={`absolute top-[1.55rem] left-0 block size-[7px] -translate-x-[3px] ${colour}`}
          aria-hidden
        />
        <span
          className={`absolute ${
            placement === "above" ? "top-0" : "top-11"
          } left-0 flex -translate-x-1/2 flex-col items-center whitespace-nowrap`}
        >
          <Mono className={`text-[0.68rem] ${text}`}>{value}</Mono>
          <span className="text-[0.6rem] tracking-wide text-dim">{label}</span>
        </span>
      </div>
    </div>
  );
}
