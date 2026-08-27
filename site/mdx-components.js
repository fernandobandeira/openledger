import { useMDXComponents as themeComponents } from 'nextra-theme-docs'

/** The text a node renders, flattened, so a component can read its own lead. */
function textOf(node) {
  if (node == null || typeof node === 'boolean') return ''
  if (typeof node === 'string' || typeof node === 'number') return String(node)
  if (Array.isArray(node)) return node.map(textOf).join('')
  if (node.props) return textOf(node.props.children)
  return ''
}

// The documents use a blockquote for two different things, and telling them
// apart is the whole point. A defect the design CAUGHT is evidence the design
// works. A STILL OPEN one is a hole. Rendered identically -- which is what a
// plain markdown blockquote does -- a hardened schema reads as a fragile one,
// because the eye counts alarm-coloured boxes and does not read the first word.
//
// The classification is done here rather than in the markdown because the
// markdown is the deliverable and must stay portable: it says `**CAUGHT --**`
// in bold, which is legible in a diff, on GitHub, and in a terminal. This
// reads that same first word and colours it.
const CAUGHT = /^\s*CAUGHT\b/i
const GAP = /^\s*(STILL OPEN|OPEN|GAP|NOT ENFORCED|WHAT (IT|THEY) DO(ES)? NOT)/i

function Blockquote({ children, className, ...rest }) {
  const lead = textOf(children).trimStart().slice(0, 40)
  const kind = CAUGHT.test(lead) ? 'ol-caught' : GAP.test(lead) ? 'ol-gap' : ''
  return (
    <blockquote {...rest} className={['ol-note', kind, className].filter(Boolean).join(' ')}>
      {children}
    </blockquote>
  )
}

export function useMDXComponents(components) {
  return { ...themeComponents(), blockquote: Blockquote, ...components }
}
