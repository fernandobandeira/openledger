// Click-to-fullscreen for a rendered diagram, with scroll-to-zoom and drag-to-pan.
//
// `mermaid-component.jsx` renders the diagram to an SVG string at build time
// (server, no client JS). This thin client wrapper is the ONLY interactive part:
// it inlines that same SVG, and on click opens it in a fullscreen overlay you
// can zoom (wheel, toward the cursor) and pan (drag). The SVG is already in the
// static HTML, so there is no flash and nothing is fetched — hydration only
// attaches the handlers.
'use client'
import { useState, useEffect, useRef, useCallback } from 'react'

const MIN = 0.4
const MAX = 12

export function MermaidZoom({ html }) {
  const [open, setOpen] = useState(false)
  const [view, setView] = useState({ s: 1, x: 0, y: 0 })
  const drag = useRef(null)
  const moved = useRef(false)

  const close = useCallback(() => {
    setOpen(false)
    setView({ s: 1, x: 0, y: 0 })
  }, [])

  useEffect(() => {
    if (!open) return
    const onKey = (e) => e.key === 'Escape' && close()
    document.addEventListener('keydown', onKey)
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.removeEventListener('keydown', onKey)
      document.body.style.overflow = prev
    }
  }, [open, close])

  // Wheel zooms toward the cursor: the content point under the pointer stays put.
  const onWheel = (e) => {
    e.preventDefault()
    const r = e.currentTarget.getBoundingClientRect()
    const cx = e.clientX - r.left - r.width / 2
    const cy = e.clientY - r.top - r.height / 2
    setView((p) => {
      const s = Math.min(MAX, Math.max(MIN, p.s * (e.deltaY < 0 ? 1.15 : 1 / 1.15)))
      const k = s / p.s
      return { s, x: cx - (cx - p.x) * k, y: cy - (cy - p.y) * k }
    })
  }

  const onPointerDown = (e) => {
    moved.current = false
    drag.current = { x: e.clientX, y: e.clientY }
    e.currentTarget.setPointerCapture?.(e.pointerId)
  }
  const onPointerMove = (e) => {
    if (!drag.current) return
    const dx = e.clientX - drag.current.x
    const dy = e.clientY - drag.current.y
    if (Math.abs(dx) + Math.abs(dy) > 3) moved.current = true
    drag.current = { x: e.clientX, y: e.clientY }
    setView((p) => ({ ...p, x: p.x + dx, y: p.y + dy }))
  }
  const onPointerUp = () => {
    drag.current = null
  }

  return (
    <>
      <div
        className="ol-mermaid"
        role="button"
        tabIndex={0}
        aria-label="Enlarge diagram"
        title="Click to enlarge"
        onClick={() => setOpen(true)}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault()
            setOpen(true)
          }
        }}
        dangerouslySetInnerHTML={{ __html: html }}
      />
      {open && (
        <div
          className="ol-mermaid-overlay"
          role="dialog"
          aria-modal="true"
          onClick={() => {
            if (!moved.current) close()
          }}
          onWheel={onWheel}
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerUp}
        >
          <button
            className="ol-mermaid-close"
            aria-label="Close"
            onClick={(e) => {
              e.stopPropagation()
              close()
            }}
          >
            ×
          </button>
          <div className="ol-mermaid-hint">scroll to zoom · drag to pan · Esc to close</div>
          <div
            className="ol-mermaid-stage"
            style={{ transform: `translate(${view.x}px, ${view.y}px) scale(${view.s})` }}
            dangerouslySetInnerHTML={{ __html: html }}
          />
        </div>
      )}
    </>
  )
}
