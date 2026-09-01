import type { Metadata } from "next";
import { GeistSans } from "geist/font/sans";
import { GeistMono } from "geist/font/mono";

import "./globals.css";

export const metadata: Metadata = {
  title: "OpenLedger operator",
  description:
    "Open an account, post a transaction, and read the book back at a cursor you pinned.",
};

/**
 * Server component, so `metadata` above is allowed. Everything interactive
 * lives under `"use client"` in `<Dashboard>`; nothing here reads the URL, so
 * no Suspense boundary is owed.
 *
 * `class="dark"` is unconditional: the palette in `globals.css` is the docs
 * site's, Vesper has no light variant, and a toggle would promise one.
 */
export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`dark ${GeistSans.variable} ${GeistMono.variable} h-full antialiased`}
    >
      <body className="flex min-h-full flex-col">{children}</body>
    </html>
  );
}
