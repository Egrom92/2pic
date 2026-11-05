#!/bin/bash
# Builds 2pic, replaces /Applications/2pic.app and starts it.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
osascript -e 'tell application id "local.2pic" to quit' >/dev/null 2>&1 || true
pkill -x 2pic 2>/dev/null || true
sleep 0.5
rm -rf /Applications/2pic.app
ditto build/2pic.app /Applications/2pic.app
open /Applications/2pic.app
echo "Installed /Applications/2pic.app"
