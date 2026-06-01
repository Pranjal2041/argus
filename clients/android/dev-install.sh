#!/usr/bin/env bash
# Build the debug APK and install it on the connected (wireless) adb device.
# One-time setup: pair + connect over Wi-Fi/tailnet (see README). Then just run this.
set -euo pipefail
cd "$(dirname "$0")"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export PATH="$HOME/Library/Android/sdk/platform-tools:$PATH"

echo "==> building debug APK"
./gradlew :app:assembleDebug --console=plain -q
APK="app/build/outputs/apk/debug/app-debug.apk"

# Prefer an explicit ip:port device (avoids the mDNS duplicate adb shows).
DEV="${UT_ADB_DEVICE:-$(adb devices | awk '/:[0-9]+\tdevice$/{print $1; exit}')}"
[ -n "$DEV" ] || DEV="$(adb devices | awk '/\tdevice$/{print $1; exit}')"
if [ -z "$DEV" ]; then
  echo "no adb device connected. Reconnect with:  adb connect <phone-ip>:<port>" >&2
  exit 1
fi
echo "==> installing to $DEV"
adb -s "$DEV" install -r "$APK"
echo "==> done. Launching."
adb -s "$DEV" shell monkey -p dev.universaltmux.android -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
