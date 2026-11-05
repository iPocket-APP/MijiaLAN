#!/usr/bin/env python3
"""Pinned updater runtimes, release metadata, and separately signed Rust update feeds."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
PLATFORMS = ('macos-arm64', 'macos-x86_64', 'windows-x86_64')
ET.register_namespace('sparkle', SPARKLE)


def configuration():
    config = json.loads((ROOT / 'updates.json').read_text())
    if config['base_url'] != 'https://mijialan-updates.ipocket.xyz':
        raise ValueError('Unexpected shared update domain')
    if len(base64.b64decode(config['public_key'], validate=True)) != 32:
        raise ValueError('Expected an Ed25519 public key')
    return config


def feed_url(platform):
    if platform not in PLATFORMS:
        raise ValueError('Unsupported Rust update platform')
    return configuration()['base_url'] + f'/rs/{platform}/appcast.xml'


def build_number(value):
    if not re.fullmatch(r'[1-9][0-9]*', str(value)) or int(value) > 65535:
        raise ValueError('Release build must be in 1..65535 (also used by MSI)')
    return int(value)


def openssl():
    return os.environ.get('OPENSSL', '/opt/homebrew/opt/openssl@3/bin/openssl'
                          if Path('/opt/homebrew/opt/openssl@3/bin/openssl').exists() else 'openssl')


def sign(path):
    seed = base64.b64decode(os.environ['RUST_UPDATE_PRIVATE_KEY'].strip(), validate=True)
    if len(seed) != 32:
        raise ValueError('Expected a 32-byte Rust signing seed')
    with tempfile.TemporaryDirectory(prefix='mijialan-update-key-') as directory:
        key = Path(directory) / 'key.der'
        with key.open('xb') as stream:
            os.chmod(key, 0o600)
            stream.write(bytes.fromhex('302e020100300506032b657004220420') + seed)
        public = subprocess.check_output([openssl(), 'pkey', '-inform', 'DER', '-in', str(key), '-pubout', '-outform', 'DER'])
        if public[-32:] != base64.b64decode(configuration()['public_key']):
            raise ValueError('CI signing seed does not match the Rust public key')
        signature = subprocess.check_output([openssl(), 'pkeyutl', '-sign', '-keyform', 'DER', '-inkey', str(key), '-rawin', '-in', str(path)])
    return base64.b64encode(signature).decode()


def verify_signature(path, signature, public_key):
    raw_key, raw_signature = base64.b64decode(public_key, validate=True), base64.b64decode(signature, validate=True)
    if len(raw_key) != 32 or len(raw_signature) != 64:
        raise ValueError('Invalid Ed25519 key or signature')
    with tempfile.TemporaryDirectory(prefix='mijialan-verify-') as directory:
        key, sig = Path(directory) / 'public.der', Path(directory) / 'signature'
        key.write_bytes(bytes.fromhex('302a300506032b6570032100') + raw_key)
        sig.write_bytes(raw_signature)
        result = subprocess.run([openssl(), 'pkeyutl', '-verify', '-pubin', '-keyform', 'DER', '-inkey', str(key),
                                 '-rawin', '-in', str(path), '-sigfile', str(sig)], capture_output=True)
        if result.returncode:
            raise ValueError('Update signature verification failed')


def runtime(name):
    config = configuration()[name]
    version = config['version']
    extension = 'tar.xz' if name == 'sparkle' else 'zip'
    label = 'Sparkle' if name == 'sparkle' else 'WinSparkle'
    cache = ROOT / '.cache/updater'
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f'{label}-{version}.{extension}'
    if not archive.exists():
        repo = 'sparkle-project/Sparkle' if name == 'sparkle' else 'vslavik/winsparkle'
        tag = version if name == 'sparkle' else 'v' + version
        url = f'https://github.com/{repo}/releases/download/{tag}/{archive.name}'
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as stream:
            temporary = Path(stream.name)
            try:
                with urllib.request.urlopen(url, timeout=120) as response:
                    shutil.copyfileobj(response, stream)
                stream.close()
                if hashlib.sha256(temporary.read_bytes()).hexdigest() != config['sha256']:
                    raise ValueError(f'{label} download checksum mismatch')
                temporary.replace(archive)
            finally:
                temporary.unlink(missing_ok=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != config['sha256']:
        raise ValueError(f'{label} cached checksum mismatch')
    return archive


def configure_mac(app, arch):
    platform = 'macos-' + arch
    url = feed_url(platform)
    with tempfile.TemporaryDirectory(prefix='sparkle-runtime-') as directory:
        with tarfile.open(runtime('sparkle')) as archive:
            archive.extractall(directory, filter='tar')
        source = Path(directory) / 'Sparkle.framework'
        target = app / 'Contents/Frameworks/Sparkle.framework'
        if target.exists():
            shutil.rmtree(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['ditto', str(source), str(target)], check=True)
        resources = app / 'Contents/Resources'
        license_file = Path(directory) / 'LICENSE'
        if license_file.exists():
            shutil.copy2(license_file, resources / 'Sparkle-LICENSE')
    plist = app / 'Contents/Info.plist'
    info = plistlib.loads(plist.read_bytes())
    if info['CFBundleIdentifier'] != 'xyz.ipocket.MijiaLAN.Rust':
        raise ValueError('Refusing to configure updates for another app identity')
    info.update(SUFeedURL=url, SUPublicEDKey=configuration()['public_key'],
                SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=True,
                SUEnableSystemProfiling=False, SUScheduledCheckInterval=86400, SUVerifyUpdateBeforeExtraction=True)
    plist.write_bytes(plistlib.dumps(info, sort_keys=False))


def windows_metadata(version, build):
    return dict(product='mijialan-rs', platform='windows-x86_64', version=version, build=build_number(build))


def configure_windows(stage, version, build):
    info = windows_metadata(version, build)
    with zipfile.ZipFile(runtime('winsparkle')) as archive:
        prefix = 'WinSparkle-' + configuration()['winsparkle']['version'] + '/'
        (stage / 'WinSparkle.dll').write_bytes(archive.read(prefix + 'x64/Release/WinSparkle.dll'))
        notices = stage / 'licenses/WinSparkle'
        notices.mkdir(parents=True, exist_ok=True)
        for name in ('COPYING', 'COPYING.expat', 'AUTHORS'):
            (notices / name).write_bytes(archive.read(prefix + name))
    (stage / 'mijialan-update.json').write_text(json.dumps(info, indent=2) + '\n')


def repackage_windows(source, destination, version, build):
    # Release jobs stamp the release build without recompiling the verified CI executables or DLL.
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as output:
        names = original.namelist()
        roots = {name.split('/')[0] for name in names}
        if len(roots) != 1 or any(name.startswith('/') or '..' in name.split('/') or '\\' in name for name in names):
            raise ValueError('Unsafe portable archive')
        root = roots.pop()
        expected = f'{root}/mijialan-update.json'
        if expected not in names or f'{root}/WinSparkle.dll' not in names:
            raise ValueError('CI package is missing its updater runtime or metadata')
        for item in original.infolist():
            content = original.read(item)
            if item.filename == expected:
                existing = json.loads(content)
                if existing['product'] != 'mijialan-rs' or existing['version'] != version:
                    raise ValueError('Unexpected Windows package identity')
                content = (json.dumps(windows_metadata(version, build), indent=2) + '\n').encode()
            output.writestr(item, content)


def make_feed(path, version, build, platform, archive):
    url = f'https://github.com/iPocket-APP/MijiaLAN/releases/download/rs-v{version}-b{build}/{archive.name}'
    root = ET.Element('rss', version='2.0')
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = f'MijiaLAN Rust · {platform}'
    ET.SubElement(channel, 'link').text = feed_url(platform)
    ET.SubElement(channel, 'description').text = 'Updates for this Rust client only.'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'MijiaLAN Rust {version} ({build})'
    ET.SubElement(item, 'link').text = f'https://github.com/iPocket-APP/MijiaLAN/releases/tag/rs-v{version}-b{build}'
    ET.SubElement(item, f'{{{SPARKLE}}}version').text = str(build)
    ET.SubElement(item, f'{{{SPARKLE}}}shortVersionString').text = version
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = '11.0.0' if platform.startswith('macos') else '10.0'
    attributes = dict(url=url, length=str(archive.stat().st_size), type='application/octet-stream')
    attributes[f'{{{SPARKLE}}}edSignature'] = sign(archive)
    attributes[f'{{{SPARKLE}}}os'] = 'macos' if platform.startswith('macos') else 'windows-x64'
    if platform == 'macos-arm64':
        ET.SubElement(item, f'{{{SPARKLE}}}hardwareRequirements').text = 'arm64'
    if platform.startswith('windows'):
        attributes[f'{{{SPARKLE}}}installerArguments'] = '/passive /norestart'
    ET.SubElement(item, 'enclosure', attributes)
    ET.indent(root)
    path.write_bytes(ET.tostring(root, encoding='utf-8', xml_declaration=True))


def prepare_feeds(dist, version, build):
    build = build_number(build)
    feeds = []
    with tempfile.TemporaryDirectory(prefix='rust-feeds-') as directory:
        stage = Path(directory)
        for platform in PLATFORMS:
            suffix = 'msi' if platform.startswith('windows') else 'zip'
            archive = dist / f'MijiaLAN-rs-{version}-b{build}-{platform}.{suffix}'
            if not archive.is_file():
                continue
            if platform.startswith('macos'):
                with zipfile.ZipFile(archive) as payload:
                    info = plistlib.loads(payload.read('MijiaLAN.app/Contents/Info.plist'))
                expected = {'CFBundleIdentifier': 'xyz.ipocket.MijiaLAN.Rust', 'CFBundleVersion': str(build),
                            'CFBundleShortVersionString': version, 'SUFeedURL': feed_url(platform),
                            'SUPublicEDKey': configuration()['public_key']}
                if any(info.get(k) != v for k, v in expected.items()):
                    raise ValueError('Packaged Mac app has wrong update identity, build, key or platform')
            path = stage / f'rs/{platform}/appcast.xml'
            path.parent.mkdir(parents=True)
            make_feed(path, version, build, platform, archive)
            feeds.append(path)
        if not any('/macos-' in str(path) for path in feeds) or not any('/windows-' in str(path) for path in feeds):
            raise ValueError('A release must include both Mac and Windows update packages')
        bundle = dist / 'rust-update-feeds.zip'
        with zipfile.ZipFile(bundle, 'w', zipfile.ZIP_DEFLATED) as archive:
            for path in feeds:
                archive.write(path, path.relative_to(stage).as_posix())
        signature = sign(bundle)
        verify_signature(bundle, signature, configuration()['public_key'])
        (dist / 'rust-update-feeds.zip.sig').write_text(signature + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    mac = commands.add_parser('configure-mac')
    mac.add_argument('app', type=Path)
    mac.add_argument('--arch', choices=['arm64', 'x86_64'], required=True)
    win = commands.add_parser('configure-windows')
    win.add_argument('stage', type=Path)
    win.add_argument('--version', required=True)
    win.add_argument('--build', default='1')
    feeds = commands.add_parser('prepare-feeds')
    feeds.add_argument('dist', type=Path)
    feeds.add_argument('--version', required=True)
    feeds.add_argument('--build', required=True)
    args = parser.parse_args()
    if args.command == 'configure-mac': configure_mac(args.app, args.arch)
    elif args.command == 'configure-windows': configure_windows(args.stage, args.version, args.build)
    else: prepare_feeds(args.dist, args.version, args.build)


if __name__ == '__main__':
    main()
