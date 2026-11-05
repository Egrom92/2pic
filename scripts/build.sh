#!/bin/bash
# Builds build/2pic.app and signs it with the local "2pic Local Signing" certificate.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/2pic.app
IDENTITY="2pic Local Signing"

swift build -c release --product TwoPic

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
codesign --force --sign "$IDENTITY" --identifier local.2pic "$APP"
codesign --verify "$APP"
echo "Built $APP"
