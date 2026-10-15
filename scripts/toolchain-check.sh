#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/build/source"
[ "$(uname -s)" = Darwin ] || { echo "macOS + full Xcode required" >&2; exit 1; }
for tool in xcodebuild xcodegen meson ninja pkg-config python3 qemu-img rustup cargo cmake; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
mkdir -p "$ROOT/artifacts/logs"
# Check the same executable that Meson's find_installation('python3') uses,
# before spending time rebuilding ANGLE and the rest of the native runtime.
python3 -c 'import sys, yaml; print("Gallium host Python:", sys.executable, "PyYAML", yaml.__version__)'
{
    xcodebuild -version
    xcrun swiftc --version
    xcrun --sdk iphoneos --show-sdk-version
    rustc --version
    cargo --version
    meson --version
    ninja --version
    xcodegen --version
    sw_vers
} > "$ROOT/artifacts/logs/toolchain.txt" 2>&1
cat "$ROOT/artifacts/logs/toolchain.txt"
FRAMEWORKS="$SOURCE/src/app/Frameworks/StikJIT.xcframework/ios-arm64"
INTERFACE="$FRAMEWORKS/StikJIT.framework/Modules/StikJIT.swiftmodule/arm64-apple-ios.swiftinterface"
[ -f "$INTERFACE" ] || { echo "Missing pinned StikJIT XCFramework" >&2; exit 1; }
head -5 "$INTERFACE" > "$ROOT/artifacts/logs/stikjit-interface.txt"
printf 'import StikJIT\n' > "$ROOT/build/check-stikjit.swift"
# Probe the actual importer instead of assuming a runner's default Xcode can
# read a Swift 6.4 XCFramework. No binary is emitted by this check.
if ! xcrun swiftc -typecheck -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -target arm64-apple-ios26.0 -F "$FRAMEWORKS" "$ROOT/build/check-stikjit.swift" \
    > "$ROOT/artifacts/logs/stikjit-import.txt" 2>&1; then
    cat "$ROOT/artifacts/logs/stikjit-import.txt" >&2
    echo "StikJIT import failed. Upstream interface was produced by Apple Swift 6.4; select a compatible recent Xcode (possibly macos-26)." >&2
    exit 1
fi
rustup target add aarch64-apple-ios
