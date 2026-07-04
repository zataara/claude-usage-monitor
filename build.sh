#!/usr/bin/env bash
# Build the SPM executable and wrap it into a menu-bar .app bundle (LSUIElement).
# Personal, local-only tool: ad-hoc signed, no notarization.
set -euo pipefail
cd "$(dirname "$0")"

APP="ClaudeUsageMonitor.app"
BIN="ClaudeUsageMonitor"

echo "→ swift build -c release"
swift build -c release

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$BIN" "$APP/Contents/MacOS/$BIN"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/claude-mark.svg" "$APP/Contents/Resources/claude-mark.svg"

echo "→ ad-hoc codesign"
codesign --force --sign - "$APP" >/dev/null

echo "✓ built $APP"
echo "  run now:        open $APP"
echo "  install:        cp -R $APP /Applications/ && open /Applications/$APP"
echo "  (login item toggles from inside the app; needs the app in a stable path)"
