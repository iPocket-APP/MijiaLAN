#!/usr/bin/env python3
"""Mirror this working tree into an isolated, portable package; never patch SwiftPM checkouts."""
import hashlib
import json
from pathlib import Path
import shutil
import stat

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
OUT = HERE / ".generated" / "MijiaTVDependencies"
CORE_REVISION = "c6a9db1c84fa30125ed4b642b6745487dec94e89"
core = ROOT / "Vendor/MenuBarMijia"
if not (core / "Sources/MijiaCore").is_dir():
    raise SystemExit("Missing locally maintained MijiaCore: Vendor/MenuBarMijia. Restore the vendored sources; no upstream checkout is used.")
revision = CORE_REVISION  # Original import provenance; local maintenance is fingerprinted below.

OUT.mkdir(parents=True, exist_ok=True)
fingerprints = {}
for name, source in [
    ("MijiaCore", core / "Sources/MijiaCore"),
    ("MijiaLAN", ROOT / "Sources/MijiaLAN"),
    ("MijiaHomeKitBridge", ROOT / "Sources/MijiaHomeKitBridge"),
]:
    destination = OUT / "Sources" / name
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination)
    for copied in destination.rglob("*"):
        if copied.is_file():
            copied.chmod(copied.stat().st_mode | stat.S_IWUSR)
    for file in sorted(source.rglob("*")):
        if file.is_file():
            fingerprints[f"{name}/{file.relative_to(source)}"] = hashlib.sha256(file.read_bytes()).hexdigest()

# The upstream HA discovery shells out to dns-sd/arp. It is unrelated to miIO and unavailable on tvOS.
file = OUT / "Sources/MijiaCore/HADiscovery.swift"
source = file.read_text()
for anchor in [
    "private static func queryMDNSInstances() -> [HADiscoveredInstance] {\n        #if canImport(Darwin)",
    "static func queryARPHosts() -> [String] {\n        #if canImport(Darwin)",
    "#if canImport(Darwin)\n    private static func runCommand",
]:
    if source.count(anchor) != 1:
        raise SystemExit(f"Upstream portability anchor changed: {anchor}")
    source = source.replace(anchor, anchor.replace("canImport(Darwin)", "os(macOS)"))
file.write_text(source)

# The desktop self-updater is not used by the tvOS experiment.
file = OUT / "Sources/MijiaCore/UpdateChecker.swift"
source = file.read_text()
start = source.index("    public static let live = UpdateSystemDriver(")
end = source.index("\n}\n\npublic struct AppUpdater", start)
fallback = '''
    #else
    public static let live = UpdateSystemDriver(
        downloadFile: { _, _, _ in throw UpdateInstallError.missingPackageAsset },
        unpackArchive: { _, _, _ in throw UpdateInstallError.missingPackageAsset },
        verifyCodeSignature: { _, _ in throw UpdateInstallError.missingPackageAsset },
        launchDetachedSwapAndRelaunch: { _, _, _ in throw UpdateInstallError.missingPackageAsset }
    )
    #endif
'''
file.write_text(source[:start] + "    #if os(macOS)\n" + source[start:end] + fallback + source[end:])

file = OUT / "Sources/MijiaCore/AssistantConfig.swift"
source = file.read_text()
anchor = '''        let url = configURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/codexbar/config.json")'''
if source.count(anchor) != 1:
    raise SystemExit("Ambient credential portability anchor changed")
file.write_text(source.replace(anchor, "        #if os(macOS)\n" + anchor +
    "\n        #else\n        guard let url = configURL else { return nil }\n        #endif"))

# ProcessInfo idle-sleep assertions are a macOS facility, not a tvOS keep-alive mechanism.
file = OUT / "Sources/MijiaHomeKitBridge/HomeKitBridgeController.swift"
source = file.read_text()
anchor = "    private func updateSleepAssertion() {\n"
if source.count(anchor) != 1 or not source.rstrip().endswith("    }\n}"):
    raise SystemExit("Bridge portability anchor changed")
source = source.replace(anchor, anchor + "        #if os(macOS)\n")
end = source.rfind("    }\n}")
source = source[:end] + "        #endif\n" + source[end:]
source = source.replace('public static let bridgeName = "MijiaLAN Bridge"',
                        'public static let bridgeName = "MijiaLAN NE Experiment"')
# Keep the actual listen / Bonjour error in the experiment's redacted status.
# The desktop controller intentionally uses a concise generic error, which is not
# enough to distinguish an NE sandbox restriction from a configuration failure.
listener_anchor = "        var started: AppleHAPService?\n"
catch_anchor = '''            } catch {
                logger.error("HomeKit bridge failed to listen on port'''
failure_anchor = '''status = .failed(L10n.tr("无法在局域网上启动 HomeKit 桥", "Could not start the HomeKit bridge on the network"))'''
for value in [listener_anchor, catch_anchor, failure_anchor]:
    if source.count(value) != 1:
        raise SystemExit("Bridge diagnostics portability anchor changed")
source = source.replace(listener_anchor, listener_anchor + "        var lastListenError: String?\n")
source = source.replace(catch_anchor, '''            } catch {
                await service.stop()
                lastListenError = String(describing: error)
                logger.error("HomeKit bridge failed to listen on port''')
source = source.replace(failure_anchor, failure_anchor[:-1] + ''' + (lastListenError.map { ": " + $0 } ?? ""))''')
file.write_text(source)

(OUT / "Package.swift").write_text('''// swift-tools-version: 6.1
// Generated by Experiments/AppleTV/prepare.py from the current working tree.
import PackageDescription
let package = Package(
    name: "MijiaTVDependencies",
    platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18)],
    products: [
        .library(name: "MijiaCore", targets: ["MijiaCore"]),
        .library(name: "MijiaLAN", targets: ["MijiaLAN"]),
        .library(name: "MijiaHomeKitBridge", targets: ["MijiaHomeKitBridge"])
    ],
    dependencies: [.package(path: "../../../../Vendor/hap-swift")],
    targets: [
        .target(name: "MijiaCore", resources: [.copy("Resources/Localizations")]),
        .target(name: "MijiaLAN", dependencies: ["MijiaCore"], resources: [.process("Resources")]),
        .target(name: "MijiaHomeKitBridge", dependencies: ["MijiaCore", "MijiaLAN",
            .product(name: "HAPSwift", package: "hap-swift")])
    ]
)
''')

# Retain upstream notices with the generated source used by both executable targets.
for name, origin in [("MijiaCore-LICENSE", core / "LICENSE"), ("MijiaLAN-LICENSE", ROOT / "LICENSE")]:
    if origin.exists():
        destination = OUT / name
        if destination.exists():
            destination.unlink()
        shutil.copyfile(origin, destination)
(OUT / "source-manifest.json").write_text(json.dumps({
    "coreRevision": revision, "coreSource": "Vendor/MenuBarMijia", "sourceSHA256": fingerprints,
    "overlays": ["macOS-only HA subprocess discovery", "macOS-only desktop self-updater", "macOS-only ambient credential path", "macOS-only sleep assertion", "distinct experiment bridge name", "retain listener failure details and close failed listeners"]
}, indent=2) + "\n")
print("Prepared shared iOS / tvOS dependencies from the current working tree.")
