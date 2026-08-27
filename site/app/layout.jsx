import { Footer, Layout, Navbar } from 'nextra-theme-docs'
import { Head } from 'nextra/components'
import { getPageMap } from 'nextra/page-map'
import 'nextra-theme-docs/style.css'
import './theme.css'

export const metadata = {
  title: {
    default: 'openledger',
    template: '%s — openledger'
  },
  description:
    'An open-source double-entry ledger. Postgres for storage, Rust for the service. ' +
    'Every decision, its evidence, and what it costs.'
}

const navbar = (
  <Navbar
    logo={
      <span className="ol-logo">
        <b>openledger</b>
        <span className="ol-logo-sub">a double-entry ledger, decided in the open</span>
      </span>
    }
  />
)

const footer = (
  <Footer>
    <span>
      MIT. Every page here is a file in the repository — the markdown is the deliverable,
      this site is a viewer over it.
    </span>
  </Footer>
)

export default async function RootLayout({ children }) {
  return (
    <html lang="en" dir="ltr" suppressHydrationWarning>
      <Head
        color={{ hue: 210, saturation: 65 }}
        backgroundColor={{ light: '#f4f6f8', dark: '#0f141a' }}
      />
      <body>
        <Layout
          navbar={navbar}
          footer={footer}
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
