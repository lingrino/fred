#!/bin/bash
# Stores the Apple release credentials where CI gets them: AWS Secrets Manager
# github/keys/apple-developer (prod account). They belong to the team, so lingrino/infra
# copies them into the Actions secrets of every Mac app it lists (local.mac_app_repos) on
# its next apply, and setup-signing.sh imports them for local builds.
#   scripts/store-release-secrets.sh <DeveloperID.p12> <AuthKey_KEYID.p8> <issuer-id>
#
# The .p12 is the "Developer ID Application" certificate with its private key (Keychain
# Access → My Certificates → Export); its password is asked for, never passed. The .p8 is
# an App Store Connect team API key with the Developer role (notarization); the key id
# comes from the file name Apple gives it (FRED_API_KEY_ID overrides). Both are checked the
# way the release workflow uses them before anything is stored: the .p12 imports into a
# scratch keychain as a Developer ID identity, and notarytool accepts the key.
# Run it again with a new certificate before the current one expires (it prints the date;
# releases already signed and notarized keep working after that).
set -euo pipefail

usage="usage: $0 <cert.p12> <AuthKey_KEYID.p8> <issuer-id>"
P12="${1:?$usage}"
P8="${2:?$usage}"
ISSUER="${3:?$usage}"
KEY_ID="${FRED_API_KEY_ID:-$(basename "$P8" .p8 | sed -n 's/^AuthKey_//p')}"
[[ -n "$KEY_ID" ]] || { echo "no key id in the name $(basename "$P8"); set FRED_API_KEY_ID" >&2; exit 1; }
PROFILE="${AWS_PROFILE:-prod}"
REGION=us-west-2
SECRET=github/keys/apple-developer

TMP="$(mktemp -d)"
chmod 700 "$TMP"
KC="$TMP/check.keychain-db"
trap 'security delete-keychain "$KC" 2>/dev/null || true; rm -rf "$TMP"' EXIT

read -rsp "password of $(basename "$P12"): " PW
echo

# Certificate: the same import as the release workflow, into a throwaway keychain.
security create-keychain -p "$(openssl rand -hex 16)" "$KC"
security import "$P12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
ident="$(security find-identity -p codesigning "$KC" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
[[ -n "$ident" ]] || { echo "$(basename "$P12") has no Developer ID Application identity" >&2; exit 1; }
expires="$(security find-certificate -c "$ident" -p "$KC" | openssl x509 -noout -enddate | cut -d= -f2)"
echo "certificate: $ident, expires $expires"

# Notarization key: any authenticated notarytool call proves it.
if ! xcrun notarytool history --key "$P8" --key-id "$KEY_ID" --issuer "$ISSUER" >/dev/null; then
  echo "notarytool rejected the key $KEY_ID (issuer $ISSUER)" >&2
  exit 1
fi
echo "notary key: $KEY_ID works"

aws sts get-caller-identity --profile "$PROFILE" >/dev/null 2>&1 || aws sso login --profile "$PROFILE"
base64 -i "$P12" | tr -d '\n' > "$TMP/p12"
base64 -i "$P8" | tr -d '\n' > "$TMP/p8"
printf '%s' "$PW" | jq -Rs --rawfile p12 "$TMP/p12" --rawfile p8 "$TMP/p8" --arg id "$KEY_ID" --arg iss "$ISSUER" \
  '{APPLE_CERT_P12_BASE64: $p12, APPLE_CERT_PASSWORD: ., APPLE_API_KEY_P8_BASE64: $p8,
    APPLE_API_KEY_ID: $id, APPLE_API_ISSUER_ID: $iss}' > "$TMP/secret.json"
version="$(aws secretsmanager put-secret-value --profile "$PROFILE" --region "$REGION" \
  --secret-id "$SECRET" --secret-string "file://$TMP/secret.json" --query VersionId --output text)"
echo "stored $SECRET (version $version)"
echo "next: apply lingrino/infra (terraform workflow, or wait for its Monday run) so the repos get"
echo "it, then scripts/setup-signing.sh on each Mac that builds locally"
