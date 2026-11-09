#!/bin/bash
# Builds build/SpaceLens.app with swiftc only (SwiftPM cannot evaluate manifests with the local Command Line
# Tools). Environment: ARCHS="arm64 x86_64" for a universal binary, SIGN_IDENTITY for a real certificate
# (default: ad-hoc), SNAPSHOT_TOOLS=1 to add the screenshot/demo harness (never in releases).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
ARCHS="${ARCHS:-$(uname -m)}"
APP=build/SpaceLens.app
SDK_DEFAULT="$(xcrun --show-sdk-path)"

# The macOS 27 SDK of some Command Line Tools declares @State as a macro whose plugin is not installed.
# Probe it and fall back to the newest macOS 26 SDK that is.
probe="$(mktemp -d)/probe.swift"
printf 'import SwiftUI\nstruct P: View { @State var x = 0; var body: some View { Text("\\(x)") } }\n' > "$probe"
SDK="${SDK:-$SDK_DEFAULT}"
if ! swiftc -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macos14.0" -typecheck "$probe" >/dev/null 2>&1; then
  FALLBACK="$(ls -d "$(dirname "$SDK_DEFAULT")"/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)"
  [ -n "$FALLBACK" ] || { echo "No usable macOS SDK for SwiftUI" >&2; exit 1; }
  echo "• SDK $SDK cannot compile @State here; using $FALLBACK"
  SDK="$FALLBACK"
fi

FLAGS=()
[ "${SNAPSHOT_TOOLS:-0}" = "1" ] && FLAGS+=(-D SNAPSHOT_TOOLS)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
SOURCES=$(find Sources -name '*.swift')

slices=()
for arch in $ARCHS; do
  out="build/obj/SpaceLens-$arch"
  echo "• compiling $arch"
  swiftc -O -swift-version 5 -sdk "$SDK" -target "$arch-apple-macos14.0" -module-name SpaceLens \
    ${FLAGS[@]+"${FLAGS[@]}"} $SOURCES -o "$out"
  slices+=("$out")
done
if [ "${#slices[@]}" -gt 1 ]; then lipo -create "${slices[@]}" -output "$APP/Contents/MacOS/SpaceLens"
else cp "${slices[0]}" "$APP/Contents/MacOS/SpaceLens"; fi

sed "s/__VERSION__/$VERSION/g" Resources/Info.plist.in > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Translations: one <code>.lproj/Localizable.strings per language (the in-app language switch reads them).
for lproj in Resources/Localization/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
  plutil -lint "$APP/Contents/Resources/$(basename "$lproj")/Localizable.strings" >/dev/null
done

codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "✓ $APP ($VERSION, $ARCHS)"
