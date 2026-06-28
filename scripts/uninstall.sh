#!/usr/bin/env bash
# Stop and remove the installed app.
set -euo pipefail

APP_NAME="AI Usage Menu Bar"
DEST="/Applications/$APP_NAME.app"

pkill -f "AIUsageMenuBar" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
echo "Removed: $DEST"
echo "Note: if you enabled 'Launch at Login', disable it from the menu first;"
echo "otherwise the login item registration is cleared when the app is gone."
