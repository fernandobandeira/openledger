// Build public/api-reference/index.html: the OpenAPI spec, navigable.
//
// The page is one SELF-CONTAINED file — the spec AND the Redoc viewer are both
// inlined, so it makes zero network requests and renders from any static host
// or a bare file:// open. Spike 021 settled the two choices repeated here:
// inline the spec rather than fetch it (a fetch is one CORS rule, one basePath
// change or one file:// preview away from an empty shell), and Redoc over
// Scalar (1.10 MB vs 3.80 MB for the same page). The spike stopped at a CDN
// <script>; this vendors the same pinned bundle from node_modules instead, so
// the rendered page cannot change without a commit.
//
// The spec is read from crates/api/openapi.json — the ONE committed copy,
// which `cargo test -p api --test spec` holds against the annotations. This
// script runs on every `npm run dev` / `npm run build` (package.json), so the
// published page can never serve a spec the repo does not carry. Nothing is
// hand-maintained here; the output is gitignored.

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const at = (p) => fileURLToPath(new URL(p, import.meta.url))
const SPEC = at('../../crates/api/openapi.json')
const BUNDLE = at('../node_modules/redoc/bundles/redoc.standalone.js')
const OUT = at('../public/api-reference/index.html')

// `</` inside a <script> block can end it (`</script` does; nothing else).
// The spec is data, so every `</` is escaped — valid JSON either way. The
// viewer bundle is CODE, where a blind replace could break a regex or a
// comparison, so it is inlined verbatim and ASSERTED clean instead: the
// pinned 2.5.3 bundle contains no `</script`, and a future bump that does
// must fail this build, not silently truncate the page.
const spec = JSON.stringify(JSON.parse(readFileSync(SPEC, 'utf8'))).replaceAll('</', '<\\/')
const bundle = readFileSync(BUNDLE, 'utf8')
if (/<\/script/i.test(bundle)) {
  throw new Error('redoc.standalone.js contains "</script" — it can no longer be inlined verbatim')
}

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenLedger API reference</title>
<style>
  body { margin: 0; }
  /* The one addition over Redoc's own chrome: a way back to the docs. The
     href is relative because the docs root is "/" locally and "/openledger/"
     on GitHub Pages — from /api-reference/, "../" is both. */
  .back { display: block; padding: .5rem 1rem; font: 13px/1.4 system-ui, sans-serif;
          color: #666; background: #fafafa; border-bottom: 1px solid #e5e5e5;
          text-decoration: none; }
  .back:hover { color: #111; }
</style>
</head>
<body>
<a class="back" href="../">&larr; OpenLedger docs</a>
<div id="redoc"></div>
<script type="application/json" id="openapi-spec">
${spec}
</script>
<script>
${bundle}
</script>
<script>
  Redoc.init(JSON.parse(document.getElementById('openapi-spec').textContent),
             { hideDownloadButton: false, expandResponses: '201,422' },
             document.getElementById('redoc'));
</script>
</body>
</html>
`

mkdirSync(at('../public/api-reference'), { recursive: true })
writeFileSync(OUT, html)
console.log(`api-reference: wrote ${OUT} (${html.length} bytes, spec + viewer inlined)`)
