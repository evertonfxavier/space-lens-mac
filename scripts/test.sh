#!/bin/bash
# Compiles Core + Tests (never the UI, so Core cannot depend on it) and runs the Swift Testing suites.
# SwiftPM is not used on purpose: it cannot evaluate manifests with the local Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="$(xcode-select -p)"
case "$DEV" in
  *CommandLineTools) FW="$DEV/Library/Developer/Frameworks"; LIB="$DEV/Library/Developer/usr/lib"; PLUGINS="$DEV/usr/lib/swift/host/plugins/testing" ;;
  *) FW="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks"; LIB="$DEV/Platforms/MacOSX.platform/Developer/usr/lib"
     PLUGINS="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing" ;;
esac

OUT=build/tests
mkdir -p "$OUT"
swiftc -swift-version 5 -parse-as-library -Onone -g \
  -module-name SpaceLensTests \
  -plugin-path "$PLUGINS" -F "$FW" \
  -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" \
  $(find Sources/SpaceLens/Core Tests -name '*.swift') \
  -o "$OUT/run"

"$OUT/run" "$@"
