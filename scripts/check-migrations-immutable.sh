#!/usr/bin/env bash
# check-migrations-immutable.sh <base-ref>
#
# Fail if any file under migrations/ was Modified, Renamed or Deleted relative
# to the base ref. Adding a new migration is fine; touching an existing one is
# not. ADR-0003: an applied migration is history, and history does not get
# edited — a change is a NEW numbered migration.
#
# The baseline 00001 gets NO exemption. It froze on 2026-08-27, ahead of v0.1
# — closing early the "editable in place until v0.1 is tagged" exception
# ADR-0003 had written down: a kept database is now one `git pull && make up`
# away, which is the situation the never-edit rule exists to protect.
#
# There is deliberately NO opt-out marker (no magic commit message, no label,
# no env var). A check with an escape hatch is a comment, and the file this
# guards is the one file whose edits are silently destructive.
#
# Also fails on a duplicate version prefix inside migrations/ — two PRs each
# adding "the next number" are individually green and collide only on the
# merge ref, which is exactly where CI runs this.
set -euo pipefail

if [ $# -ne 1 ] || [ -z "$1" ]; then
  echo "usage: $0 <base-ref>" >&2
  exit 2
fi
base="$1"

# A bad or missing base ref must fail loudly, never pass vacuously: a diff
# against nothing is a green check that did not execute.
if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
  echo "error: base ref '${base}' does not resolve to a commit — refusing to pass without a real comparison" >&2
  exit 2
fi

# Three-dot semantics via merge-base: compare HEAD against where it forked
# from the base, so commits already on the base are not re-litigated.
merge_base="$(git merge-base "${base}" HEAD)" || {
  echo "error: no merge base between '${base}' and HEAD" >&2
  exit 2
}

# -M so a rename is reported as R (not as an A the check would wave through
# plus a D it flags anyway); --diff-filter keeps Added out, which also makes
# "no migrations changed" an empty diff and therefore a success.
violations="$(git diff --name-status -M --diff-filter=MRD "${merge_base}" HEAD -- migrations/)"
if [ -n "${violations}" ]; then
  echo "error: files under migrations/ were modified, renamed or deleted:" >&2
  echo "${violations}" >&2
  echo "migrations are immutable once committed (ADR-0003; the 00001 baseline froze 2026-08-27)." >&2
  echo "Write a NEW numbered migration instead." >&2
  exit 1
fi

# Duplicate version prefixes, checked on HEAD's tree (the merge ref in CI):
# two branches both adding 00002_* are only visible together.
duplicates="$(git ls-tree --name-only HEAD -- migrations/ | xargs -rn1 basename \
  | cut -d_ -f1 | sort -n | uniq -d)"
if [ -n "${duplicates}" ]; then
  echo "error: duplicate migration version prefix(es): ${duplicates}" >&2
  echo "two migrations claim the same number; renumber one in a new commit." >&2
  exit 1
fi

echo "migrations immutable: OK (base $(git rev-parse --short "${merge_base}"), $(git ls-tree HEAD -- migrations/ | wc -l) file(s), no M/R/D, no duplicate versions)"
