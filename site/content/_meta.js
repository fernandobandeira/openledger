// Sidebar order and labels. Hand-maintained, like the documents themselves.
export default {
  index: 'Overview',
  '-- design': { type: 'separator', title: 'The ledger' },
  vision: 'Vision',
  // Between the why and the how it is built: the conceptual bridge from a real
  // payment to a set of balanced transactions. Reads before the schema on purpose.
  bookings: 'Booking a payment',
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
