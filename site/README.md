# site/ — the docs viewer

A [Nextra 4](https://nextra.site) site that renders this repository's own markdown. It adds
navigation, search and a reading layout; it does not add content.

## Where the words live

`site/content/` **is** the documentation and every file under it is committed. Edit it directly;
nothing here is generated.

Pages are `.md`, never `.mdx`, **on purpose**: the prose contains
`Option<i64>` and `<table>_<column>_not_null`, which MDX would try to parse as JSX. Keep it that
way.

## Running it

```
npm install
npm run dev      # next dev
npm run build    # static export to out/ + pagefind index
npm start        # serve out/
```

`npm run build` is a static export (`output: 'export'`): `out/` is plain files. Publish by
copying `out/` to any static host — GitHub Pages, S3, Netlify, `python3 -m http.server` from
inside it. `public/.nojekyll` is emitted because GitHub Pages otherwise drops the `_next/` and
`_pagefind/` directories. No server, no runtime, no database.

## Search

Nextra 4's search box is a [Pagefind](https://pagefind.app) client that fetches an index from
`/_pagefind/`. Without that index the box renders and finds nothing, so `npm run build` runs
`pagefind --site out --output-subdir _pagefind` after the export — that is the only reason
`pagefind` is a dependency. `next.config.mjs` sets `search: { codeblocks: true }`; Nextra
excludes code from the index by default.

The index is built from `out/`, so **search does not work under `npm run dev`** — the box is
there and returns nothing. Use `npm run build && npm start` to try it.

## The API reference

`/api-reference/` is the one page that is not markdown: a single self-contained HTML rendering
`crates/api/openapi.json` with Redoc. `scripts/api-reference.mjs` regenerates it into
`public/api-reference/` (gitignored) at the front of both `npm run dev` and `npm run build`, with
the spec **and** the pinned viewer bundle inlined — no CDN, no fetch, renders from `file://`. The
spec is read from the one committed copy the api crate's snapshot test owns, so the page cannot go
stale without the Pages workflow redeploying it (`pages.yml` triggers on the spec path too).

## The one version constraint

Every package here is on its latest release. **`zod` is the exception, held below 4.4** by an
override in `package.json`.

`nextra-theme-docs`'s `Layout` destructures `children` out of its props and then validates what is
left against a schema that still declares `children` as required. Until zod 4.3 that was harmless —
`z.custom()` let a missing key through. zod 4.4 made it an error, so on 4.4+ **every page** throws
`Invalid input: expected nonoptional, received undefined` at render.

Nextra 4.5.1 escaped it by pinning zod to an exact beta; 4.6.1 loosened that to `^4.1.12`, which is
what exposed the bug. Holding zod at `<4.4` lets us run the current Nextra. Measured: zod 4.1.12,
4.2.1 and 4.3.0 all work, 4.4.3 does not. Drop the override once Nextra's schema stops requiring a
prop its own component removes.

## Layout of this directory

```
app/layout.jsx        navbar, footer, theme tokens, Layout options
app/theme.css         the only styling this site adds on top of the theme
app/[[...mdxPath]]/   the catch-all that renders a content page
mdx-components.js     blockquote classification (CAUGHT vs STILL OPEN callouts)
scripts/              api-reference.mjs: regenerates the API reference page into
                      public/api-reference/ on every dev run and build.
content/              THE DOCUMENTATION. Committed, and the source of truth.
```
