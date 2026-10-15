#!/usr/bin/env python3
"""Sign an existing app using a development identity and three matching profiles.

Secrets are read only from environment variables; decoded profiles and private
key material remain in a temporary directory and never enter build artifacts.
"""
# SPDX-License-Identifier: GPL-2.0-or-later
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
required = ("IOS_CERTIFICATE_P12_BASE64", "IOS_CERTIFICATE_PASSWORD", "IOS_APP_PROFILE_BASE64",
            "IOS_HELPER_PROFILE_BASE64", "IOS_WIDGET_PROFILE_BASE64", "IOS_TEAM_ID")
missing = [name for name in required if not os.environ.get(name)]
if missing:
    raise SystemExit("Missing GitHub signing secrets: " + ", ".join(missing))
team = os.environ["IOS_TEAM_ID"]
if not re.fullmatch(r"[A-Z0-9]{10}", team):
    raise SystemExit("IOS_TEAM_ID must be your Apple Developer team identifier")
config = json.loads((root / "artifacts/build-config.json").read_text(encoding="utf-8"))
unsigned_ipa = root / "artifacts/HuskRebuilt-unsigned.ipa"
if not unsigned_ipa.is_file():
    raise SystemExit("Missing IPA from a successful unsigned build")
def run(*args, **kwargs):
    # Never print arguments: security import receives a private-key password.
    result = subprocess.run(args, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{Path(args[0]).name} failed with exit code {result.returncode}: "
                           + result.stderr.decode(errors="replace"))
    return result.stdout
def load_profile(encoded, destination, bundle_id):
    destination.write_bytes(base64.b64decode(encoded, validate=True))
    profile = plistlib.loads(run("security", "cms", "-D", "-i", str(destination)))
    allowed = profile.get("Entitlements", {})
    if "iOS" not in profile.get("Platform", []):
        raise RuntimeError("Use iOS development provisioning profiles")
    if team not in profile.get("TeamIdentifier", []):
        raise RuntimeError("Provisioning profiles must all belong to IOS_TEAM_ID")
    if allowed.get("get-task-allow") is not True or not profile.get("ProvisionedDevices"):
        raise RuntimeError("Use iOS DEVELOPMENT profiles with registered devices and get-task-allow=true")
    expiry = profile["ExpirationDate"].replace(tzinfo=timezone.utc)
    if expiry <= datetime.now(timezone.utc):
        raise RuntimeError("A development provisioning profile has expired")
    if not allowed.get("application-identifier", "").endswith("." + bundle_id):
        raise RuntimeError(f"Profile App ID does not match {bundle_id}; use explicit App IDs for app and both extensions")
    return profile
original_keychains = shlex.split(run("security", "list-keychains", "-d", "user").decode())
with tempfile.TemporaryDirectory(prefix="husk-sign-", dir=os.environ.get("RUNNER_TEMP")) as temporary:
    temporary = Path(temporary)
    keychain = temporary / "signing.keychain-db"
    p12 = temporary / "identity.p12"
    password = secrets.token_urlsafe(36)
    profiles = []
    try:
        for label, encoded, bundle_id in (
            ("app", os.environ["IOS_APP_PROFILE_BASE64"], config["bundleIdentifier"]),
            ("helper", os.environ["IOS_HELPER_PROFILE_BASE64"], config["extensions"][0]),
            ("widget", os.environ["IOS_WIDGET_PROFILE_BASE64"], config["extensions"][1])):
            path = temporary / (label + ".mobileprovision")
            profiles.append((path, load_profile(encoded, path, bundle_id)))
        certificate_sets = [{hashlib.sha1(cert).hexdigest().upper()
                             for cert in profile.get("DeveloperCertificates", [])} for _, profile in profiles]
        device_sets = [set(profile.get("ProvisionedDevices", [])) for _, profile in profiles]
        if not set.intersection(*device_sets):
            raise RuntimeError("The three profiles must register at least one common installation device")
        shared_certs = set.intersection(*certificate_sets)
        if not shared_certs:
            raise RuntimeError("App and both extension profiles must authorize the same development certificate")
        p12.write_bytes(base64.b64decode(os.environ["IOS_CERTIFICATE_P12_BASE64"], validate=True))
        run("security", "create-keychain", "-p", password, str(keychain))
        run("security", "set-keychain-settings", "-lut", "21600", str(keychain))
        run("security", "unlock-keychain", "-p", password, str(keychain))
        run("security", "import", str(p12), "-P", os.environ["IOS_CERTIFICATE_PASSWORD"],
            "-A", "-t", "cert", "-f", "pkcs12", "-k", str(keychain))
        run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-k", password, str(keychain))
        run("security", "list-keychains", "-d", "user", "-s", str(keychain), *original_keychains)
        identities = run("security", "find-identity", "-v", "-p", "codesigning", str(keychain)).decode()
        valid = set(re.findall(r"\b[A-F0-9]{40}\b", identities))
        candidates = sorted(shared_certs & valid)
        if not candidates:
            raise RuntimeError("The P12 must contain the private key for a certificate authorized by ALL three profiles")
        identity = candidates[0]
        stage = temporary / "stage"
        stage.mkdir()
        run("ditto", "-x", "-k", str(unsigned_ipa), str(stage))
        app = stage / "Payload/Husk.app"
        bundles = [app, app / "PlugIns/HuskJITHelper.appex", app / "PlugIns/HuskDownloadsWidget.appex"]
        def sign(path, entitlement_file=None):
            args = ["codesign", "--force", "--sign", identity, "--keychain", str(keychain),
                    "--timestamp=none", "--generate-entitlement-der"]
            if entitlement_file:
                args += ["--entitlements", str(entitlement_file)]
            run(*args, str(path))
        for dylib in sorted(app.rglob("*.dylib"), key=lambda path: len(path.parts), reverse=True):
            sign(dylib)
        for framework in sorted(app.rglob("*.framework"), key=lambda path: len(path.parts), reverse=True):
            sign(framework)
        entitlement_files = []
        for bundle, (profile_path, profile) in zip(bundles, profiles):
            shutil.copyfile(profile_path, bundle / "embedded.mobileprovision")
            allowed = profile["Entitlements"]
            entitlement_path = temporary / (bundle.stem + ".entitlements")
            # Apple-authorized development entitlements only. Do not copy the
            # upstream TrollStore dynamic-codesigning entitlement to this IPA.
            claimed = {"get-task-allow": True, "application-identifier": allowed["application-identifier"],
                       "com.apple.developer.team-identifier": team}
            entitlement_path.write_bytes(plistlib.dumps(claimed))
            entitlement_files.append(entitlement_path)
        for index in (1, 2, 0):
            sign(bundles[index], entitlement_files[index])
        report = []
        for bundle in bundles:
            run("codesign", "--verify", "--deep", "--strict", str(bundle))
            embedded = plistlib.loads(run("codesign", "-d", "--entitlements", ":-", str(bundle)))
            if embedded.get("get-task-allow") is not True or embedded.get("com.apple.developer.team-identifier") != team:
                raise RuntimeError("Final app/extension lacks an authorized development signature")
            if embedded.get("dynamic-codesigning") or any(key.startswith("com.apple.private.") for key in embedded):
                raise RuntimeError("Unexpected private entitlement in developer-signed app")
            report.append({"bundle": bundle.name, "signatureVerified": True, "getTaskAllow": True})
        output = root / "artifacts/HuskRebuilt-development-device.ipa"
        run("ditto", "-c", "-k", "--keepParent", str(stage / "Payload"), str(output))
        (root / "artifacts/development-signing-report.json").write_text(json.dumps({
            "bundles": report, "certificateSHA1": identity,
            "ipaSHA256": hashlib.sha256(output.read_bytes()).hexdigest(),
            "installation": "Only devices registered in all corresponding development profiles; Developer Mode may be required. JIT is not guaranteed."}, indent=2) + "\n", encoding="utf-8")
        print("Verified development signatures for app and both extensions; wrote development IPA.")
    finally:
        subprocess.run(["security", "list-keychains", "-d", "user", "-s", *original_keychains], capture_output=True)
        if keychain.exists():
            subprocess.run(["security", "delete-keychain", str(keychain)], capture_output=True)
