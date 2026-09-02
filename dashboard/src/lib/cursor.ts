/**
 * The cursor: an `xid8`, which is a 64-bit unsigned commit position, carried
 * on the wire as a decimal string because JSON numbers cannot hold one
 * exactly. Everything here is `BigInt` for the same reason.
 *
 * **An `xid8` is an ORDER and not a MEASURE, and the difference is the whole
 * design of the rail.** `report_cursor()` is `pg_snapshot_xmin`, and the
 * counter it reads is *cluster-global*: the numbers between two of this
 * book's commits were spent on transactions in other databases, other
 * tenants, autovacuum. So `b - a` is a real number that answers no question
 * anyone has — plotting two cursors on a linear scale draws a distance that
 * does not exist, and a pin one commit back from the horizon lands on the
 * same pixel as the horizon whenever the cluster was busy in between.
 *
 * What is meaningful is the RANK of a cursor among this book's own commits:
 * how many commits of this book are at or below it. That is a count, it is
 * exact, and it is what the rail draws.
 */

const DIGITS = /^\d+$/;
const XID8_MAX = 18446744073709551615n;

export function isCursor(value: string): boolean {
  const trimmed = value.trim();
  if (!DIGITS.test(trimmed)) return false;
  return BigInt(trimmed) <= XID8_MAX;
}

export function toCursorBigInt(value: string): bigint | null {
  return isCursor(value) ? BigInt(value.trim()) : null;
}

export function isBehind(candidate: string, reference: string): boolean {
  const a = toCursorBigInt(candidate);
  const b = toCursorBigInt(reference);
  return a !== null && b !== null && a < b;
}

/**
 * The commit position out of a **recorded-axis** page key.
 *
 * `next_after` is documented on the wire as the last row's ordering key —
 * `xact_id` and entry id on the recorded axis — so this reads a field the
 * spec spells rather than reverse-engineering an opaque token. The effective
 * axis's key has three parts and leads with a business date in nanoseconds,
 * so a key of the wrong arity is refused here rather than read as far as it
 * parses; that is the same rule the server applies to a key sent back to it.
 */
export function commitOfRecordedKey(key: string): string | null {
  const parts = key.split(",");
  if (parts.length !== 2) return null;
  const commit = parts[0].trim();
  return isCursor(commit) ? commit : null;
}

/** Ascending, de-duplicated. Two entries of one batch share a commit. */
export function sortedDistinctCommits(commits: readonly string[]): string[] {
  const seen = new Map<string, bigint>();
  for (const commit of commits) {
    const parsed = toCursorBigInt(commit);
    if (parsed !== null) seen.set(parsed.toString(), parsed);
  }
  return [...seen.values()].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)).map(String);
}

/**
 * Where a cursor sits in a sequence of commits.
 *
 * `rank` is how many of them are at or below it — 0 when it is older than
 * every one, `commits.length` when it is at or past the newest. `onATick` is
 * true when the cursor IS one of them, which is the difference between "this
 * pin is that commit" and "this pin is somewhere between those two", and the
 * rail draws the two differently rather than rounding one into the other.
 */
export interface Placement {
  rank: number;
  onATick: boolean;
}

export function placeAmong(
  commits: readonly string[],
  cursor: string
): Placement | null {
  const value = toCursorBigInt(cursor);
  if (value === null) return null;
  let rank = 0;
  let onATick = false;
  for (const commit of commits) {
    const at = toCursorBigInt(commit);
    if (at === null || at > value) break;
    rank += 1;
    onATick = at === value;
  }
  return { rank, onATick };
}

/**
 * How many of this book's commits separate two cursors — a COUNT of commits,
 * never a difference of `xid8` values.
 *
 * `atLeast` is true when either end is not itself one of the known commits,
 * because then the answer is a floor: this dashboard knows the commits it has
 * read, and a book has commits it has not.
 */
export interface Separation {
  commits: number;
  atLeast: boolean;
  /** True when `pin` is older than `horizon`. */
  behind: boolean;
}

export function commitsBetween(
  commits: readonly string[],
  pin: string,
  horizon: string
): Separation | null {
  const at = placeAmong(commits, pin);
  const to = placeAmong(commits, horizon);
  if (at === null || to === null) return null;
  return {
    commits: Math.abs(to.rank - at.rank),
    atLeast: !at.onATick || !to.onATick,
    behind: isBehind(pin, horizon),
  };
}
