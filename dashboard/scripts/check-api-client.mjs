/**
 * Fail if `src/lib/api/` drifted from `crates/api/openapi.json`.
 *
 * The same contract `make openapi-check` holds over the spec and
 * `make schema-snapshot-check` holds over the schema dump, and it is a
 * contract about what this script MUST NOT do: it regenerates into a
 * throwaway directory and compares, and it never writes into the committed
 * tree. A check that quietly fixes the drift it was built to catch reports a
 * green run for a repository whose committed client is still wrong — which is
 * the failure both of those gates exist to refuse. Regenerating is a separate,
 * deliberate command (`npm run generate:api-client`), so a normal run here can
 * only ever pass or fail.
 *
 * The comparison is the whole tree, byte for byte: file set first, then
 * contents. Nothing in the generated output depends on where it sits — no
 * baseUrl, no runtime-config import — which is what makes a temporary
 * directory a fair comparison rather than a diff full of relative paths.
 */
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const dashboard = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const committed = path.join(dashboard, "src", "lib", "api");

/** Every file under `root`, as paths relative to it, sorted. */
function filesUnder(root) {
  const found = [];
  for (const entry of readdirSync(root, {
    recursive: true,
    withFileTypes: true,
  })) {
    if (!entry.isFile()) continue;
    found.push(path.relative(root, path.join(entry.parentPath, entry.name)));
  }
  return found.sort();
}

if (!existsSync(committed)) {
  console.error(
    "src/lib/api/ is not there at all. It is committed on purpose — see\n" +
      "dashboard/README.md — and `npm run generate:api-client` writes it."
  );
  process.exit(1);
}

const scratch = mkdtempSync(path.join(tmpdir(), "openledger-api-client-"));
try {
  const generated = spawnSync(
    process.execPath,
    [
      path.join(dashboard, "node_modules", "@hey-api", "openapi-ts", "bin", "run.js"),
      "--output",
      scratch,
    ],
    { cwd: dashboard, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }
  );
  if (generated.status !== 0) {
    console.error(
      "openapi-ts failed, so nothing was compared — the drift check did NOT run."
    );
    process.exit(1);
  }

  const regenerate =
    "regenerate it with `npm run generate:api-client` and commit the diff — but\n" +
    "only if the spec change itself is intended: this directory is the guard\n" +
    "against the dashboard drifting from crates/api/openapi.json.";

  const theirs = filesUnder(scratch);
  const ours = filesUnder(committed);

  const missing = theirs.filter((file) => !ours.includes(file));
  const extra = ours.filter((file) => !theirs.includes(file));
  const differing = theirs
    .filter((file) => ours.includes(file))
    .filter(
      (file) =>
        !readFileSync(path.join(scratch, file)).equals(
          readFileSync(path.join(committed, file))
        )
    );

  if (missing.length === 0 && extra.length === 0 && differing.length === 0) {
    console.log(
      `src/lib/api/ matches crates/api/openapi.json — ${ours.length} files compared.`
    );
    process.exit(0);
  }

  console.error("src/lib/api/ is not what the spec generates.\n");
  for (const file of missing) console.error(`  missing from the commit: ${file}`);
  for (const file of extra) console.error(`  committed but not generated: ${file}`);
  for (const file of differing) console.error(`  differs: ${file}`);
  console.error(`\n${regenerate}`);
  process.exit(1);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
