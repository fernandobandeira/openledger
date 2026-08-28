#!/usr/bin/env bash
# Spike 021 — regenerate everything this directory claims.
#
#   ./RUN.sh            build both projects, emit all three specs, rebuild the
#                       static pages, and re-verify the determinism claim
#   ./RUN.sh drift      also run the nine drift experiments (slower)
#
# Needs: a Rust toolchain (measured on 1.97.1), python3, and network for the
# first `cargo build`. The static pages load Redoc/Scalar from a CDN at VIEW
# time; building them needs no network.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

hr() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

hr "versions"
rustc --version
cargo --version
python3 --version

hr "build"
for p in bare-axum utoipa-api aide-api; do
  (cd "$p" && cargo build 2>&1 | tail -1 | sed "s|^|  $p: |")
done

hr "emit the specs"
utoipa-api/target/debug/utoipa-api emit spec/openapi.utoipa.json
aide-api/target/debug/aide-api     emit spec/openapi.aide.json
aide-api/target/debug/aide-naive   emit spec/openapi.aide-naive.json

hr "determinism: five separate processes must agree, byte for byte"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
for i in 1 2 3 4 5; do
  utoipa-api/target/debug/utoipa-api emit "$tmp/u.$i.json" 2>/dev/null
  aide-api/target/debug/aide-api     emit "$tmp/a.$i.json" 2>/dev/null
done
for lib in u:utoipa a:aide; do
  pre="${lib%%:*}"; name="${lib##*:}"
  n=$(sha256sum "$tmp/$pre".*.json | awk '{print $1}' | sort -u | wc -l)
  if [ "$n" -eq 1 ]; then
    echo "  $name: 5/5 identical  $(sha256sum "$tmp/$pre.1.json" | cut -c1-16)"
  else
    echo "  $name: NOT DETERMINISTIC across processes ($n distinct hashes)"; exit 1
  fi
done
echo "  (the stronger claim -- stable across a cargo clean -- is the 'clean rebuild'"
echo "   block below; run it explicitly, it recompiles everything)"

hr "static render pages"
python3 render/build.py

hr "clean rebuild determinism (slow: recompiles both projects from scratch)"
if [ "${SKIP_CLEAN:-}" = "1" ]; then
  echo "  skipped (SKIP_CLEAN=1)"
else
  for p in utoipa-api aide-api; do
    bin=$p
    cp "spec/openapi.${p%-api}.json" "$tmp/$p.before.json"
    (cd "$p" && cargo clean >/dev/null 2>&1 && cargo build >/dev/null 2>&1)
    "$p/target/debug/$bin" emit "$tmp/$p.after.json" 2>/dev/null
    if diff -q "$tmp/$p.before.json" "$tmp/$p.after.json" >/dev/null; then
      echo "  $p: identical across cargo clean"
    else
      echo "  $p: DIFFERS across cargo clean"; diff "$tmp/$p.before.json" "$tmp/$p.after.json" | head -20
    fi
  done
fi

hr "cost"
for p in bare-axum utoipa-api aide-api; do
  n=$(cd "$p" && cargo tree --edges normal --prefix none 2>/dev/null | sed 's/ (\*)$//' | awk 'NF' | sort -u | wc -l)
  printf "  %-11s unique normal deps (incl. self): %s\n" "$p" "$n"
done

if [ "${1:-}" = "drift" ]; then
  hr "drift experiments"
  ./drift/RUN-drift.sh
fi

hr "done"
echo "  spec/openapi.utoipa.json      utoipa 5.5.0 + utoipa-axum 0.2.0"
echo "  spec/openapi.aide.json        aide 0.15.1"
echo "  spec/openapi.aide-naive.json  aide 0.15.1, handlers written the plain axum way"
echo "  render/redoc.html             open in a browser (works over file://)"
echo "  render/scalar.html            open in a browser (works over file://)"
