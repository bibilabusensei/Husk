#!/usr/bin/env python3
"""Fail packaging if required runtime files or either embedded extension is absent."""
# SPDX-License-Identifier: GPL-2.0-or-later
import json
from pathlib import Path
import plistlib
import sys

app, config = Path(sys.argv[1]), json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
required = ["Frameworks/libqemu-aarch64-softmmu.dylib", "Frameworks/libANGLE-shared.dylib",
    "Frameworks/StikJIT.framework/StikJIT", "Frameworks/StikJIT.framework/Info.plist",
    "Frameworks/libFilePickerFix.dylib", "Frameworks/MoltenVK.framework/MoltenVK",
    "vmlinuz-virt", "initramfs-virt", "husk-jit.js",
    "edk2-aarch64-code.fd", "lineage-efi-vars-seed.fd", "lineage-vdb-seed.qcow2", "HuskRebuildProvenance.json"]
for relative in required:
    if not (app / relative).is_file():
        raise SystemExit(f"Required runtime asset is missing: {relative}")
bundles = [(app, config["bundleIdentifier"], "APPL"),
    (app / "PlugIns/HuskJITHelper.appex", config["extensions"][0], "XPC!"),
    (app / "PlugIns/HuskDownloadsWidget.appex", config["extensions"][1], "XPC!")]
for bundle, expected_id, package_type in bundles:
    with (bundle / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleVersion", "CFBundleShortVersionString"):
        if not info.get(key) or "$(" in str(info[key]):
            raise SystemExit(f"Missing or unresolved {key}: {bundle}")
    if info["CFBundleIdentifier"] != expected_id or info.get("CFBundlePackageType") != package_type:
        raise SystemExit(f"Bundle identity mismatch: {bundle}")
    if not (bundle / info["CFBundleExecutable"]).is_file():
        raise SystemExit(f"Missing executable: {bundle}")
    if package_type == "XPC!" and not info.get("NSExtension", {}).get("NSExtensionPointIdentifier"):
        raise SystemExit(f"Missing extension registration: {bundle}")
print("Validated runtime assets and app + two extension bundles.")
