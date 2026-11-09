#!/bin/bash
# Regenerates the README screenshots (demo data, never your files) in docs/screenshots/<language>, then rebuilds the
# normal app. The window is captured with screencapture, so the terminal needs the Screen Recording permission.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SNAPSHOT_TOOLS=1 ./scripts/build.sh

for pair in en:en pt:pt-BR; do
  lang="${pair%%:*}"; dir="${pair##*:}"
  SPACELENS_SNAPSHOT_DIR="$WORK/$lang" SPACELENS_LANGUAGE="$lang" build/SpaceLens.app/Contents/MacOS/SpaceLens
  mkdir -p "docs/screenshots/$dir"
  for name in overview recommendations explorer-map routines menubar; do
    cp "$WORK/$lang/$name.png" "docs/screenshots/$dir/$name.png"
  done
done

./scripts/build.sh   # back to the normal build: the screenshot harness must never ship
echo "✓ docs/screenshots"
