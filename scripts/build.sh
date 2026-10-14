#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/artifacts/logs" "$ROOT/build"
if [ -z "${DEVELOPER_DIR:-}" ]; then export DEVELOPER_DIR="$(bash "$ROOT/scripts/select-xcode.sh")"; fi
bash "$ROOT/scripts/prepare-source.sh" 2>&1 | tee "$ROOT/artifacts/logs/prepare.log"
bash "$ROOT/scripts/toolchain-check.sh" 2>&1 | tee "$ROOT/artifacts/logs/preflight.log"
export DD="$(mktemp -d "$ROOT/build/derived-data.XXXXXX")"
printf '%s\n' "$DD" > "$ROOT/build/derived-data-path.txt"
finish() {
    local status=$?
    trap - EXIT
    [ ! -f "$DD/build.log" ] || cp "$DD/build.log" "$ROOT/artifacts/logs/xcodebuild.log"
    python3 "$ROOT/scripts/source-provenance.py" "$ROOT" "$ROOT/build/source" || status=1
    printf '%s\n' "$status" > "$ROOT/artifacts/build-exit-status.txt"
    exit "$status"
}
trap finish EXIT
# Run the REAL upstream dependency, QEMU, ANGLE, MoltenVK, Rust and app build.
# Pipeline failures propagate; fresh DerivedData prevents stale IPA reuse.
bash "$ROOT/build/source/scripts/ci_build.sh" "$ROOT/build/upstream-package.ipa" \
    2>&1 | tee "$ROOT/artifacts/logs/full-build.log"
APP="$DD/Build/Products/Release-iphoneos/Husk.app"
python3 "$ROOT/scripts/source-provenance.py" "$ROOT" "$ROOT/build/source"
cp "$ROOT/artifacts/provenance.json" "$APP/HuskRebuildProvenance.json"
python3 "$ROOT/scripts/validate-bundle.py" "$APP" "$ROOT/artifacts/build-config.json"
bash "$ROOT/scripts/package-rebuilt.sh" "$APP"
bash "$ROOT/scripts/archive-source.sh"
