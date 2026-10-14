#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo "Building iOS requires macOS and full Xcode." >&2; exit 1; }
SELECTED="$(python3 - <<'PY'
from pathlib import Path
import os, re
requested = os.environ.get("XCODE_PATH", "").strip()
if requested:
    selected = Path(requested)
else:
    candidates = [p for p in Path("/Applications").glob("Xcode_*.app") if "beta" not in p.name.lower()]
    def version(p):
        return tuple(int(x) for x in re.findall(r"\d+", p.stem))
    selected = max(candidates, key=version) if candidates else Path("/Applications/Xcode.app")
developer = selected / "Contents/Developer"
if not developer.is_dir():
    raise SystemExit(f"Full Xcode not found at {selected}")
print(developer)
PY
)"
if [ -n "${GITHUB_ENV:-}" ]; then printf 'DEVELOPER_DIR=%s\n' "$SELECTED" >> "$GITHUB_ENV"; fi
printf '%s\n' "$SELECTED"
