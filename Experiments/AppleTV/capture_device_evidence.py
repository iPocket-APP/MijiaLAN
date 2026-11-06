#!/usr/bin/env python3
"""Read only redacted experiment files staged by the foreground app on a paired device."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", required=True, help="devicectl device ID or UDID")
parser.add_argument("--platform", choices=("iOS", "tvOS"), required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
group = "group.com.ipocket.MijiaLAN." + ("iOSPrototype" if args.platform == "iOS" else "TVPrototype")
bundle = "com.ipocket.MijiaLAN.iOSPrototype"
args.output.mkdir(parents=True, exist_ok=True)
copied = []
for name in ("evidence.json", "app-lifecycle.json", "activation.json", "network-diagnostics.json"):
    domain = "appDataContainer" if args.platform == "iOS" else "appGroupDataContainer"
    identifier = bundle if args.platform == "iOS" else group
    source = "Documents/Diagnostics/" + name if args.platform == "iOS" else name
    result = subprocess.run([
        "xcrun", "devicectl", "device", "copy", "from", "--device", args.device,
        "--domain-type", domain, "--domain-identifier", identifier,
        "--source", source, "--destination", str(args.output / name), "--timeout", "20",
    ], capture_output=True, text=True)
    if result.returncode:
        if name == "evidence.json":
            raise SystemExit(result.stderr.strip() or result.stdout.strip())
        continue
    copied.append(name)
evidence = json.loads((args.output / "evidence.json").read_text())
if evidence.get("platform") != args.platform:
    raise SystemExit("Evidence platform mismatch; do not compare these snapshots.")
print(json.dumps({"copied": copied, "platform": evidence.get("platform"),
    "executor": evidence.get("executor"), "fixture": evidence.get("fixture"),
    "bridgeStatus": evidence.get("bridgeStatus"), "backgroundReads": evidence.get("backgroundReads"),
    "backgroundWrites": evidence.get("backgroundWrites")}, ensure_ascii=False, indent=2))
