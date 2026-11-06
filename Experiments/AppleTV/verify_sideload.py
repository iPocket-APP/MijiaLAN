#!/usr/bin/env python3
"""Inspect a template or Sideloadly-exported IPA without installing it or changing any certificate."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import tempfile
import zipfile

NE = "com.apple.developer.networking.networkextension"
GROUPS = "com.apple.security.application-groups"
KEYCHAIN = "keychain-access-groups"
TEAM = "com.apple.developer.team-identifier"
TEMPLATE_TEAM = "UNSIGNED00"


def run(*args):
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        reason = result.stderr.decode(errors="replace").strip().replace(args[-1], Path(args[-1]).name)
        raise ValueError("Signature inspection failed: " + args[0] + " / " + reason[-600:])
    return result.stdout


def permitted(value, rules):
    return any(value == rule or (rule.endswith("*") and "*" not in rule[:-1] and value.startswith(rule[:-1])) for rule in rules)


def inspect_bundle(bundle, template, platform, device, scratch):
    info = plistlib.loads((bundle / "Info.plist").read_bytes())
    bundle_id = info["CFBundleIdentifier"]
    required_platform = "AppleTVOS" if platform == "tvOS" else "iPhoneOS"
    if info.get("CFBundleSupportedPlatforms") != [required_platform]:
        raise ValueError("Wrong device platform; a simulator package cannot be sideloaded")
    executable = bundle / info["CFBundleExecutable"]
    architectures = run("xcrun", "lipo", "-archs", str(executable)).decode().split()
    if not architectures or not set(architectures).issubset({"arm64", "arm64e"}):
        raise ValueError("The executable does not contain only device ARM architectures")
    expected_load_platform = "TVOS" if platform == "tvOS" else "IOS"
    if not re.search(r"\bplatform\s+" + expected_load_platform + r"\b", run("xcrun", "vtool", "-show-build", str(executable)).decode()):
        raise ValueError("The executable targets a different platform from its metadata")
    run("codesign", "--verify", "--strict", str(bundle))
    signed = plistlib.loads(run("codesign", "-d", "--entitlements", ":-", str(bundle)))
    if "packet-tunnel-provider" not in signed.get(NE, []):
        raise ValueError("Packet Tunnel permission was removed by re-signing")
    identity = signed.get("application-identifier", "")
    if not identity.endswith("." + bundle_id) or "*" in identity:
        raise ValueError("Signed identity does not match the rewritten bundle ID")
    for key in (GROUPS, KEYCHAIN):
        if not signed.get(key) or any("*" in value for value in signed[key]):
            raise ValueError("Missing concrete shared permissions: " + key)
    profile_path = bundle / "embedded.mobileprovision"
    if template:
        details = subprocess.run(["codesign", "-dvv", str(bundle)], capture_output=True, text=True)
        if signed.get(TEAM) != TEMPLATE_TEAM or profile_path.exists() or "Signature=adhoc" not in details.stderr:
            raise ValueError("Expected a certificate-free entitlement template without a provisioning profile")
    else:
        if not profile_path.is_file():
            raise ValueError("Re-signing must embed a provisioning profile in both App and NE")
        profile = plistlib.loads(run("security", "cms", "-D", "-i", str(profile_path)))
        allowed = profile.get("Entitlements", {})
        expiration = profile["ExpirationDate"].replace(tzinfo=timezone.utc)
        if expiration <= datetime.now(timezone.utc):
            raise ValueError("The provisioning profile has expired")
        if platform not in profile.get("Platform", []):
            raise ValueError("The profile is for a different Apple platform")
        if signed.get(TEAM) not in profile.get("TeamIdentifier", []) or signed.get(TEAM) == TEMPLATE_TEAM:
            raise ValueError("Profile and signed team do not match")
        if not permitted(identity, [allowed.get("application-identifier", "")]):
            raise ValueError("The profile does not authorize this application identifier")
        if "packet-tunnel-provider" not in allowed.get(NE, []):
            raise ValueError("The Apple profile does not grant Network Extensions; a re-signing tool cannot grant it")
        for key in (GROUPS, KEYCHAIN):
            if not all(permitted(value, allowed.get(key, [])) for value in signed[key]):
                raise ValueError("The profile does not authorize the signed shared permissions: " + key)
        devices = profile.get("ProvisionedDevices", [])
        if not devices and not profile.get("ProvisionsAllDevices", False):
            raise ValueError("This is not a direct-device provisioning profile; an App Store-signed IPA requires Apple distribution")
        if device and device not in devices and not profile.get("ProvisionsAllDevices", False):
            raise ValueError("This device is not included in the provisioning profile")
        prefix = scratch / ("cert-" + bundle.name)
        run("codesign", "-d", "--extract-certificates=" + str(prefix), str(bundle))
        certificate = Path(str(prefix) + "0")
        if not certificate.exists() or hashlib.sha256(certificate.read_bytes()).digest() not in {
                hashlib.sha256(item).digest() for item in profile.get("DeveloperCertificates", [])}:
            raise ValueError("The signing certificate is not authorized by the provisioning profile")
    return info, signed


def verify(ipa, template=False, platform="tvOS", device=None):
    with tempfile.TemporaryDirectory(prefix="mijialan-sideload-check-") as temporary:
        directory = Path(temporary)
        with zipfile.ZipFile(ipa) as zipped:
            if len(zipped.infolist()) > 100_000 or sum(item.file_size for item in zipped.infolist()) > 1024**3:
                raise ValueError("IPA exceeds inspection limits")
            for item in zipped.infolist():
                path = PurePosixPath(item.filename)
                if path.is_absolute() or ".." in path.parts or "\\" in item.filename or stat.S_ISLNK(item.external_attr >> 16):
                    raise ValueError("IPA contains an unsupported or unsafe path")
        run("ditto", "-x", "-k", str(ipa.resolve()), str(directory))
        apps = list((directory / "Payload").glob("*.app"))
        if len(apps) != 1:
            raise ValueError("Expected exactly one application")
        app = apps[0]
        providers = []
        for extension in (app / "PlugIns").glob("*.appex"):
            info = plistlib.loads((extension / "Info.plist").read_bytes())
            if info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.networkextension.packet-tunnel":
                providers.append(extension)
        if len(providers) != 1:
            raise ValueError("Exactly one Packet Tunnel extension must survive re-signing; do not remove PlugIns")
        app_info, app_signed = inspect_bundle(app, template, platform, device, directory)
        ne_info, ne_signed = inspect_bundle(providers[0], template, platform, device, directory)
        if app_signed[TEAM] != ne_signed[TEAM] or not ne_info["CFBundleIdentifier"].startswith(app_info["CFBundleIdentifier"] + "."):
            raise ValueError("App and NE identities do not belong to the same re-signed installation")
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            if app_info[key] != ne_info[key]:
                raise ValueError("App and NE versions do not match")
        for key in (GROUPS, KEYCHAIN):
            if not set(app_signed[key]).intersection(ne_signed[key]):
                raise ValueError("App and NE have no common signed sharing permission: " + key)
        run("codesign", "--verify", "--deep", "--strict", str(app))
        return dict(platform=platform, version=app_info["CFBundleShortVersionString"], build=app_info["CFBundleVersion"],
            appBundleIdentifier=app_info["CFBundleIdentifier"], providerBundleIdentifier=ne_info["CFBundleIdentifier"],
            codeSignaturesVerified=True, packetTunnelEntitlementsPresent=True,
            commonAppGroup=True, commonKeychain=True, appleProfilesVerified=not template,
            signingMode="entitlement-template" if template else "device-provisioned",
            deviceRegistrationChecked=not template and device is not None, installedOrLaunched=False,
            sha256=hashlib.sha256(ipa.read_bytes()).hexdigest())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--template", action="store_true", help="Verify a public entitlement template, which is not installable as-is")
    parser.add_argument("--platform", choices=["tvOS", "iOS"], default="tvOS")
    parser.add_argument("--device", help="Privately check this device's registration in both profiles")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        result = verify(args.ipa, args.template, args.platform, args.device)
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException, zipfile.BadZipFile) as error:
        raise SystemExit(str(error))
    output = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(output)
    print(output, end="")
