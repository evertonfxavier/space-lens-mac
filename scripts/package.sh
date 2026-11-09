#!/bin/bash
# Packages the already built build/SpaceLens.app into build/dist: zip, dmg and SHA256SUMS.txt.
# Usage: scripts/package.sh [zip|dmg|all]   (run scripts/build.sh first)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
APP=build/SpaceLens.app
DIST=build/dist
WHAT="${1:-all}"

[ -d "$APP" ] || { echo "$APP not found: run scripts/build.sh first" >&2; exit 1; }
mkdir -p "$DIST"

if [ "$WHAT" = "zip" ] || [ "$WHAT" = "all" ]; then
  rm -f "$DIST/SpaceLens-$VERSION.zip"
  ditto -c -k --keepParent "$APP" "$DIST/SpaceLens-$VERSION.zip"
fi

if [ "$WHAT" = "dmg" ] || [ "$WHAT" = "all" ]; then
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DIST/SpaceLens-$VERSION.dmg"
  hdiutil create -volname SpaceLens -srcfolder "$STAGE" -ov -format UDZO "$DIST/SpaceLens-$VERSION.dmg" >/dev/null
  rm -rf "$STAGE"
fi

(cd "$DIST" && shasum -a 256 SpaceLens-"$VERSION".* > SHA256SUMS.txt)
echo "✓ $DIST"
ls -la "$DIST"
