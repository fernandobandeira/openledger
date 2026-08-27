// The renderer for every ```mermaid fence, in place of Nextra's default.
//
// Nextra's `@theguild/remark-mermaid` rewrites each mermaid fence into
// `<Mermaid chart="…"/>` and hard-imports `Mermaid` from
// `@theguild/remark-mermaid/mermaid`. `next.config.mjs` aliases that specifier
// to this file, so the compiled JSX binds `Mermaid` here. There is no
// 'use client': this is a server component, so `renderMermaidSVG` runs during
// the static export and the finished SVG is baked into the HTML -- no client
// JavaScript, no mermaid bundle, no hydration flash. beautiful-mermaid's
// renderer is synchronous and DOM-free, which is what makes that possible.
//
// The `chart` prop arrives with newlines encoded as the two characters `\n`
// (remark-mermaid does `value.replaceAll('\n', '\\n')`), so it is decoded back
// to real newlines first -- the same thing @theguild's own component does.
import { renderMermaidSVG } from 'beautiful-mermaid'

// Colours are passed as CSS-variable references. beautiful-mermaid writes them
// onto the SVG's own `style` attribute, so the one SVG inherits whatever
// `--ol-mm-*` resolves to on the page (defined in `app/theme.css`, from Vesper's
// palette). No colours are baked in.
const OPTS = {
  bg: 'var(--ol-mm-bg)',
  fg: 'var(--ol-mm-fg)',
  line: 'var(--ol-mm-line)',
  accent: 'var(--ol-mm-accent)',
  muted: 'var(--ol-mm-muted)',
  surface: 'var(--ol-mm-surface)',
  border: 'var(--ol-mm-border)',
  // No background rect: the diagram sits on the page's own ground.
  transparent: true
}

// beautiful-mermaid always emits `@import url('https://fonts.googleapis.com/…')`
// for its label font. This site is a static export that deliberately fetches
// nothing at runtime (`app/layout.jsx` self-hosts Geist for exactly this
// reason), so the import is stripped and the SVG's text is pointed at the site's
// own font variables.
function localiseFonts(svg) {
  return svg
    .replace(/\s*@import url\('https:\/\/fonts\.googleapis\.com[^']*'\);/g, '')
    .replace(/font-family:\s*'[^']*',\s*system-ui,\s*sans-serif;/g, 'font-family: var(--ol-sans);')
    .replace(/font-family:\s*'JetBrains Mono'[^;]*;/g, 'font-family: var(--ol-mono);')
}

export function Mermaid({ chart }) {
  const source = String(chart).replaceAll('\\n', '\n')
  try {
    const svg = localiseFonts(renderMermaidSVG(source, OPTS))
    return (
      <div
        className="ol-mermaid"
        role="img"
        dangerouslySetInnerHTML={{ __html: svg }}
      />
    )
  } catch (error) {
    // A diagram beautiful-mermaid cannot render must never break the build:
    // fall back to the diagram source as a plain code block.
    console.warn(`[beautiful-mermaid] could not render a diagram: ${error.message}`)
    return (
      <pre className="ol-mermaid-fallback">
        <code>{source}</code>
      </pre>
    )
  }
}
