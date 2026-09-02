"use client";

import type { CSSProperties, ReactNode } from "react";
import { XIcon } from "lucide-react";

import { Button } from "@/components/ui/button";
import {
  Drawer,
  DrawerContent,
  DrawerDescription,
  DrawerTitle,
} from "@/components/ui/drawer";

/**
 * How wide a drawer opens, by what it holds.
 *
 * **A figure must never be the element that scrolls away**, and one width for
 * every drawer is what makes that happen: a balance sheet, a trial balance
 * and an income statement are wide artifacts, and squeezing them into the
 * width "open an account" needs pushes the amount column off the right edge
 * behind a horizontal scrollbar. The number is what a statement is for.
 *
 * `min(94vw, …)` rather than a breakpoint, because it is one value that is
 * already right on a phone: the drawer is the viewport less a thumb's worth
 * of the page behind it, or the width the artifact wants, whichever is
 * smaller.
 *
 * It is set as an inline style and not a class on purpose. The Base UI popup
 * declares `--drawer-content-width` under a `data-[swipe-axis=x]` selector,
 * which outranks any plain utility class of ours whatever the source order —
 * so a class here silently loses and the drawer opens at the primitive's own
 * 24rem. An inline style is the one place that argument cannot be had.
 */
export type DrawerWidth = "form" | "wide-form" | "statement" | "ledger";

const WIDTHS: Record<DrawerWidth, string> = {
  /** A handful of fields and their prose. */
  form: "min(94vw, 38rem)",
  /** Fields plus a leg list, or fields plus a small table. */
  "wide-form": "min(94vw, 50rem)",
  /** A face: captions down the left, figures down the right. */
  statement: "min(94vw, 54rem)",
  /** Seven columns, three of them figures. */
  ledger: "min(94vw, 68rem)",
};

/**
 * One composer form, in a drawer over the page.
 *
 * The forms did not change and neither did their copy: every field is still
 * spelled in the API's own names and every explanation is still under the
 * field it explains. What changed is where they live. Seven of them expanded
 * at once was a wall the page had to be scrolled past to reach the book, and
 * prose that teaches is worth keeping and not worth putting between an
 * operator and their entries — a drawer is where it can run at full length
 * without owning the page.
 *
 * The panel keeps its own heading, so this frame carries the port instead:
 * which side of the spine you are on, and what that costs. The accessible
 * name is the same title the panel prints, given here because a dialog needs
 * one before its content is read.
 *
 * `keepMounted` is deliberate. Closing a drawer is not abandoning the form:
 * the key you minted, the answer you got back and the id it carried are all
 * still there when you open it again.
 */
export function ComposerDrawer({
  open,
  onOpenChange,
  title,
  route,
  side,
  port,
  width,
  children,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  route: string;
  /** `Write` or `Read` — which port answers this. */
  side: string;
  /** What that port is, in one line. */
  port: string;
  /** How much room what is inside actually needs. */
  width: DrawerWidth;
  children: ReactNode;
}) {
  return (
    <Drawer open={open} onOpenChange={onOpenChange} swipeDirection="right">
      <DrawerContent
        keepMounted
        style={
          { "--drawer-content-width": WIDTHS[width] } as CSSProperties
        }
        className="border-l border-rule bg-ground text-ink"
      >
        <DrawerTitle className="sr-only">{title}</DrawerTitle>
        <DrawerDescription className="sr-only">{route}</DrawerDescription>

        <div className="flex shrink-0 flex-wrap items-baseline justify-between gap-x-4 gap-y-1 border-b border-rule px-5 py-3">
          <p className="flex flex-wrap items-baseline gap-x-3">
            <span className="text-[0.72rem] tracking-[0.14em] text-peach uppercase">
              {side}
            </span>
            <span className="text-[0.7rem] text-dim">{port}</span>
          </p>
          <Button
            variant="ghost"
            size="xs"
            onClick={() => onOpenChange(false)}
            aria-label={`Close ${title}`}
          >
            <XIcon aria-hidden /> Close
          </Button>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto px-5 py-4">
          {children}
        </div>
      </DrawerContent>
    </Drawer>
  );
}
