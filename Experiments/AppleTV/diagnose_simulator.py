#!/usr/bin/env python3
"""Read-only NE API/signature A/B probes. Does not save a VPN or touch the Mac's network services."""
import argparse
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def run(arguments, *, timeout=120, check=True):
    result = subprocess.run([str(a) for a in arguments], capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{arguments[0]} exited {result.returncode}: {result.stderr[-3000:]}")
    return result


def simulator_entitlements(executable):
    """Xcode embeds simulator permissions in __TEXT, separately from codesign's entitlement blob."""
    data = Path(executable).read_bytes()
    if struct.unpack_from("<I", data)[0] != 0xFEEDFACF:
        raise ValueError("Expected a thin little-endian Mach-O 64-bit executable")
    count = struct.unpack_from("<I", data, 16)[0]
    position = 32
    for _ in range(count):
        command, length = struct.unpack_from("<II", data, position)
        if command == 0x19:  # LC_SEGMENT_64
            sections = struct.unpack_from("<I", data, position + 64)[0]
            for index in range(sections):
                section = position + 72 + index * 80
                name = data[section:section + 16].rstrip(b"\0")
                if name == b"__entitlements":
                    size, offset = struct.unpack_from("<QI", data, section + 40)
                    return plistlib.loads(data[offset:offset + size].rstrip(b"\0"))
        position += length
    return {}


def signature(executable):
    verification = run(["codesign", "--verify", "--strict", executable], check=False)
    entitlements = run(["codesign", "-d", "--entitlements", ":-", executable], check=False)
    return {
        "verificationPassed": verification.returncode == 0,
        "simulatorEntitlements": simulator_entitlements(executable),
        "codeSignatureEntitlements": plistlib.loads(entitlements.stdout.encode()) if entitlements.stdout else {},
    }


def inventory(simulator):
    runtime = Path(run(["xcrun", "simctl", "getenv", simulator, "SIMULATOR_ROOT"]).stdout.strip())
    services = {}
    daemon_directory = runtime / "System/Library/LaunchDaemons"
    for path in daemon_directory.rglob("*.plist"):
        try:
            value = plistlib.loads(path.read_bytes())
        except (OSError, plistlib.InvalidFileException):
            continue
        if any(name in json.dumps(value).lower() for name in ["nehelper", "nesessionmanager"]):
            services[str(path.relative_to(runtime))] = value
    registered = run(["xcrun", "simctl", "spawn", simulator, "launchctl", "list"]).stdout
    return {
        "simulatorID": simulator,
        "runtimeVersion": run(["xcrun", "simctl", "getenv", simulator, "SIMULATOR_RUNTIME_VERSION"]).stdout.strip(),
        "runtimeRoot": str(runtime),
        "nehelperExecutablePresent": (runtime / "usr/libexec/nehelper").is_file(),
        "nesessionmanagerExecutablePresent": (runtime / "usr/libexec/nesessionmanager").is_file(),
        "relatedLaunchDaemonPlists": services,
        "relatedRegisteredServices": [line for line in registered.splitlines() if
                                      any(name in line.lower() for name in ["nehelper", "nesessionmanager"])],
    }


def probe(simulator, output, label, personal_vpn, identity, team):
    directory = output / label
    app = directory / "NEPreferencesProbe.app"
    app.mkdir(parents=True, exist_ok=True)
    bundle = "com.ipocket.MijiaLAN.NEIPCProbe." + label
    entitlements = {
        "application-identifier": f"{team}.{bundle}",
        "com.apple.developer.team-identifier": team,
        "com.apple.developer.networking.networkextension": ["packet-tunnel-provider"],
    }
    if personal_vpn:
        entitlements["com.apple.developer.networking.vpn.api"] = ["allow-vpn"]
    entitlement_file = directory / "entitlements.plist"
    entitlement_file.write_bytes(plistlib.dumps(entitlements))
    (app / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle, "CFBundleName": "NEPreferencesProbe", "CFBundleExecutable": "NEPreferencesProbe",
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "CFBundleSupportedPlatforms": ["AppleTVSimulator"], "UIDeviceFamily": [3],
        "LSRequiresIPhoneOS": True, "MinimumOSVersion": "18.0", "UILaunchScreen": {},
    }))
    sdk = run(["xcrun", "--sdk", "appletvsimulator", "--show-sdk-path"]).stdout.strip()
    executable = app / "NEPreferencesProbe"
    compiler = run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    "-target", "arm64-apple-tvos18.0-simulator", "-sdk", sdk,
                    HERE / "Diagnostics/NEPreferencesProbe.swift", "-o", executable,
                    "-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift",
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements",
                    "-Xlinker", entitlement_file])
    (directory / "compiler.log").write_text(compiler.stdout + compiler.stderr)
    # Match Xcode's simulator packaging: simulated permissions are in __TEXT, not the host
    # code signature. Host entitlement restrictions must not be introduced into this control.
    signing = run(["codesign", "--force", "--sign", identity, "--timestamp=none", app])
    (directory / "signing.log").write_text(signing.stdout + signing.stderr)
    result = {"label": label, "personalVPNEntitlement": personal_vpn,
              "signing": "ad-hoc" if identity == "-" else "Apple Development", "signature": signature(executable)}
    try:
        run(["xcrun", "simctl", "install", simulator, app])
        run(["xcrun", "simctl", "launch", "--terminate-running-process", simulator, bundle])
        container = Path(run(["xcrun", "simctl", "get_app_container", simulator, bundle, "data"]).stdout.strip())
        result_file = container / "Library/Caches/ne-probe.json"
        deadline = time.monotonic() + 15
        while not result_file.exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        result["apiResults"] = json.loads(result_file.read_text()) if result_file.exists() else []
        result["receivedResults"] = result_file.exists()
    finally:
        run(["xcrun", "simctl", "terminate", simulator, bundle], check=False)
        run(["xcrun", "simctl", "uninstall", simulator, bundle], check=False)
    (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True, help="A booted Apple TV simulator UDID")
    parser.add_argument("--output", type=Path, default=ROOT / "build/validation/tvos-ipc-investigation-20261104")
    parser.add_argument("--team", default="SIMULATOR", help="Identifier prefix for controlled probe signatures")
    parser.add_argument("--development-identity", help="Optional Apple Development signing identity for a third control")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {"inventory": inventory(args.simulator), "probes": []}
    original = ROOT / "build/tvos-prototype-derived/Build/Products/Debug-appletvsimulator/MijiaLANTVPrototype.app"
    if original.exists():
        report["prototypeSignatures"] = {
            "app": signature(original / "MijiaLANTVPrototype"),
            "provider": signature(original / "PlugIns/MijiaLANTVTunnel.appex/MijiaLANTVTunnel"),
        }
    cases = [("neonly", False, "-"), ("nepersonal", True, "-")]
    if args.development_identity:
        cases.append(("development", True, args.development_identity))
    for label, personal, identity in cases:
        result = probe(args.simulator, output, label, personal, identity, args.team)
        report["probes"].append(result)
        print(label, json.dumps(result["apiResults"]), flush=True)
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Diagnostic report:", output / "report.json")


if __name__ == "__main__":
    main()
