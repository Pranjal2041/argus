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
cp -R Resources/render "$APP/Contents/Resources/" 2>/dev/null || true      # faithful terminal + offline typeset bundle for Renders (⇧⌘M)
cp -R Resources/gitview "$APP/Contents/Resources/" 2>/dev/null || true
cp -R Resources/ledger "$APP/Contents/Resources/" 2>/dev/null || true    # activity ledger viewer
cp -R Resources/wrapped "$APP/Contents/Resources/" 2>/dev/null || true   # Argus Wrapped deck/dashboard
cp -R Resources/lab "$APP/Contents/Resources/" 2>/dev/null || true       # the Lab experiments hub (â§âL)

# SwiftPM linker-signs the loose executable before these bundle resources exist.
# Re-sign the finished bundle with a stable identity so its resource seal is
# valid and macOS privacy grants survive app updates. Never silently install an
# ad-hoc-signed build: its designated requirement is tied to that one binary.
SIGN_IDENTITY="${UT_CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    VALID_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/^[[:space:]]*[0-9]+\)/ { print $2 }')"
    IDENTITY_COUNT="$(printf '%s\n' "$VALID_IDENTITIES" \
        | awk 'NF { count++ } END { print count + 0 }')"
    if [ "$IDENTITY_COUNT" -eq 1 ]; then
        SIGN_IDENTITY="$(printf '%s\n' "$VALID_IDENTITIES" | awk 'NF { print; exit }')"
    else
        echo "Error: expected one stable code-signing identity, found $IDENTITY_COUNT." >&2
        echo "Set UT_CODESIGN_IDENTITY to the certificate name or SHA-1 hash." >&2
        exit 1
    fi
fi
if [ "$SIGN_IDENTITY" = "-" ] && [ "${UT_NO_INSTALL:-0}" != "1" ]; then
    echo "Error: refusing to install an ad-hoc-signed Argus.app." >&2
    exit 1
fi
codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
echo "Signed with stable identity: $SIGN_IDENTITY"

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
