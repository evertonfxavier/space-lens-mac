#!/bin/bash
# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift (output is committed).
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"; set="$tmp/AppIcon.iconset"; mkdir -p "$set"
swiftc -O -o "$tmp/make-icon" scripts/make-icon.swift
"$tmp/make-icon" "$set"
iconutil -c icns "$set" -o Resources/AppIcon.icns
echo "✓ Resources/AppIcon.icns"
