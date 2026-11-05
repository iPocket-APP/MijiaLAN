#!/usr/bin/env python3
"""Read and validate the native release version used locally and in Actions."""

import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def metadata():
    data = json.loads((ROOT / "release.json").read_text())
    if not isinstance(data.get("version"), str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", data["version"]):
        raise ValueError("release.json must contain a three-part version")
    if type(data.get("build_number")) is not int or data["build_number"] < 1:
        raise ValueError("release.json must contain a positive integer build_number")
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("field", nargs="?", choices=["version", "build-number"])
    parser.add_argument("--tag", help="Require this tag to match release.json exactly")
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    data = metadata()
    tag = "v" + data["version"]
    if args.tag is not None and args.tag != tag:
        parser.error(f"Expected tag {tag}, received {args.tag!r}")
    if args.field:
        print(data[args.field.replace("-", "_")])
    if args.github_output:
        outputs = {
            **data, "tag": tag, "release_dir": f"build/releases/{tag}",
            "stem": f"MijiaLAN-{data['version']}-universal",
        }
        with args.github_output.open("a") as stream:
            stream.writelines(f"{key}={value}\n" for key, value in outputs.items())
    if not args.field and not args.github_output:
        print(json.dumps(data))


if __name__ == "__main__":
    main()
