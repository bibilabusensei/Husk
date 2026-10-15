#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/artifacts/logs" "$ROOT/build"
if [ -z "${DEVELOPER_DIR:-}" ]; then export DEVELOPER_DIR="$(bash "$ROOT/scripts/select-xcode.sh")"; fi
bash "$ROOT/scripts/prepare-source.sh" 2>&1 | tee "$ROOT/artifacts/logs/prepare.log"
# virglrenderer invokes python3 from PATH to generate its Gallium format tables.
# Keep its Python modules in a build-local environment: Homebrew's interpreter
# is externally managed and a globally installed meson does not install PyYAML.
python3 -m venv "$ROOT/build/host-python"
"$ROOT/build/host-python/bin/python3" -m pip install --disable-pip-version-check \
    -r "$ROOT/scripts/requirements-host.txt" 2>&1 | tee "$ROOT/artifacts/logs/host-python-install.log"
export PATH="$ROOT/build/host-python/bin:$PATH"
bash "$ROOT/scripts/toolchain-check.sh" 2>&1 | tee "$ROOT/artifacts/logs/preflight.log"
export DD="$(mktemp -d "$ROOT/build/derived-data.XXXXXX")"
printf '%s\n' "$DD" > "$ROOT/build/derived-data-path.txt"
finish() {
    local status=$?
    trap - EXIT
    # Diagnostics must not replace the real build exit code, including when
    # a full disk or missing permissions prevent collecting the logs.
    if [ -f "$DD/build.log" ]; then
        if ! cp "$DD/build.log" "$ROOT/artifacts/logs/xcodebuild.log"; then
            echo "Warning: could not preserve Xcode build.log; original build exit code is $status." >&2
        fi
    fi
    if [ -d "$ROOT/build/source/build/logs" ]; then
        if mkdir -p "$ROOT/artifacts/logs/native"; then
            if ! cp -R "$ROOT/build/source/build/logs/." "$ROOT/artifacts/logs/native/"; then
                echo "Warning: could not preserve all native build logs; original build exit code is $status." >&2
            fi
        else
            echo "Warning: could not create native log artifact directory; original build exit code is $status." >&2
        fi
    fi
    if ! python3 "$ROOT/scripts/source-provenance.py" "$ROOT" "$ROOT/build/source"; then
        echo "Warning: final provenance refresh failed; original build exit code is $status." >&2
    fi
    if ! printf '%s\n' "$status" > "$ROOT/artifacts/build-exit-status.txt"; then
        echo "Warning: could not record build exit status $status in artifacts." >&2
    fi
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
