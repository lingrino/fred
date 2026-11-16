#!/bin/bash
# Assemble and sign Fred.app from a SwiftPM build.
#   scripts/bundle.sh <release|debug> <output.app>
#
# Version: 0.0.N where N = commits on HEAD (main is squash-merged, so every merge bumps
# N); CFBundleVersion is N, FredRevision the short git hash. FRED_VERSION overrides.
#
# Signing identity, FRED_SIGN_IDENTITY:
#   unset  the local self-signed "Fred Local Signing" (keychain from setup-signing.sh),
#          which keeps the designated requirement, and so the privacy grants, stable
#   "-"    ad-hoc: CI checks that build and verify the bundle but never install it
#   other  that identity from the keychain search list, with a secure timestamp
#          (Developer ID releases; notarization requires the timestamp)
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
REV="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
N="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
VERSION="${FRED_VERSION:-0.0.$N}"
PLIST="$OUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $N" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :FredRevision string $REV" "$PLIST"

if [[ "$CONFIG" == "release" ]]; then
  strip -x "$OUT/Contents/MacOS/Fred"   # drop local symbols: smaller binary, less to page in
fi

sign=(codesign --force --options runtime --entitlements "$ROOT/Resources/Fred.entitlements"
      --identifier dev.fred.Fred)
case "${FRED_SIGN_IDENTITY:-}" in
  "")
    security unlock-keychain -p "$(cat "$PASS_FILE")" "$KC"
    "${sign[@]}" --sign "Fred Local Signing" --keychain "$KC" "$OUT" ;;
  -)
    "${sign[@]}" --sign - "$OUT" ;;
  *)
    "${sign[@]}" --timestamp --sign "$FRED_SIGN_IDENTITY" "$OUT" ;;
esac
echo "built $OUT ($VERSION, $REV)"
