#!/bin/bash
# Assemble and sign Fred.app from a SwiftPM build.
#   scripts/bundle.sh <release|debug> <output.app>
set -euo pipefail

CONFIG="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/$CONFIG/Fred"
KC="$HOME/Library/Keychains/fred-signing.keychain-db"
PASS_FILE="$HOME/Library/Application Support/FredDev/keychain-password"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/Fred"
cp "$ROOT/Resources/Info.plist" "$OUT/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
fi
# Stamp the build with the git revision so `Fred --version` and crash logs are traceable.
REV="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $REV" "$OUT/Contents/Info.plist"

if [[ "$CONFIG" == "release" ]]; then
  strip -x "$OUT/Contents/MacOS/Fred"   # drop local symbols: smaller binary, less to page in
fi

security unlock-keychain -p "$(cat "$PASS_FILE")" "$KC"
codesign --force --sign "Fred Local Signing" --keychain "$KC" \
  --options runtime --entitlements "$ROOT/Resources/Fred.entitlements" \
  --identifier dev.fred.Fred "$OUT"
echo "built $OUT ($REV)"
