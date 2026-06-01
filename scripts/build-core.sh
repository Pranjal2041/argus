#!/usr/bin/env bash
# Rebuild the embedded tsnet core (gomobile) -> clients/android/app/libs/uttsnet.aar
# Requires: gomobile/gobind (go install golang.org/x/mobile/cmd/...), Android NDK.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:$PATH"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/27.0.12077973}"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
# -checklinkname=0 is required: wlynxg/anet uses go:linkname into the net package
# for the netlink-free interface enumeration Android needs.
gomobile bind -target=android/arm64 -androidapi 26 -javapkg=dev.universaltmux.core \
  -ldflags="-checklinkname=0" \
  -o clients/android/app/libs/uttsnet.aar \
  ./mobile/uttsnet
echo "built clients/android/app/libs/uttsnet.aar"
