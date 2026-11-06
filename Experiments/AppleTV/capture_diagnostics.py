#!/usr/bin/env python3
"""Copy only the user-generated tvOS diagnostic report, never its Keychain or configuration."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
target = parser.add_mutually_exclusive_group(required=True)
target.add_argument("--simulator", help="tvOS simulator UDID")
target.add_argument("--device", help="paired Apple TV devicectl ID")
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
bundle = "com.ipocket.MijiaLAN.TVPrototype"
relative = "Library/Caches/Diagnostics/MijiaLAN-Diagnostics.json"
with tempfile.TemporaryDirectory(prefix="mijialan-tv-diagnostics-") as temporary:
    if args.simulator:
        container = subprocess.check_output(["xcrun", "simctl", "get_app_container", args.simulator, bundle, "data"], text=True).strip()
        source = Path(container) / relative
    else:
        source = Path(temporary) / "diagnostics.json"
        subprocess.run(["xcrun", "devicectl", "device", "copy", "from", "--device", args.device,
            "--domain-type", "appDataContainer", "--domain-identifier", bundle,
            "--source", relative, "--destination", str(source), "--timeout", "20"], check=True, capture_output=True)
    try:
        data = source.read_bytes()
    except FileNotFoundError:
        raise SystemExit("请先在 TV App 的诊断页生成报告。")
    report = json.loads(data)
    if report.get("schemaVersion") != 1 or report.get("platform") != "tvOS":
        raise SystemExit("诊断报告格式或平台不匹配。")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    print(json.dumps({"output": str(args.output), "source": report.get("source"), "fixture": report.get("fixture"),
        "recordedAt": report.get("recordedAt"), "devices": len(report.get("devices", []))}, ensure_ascii=False, indent=2))
