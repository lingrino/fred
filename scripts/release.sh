#!/bin/bash
# Build a Fred release and the Homebrew cask that installs it (what CI publishes).
#   scripts/release.sh  →  build/release/Fred.app, Fred-<version>.zip, fred.rb, version
#
# Version and signing: see bundle.sh (FRED_SIGN_IDENTITY; "-" for an unsigned dry run).
# Notarization runs when an App Store Connect API key is given: FRED_NOTARY_KEY (path to
# the .p8), FRED_NOTARY_KEY_ID, FRED_NOTARY_ISSUER. The ticket is stapled to the app
# before zipping, so Gatekeeper accepts it offline.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT"

./scripts/swift.sh build -c release --product Fred
./scripts/bundle.sh release "$OUT/Fred.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$OUT/Fred.app/Contents/Info.plist")"
ZIP="$OUT/Fred-$VERSION.zip"
codesign --verify --strict --deep "$OUT/Fred.app"

if [[ -n "${FRED_NOTARY_KEY:-}" ]]; then
  ditto -c -k --keepParent "$OUT/Fred.app" "$OUT/notarize.zip"
  result="$(xcrun notarytool submit "$OUT/notarize.zip" --wait --output-format json \
    --key "$FRED_NOTARY_KEY" --key-id "$FRED_NOTARY_KEY_ID" --issuer "$FRED_NOTARY_ISSUER")"
  echo "$result"
  rm "$OUT/notarize.zip"
  if [[ "$(jq -r .status <<<"$result")" != Accepted ]]; then
    xcrun notarytool log "$(jq -r .id <<<"$result")" \
      --key "$FRED_NOTARY_KEY" --key-id "$FRED_NOTARY_KEY_ID" --issuer "$FRED_NOTARY_ISSUER" || true
    echo "release: notarization failed" >&2
    exit 1
  fi
  xcrun stapler staple "$OUT/Fred.app"
  spctl --assess --type execute --verbose "$OUT/Fred.app"
fi

ditto -c -k --keepParent "$OUT/Fred.app" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

# No `uninstall quit:`: brew runs uninstall stanzas on every upgrade too, and nothing
# would start Fred again afterwards. Fred restarts itself when its bundle is replaced
# (AppDelegate.selfChanged), so upgrades just work; `brew uninstall` leaves a running Fred
# until it is quit ("Quit Fred"). The macOS minimum is LSMinimumSystemVersion's job.
# postflight clears the quarantine flag brew puts on every copy it installs: otherwise
# macOS asks "downloaded from the Internet… open it?" on the first launch of each upgrade,
# and Fred's self-restart waits on that click (no launcher meanwhile). brew's sha256 check
# still pins the bits to the zip CI notarized; the user chose this on 2026-11-16.
cat > "$OUT/fred.rb" <<EOF
cask "fred" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/lingrino/fred/releases/download/v#{version}/Fred-#{version}.zip"
  name "Fred"
  desc "Launcher and clipboard manager"
  homepage "https://github.com/lingrino/fred"

  depends_on arch: :arm64

  app "Fred.app"

  postflight_steps do
    run "/usr/bin/xattr", args: ["-d", "-r", "com.apple.quarantine", "{{appdir}}/Fred.app"]
  end

  zap trash: "~/Library/Application Support/Fred"
end
EOF
echo "$VERSION" > "$OUT/version"
echo "release: $ZIP ($SHA)"
