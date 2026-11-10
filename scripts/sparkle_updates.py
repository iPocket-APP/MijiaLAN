#!/usr/bin/env python3
"""Configure the app and generate a signed Sparkle feed from a notarized release."""

import argparse
import base64
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

from release_metadata import ROOT, metadata

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def configuration():
    data = json.loads((ROOT / "updates.json").read_text())
    url = urllib.parse.urlsplit(data["feed_url"])
    if url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise ValueError("The update feed must have a public HTTPS URL without credentials, query or fragment")
    if len(base64.b64decode(data["public_key"], validate=True)) != 32:
        raise ValueError("The Sparkle public key must contain 32 bytes")
    resolved = json.loads((ROOT / "Package.resolved").read_text())
    pinned = next(pin["state"]["version"] for pin in resolved["pins"] if pin["identity"] == "sparkle")
    if pinned != data["sparkle_version"]:
        raise ValueError("Sparkle tools and the pinned framework must have the same version")
    return data


def configure_app(app):
    config = configuration()
    path = app / "Contents/Info.plist"
    info = plistlib.loads(path.read_bytes())
    info.update({
        "SUFeedURL": config["feed_url"], "SUPublicEDKey": config["public_key"],
        "SUEnableAutomaticChecks": True, "SUAutomaticallyUpdate": False,
        "SUAllowsAutomaticUpdates": True, "SUEnableSystemProfiling": False,
        "SUScheduledCheckInterval": 86400, "SUVerifyUpdateBeforeExtraction": True,
    })
    path.write_bytes(plistlib.dumps(info, sort_keys=False))


def fetch_tools(destination):
    config = configuration()
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / "sparkle.tar.xz"
    url = f"https://github.com/sparkle-project/Sparkle/releases/download/{config['sparkle_version']}/Sparkle-{config['sparkle_version']}.tar.xz"
    with urllib.request.urlopen(url, timeout=120) as response, archive.open("wb") as output:
        shutil.copyfileobj(response, output)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != config["tools_sha256"]:
        raise ValueError("Sparkle tools checksum mismatch")
    subprocess.run(["tar", "-xf", str(archive), "-C", str(destination)], check=True)
    return destination / "bin"


def validate_feed(feed, archive, info, download_prefix):
    items = ET.parse(feed).getroot().findall("./channel/item")
    if len(items) != 1:
        raise ValueError("A release feed must contain exactly the verified release")
    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("The update enclosure is missing")
    if item.findtext(f"{{{SPARKLE}}}version") != info["CFBundleVersion"]:
        raise ValueError("Feed build number does not match the packaged app")
    if item.findtext(f"{{{SPARKLE}}}shortVersionString") != info["CFBundleShortVersionString"]:
        raise ValueError("Feed version does not match the packaged app")
    if item.findtext(f"{{{SPARKLE}}}minimumSystemVersion") != info["LSMinimumSystemVersion"]:
        raise ValueError("Feed minimum macOS does not match the packaged app")
    expected_url = download_prefix + urllib.parse.quote(archive.name)
    if enclosure.get("url") != expected_url or enclosure.get("length") != str(archive.stat().st_size):
        raise ValueError("Feed download URL or length does not match the release archive")
    if len(base64.b64decode(enclosure.get(f"{{{SPARKLE}}}edSignature", ""), validate=True)) != 64:
        raise ValueError("The update must have an Ed25519 signature")


def prepare_feed(app, archive, notes, output, tools):
    config, release = configuration(), metadata()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {"CFBundleVersion": str(release["build_number"]), "CFBundleShortVersionString": release["version"],
                "CFBundleIdentifier": "com.mijialan.MijiaLAN", "SUFeedURL": config["feed_url"], "SUPublicEDKey": config["public_key"]}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"Packaged app has unexpected {key}")
    prefix = f"https://github.com/iPocket-APP/MijiaLAN/releases/download/v{release['version']}/"
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="mijialan-appcast-") as directory:
        staging = Path(directory)
        shutil.copy2(archive, staging / archive.name)
        shutil.copy2(notes, (staging / archive.name).with_suffix(".md"))
        command = [str(tools / "generate_appcast"), "--download-url-prefix", prefix, "--embed-release-notes",
                   "--maximum-deltas", "0", "--link", "https://github.com/iPocket-APP/MijiaLAN",
                   "-o", str(staging / "appcast.xml")]
        secret = os.environ.get("SPARKLE_PRIVATE_KEY")
        command += ["--ed-key-file", "-"] if secret else ["--account", config["keychain_account"]]
        subprocess.run([*command, str(staging)], input=secret, text=True, check=True)
        validate_feed(staging / "appcast.xml", archive, info, prefix)
        shutil.copy2(staging / "appcast.xml", output / "appcast.xml")
    # This artifact deliberately contains no binaries or private signing material.
    (output / "index.html").write_text('<!doctype html><html lang="en"><meta charset="utf-8"><title>MijiaLAN Updates</title>'
                                      '<h1>MijiaLAN Updates</h1><p><a href="appcast.xml">Update feed</a></p>'
                                      '<p><a href="https://github.com/iPocket-APP/MijiaLAN/releases">Downloads and release notes</a></p></html>\n')


def verify_public_feed(feed, openssl="openssl"):
    """Verify an existing feed against the immutable public ZIP and embedded public key."""
    config, release = configuration(), metadata()
    name = f"MijiaLAN-{release['version']}-universal.zip"
    prefix = f"https://github.com/iPocket-APP/MijiaLAN/releases/download/v{release['version']}/"
    with tempfile.TemporaryDirectory(prefix="mijialan-public-update-") as directory:
        root = Path(directory)
        archive = root / name
        with urllib.request.urlopen(prefix + name, timeout=120) as response, archive.open("wb") as output:
            shutil.copyfileobj(response, output)
        with zipfile.ZipFile(archive) as bundle:
            info = plistlib.loads(bundle.read("MijiaLAN.app/Contents/Info.plist"))
        if (info["CFBundleVersion"] != str(release["build_number"])
                or info["CFBundleShortVersionString"] != release["version"]):
            raise ValueError("The public package does not match the expected release")
        validate_feed(feed, archive, info, prefix)
        enclosure = ET.parse(feed).find("./channel/item/enclosure")
        public_key, signature = root / "public.der", root / "archive.sig"
        public_key.write_bytes(bytes.fromhex("302a300506032b6570032100") + base64.b64decode(config["public_key"]))
        signature.write_bytes(base64.b64decode(enclosure.get(f"{{{SPARKLE}}}edSignature"), validate=True))
        subprocess.run([openssl, "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", str(public_key),
                        "-rawin", "-in", str(archive), "-sigfile", str(signature)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    configure = commands.add_parser("configure-app")
    configure.add_argument("app", type=Path)
    fetch = commands.add_parser("fetch-tools")
    fetch.add_argument("destination", type=Path)
    verify = commands.add_parser("verify-public-feed")
    verify.add_argument("feed", type=Path)
    verify.add_argument("--openssl", default="openssl", help="OpenSSL 3 executable")
    prepare = commands.add_parser("prepare-feed")
    for name in ("app", "archive", "notes", "output", "tools"):
        prepare.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    if args.command == "configure-app":
        configure_app(args.app)
    elif args.command == "fetch-tools":
        print(fetch_tools(args.destination.resolve()))
    elif args.command == "verify-public-feed":
        verify_public_feed(args.feed, args.openssl)
    else:
        prepare_feed(args.app.resolve(), args.archive.resolve(), args.notes.resolve(), args.output.resolve(), args.tools.resolve())


if __name__ == "__main__":
    main()
