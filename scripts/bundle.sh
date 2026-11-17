#!/bin/bash
# Assemble and sign Fred.app from a SwiftPM build.
#   scripts/bundle.sh <release|debug> <output.app>
#
# Version: 0.0.N where N = commits on HEAD (main is squash-merged, so every merge bumps
# N); CFBundleVersion is N, FredRevision the short git hash. FRED_VERSION overrides.
#
# Signing identity, FRED_SIGN_IDENTITY:
#   unset  the Developer ID from the signing keychain (setup-signing.sh), no timestamp:
#          the same designated requirement as releases, so privacy grants carry across
#          brew-installed releases and local builds
#   "-"    ad-hoc: CI checks that build and verify the bundle but never install it
#   other  that identity from the keychain search list, with a secure timestamp
#          (Developer ID releases; notarization requires the timestamp)
# Local builds (the first case) also get FredDevTools = true in Info.plist: only then does
# Fred open its control socket (fredctl), which can read contacts and clipboard history
# with Fred's privacy grants. Released builds never have it.
set -euo pipefail

CONFIG="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/$CONFIG/Fred"
KC="$HOME/Library/Keychains/developer-id.keychain-db"   # setup-signing.sh
PASS_FILE="$HOME/Library/Application Support/DeveloperID/keychain-password"

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
    /usr/libexec/PlistBuddy -c "Add :FredDevTools bool true" "$PLIST"
    security unlock-keychain -p "$(cat "$PASS_FILE")" "$KC"
    id="$(security find-identity -v -p codesigning "$KC" | awk '/"Developer ID Application: / { print $2; exit }')"
    [[ -n "$id" ]] || { echo "no Developer ID identity for local builds: run scripts/setup-signing.sh" >&2; exit 1; }
    "${sign[@]}" --timestamp=none --sign "$id" --keychain "$KC" "$OUT" ;;
  -)
    "${sign[@]}" --sign - "$OUT" ;;
  *)
    "${sign[@]}" --timestamp --sign "$FRED_SIGN_IDENTITY" "$OUT" ;;
esac
echo "built $OUT ($VERSION, $REV)"
