#!/usr/bin/env python3
"""Apply the distributable overlay and set a consistent app/extension ID prefix."""
# SPDX-License-Identifier: GPL-2.0-or-later
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys

root, source = (Path(arg).resolve() for arg in sys.argv[1:3])
overlay = root / "overlay"
if not overlay.is_dir():
    raise SystemExit("Missing overlay directory")
bundle_id = os.environ.get("HUSK_BUNDLE_IDENTIFIER", "com.husk.rebuilt")
if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
    raise SystemExit("HUSK_BUNDLE_IDENTIFIER must be a reverse DNS identifier")
files = []
for path in sorted(overlay.rglob("*")):
    if path.is_symlink():
        raise SystemExit(f"Overlay may not contain symlinks: {path}")
    if not path.is_file():
        continue
    relative = path.relative_to(overlay)
    target = source / relative
    if not target.resolve().is_relative_to(source):
        raise SystemExit(f"Overlay escapes checkout: {relative}")
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(path, target)
    files.append({"path": relative.as_posix(), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
project = source / "src/app/project.yml"
text, count = re.subn(r"(?m)^(\s*HUSK_BUNDLE_IDENTIFIER:)\s+[^\n]+$", rf"\1 {bundle_id}", project.read_text(encoding="utf-8"))
if count != 1:
    raise SystemExit("Expected one shared HUSK_BUNDLE_IDENTIFIER in project.yml")
project.write_text(text, encoding="utf-8", newline="\n")
artifact_dir = root / "artifacts"
artifact_dir.mkdir(exist_ok=True)
(artifact_dir / "overlay-files.json").write_text(json.dumps(files, indent=2) + "\n", encoding="utf-8")
(artifact_dir / "build-config.json").write_text(json.dumps({"bundleIdentifier": bundle_id,
    "extensions": [bundle_id + ".JITHelper", bundle_id + ".Downloads"]}, indent=2) + "\n", encoding="utf-8")
