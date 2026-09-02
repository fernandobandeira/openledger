import { ArrowUpRightIcon } from "lucide-react";

import { guide } from "@/lib/docs";

/**
 * One line out to the guide, in place of the paragraph that used to be here.
 * Unobtrusive by design: it is a footnote marker, not a banner.
 */
export function GuideLink({ children }: { children: string }) {
  return (
    <a
      href={guide()}
      target="_blank"
      rel="noreferrer"
      className="inline-flex items-baseline gap-0.5 text-[0.68rem] text-dim underline decoration-dotted underline-offset-2 hover:text-peach"
    >
      {children}
      <ArrowUpRightIcon className="size-2.5 self-center" aria-hidden />
    </a>
  );
}
