#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/scripts/source-provenance.py" "$ROOT" "$ROOT/build/source"
# Keep third_party/build: upstream stores the dependency SOURCE and patches in
# that directory. Only its compiler products are excluded, never the whole dir.
tar -czf "$ROOT/artifacts/HuskRebuilt-corresponding-source.tar.gz" \
    --exclude='.git' --exclude='build/source/build' --exclude='*/_husk_build' \
    --exclude='*/target' --exclude='*/node_modules' \
    -C "$ROOT" build/source build/license-sources overlay scripts docs \
    README.md LICENSE UPSTREAM.json .github checks artifacts/provenance.json artifacts/build-config.json
shasum -a 256 "$ROOT/artifacts/HuskRebuilt-corresponding-source.tar.gz" > "$ROOT/artifacts/source-sha256.txt"
