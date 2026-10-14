#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_BUILD_DIR="$PACKAGE_ROOT/work/checks"
CHECK_TARGET="$(uname -m)-apple-macosx14.0"
mkdir -p "$CHECK_BUILD_DIR"

swiftc -swift-version 5 -parse-as-library -target "$CHECK_TARGET" \
  "$PACKAGE_ROOT/overlay/src/app/HuskJITHelper/HuskJITMessages.swift" \
  "$PACKAGE_ROOT/checks/MessageCompatibility.swift" \
  -o "$CHECK_BUILD_DIR/message-compatibility"
"$CHECK_BUILD_DIR/message-compatibility"

swiftc -swift-version 5 -parse-as-library -target "$CHECK_TARGET" \
  "$PACKAGE_ROOT/overlay/src/app/HuskJITHelper/HuskJITProgress.swift" \
  "$PACKAGE_ROOT/checks/ProgressTransport.swift" \
  -o "$CHECK_BUILD_DIR/progress-transport"
"$CHECK_BUILD_DIR/progress-transport"
