import { GeistSans } from 'geist/font/sans'
import { GeistMono } from 'geist/font/mono'
import { Layout, Navbar } from 'nextra-theme-docs'
import { Head } from 'nextra/components'
import { getPageMap } from 'nextra/page-map'
import 'nextra-theme-docs/style.css'
import './theme.css'

export const metadata = {
  title: {
    default: 'OpenLedger',
    template: '%s — OpenLedger'
  },
  description:
    'An open-source double-entry ledger. Postgres for storage, Rust for the service. ' +
    'Every decision, its evidence, and what it costs.'
}

const navbar = <Navbar logo={<b className="ol-logo">OpenLedger</b>} />


export default async function RootLayout({ children }) {
  return (
    /* The three families `theme.css` asked for -- IBM Plex Serif, Sans and Mono
       -- were named and never loaded: no `next/font`, no `<link>`, no
       `@font-face`. Every reader without them installed locally has been seeing
       Georgia and system-ui. Geist is self-hosted by the package, so the static
       export stays a directory of plain files with no network fetch at runtime. */
    <html
      lang="en"
      dir="ltr"
      className={`${GeistSans.variable} ${GeistMono.variable}`}
      suppressHydrationWarning
    >
      {/* The palette is Vesper's, read off the theme itself rather than guessed:
          `#FFC799` is its link/focus colour and `#101010` its editor background,
          which is a true neutral black -- zero chroma -- and the reason the site
          no longer reads blue. Light mode is invented; Vesper is dark-only. */}
      <Head
        color={{
          hue: { light: 24, dark: 27 },
          saturation: { light: 85, dark: 100 },
          lightness: { light: 40, dark: 80 }
        }}
        backgroundColor={{ light: '#fffdfa', dark: '#101010' }}
      />
      <body>
        <Layout
          navbar={navbar}
          pageMap={await getPageMap()}
          // There is no public repository to edit against or file issues in, so
          // the theme's two default GitHub links -- which point at Nextra's own
          // repo -- are removed rather than left pointing somewhere wrong.
          editLink={null}
          feedback={{ content: null }}
          sidebar={{ defaultMenuCollapseLevel: 2, autoCollapse: false }}
          toc={{ title: 'On this page', backToTop: 'Back to top' }}
        >
          {children}
        </Layout>
      </body>
    </html>
  )
}
