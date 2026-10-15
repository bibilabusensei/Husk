#!/usr/bin/env python3
"""Record exact source, overlay, fetched archives and nested git revisions."""
# SPDX-License-Identifier: GPL-2.0-or-later
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root, source = (Path(arg).resolve() for arg in sys.argv[1:3])
def git(directory, *args):
    result = subprocess.run(["git", "-C", str(directory), *args], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None
def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()
pins = json.loads((root / "UPSTREAM.json").read_text(encoding="utf-8"))
overlay = [{"path": p.relative_to(root / "overlay").as_posix(), "sha256": digest(p)}
           for p in sorted((root / "overlay").rglob("*")) if p.is_file()]
overlay_digest = hashlib.sha256(json.dumps(overlay, sort_keys=True).encode()).hexdigest()
repos, archives, locks = [], [], []
for directory in (source / "third_party", root / "build/license-sources"):
    if not directory.is_dir():
        continue
    for current, dirs, files in os.walk(directory):
        current = Path(current)
        if ".git" in dirs or ".git" in files:
            repos.append({"path": str(current.relative_to(root)), "commit": git(current, "rev-parse", "HEAD"),
                          "remote": git(current, "remote", "get-url", "origin")})
        dirs[:] = [d for d in dirs if d not in (".git", "target", "node_modules", "_husk_build")]
        for name in files:
            path = current / name
            if path.is_symlink():
                continue
            if name.endswith((".tar.gz", ".tar.xz", ".tar.bz2", ".tgz", ".zip", ".crate")) or name in ("Cargo.lock", "Package.resolved"):
                entry = {"path": str(path.relative_to(root)), "sha256": digest(path), "size": path.stat().st_size}
                (locks if name in ("Cargo.lock", "Package.resolved") else archives).append(entry)
# The app's pairing crate is outside third_party. Record its actual lockfile
# explicitly rather than scanning the whole source tree or duplicating walks.
pairing_lock = source / "src/rppairing-ios/Cargo.lock"
if pairing_lock.is_file() and not pairing_lock.is_symlink():
    locks.append({"path": str(pairing_lock.relative_to(root)),
                  "sha256": digest(pairing_lock), "size": pairing_lock.stat().st_size})
artifacts = root / "artifacts"
artifacts.mkdir(exist_ok=True)
git_root = git(root, "rev-parse", "--show-toplevel")
own_checkout = git_root and Path(git_root).resolve() == root
fork_sha = os.environ.get("GITHUB_SHA") or (git(root, "rev-parse", "HEAD") if own_checkout else None)
actual_sha = git(source, "rev-parse", "HEAD")
record = {"format": 1, "upstream": pins, "actualUpstreamCommit": actual_sha,
    "overlayCommit": fork_sha, "overlayTreeSHA256": overlay_digest, "overlayFiles": overlay,
    "nestedRepositories": repos, "downloadedArchives": archives, "dependencyLockfiles": locks,
    "note": "The overlay digest is authoritative for local packages without git metadata. Download hashes and actual repository commits record dependency resolutions; this is not a reproducible-build attestation."}
(artifacts / "provenance.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
if actual_sha != pins["commit"]:
    raise SystemExit("Prepared source is not the required upstream commit")
