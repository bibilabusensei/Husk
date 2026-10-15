#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Supply a built unsigned Husk.app}"
STAGE="$(mktemp -d "$ROOT/build/package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/Husk.app"
SAPP="$STAGE/Payload/Husk.app"
# Remove any imported developer signature or profile before publishing the
# explicitly unsigned artifact. Re-signable ad-hoc is a separate artifact.
find "$SAPP" -type d -name _CodeSignature -prune -exec rm -rf {} +
find "$SAPP" -name embedded.mobileprovision -type f -delete
find "$SAPP" -type f -print0 | while IFS= read -r -d '' item; do
    if file -b "$item" | grep -q 'Mach-O'; then codesign --remove-signature "$item" 2>/dev/null || true; fi
done
(cd "$STAGE" && zip -qry "$ROOT/artifacts/HuskRebuilt-unsigned.ipa" Payload)
sign() { codesign --force --sign - --timestamp=none "$@"; }
find "$SAPP" -type f -name '*.dylib' -print0 | while IFS= read -r -d '' item; do sign "$item"; done
find "$SAPP" -type d -name '*.framework' -print0 | while IFS= read -r -d '' item; do sign "$item"; done
find "$SAPP/PlugIns" -type d -name '*.appex' -print0 | while IFS= read -r -d '' item; do sign "$item"; done
sign --entitlements "$ROOT/scripts/development.entitlements" "$SAPP"
codesign --verify --deep --strict "$SAPP"
codesign -d --entitlements :- "$SAPP" > "$ROOT/artifacts/logs/ad-hoc-entitlements.plist" 2>/dev/null
(cd "$STAGE" && zip -qry "$ROOT/artifacts/HuskRebuilt-adhoc-resign-required.ipa" Payload)
shasum -a 256 "$ROOT/artifacts/HuskRebuilt-"*.ipa > "$ROOT/artifacts/ipa-sha256.txt"
