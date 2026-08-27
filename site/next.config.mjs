import path from 'node:path'
import { fileURLToPath } from 'node:url'
import nextra from 'nextra'

// Every ```mermaid fence renders through beautiful-mermaid (MIT) instead of
// Nextra's default. Nextra's own `@theguild/remark-mermaid` rewrites a mermaid
// fence into `<Mermaid chart="…"/>` and hard-imports that component from
// `@theguild/remark-mermaid/mermaid`; a `mdx-components.js` override can't touch
// it because the compiled JSX binds to that import, not to the MDX provider.
// So the interception is at the module level: this specifier is aliased to
// `mermaid-component.jsx`, whose `Mermaid` renders the diagram to an inline SVG
// with beautiful-mermaid's synchronous, DOM-free `renderMermaidSVG` at build
// time (it is a server component -- no 'use client' -- so the SVG is baked into
// the static export, with no client JS and no hydration flash).
//
// A resolveAlias/config alias stays a plain string, so it survives Turbopack's
// serializable-loader-options constraint that a remark-plugin function does not.
const MERMAID_SPECIFIER = '@theguild/remark-mermaid/mermaid'
const MERMAID_COMPONENT_ABS = fileURLToPath(new URL('./mermaid-component.jsx', import.meta.url))
// Turbopack's `resolveAlias` resolves its value relative to the project root
// (the same shape Nextra's own default for this key uses); webpack's alias wants
// an absolute path.
const MERMAID_COMPONENT_REL = './' + path.relative(process.cwd(), MERMAID_COMPONENT_ABS)

// GitHub Pages serves a project site under /<repo>, so ONLY the Pages build sets
// this basePath (the deploy workflow exports GITHUB_PAGES=true). Local `npm run
// dev` and a plain `npm run build` leave it unset and stay at the root.
const basePath = process.env.GITHUB_PAGES === 'true' ? '/openledger' : undefined

const withNextra = nextra({
  defaultShowCopyCode: true,
  // Index code blocks. Four of these pages ARE code -- the migration, the chart,
  // the parked card DDL, the migrator -- and Nextra's default marks every code
  // block `data-pagefind-ignore`, which made searching for `uq_entries__account_seq`
  // return the prose that mentions it and not the file that defines it.
  search: { codeblocks: true },
  // The repo's own markdown, unmodified apart from link rewriting, is the input.
  contentDirBasePath: '/',
  // Vesper ships with Shiki, so this costs nothing to load. It is the source of
  // the site's palette rather than a decoration on top of it: `app/layout.jsx`
  // takes its accent from Vesper's own link colour, so prose and code agree.
  // Vesper has no light variant; `vitesse-light` is the warm neutral that pairs
  // with it. Nextra passes `keepBackground: false`, so these set token colours
  // only -- the block's own background stays the docs theme's.
  mdxOptions: {
    rehypePrettyCodeOptions: {
      theme: { light: 'vitesse-light', dark: 'vesper' }
    }
  }
})

export default withNextra({
  // A static export: `npm run build` produces `out/`, which is a directory of
  // plain files anyone can host or open. No server, no runtime.
  output: 'export',
  ...(basePath ? { basePath } : {}),
  images: { unoptimized: true },
  trailingSlash: true,
  eslint: { ignoreDuringBuilds: true },
  typescript: { ignoreBuildErrors: true },

  // Point Nextra's mermaid import at our beautiful-mermaid renderer. Nextra
  // spreads a user `turbopack.resolveAlias` in AFTER its own default for this
  // key (see `nextra/dist/server/index.js`), so this override wins. The build
  // uses Turbopack; the webpack alias below keeps `next build --webpack` working
  // too.
  turbopack: {
    resolveAlias: {
      [MERMAID_SPECIFIER]: MERMAID_COMPONENT_REL
    }
  },
  webpack(config) {
    config.resolve.alias[MERMAID_SPECIFIER] = MERMAID_COMPONENT_ABS
    return config
  }
})
