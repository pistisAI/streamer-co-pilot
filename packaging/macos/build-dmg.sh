#!/bin/bash
set -euo pipefail
VERSION="${1:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_PATH="$PROJECT_DIR/build/macos/Build/Products/Release/streamer_co_pilot.app"
DMG_PATH="$PROJECT_DIR/StreamerCoPilot-$VERSION.dmg"
[ ! -d "$APP_PATH" ] && { echo "Build first: flutter build macos --release"; exit 1; }
echo "Building $DMG_PATH"
if command -v create-dmg &>/dev/null; then
  create-dmg --volname "Streamer Co-Pilot $VERSION" --window-pos 200 120 --window-size 600 400 --icon-size 100 --icon "streamer_co_pilot.app" 175 190 --app-drop-link 425 190 "$DMG_PATH" "$APP_PATH"
else
  STAGING="/tmp/dmg-staging"; rm -rf "$STAGING"; mkdir -p "$STAGING"
  cp -R "$APP_PATH" "$STAGING/"; ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "Streamer Co-Pilot $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
  rm -rf "$STAGING"
fi
echo "Done: $DMG_PATH"