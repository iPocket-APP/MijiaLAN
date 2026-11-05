#!/usr/bin/env python3
"""Embed and audit Swift back-deployment libraries in the macOS app bundle."""

import argparse
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

SYSTEM_PATHS = ("/usr/lib/", "/System/Library/")
FRAMEWORKS_RPATH = "@executable_path/../Frameworks"
LOAD_COMMANDS = {
    "LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
    "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB",
}


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def architectures(binary):
    return output("lipo", "-archs", str(binary)).split()


def inspect(binary, arch):
    text = output("otool", "-arch", arch, "-l", str(binary))
    rpaths, dependencies, minimums = [], [], []
    for block in re.split(r"Load command \d+\n", text)[1:]:
        command = re.search(r"\bcmd (LC_\w+)", block).group(1)
        if command == "LC_RPATH":
            rpaths.append(re.search(r"\bpath (.*?) \(offset", block).group(1))
        elif command in LOAD_COMMANDS:
            name = re.search(r"\bname (.*?) \(offset", block).group(1)
            dependencies.append((name, command == "LC_LOAD_WEAK_DYLIB"))
        elif command == "LC_BUILD_VERSION" and re.search(r"platform (?:1|MACOS)\s", block):
            minimums.append(re.search(r"minos ([\d.]+)", block).group(1))
        elif command == "LC_VERSION_MIN_MACOSX":
            minimums.append(re.search(r"version ([\d.]+)", block).group(1))
    return {"rpaths": rpaths, "dependencies": dependencies, "minimum_macos": minimums}


def version(value):
    parts = [int(p) for p in value.split(".")]
    return tuple((parts + [0, 0, 0])[:3])


def app_info(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    return app / "Contents/MacOS" / info["CFBundleExecutable"], info["LSMinimumSystemVersion"]


def expand(value, binary, executable):
    for token, directory in (("@executable_path", executable.parent), ("@loader_path", binary.parent)):
        if value == token or value.startswith(token + "/"):
            return directory / value[len(token):].lstrip("/")
    return Path(value) if value.startswith("/") else None


def verify(app):
    executable, minimum = app_info(app)
    report = {"app": str(app), "minimum_macos": minimum, "architectures": {}, "errors": []}
    errors = report["errors"]
    for arch in architectures(executable):
        main = inspect(executable, arch)
        queue, seen, binaries = [executable], set(), []
        while queue:
            binary = queue.pop()
            if binary in seen:
                continue
            seen.add(binary)
            if arch not in architectures(binary):
                errors.append(f"{binary}: missing {arch} architecture")
                continue
            data = main if binary == executable else inspect(binary, arch)
            binaries.append({"file": str(binary.relative_to(app)), **data})
            for required in data["minimum_macos"]:
                if version(required) > version(minimum):
                    errors.append(f"{binary.name} ({arch}): requires macOS {required}, app promises {minimum}")
            for rpath in data["rpaths"]:
                if rpath.startswith("/") and not rpath.startswith(SYSTEM_PATHS):
                    errors.append(f"{binary.name} ({arch}): development-machine rpath: {rpath}")
            for name, weak in data["dependencies"]:
                if name.startswith(SYSTEM_PATHS):
                    continue  # System libraries may exist only in the dyld shared cache.
                if name.startswith("@rpath/"):
                    candidates = [expand(r, binary, executable) for r in data["rpaths"] + main["rpaths"]]
                    candidates = [p / name[len("@rpath/"):] for p in candidates if p is not None]
                else:
                    candidate = expand(name, binary, executable)
                    candidates = [candidate] if candidate is not None else []
                local = next((p.resolve() for p in candidates
                              if p.is_file() and p.resolve().is_relative_to(app)), None)
                if local is not None:
                    queue.append(local)
                elif not weak:
                    errors.append(f"{binary.name} ({arch}): required library not reachable inside app: {name}")
        report["architectures"][arch] = binaries
    report["errors"] = list(dict.fromkeys(errors))
    return report


def embed(app, identity):
    executable, _ = app_info(app)
    frameworks = app / "Contents/Frameworks"
    frameworks.mkdir(exist_ok=True)
    subprocess.run(["xcrun", "swift-stdlib-tool", "--copy", "--platform", "macosx",
                    "--scan-executable", str(executable), "--destination", str(frameworks)], check=True)
    # SwiftPM emits toolchain search paths for local command-line execution. They
    # must not substitute for the libraries shipped in a distributable .app.
    slices = [inspect(executable, arch) for arch in architectures(executable)]
    for rpath in dict.fromkeys(p for data in slices for p in data["rpaths"]):
        if rpath.startswith("/") and not rpath.startswith(SYSTEM_PATHS):
            subprocess.run(["install_name_tool", "-delete_rpath", rpath, str(executable)], check=True)
    if not any(FRAMEWORKS_RPATH in data["rpaths"] for data in slices):
        subprocess.run(["install_name_tool", "-add_rpath", FRAMEWORKS_RPATH, str(executable)], check=True)
    for library in sorted(frameworks.glob("*.dylib")):
        signing = ["--timestamp=none"] if identity == "-" else ["--options", "runtime", "--timestamp"]
        subprocess.run(["codesign", "--force", "--sign", identity, *signing, str(library)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["embed", "verify"])
    parser.add_argument("app", type=Path)
    parser.add_argument("--sign", default="-")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    if args.mode == "embed":
        embed(app, args.sign)
    report = verify(app)
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    for error in report["errors"]:
        print(error, file=sys.stderr)
    if report["errors"]:
        return 1
    print(f"Swift runtime audit passed: {app} ({', '.join(report['architectures'])})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
