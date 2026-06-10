#!/usr/bin/env bash
# Build a double-clickable Argus.app from the SwiftPM executable.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Argus.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/UniversalTmuxMac" "$APP/Contents/MacOS/Argus"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Argus.icns "$APP/Contents/Resources/" 2>/dev/null || true
cp Resources/fonts/*.ttf "$APP/Contents/Resources/" 2>/dev/null || true
cp -R Resources/codemirror "$APP/Contents/Resources/" 2>/dev/null || true  # CM6 bundle for the Files editor/viewer
cp -R Resources/render "$APP/Contents/Resources/" 2>/dev/null || true      # offline marked+KaTeX+hljs bundle for Renders (⇧⌘P)

echo "Built $(pwd)/$APP"
echo "Run it with:  open Argus.app    (or double-click in Finder)"
