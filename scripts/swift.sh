#!/bin/bash
# `swift` wrapper used by the Makefile.
#
# This machine's Command Line Tools ship stale (Feb 2024) PackageDescription
# *.private.swiftinterface files that shadow the current API, so every manifest fails
# to link. We keep a copy of the manifest/plugin API without those stale files and
# point SwiftPM at it. Harmless when the toolchain is healthy; delete this wrapper
# once `swift build` works without it.
set -euo pipefail
SRC=/Library/Developer/CommandLineTools/usr/lib/swift/pm
DST="$HOME/Library/Application Support/FredDev/swiftpm-libs"
STAMP="$DST/.source-mtime"
cur="$(stat -f %m "$SRC/ManifestAPI/libPackageDescription.dylib")"
if [[ ! -f "$STAMP" || "$(cat "$STAMP")" != "$cur" ]]; then
  mkdir -p "$DST"
  for d in ManifestAPI PluginAPI; do
    rsync -a --delete --exclude '*.private.swiftinterface' "$SRC/$d/" "$DST/$d/"
  done
  echo "$cur" > "$STAMP"
fi
export SWIFTPM_CUSTOM_LIBS_DIR="$DST"
exec swift "$@"
