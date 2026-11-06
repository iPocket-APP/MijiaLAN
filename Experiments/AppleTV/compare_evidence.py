#!/usr/bin/env python3
"""Compare redacted snapshots; foreground and simulated-device runs can never pass device acceptance."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("before", type=Path)
parser.add_argument("after", type=Path)
parser.add_argument("--minimum-seconds", type=float, default=300)
parser.add_argument("--maximum-gap-seconds", type=float, default=15)
parser.add_argument("--fixture-only", action="store_true", help="Validate the NE fixture run, without claiming real-device control acceptance")
args = parser.parse_args()
before, after = [json.loads(path.read_text()) for path in (args.before, args.after)]
network_settings = after.get("networkSettings") or {}
checks = {
    "sameDevicePlatform": before.get("platform") == after.get("platform") and after.get("platform") in ("iOS", "tvOS"),
    "sameExtensionSession": before["sessionID"] == after["sessionID"] and
        before["executor"] == after["executor"] == "networkExtension" and before["processID"] == after["processID"],
    "matchesRequestedDeviceMode": before["fixture"] == after["fixture"] == args.fixture_only,
    "sameTransport": before.get("transportKind") == after.get("transportKind") and
        after.get("transportKind") in (("udpFixture", "memoryFixture") if args.fixture_only else ("udpDevice",)),
    "minimumObservationWindow": after["updatedAt"] - before["updatedAt"] >= args.minimum_seconds,
    "backgroundAuthenticatedReads": after["backgroundReads"] > before["backgroundReads"],
    "backgroundAcknowledgedWrites": after["backgroundWrites"] > before["backgroundWrites"],
    "fixtureTimerWritesDisabled": not args.fixture_only or after.get("transportKind") != "udpFixture" or
        (before.get("fixtureSelfTestWrites") is False and after.get("fixtureSelfTestWrites") is False),
    "noNewTransportFailures": after["transportFailures"] == before["transportFailures"],
    "bridgeRunningAndPaired": after["bridgeStatus"] == "running" and after["paired"],
    "notStopped": after.get("stoppedAt") is None,
    "noLongExecutionGap": after["largestHeartbeatGap"] <= args.maximum_gap_seconds,
    "noIncludedRoutesRequested": network_settings.get("includedIPv4RouteCount") == 0 and
        network_settings.get("includedIPv6RouteCount") == 0,
    "recentDeviceRead": after.get("lastAuthenticatedReadAt") is not None and
        after["updatedAt"] - after["lastAuthenticatedReadAt"] <= 15,
}
print(json.dumps({"mode": "fixtureOnly" if args.fixture_only else "realDevices", "platform": after.get("platform"),
                  "transport": after.get("transportKind"),
                  "indicatorsPassed": all(checks.values()), "checks": checks,
                  "note": "These indicators cover the sampled window; verify Apple Home reachability and device state independently."}, indent=2))
raise SystemExit(0 if all(checks.values()) else 1)
