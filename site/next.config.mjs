import nextra from 'nextra'

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
  images: { unoptimized: true },
  trailingSlash: true,
  eslint: { ignoreDuringBuilds: true },
  typescript: { ignoreBuildErrors: true }
})
