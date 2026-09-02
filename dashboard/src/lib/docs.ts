/**
 * Where the prose lives now.
 *
 * The page used to carry the explanations: a paragraph under the rail, one
 * under the axis toggle, one under every field. `site/content/bookings.md` is
 * the guide that teaches all of it properly and at length, so the page shows
 * and the guide explains. What is left here is a link, put where a reader
 * would otherwise have wanted the paragraph.
 *
 * The docs site and this app are different Next apps. Served from one origin
 * the default path is already right; otherwise name the docs origin in
 * `NEXT_PUBLIC_OPENLEDGER_DOCS_ORIGIN`.
 */
const origin = (
  process.env.NEXT_PUBLIC_OPENLEDGER_DOCS_ORIGIN ?? ""
).replace(/\/+$/, "");

/** `Booking a payment` — the guide this page used to try to be. */
export function guide(): string {
  return `${origin}/bookings`;
}
