#!/usr/bin/env python3
"""Package a real tvOS Release archive for personal signing; never sign or upload it."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile

BUNDLE = "com.ipocket.MijiaLAN.TVPrototype"
ROOT = Path(__file__).resolve().parents[2]


def validate_bundle(bundle, identifier, version=None, build=None):
    info = plistlib.loads((bundle / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != identifier:
        raise ValueError("Unexpected bundle identifier")
    if info.get("CFBundleSupportedPlatforms") != ["AppleTVOS"]:
        raise ValueError("Only a tvOS device archive can be published")
    if info.get("DTPlatformName") != "appletvos":
        raise ValueError("A simulator bundle cannot be published as a device package")
    current_version, current_build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not re.fullmatch(r"(?:0|[1-9][0-9]{0,5})\.(?:0|[1-9][0-9]{0,5})\.(?:0|[1-9][0-9]{0,5})", current_version):
        raise ValueError("Invalid TV release version")
    if not re.fullmatch(r"[1-9][0-9]*", current_build) or int(current_build) > 2_147_483_647:
        raise ValueError("Invalid TV build number")
    if version is not None and (current_version, current_build) != (version, build):
        raise ValueError("App and extension versions do not match")
    executable = bundle / info["CFBundleExecutable"]
    architectures = subprocess.check_output(["xcrun", "lipo", "-archs", str(executable)], text=True).strip().split()
    if architectures != ["arm64"]:
        raise ValueError("The device package must contain only arm64")
    load_commands = subprocess.check_output(["xcrun", "vtool", "-show-build", str(executable)], text=True)
    if not re.search(r"\bplatform\s+TVOS\b", load_commands):
        raise ValueError("The executable does not target the tvOS device platform")
    if (bundle / "embedded.mobileprovision").exists() or (bundle / "_CodeSignature").exists():
        raise ValueError("The public unsigned artifact must not contain personal signing material")
    return info


def package(archive, output, checkouts):
    app = archive / "Products/Applications/MijiaLANTVPrototype.app"
    info = validate_bundle(app, BUNDLE)
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    plugins = list((app / "PlugIns").glob("*.appex"))
    if len(plugins) != 1 or plugins[0].name != "MijiaLANTVTunnel.appex":
        raise ValueError("The archive must embed exactly the TV tunnel extension")
    tunnel_info = validate_bundle(plugins[0], BUNDLE + ".Tunnel", version, build)
    if tunnel_info.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.networkextension.packet-tunnel":
        raise ValueError("Missing packet tunnel extension")
    for candidate in (info, tunnel_info):
        if not {"_hap._tcp", "_miio._udp"}.issubset(candidate.get("NSBonjourServices", [])):
            raise ValueError("App and extension must both declare the Bonjour services")
    for path in app.rglob("*"):
        if path.name == "embedded.mobileprovision" or path.name == "_CodeSignature":
            raise ValueError("Unexpected embedded signing material")
    output.mkdir(parents=True, exist_ok=True)
    name = f"MijiaLAN-tvOS-{version}-b{build}.ipa"
    ipa = output / name
    if ipa.exists():
        raise ValueError("Refusing to replace an existing package")
    with tempfile.TemporaryDirectory(prefix="mijialan-tvos-package-") as temporary:
        staging = Path(temporary)
        payload = staging / "Payload"
        payload.mkdir()
        staged_app = payload / app.name
        shutil.copytree(app, staged_app, symlinks=True)
        licenses = staged_app / "ThirdPartyLicenses"
        projects = {"MijiaLAN": ROOT, **{p.name: p for p in (ROOT / "Vendor").iterdir() if p.is_dir()},
                    **{p.name: p for p in checkouts.iterdir() if p.is_dir()}}
        copied = set()
        for project, folder in projects.items():
            files = [folder / "LICENSE", folder / "THIRD_PARTY_NOTICES.md"] if folder == ROOT else folder.rglob("*")
            for source in files:
                if not source.is_file() or ".git" in source.relative_to(folder).parts:
                    continue
                if not source.name.upper().startswith(("LICENSE", "NOTICE", "COPYING", "PATENTS", "THIRD_PARTY_NOTICES")):
                    continue
                target = licenses / project / source.relative_to(folder)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
                copied.add(project)
        icon_license = licenses / "lucide/LICENSE"
        icon_license.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / "Resources/Licenses/lucide/LICENSE", icon_license)
        required = {"MijiaLAN", "MenuBarMijia", "hap-swift", "hass-xiaomi-miot", "homebridge-miot",
                    "mdns-swift", "swift-asn1", "swift-atomics", "swift-collections", "swift-crypto", "swift-log", "swift-nio", "swift-system"}
        if not required.issubset(copied):
            raise ValueError("Missing dependency licenses: " + ", ".join(sorted(required - copied)))
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(payload), str(ipa.resolve())], check=True)
    with zipfile.ZipFile(ipa) as contents:
        if contents.testzip() is not None:
            raise ValueError("Invalid IPA archive")
        if not all(name.startswith("Payload/") or name.startswith("__MACOSX/") for name in contents.namelist()):
            raise ValueError("Unexpected IPA contents")
    sha = hashlib.sha256(ipa.read_bytes()).hexdigest()
    (output / "SHA256SUMS.txt").write_text(f"{sha}  {name}\n")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip())
    manifest = dict(platform="tvOS", version=version, build=int(build), bundleIdentifier=BUNDLE,
        tag=f"tvos-v{version}-b{build}", architecture="arm64", minimumOS=info["MinimumOSVersion"],
        signing="unsigned-requires-personal-signing", sourceCommit=revision, sourceTreeDirty=dirty,
        artifact=name, sha256=sha, size=ipa.stat().st_size,
        requiredCapabilities=["packet-tunnel-provider", "App Groups", "shared Keychain"],
        dependencyLicensesBundled=True,
        physicalAppleTVVerified=False)
    (output / "tvos-package.json").write_text(json.dumps(manifest, indent=2) + "\n")
    shutil.copy2(ROOT / "Experiments/AppleTV/INSTALL.md", output / "INSTALL.md")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--checkouts", type=Path, required=True, help="Archive build's SourcePackages/checkouts directory")
    arguments = parser.parse_args()
    package(arguments.archive.resolve(), arguments.output.resolve(), arguments.checkouts.resolve())
