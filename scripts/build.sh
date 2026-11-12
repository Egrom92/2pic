#!/bin/bash
# Builds build/2pic.app and signs it with the local "2pic Local Signing" certificate.
#   SELFTEST=1 ./scripts/build.sh   — test build with the `--selftest` commands (see Sources/TwoPic/SelfTest.swift).
#                                     Run it from build/ only, never install it: it exposes 2pic's permissions.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/2pic.app
IDENTITY="2pic Local Signing"

if [ "${SELFTEST:-}" = 1 ]; then
    swift build -c release --product TwoPic -Xswiftc -DSELFTEST
else
    swift build -c release --product TwoPic
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TwoPic "$APP/Contents/MacOS/2pic"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if ! security find-identity -p codesigning | grep -q "$IDENTITY"; then
    ./scripts/setup-signing.sh
fi
security unlock-keychain -p 2pic-local-signing "$HOME/Library/Keychains/2pic-signing.keychain-db"
# Hardened runtime: other processes can't inject code (DYLD_INSERT_LIBRARIES etc.) into 2pic and borrow its
# permissions. 2pic needs no extra entitlements for it. The designated requirement (identifier + certificate)
# stays the same, so permissions already granted in System Settings are kept.
codesign --force --options runtime --sign "$IDENTITY" --identifier local.2pic "$APP"
codesign --verify "$APP"
echo "Built $APP"
