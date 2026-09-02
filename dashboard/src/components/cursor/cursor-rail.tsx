"use client";

import { RefreshCwIcon, XIcon } from "lucide-react";

import type { BookCommits } from "@/components/cursor/use-book-commits";
import { Mono } from "@/components/mono";
import { Button } from "@/components/ui/button";
import { GuideLink } from "@/components/guide-link";
import { commitsBetween, isBehind, placeAmong } from "@/lib/cursor";

export interface Horizon {
  cursor: string;
  /** When this dashboard observed it. */
  observedAt: string;
  /** Which answer carried it — a report run unpinned, or `GET /v1/cursor`. */
  from: string;
  /** True when the newly observed horizon was BELOW the previous one. */
  regressed: boolean;
}

/**
 * The cursor rail — a SEQUENCE of this book's commits, and not a ruler.
 *
 * **What was wrong with the ruler.** It plotted `xid8` values on a linear
 * scale, which draws a distance between two cursors. There is no such
 * distance: `report_cursor()` is `pg_snapshot_xmin` and the counter behind it
 * is cluster-global, so the numbers between two of this book's commits were
 * spent on transactions in other databases. An `xid8` is a total ORDER; the
 * interval between two of them carries no information, and a scale is a
 * promise that it does.
 *
 * **What replaces it.** One tick per commit this book actually made, evenly
 * spaced because their spacing means nothing, with the horizon and the pin
 * placed among them by RANK. The ticks make the point, so the readout is one
 * line and the explanation is in the guide.
 *
 * **What it does when it does not know.** The ticks are read off the account
 * on screen (`useBookCommits`), so a fresh page or an account never written
 * to leaves the rail with two points and nothing between them — and it draws
 * the break rather than interpolating a scale it has no basis for.
 *
 * Both standing rules are unchanged: the horizon advances only on an answer
 * that supplied NO cursor, and pinning is explicit.
 */
export function CursorRail({
  horizon,
  pinned,
  book,
  busy,
  onRefresh,
  onUnpin,
}: {
  horizon: Horizon | null;
  pinned: string | null;
  book: BookCommits;
  busy: boolean;
  onRefresh: () => void;
  onUnpin: () => void;
}) {
  const commits = book.commits;
  const apart =
    horizon && pinned ? commitsBetween(commits, pinned, horizon.cursor) : null;

  return (
    <section
      aria-label="Cursor rail"
      className="border-y border-rule bg-surface px-4 py-2.5 sm:px-6"
    >
      <div className="mx-auto flex max-w-[110rem] flex-col gap-2">
        <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
          {/* One line, and the ticks below it carry the rest. */}
          <p className="flex flex-wrap items-baseline gap-x-2 text-[0.72rem] text-dim">
            <Mono className="text-ink">
              {commits.length} commit{commits.length === 1 ? "" : "s"}
            </Mono>
            <span className="text-line">·</span>
            <span className="inline-flex items-baseline gap-1.5">
              <span className="size-2 shrink-0 self-center bg-peach" aria-hidden />
              horizon
              <Mono className="text-peach">
                {horizon?.cursor ?? "not observed"}
              </Mono>
            </span>
            <span className="text-line">·</span>
            <span className="inline-flex items-baseline gap-1.5">
              <span className="size-2 shrink-0 self-center bg-ok" aria-hidden />
              {pinned === null ? (
                "nothing pinned"
              ) : (
                <>
                  pinned <Mono className="text-ok">{pinned}</Mono>
                </>
              )}
            </span>
            {apart === null ? null : (
              <>
                <span className="text-line">·</span>
                <span>
                  {apart.commits === 0 && !apart.atLeast ? (
                    "at the horizon"
                  ) : (
                    <>
                      {apart.atLeast ? "≥" : ""}
                      <Mono className="text-ink">{apart.commits}</Mono>{" "}
                      {apart.behind ? "back" : "ahead"}
                    </>
                  )}
                </span>
              </>
            )}
            {horizon?.regressed === true ? (
              <>
                <span className="text-line">·</span>
                <span className="text-credit">horizon regressed</span>
              </>
            ) : null}
          </p>

          <div className="flex items-center gap-2">
            <GuideLink>the cursor</GuideLink>
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
              {busy ? "Reading…" : "Refresh the horizon"}
            </Button>
          </div>
        </div>

        {commits.length === 0 ? (
          <TwoPointsAndNothingBetween
            horizon={horizon}
            pinned={pinned}
            because={book.unknownBecause}
            busy={book.busy}
          />
        ) : (
          <Sequence commits={commits} horizon={horizon} pinned={pinned} />
        )}

      </div>
    </section>
  );
}

/**
 * The ticks, and the two marks placed among them.
 *
 * Ordinal space, not value space: tick `i` of `n` sits at `(i + 0.5) / n`, a
 * mark that IS one of the commits sits on that tick, and a mark that falls
 * between two of them sits on the boundary between them — drawn as being
 * between, because that is what is known about it.
 */
function Sequence({
  commits,
  horizon,
  pinned,
}: {
  commits: readonly string[];
  horizon: Horizon | null;
  pinned: string | null;
}) {
  const n = commits.length;
  const horizonAt = horizon ? placeAmong(commits, horizon.cursor) : null;
  const pinnedAt = pinned ? placeAmong(commits, pinned) : null;

  const where = (at: { rank: number; onATick: boolean }) =>
    at.onATick ? (at.rank - 0.5) / n : at.rank / n;

  /**
   * What is true about a mark that is not one of the ticks. "Between two
   * commits" is only right when there ARE two: a cursor past the newest
   * commit this rail read is past the end of what is drawn, and that is a
   * different statement — usually the ordinary one, because the horizon is
   * the cluster's and the ticks are one account's.
   */
  const say = (mark: string, at: { rank: number; onATick: boolean }) => {
    if (at.onATick) return mark;
    if (at.rank === 0) return `${mark} · older than every commit drawn`;
    if (at.rank === n) return `${mark} · past every commit drawn`;
    return `${mark} · between two commits`;
  };

  const litByHorizon = horizonAt?.onATick === true ? horizonAt.rank - 1 : -1;
  const litByPin = pinnedAt?.onATick === true ? pinnedAt.rank - 1 : -1;

  return (
    <div className="relative h-16 select-none" aria-hidden>
      <div className="absolute inset-x-0 top-8 h-px bg-rule" />
      {commits.map((commit, index) => (
        <span
          key={commit}
          title={commit}
          className={`absolute top-[1.6rem] block h-3 w-px -translate-x-1/2 ${
            index === litByHorizon
              ? "bg-peach"
              : index === litByPin
                ? "bg-ok"
                : "bg-line"
          }`}
          style={{ left: `${(((index + 0.5) / n) * 100).toFixed(4)}%` }}
        />
      ))}
      {horizonAt && horizon ? (
        <Mark
          at={where(horizonAt)}
          tone="peach"
          label={say("horizon", horizonAt)}
          value={horizon.cursor}
          placement="above"
        />
      ) : null}
      {pinnedAt && pinned ? (
        <Mark
          at={where(pinnedAt)}
          tone="ok"
          label={say("pinned", pinnedAt)}
          value={pinned}
          placement="below"
        />
      ) : null}
    </div>
  );
}

/**
 * The honest degenerate state: two cursors, and no commit of this book known
 * to sit between them.
 *
 * The old rail drew a scale here and put the two marks wherever arithmetic
 * on cluster-global counters happened to land them. There is nothing to
 * scale, so nothing is scaled: the break between the two points is drawn as
 * a break, and the sentence says which read would fill it in.
 */
function TwoPointsAndNothingBetween({
  horizon,
  pinned,
  because,
  busy,
}: {
  horizon: Horizon | null;
  pinned: string | null;
  because: string | null;
  busy: boolean;
}) {
  const known: { tone: "peach" | "ok"; label: string; value: string }[] = [];
  if (pinned !== null && (horizon === null || isBehind(pinned, horizon.cursor))) {
    known.push({ tone: "ok", label: "pinned", value: pinned });
  }
  if (horizon !== null) {
    known.push({ tone: "peach", label: "horizon", value: horizon.cursor });
  }
  if (pinned !== null && horizon !== null && !isBehind(pinned, horizon.cursor)) {
    known.push({ tone: "ok", label: "pinned", value: pinned });
  }

  return (
    <div className="flex min-h-16 flex-wrap items-center gap-x-3 gap-y-2 border border-dashed border-rule px-3 py-2">
      {known.length === 0 ? (
        <p className="text-[0.75rem] text-dim">
          No commit position observed yet.
        </p>
      ) : (
        <>
          {known.map((point, index) => (
            <span key={point.label} className="flex items-center gap-3">
              {index === 0 ? null : (
                <span className="flex items-center gap-1.5">
                  <span
                    className="block h-px w-10 sm:w-16"
                    style={{
                      backgroundImage:
                        "repeating-linear-gradient(90deg,var(--line) 0 3px,transparent 3px 7px)",
                    }}
                    aria-hidden
                  />
                  <span className="text-[0.66rem] text-dim">
                    nothing known between
                  </span>
                  <span
                    className="block h-px w-10 sm:w-16"
                    style={{
                      backgroundImage:
                        "repeating-linear-gradient(90deg,var(--line) 0 3px,transparent 3px 7px)",
                    }}
                    aria-hidden
                  />
                </span>
              )}
              <span className="flex items-baseline gap-2">
                <span
                  className={`inline-block size-2 shrink-0 ${
                    point.tone === "peach" ? "bg-peach" : "bg-ok"
                  }`}
                  aria-hidden
                />
                <Mono
                  className={`text-[0.78rem] ${
                    point.tone === "peach" ? "text-peach" : "text-ok"
                  }`}
                >
                  {point.value}
                </Mono>
                <span className="text-[0.62rem] tracking-wide text-dim">
                  {point.label}
                </span>
              </span>
            </span>
          ))}
        </>
      )}
      <p className="max-w-prose text-[0.68rem] leading-snug text-dim">
        {busy ? "Reading…" : because}
      </p>
    </div>
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
      style={{ left: `${(at * 100).toFixed(4)}%` }}
    >
      <div className="relative -translate-x-1/2">
        <span
          className={`absolute top-4 left-0 block h-7 w-px ${colour}`}
          aria-hidden
        />
        <span
          className={`absolute top-[1.85rem] left-0 block size-[7px] -translate-x-[3px] ${colour}`}
          aria-hidden
        />
        {/* The label is pulled back by the mark's own position rather than by
            half its width: centred in the middle of the rail, flush left at
            the start and flush right at the end. A mark at 100% with a
            centred label hangs its caption off the right of the document and
            gives the whole page a horizontal scrollbar. */}
        <span
          className={`absolute ${
            placement === "above" ? "top-0" : "top-11"
          } left-0 flex flex-col whitespace-nowrap ${
            at > 0.66 ? "items-end" : at < 0.34 ? "items-start" : "items-center"
          }`}
          style={{ transform: `translateX(${(-at * 100).toFixed(2)}%)` }}
        >
          <Mono className={`text-[0.68rem] ${text}`}>{value}</Mono>
          <span className="text-[0.58rem] tracking-wide text-dim">{label}</span>
        </span>
      </div>
    </div>
  );
}
