// Sidebar order and labels. Hand-maintained, like the documents themselves.
export default {
  index: 'Overview',
  '-- design': { type: 'separator', title: 'The ledger' },
  vision: 'Vision',
  database: 'The database',
  service: 'The service',
  roadmap: 'Roadmap',
  decisions: 'Decisions',
  spikes: 'Spikes',
  '-- card': { type: 'separator', title: 'The reference product' },
  card: { title: 'The card rail', display: 'children' },
  '-- reference': { type: 'separator', title: 'Reference' },
  glossary: 'Glossary',
  // Not a content page: a self-contained static HTML that scripts/api-reference.mjs
  // regenerates from crates/api/openapi.json on every build (dev included).
  'api-reference': { title: 'API reference', href: '/api-reference/' }
}
