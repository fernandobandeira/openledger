import path from "node:path";
import { fileURLToPath } from "node:url";

import type { NextConfig } from "next";

/**
 * The ledger the browser talks to.
 *
 * `openledger serve` binds 127.0.0.1:8080 by default and carries **no CORS
 * layer** — deliberately, and one is not coming (ADR-0017: the service is
 * internal-only and there is no auth story for a browser origin to sit
 * behind). So the dashboard never calls the ledger cross-origin: it proxies
 * `/v1/*` through its own server, and every request the browser makes is
 * same-origin.
 */
const ledgerOrigin =
  process.env.OPENLEDGER_API_ORIGIN?.replace(/\/+$/, "") ?? "http://127.0.0.1:8080";

const nextConfig: NextConfig = {
  // Pinned rather than inferred: Turbopack walks up looking for a lockfile,
  // and this app sits inside a Cargo workspace whose root carries none — so
  // without this it reaches for whatever lockfile it finds outside the repo.
  turbopack: { root: path.dirname(fileURLToPath(import.meta.url)) },

  async rewrites() {
    return [{ source: "/v1/:path*", destination: `${ledgerOrigin}/v1/:path*` }];
  },
};

export default nextConfig;
