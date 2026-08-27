// Generate the pages that are NOT prose.
//
// `site/content/` is the home of every written document in this project — the
// vision, the glossary, the database page, the ADRs, the spike write-ups. Those
// are real committed files and this script does not touch them.
//
// What it generates is the handful of pages that render source code the
// documents cite: the migration, the example chart, the parked card DDL, and the
// migrator. Those files live where they have to live — a migration has to be in
// `migrations/`, Rust has to be in `src/` — so their pages are derived, land in
// `site/content/source/`, and are the one gitignored thing under `content/`.
//
// Run it with `npm run sync`; `dev` and `build` run it first.

import { mkdir, readFile, writeFile, rm } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const SITE = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const REPO = resolve(SITE, '..')
const OUT = join(SITE, 'content/source')

/** [repo path, page slug, sidebar title, fence language] */
const SOURCES = [
  ['migrations/00001_baseline.sql', 'baseline', 'The migration', 'sql'],
  ['schema/chart.sql', 'chart', 'The example chart', 'sql'],
  ['parked/card/schema.sql', 'card-schema', 'Parked: card schema', 'sql'],
  ['src/main.rs', 'main-rs', 'src/main.rs', 'rust'],
  ['src/migrate.rs', 'migrate-rs', 'src/migrate.rs', 'rust']
]

await rm(OUT, { recursive: true, force: true })
await mkdir(OUT, { recursive: true })

for (const [repoPath, slug, title, lang] of SOURCES) {
  const raw = await readFile(join(REPO, repoPath), 'utf8')
  // The reasoning in these files is in their comments, so they are worth reading
  // whole rather than quoted. A fence inside the source would close this one, so
  // any backtick run is broken with a zero-width space.
  const body =
    `---\ntitle: '${title.replace(/'/g, "''")}'\n---\n\n` +
    `# ${title}\n\n\`${repoPath}\` in the repository, verbatim.\n\n` +
    '```' + lang + '\n' + raw.replace(/```/g, '``​`') + '\n```\n'
  await writeFile(join(OUT, `${slug}.md`), body)
}

await writeFile(
  join(OUT, '_meta.js'),
  'export default {\n' +
    SOURCES.map(([, slug, title]) => `  '${slug}': ${JSON.stringify(title)}`).join(',\n') +
    '\n}\n'
)

console.log(`generated ${SOURCES.length} source pages in content/source/`)
