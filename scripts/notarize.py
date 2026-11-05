#!/usr/bin/env python3
"""Notarize one archive and preserve submission details, including rejected jobs."""

import argparse
import json
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--keychain", type=Path)
    parser.add_argument("--log-prefix", required=True, type=Path)
    args = parser.parse_args()
    auth = ["--keychain-profile", args.profile]
    if args.keychain:
        auth += ["--keychain", str(args.keychain)]
    prefix = str(args.log_prefix)
    with open(prefix + ".json", "w") as output, open(prefix + ".stderr.txt", "w") as errors:
        result = subprocess.run(["xcrun", "notarytool", "submit", str(args.archive),
            *auth, "--wait", "--timeout", "20m", "--output-format", "json"],
            stdout=output, stderr=errors)
    try:
        submission = json.loads(Path(prefix + ".json").read_text())
    except json.JSONDecodeError:
        raise SystemExit(f"Notary submission did not return JSON; see {prefix}.stderr.txt")
    if submission.get("id"):
        # Apple recommends reading this even after acceptance: it can contain warnings.
        with open(prefix + "-details.stderr.txt", "w") as errors:
            subprocess.run(["xcrun", "notarytool", "log", submission["id"],
                prefix + "-details.json", *auth], stdout=subprocess.DEVNULL, stderr=errors)
    status = submission.get("status", "unknown")
    print(f"Notarization {args.archive.name}: {status} (id: {submission.get('id', 'unavailable')})", flush=True)
    if result.returncode or status != "Accepted":
        raise SystemExit(f"Notarization was not accepted; see {prefix}.json and its details log")


if __name__ == "__main__":
    main()
