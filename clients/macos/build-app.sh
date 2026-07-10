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
cp -R Resources/codemirror "$APP/Contents/Resources/" 2>/dev/null || true  # CM6 bundle (legacy)
cp -R Resources/monaco "$APP/Contents/Resources/" 2>/dev/null || true       # Monaco (VS Code's editor) for the Files editor
cp -R Resources/render "$APP/Contents/Resources/" 2>/dev/null || true      # offline marked+KaTeX+hljs bundle for Renders (⇧⌘P)
cp -R Resources/gitview "$APP/Contents/Resources/" 2>/dev/null || true
cp -R Resources/ledger "$APP/Contents/Resources/" 2>/dev/null || true    # activity ledger viewer
cp -R Resources/wrapped "$APP/Contents/Resources/" 2>/dev/null || true   # Argus Wrapped deck/dashboard
cp -R Resources/lab "$APP/Contents/Resources/" 2>/dev/null || true       # the Lab experiments hub (â§âL)

echo "Built $(pwd)/$APP"

# Install to /Applications so a normal relaunch (Dock/Spotlight/⌘-Tab) runs THIS build.
# Both copies share a bundle id, so LaunchServices otherwise keeps running the stale
# /Applications copy while `open ./Argus.app` only launches the repo one — which looks
# like "the new build didn't take". Set UT_NO_INSTALL=1 to skip.
if [ "${UT_NO_INSTALL:-0}" != "1" ]; then
    rm -rf /Applications/Argus.app
    ditto "$APP" /Applications/Argus.app && echo "Installed to /Applications/Argus.app"
fi
echo "Run it with:  open -a Argus    (launches the /Applications copy)"
