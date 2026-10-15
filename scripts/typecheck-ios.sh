#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Typecheck the actual complete Swift modules against the real iPhoneOS SDK.
# Usage: bash scripts/typecheck-ios.sh [complete-Husk-checkout-root]
# No native dependencies are compiled, substituted, or linked by this check.
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ARGUMENT="${1:-$PACKAGE_ROOT}"
SOURCE_ROOT="$(cd "$SOURCE_ARGUMENT" && pwd)"
APP_ROOT="$SOURCE_ROOT/src/app"
LOG_DIR="${IOS_TYPECHECK_LOG_DIR:-$PACKAGE_ROOT/artifacts/ios-swift-check}"
mkdir -p "$LOG_DIR"
LOG_DIR="$(cd "$LOG_DIR" && pwd)"

[ "$(uname -s)" = Darwin ] || { echo "Real iPhoneOS SDK typechecking requires macOS and full Xcode." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required to record the actual source manifest." >&2; exit 1; }
command -v xcrun >/dev/null || { echo "Full Xcode with xcrun is required." >&2; exit 1; }
if [ -z "${DEVELOPER_DIR:-}" ]; then
    export DEVELOPER_DIR="$(bash "$PACKAGE_ROOT/scripts/select-xcode.sh")"
fi

# Requiring these original application files rejects an overlay-only directory.
for relative in \
    src/app/project.yml \
    src/app/Husk/HuskApp.swift \
    src/app/Husk/HuskLog.swift \
    src/app/Husk/HuskBridge.h \
    src/app/Husk/HuskRPPairing.h \
    src/app/Husk/JITSetup.swift \
    src/app/Husk/JITSetupView.swift \
    src/app/Husk/JITDiagnostics.swift \
    src/app/HuskJITHelper/HuskJITMessages.swift \
    src/app/HuskJITHelper/HuskJITProgress.swift \
    src/app/HuskJITHelper/HuskJITHelper.swift \
    src/translation-layer/husk-tl.h \
    src/translation-layer-next/husk-tl-unity-app.h; do
    [ -s "$SOURCE_ROOT/$relative" ] || {
        echo "Missing actual source: $relative. Supply a complete checkout with the rebuild applied, not only overlay/." >&2
        exit 1
    }
done
for relative in src/app/Shared src/app/HuskDownloadsWidget src/translation-layer src/translation-layer-next; do
    [ -d "$SOURCE_ROOT/$relative" ] || { echo "Missing source directory: $relative" >&2; exit 1; }
done

# This intentionally mirrors project.yml's current deployment targets. Refuse
# to silently check the wrong availability range after the project changes.
python3 - "$APP_ROOT/project.yml" <<'PY'
from pathlib import Path
import re
import sys

project = Path(sys.argv[1]).read_text(encoding="utf-8")
global_target = re.search(r'(?ms)^options:\n(.*?)^settings:', project)
if not global_target or not re.search(r'(?m)^\s+iOS:\s*[\"\x27]?16\.0[\"\x27]?\s*$', global_target.group(1)):
    raise SystemExit("Expected the real project global iOS target 16.0; update typecheck configuration explicitly.")
for name, minimum in (("HuskJITHelper", "26.0"), ("HuskDownloadsWidget", "16.1")):
    target = re.search(r'(?ms)^  ' + re.escape(name) + r':\n(.*?)(?=^  [A-Za-z][A-Za-z0-9_]*:\n|\Z)', project)
    if not target or not re.search(r'(?m)^    deploymentTarget:\s*[\"\x27]?' + re.escape(minimum) + r'[\"\x27]?\s*$', target.group(1)):
        raise SystemExit(f"Expected the real {name} deployment target {minimum}; update this check explicitly.")
if not re.search(r'(?m)^    SWIFT_VERSION:\s*[\"\x27]?5\.0[\"\x27]?\s*$', project):
    raise SystemExit("Expected project Swift language version 5.0.")
PY

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
FRAMEWORKS="$APP_ROOT/Frameworks/StikJIT.xcframework/ios-arm64"
[ -s "$FRAMEWORKS/StikJIT.framework/StikJIT" ] || { echo "Missing actual StikJIT iOS arm64 framework binary." >&2; exit 1; }
[ -s "$FRAMEWORKS/StikJIT.framework/Modules/StikJIT.swiftmodule/arm64-apple-ios.swiftinterface" ] || {
    echo "Missing actual StikJIT iOS module interface." >&2; exit 1;
}
{
    printf 'Source root: %s\nDeveloper directory: %s\n' "$SOURCE_ROOT" "$DEVELOPER_DIR"
    xcodebuild -version
    xcrun swiftc --version
    printf 'iPhoneOS SDK: '
    xcrun --sdk iphoneos --show-sdk-version
    printf 'SDK path: %s\n' "$SDK_PATH"
    printf 'Targets: Husk=arm64-apple-ios16.0, HuskJITHelper=arm64-apple-ios26.0, HuskDownloadsWidget=arm64-apple-ios16.1\n'
    printf 'Mode: real SDK + actual full Swift sources + original C bridging declarations; typecheck only, no link/sign/device execution.\n'
} | tee "$LOG_DIR/toolchain.txt"

APP_SOURCES=()
HELPER_SOURCES=()
WIDGET_SOURCES=()
while IFS= read -r -d '' path; do APP_SOURCES+=("$path"); done < <(
    find "$APP_ROOT/Husk" -path "$APP_ROOT/Husk/Resources" -prune -o -type f -name '*.swift' -print0
)
for directory in "$APP_ROOT/Shared" "$SOURCE_ROOT/src/translation-layer" "$SOURCE_ROOT/src/translation-layer-next"; do
    while IFS= read -r -d '' path; do APP_SOURCES+=("$path"); done < <(find "$directory" -type f -name '*.swift' -print0)
done
APP_SOURCES+=("$APP_ROOT/HuskJITHelper/HuskJITMessages.swift" "$APP_ROOT/HuskJITHelper/HuskJITProgress.swift")
while IFS= read -r -d '' path; do HELPER_SOURCES+=("$path"); done < <(find "$APP_ROOT/HuskJITHelper" -type f -name '*.swift' -print0)
for directory in "$APP_ROOT/HuskDownloadsWidget" "$APP_ROOT/Shared"; do
    while IFS= read -r -d '' path; do WIDGET_SOURCES+=("$path"); done < <(find "$directory" -type f -name '*.swift' -print0)
done
[ "${#APP_SOURCES[@]}" -gt 2 ] && [ "${#HELPER_SOURCES[@]}" -ge 3 ] && [ "${#WIDGET_SOURCES[@]}" -ge 2 ] || {
    echo "Incomplete Swift module source sets; refusing a partial-source check." >&2; exit 1;
}

record_sources() {
    local module="$1"
    shift
    python3 - "$SOURCE_ROOT" "$LOG_DIR/$module-sources.json" "$module" "$@" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root, destination = Path(sys.argv[1]).resolve(), Path(sys.argv[2])
paths = [Path(value).resolve() for value in sys.argv[4:]]
if len(set(paths)) != len(paths):
    raise SystemExit("Duplicate Swift source in module list.")
for path in paths:
    if not path.is_relative_to(root) or not path.is_file():
        raise SystemExit(f"Module source is not an actual file in the checkout: {path}")
revision = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True, text=True)
record = {"module": sys.argv[3], "commit": revision.stdout.strip() if revision.returncode == 0 else None,
    "mode": "iPhoneOS SDK typecheck; no fake declarations or linked runtime substitutes",
    "sources": [{"path": path.relative_to(root).as_posix(), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                for path in sorted(paths)]}
destination.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
print(f"{record['module']}: {len(paths)} actual Swift files")
PY
}
record_sources Husk "${APP_SOURCES[@]}"
record_sources HuskJITHelper "${HELPER_SOURCES[@]}"
record_sources HuskDownloadsWidget "${WIDGET_SOURCES[@]}"

mkdir -p "$LOG_DIR/module-cache"
COMMON=(-typecheck -parse-as-library -swift-version 5 -sdk "$SDK_PATH" -module-cache-path "$LOG_DIR/module-cache")
printf 'module\tresult\n' > "$LOG_DIR/results.tsv"
FAILED=0
check_module() {
    local module="$1" target="$2"
    shift 2
    printf '\nChecking actual %s module (%s)...\n' "$module" "$target"
    if xcrun swiftc "${COMMON[@]}" -module-name "$module" -target "$target" "$@" 2>&1 | tee "$LOG_DIR/$module.log"; then
        printf '%s\tpassed\n' "$module" >> "$LOG_DIR/results.tsv"
    else
        printf '%s\tfailed\n' "$module" >> "$LOG_DIR/results.tsv"
        FAILED=1
    fi
}

# The original bridging header contains declarations from the real repository;
# their native implementations are required at link time, not for typecheck.
check_module Husk arm64-apple-ios16.0 \
    -import-objc-header "$APP_ROOT/Husk/HuskBridge.h" \
    -I "$APP_ROOT/Husk" -F "$APP_ROOT/Frameworks" \
    "${APP_SOURCES[@]}"
check_module HuskJITHelper arm64-apple-ios26.0 \
    -application-extension -F "$FRAMEWORKS" \
    "${HELPER_SOURCES[@]}"
check_module HuskDownloadsWidget arm64-apple-ios16.1 \
    -application-extension "${WIDGET_SOURCES[@]}"

cat "$LOG_DIR/results.tsv"
if [ "$FAILED" -ne 0 ]; then
    echo "At least one actual iOS Swift module failed typechecking. Read the per-module logs." >&2
    exit 1
fi
echo "All three actual Swift modules passed iPhoneOS SDK typechecking. Native build, linking, packaging, signing and on-device JIT remain separate checks."
