/**
 * The cursor: an `xid8`, which is a 64-bit unsigned commit position, carried
 * on the wire as a decimal string because JSON numbers cannot hold one
 * exactly. Everything here is `BigInt` for the same reason.
 *
 * The rail scales to the values actually observed rather than to the type's
 * range: 0…2^64 would put every real cursor on the same pixel.
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

/** How many commits apart two cursors are, as a string. `null` if unreadable. */
export function commitsBetween(from: string, to: string): string | null {
  const a = toCursorBigInt(from);
  const b = toCursorBigInt(to);
  if (a === null || b === null) return null;
  const gap = b > a ? b - a : a - b;
  return gap.toString();
}

export function isBehind(candidate: string, reference: string): boolean {
  const a = toCursorBigInt(candidate);
  const b = toCursorBigInt(reference);
  return a !== null && b !== null && a < b;
}

export interface Rail {
  low: bigint;
  high: bigint;
  /** 0 at the left end of the rail, 1 at the right. */
  place(cursor: string): number | null;
}

/**
 * A rail over the observed cursors, padded so the outermost mark is not
 * welded to the edge. One observation, or several identical ones, gives a rail
 * with no span — every mark then sits in the middle, which is the truth.
 */
export function railOver(observed: readonly string[]): Rail | null {
  const values: bigint[] = [];
  for (const value of observed) {
    const parsed = toCursorBigInt(value);
    if (parsed !== null) values.push(parsed);
  }
  if (values.length === 0) return null;

  let low = values[0];
  let high = values[0];
  for (const value of values) {
    if (value < low) low = value;
    if (value > high) high = value;
  }

  const span = high - low;
  const padding = span === 0n ? 0n : span / 8n + 1n;
  const paddedLow = low > padding ? low - padding : 0n;
  const paddedHigh = high + padding;
  const paddedSpan = paddedHigh - paddedLow;

  return {
    low: paddedLow,
    high: paddedHigh,
    place(cursor: string): number | null {
      const parsed = toCursorBigInt(cursor);
      if (parsed === null) return null;
      if (paddedSpan === 0n) return 0.5;
      const clamped =
        parsed < paddedLow ? paddedLow : parsed > paddedHigh ? paddedHigh : parsed;
      // Ratio via scaled integer division — the operands are far past 2^53.
      const scaled = ((clamped - paddedLow) * 100000n) / paddedSpan;
      return Number(scaled) / 100000;
    },
  };
}
