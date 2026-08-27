# site/ — the docs viewer

A [Nextra 4](https://nextra.site) site that renders this repository's own markdown. It adds
navigation, search and a reading layout; it does not add content.

## Where the words live

`docs/`, the root `README.md`, and each `spikes/*/README.md` are **the source of truth**. Edit
those. `site/content/` is **generated and gitignored** — `scripts/sync.mjs` rebuilds it from
scratch on every run, so anything written there is lost.

What the sync does:

- copies each markdown file to a site route, adding only a `title` frontmatter;
- rewrites relative links (`../../migrations/00001_baseline.sql`) to site routes;
- **de-links** repository files the site does not publish — a spike's `schema.sql`, the
  `LICENSE` — keeping the link text and dropping the dead href, because a relative path served
  from a static host is a 404 the reader cannot see coming. Each run prints the list, which is
  how you notice a file has become worth publishing;
- renders four source files (`migrations/00001_baseline.sql`, `schema/chart.sql`,
  `parked/card/schema.sql`, `src/*.rs`) as their own fenced-code pages;
- copies `docs/diagrams/` into `public/diagrams/`;
- writes the `_meta.js` files that order the sidebar.

Content is emitted as `.md`, never `.mdx`, **on purpose**: the repository's prose contains
`Option<i64>` and `<table>_<column>_not_null`, which MDX would try to parse as JSX. Keep it that
way.

## Running it

```
npm install
npm run dev      # sync + next dev
npm run build    # sync + static export to out/ + pagefind index
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
excludes code from the index by default, which here meant the migration was unsearchable on its
own identifiers.

The index is built from `out/`, so **search does not work under `npm run dev`** — the box is
there and returns nothing. Use `npm run build && npm start` to try it.

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
scripts/sync.mjs      renders the 5 source-code pages into content/source/
content/              THE DOCUMENTATION. Committed, and the source of truth.
                      Only content/source/ is generated.
public/diagrams/      the SVGs the documents embed.
```
