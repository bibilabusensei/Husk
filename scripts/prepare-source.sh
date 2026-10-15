#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/build/source"
mkdir -p "$ROOT/build" "$ROOT/artifacts/logs"
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
eval "$(python3 - "$ROOT/UPSTREAM.json" <<'PY'
import json, shlex, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
for key, value in {"UPSTREAM_URL": cfg["repository"], "UPSTREAM_SHA": cfg["commit"],
                   "STIKJIT_URL": cfg["stikjit"]["repository"], "STIKJIT_SHA": cfg["stikjit"]["commit"]}.items():
    print(f"{key}={shlex.quote(value)}")
PY
)"
clone_pin() {
    local url="$1" sha="$2" dst="$3"
    if [ -e "$dst" ]; then
        echo "Refusing to overwrite existing checkout $dst. Use a fresh package directory for a clean rebuild." >&2
        exit 1
    fi
    git init -q "$dst"
    git -C "$dst" remote add origin "$url"
    git -C "$dst" fetch --depth 1 origin "$sha"
    git -C "$dst" checkout --detach FETCH_HEAD
    [ "$(git -C "$dst" rev-parse HEAD)" = "$sha" ] || { echo "Pinned source SHA mismatch" >&2; exit 1; }
    git -C "$dst" submodule update --init --recursive
}
clone_pin "$UPSTREAM_URL" "$UPSTREAM_SHA" "$SOURCE"
clone_pin "$STIKJIT_URL" "$STIKJIT_SHA" "$ROOT/build/license-sources/StikJIT"
# This is a complete upstream checkout: QEMU, translation-layer sources and all
# dependency build scripts are retained. The overlay replaces only listed files.
python3 "$ROOT/scripts/apply-overlay.py" "$ROOT" "$SOURCE"
# XcodeGen is deliberately deferred to upstream package_ipa.sh after native
# libraries have been staged. Its declared framework paths do not exist yet.
python3 "$ROOT/scripts/source-provenance.py" "$ROOT" "$SOURCE"
printf 'Prepared complete pinned source: %s\n' "$SOURCE"
