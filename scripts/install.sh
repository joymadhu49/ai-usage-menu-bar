#!/usr/bin/env bash
# Build the app and install it to /Applications, then launch it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AI Usage Menu Bar"
DEST="/Applications/$APP_NAME.app"

APP_DIR="$(bash "$ROOT_DIR/scripts/build.sh")"

# Stop any running instance, replace the installed copy, relaunch.
pkill -f "AIUsageMenuBar" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$APP_DIR" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true
open "$DEST"

echo "Installed and launched: $DEST"
echo "Use the menu bar item -> 'Launch at Login' to start it automatically."
