#!/bin/bash
# Creates a stable, self-signed code-signing identity for local builds of Fred.
#
# Why: macOS privacy grants (Accessibility, Contacts, Automation) are keyed on the
# app's designated requirement. Ad-hoc signatures change every build, which would
# silently revoke every grant on each rebuild. A fixed certificate keeps the
# designated requirement ("identifier X and certificate leaf = H...") stable.
#
# The identity lives in a dedicated keychain whose password we generate and keep in
# ~/Library/Application Support/FredDev/, so signing never prompts for the user's
# login keychain password. Idempotent: does nothing if the keychain already exists.
set -euo pipefail

NAME="Fred Local Signing"
DEV_DIR="$HOME/Library/Application Support/FredDev"
KC="$HOME/Library/Keychains/fred-signing.keychain-db"
PASS_FILE="$DEV_DIR/keychain-password"

if [[ -f "$KC" && -f "$PASS_FILE" ]]; then
  echo "signing keychain already exists: $KC"
  exit 0
fi

mkdir -p "$DEV_DIR"
chmod 700 "$DEV_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS="$(openssl rand -hex 24)"
printf '%s' "$PASS" > "$PASS_FILE"
chmod 600 "$PASS_FILE"

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
# -legacy keeps the PKCS#12 encryption readable by `security import` on all macOS versions.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout pass:"$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -name "$NAME" -out "$TMP/id.p12" -passout pass:"$PASS"

security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"            # no auto-lock timeout
security unlock-keychain -p "$PASS" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null

echo "created signing identity '$NAME' in $KC"
