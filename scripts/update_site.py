#!/usr/bin/env python3
"""Assemble the complete shared Pages site; never deploy one flavor over the other."""
import argparse
import base64
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
import tvos_updates

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
PLATFORMS = ('macos-arm64', 'macos-x86_64', 'windows-x86_64')


def config():
    data = json.loads((ROOT / 'update-site.json').read_text())
    if data['origin'] != 'https://mijialan-updates.ipocket.xyz' or data['repository'] != 'iPocket-APP/MijiaLAN':
        raise ValueError('Unexpected update service identity')
    return data


def api(path, paginate=False):
    args = ['gh', 'api'] + (['--paginate', '--slurp'] if paginate else [])
    result = json.loads(subprocess.check_output([*args, f'repos/{config()["repository"]}/{path}'], text=True))
    return [item for page in result for item in page] if paginate else result


def download(url, path, limit):
    if not url.startswith('https://'):
        raise ValueError('Updates require HTTPS')
    with urllib.request.urlopen(url, timeout=120) as source, path.open('wb') as output:
        size = 0
        while block := source.read(1024 * 1024):
            size += len(block)
            if size > limit:
                raise ValueError('Update download exceeds its allowed size')
            output.write(block)


def verify(path, signature, key):
    key_bytes, sig_bytes = base64.b64decode(key, validate=True), base64.b64decode(signature.strip(), validate=True)
    if len(key_bytes) != 32 or len(sig_bytes) != 64:
        raise ValueError('Invalid update signature or public key')
    openssl = os.environ.get('OPENSSL', '/opt/homebrew/opt/openssl@3/bin/openssl'
                             if Path('/opt/homebrew/opt/openssl@3/bin/openssl').exists() else 'openssl')
    with tempfile.TemporaryDirectory(prefix='verify-feed-') as directory:
        public, sig = Path(directory) / 'public.der', Path(directory) / 'signature'
        public.write_bytes(bytes.fromhex('302a300506032b6570032100') + key_bytes)
        sig.write_bytes(sig_bytes)
        result = subprocess.run([openssl, 'pkeyutl', '-verify', '-pubin', '-keyform', 'DER', '-inkey', str(public),
                                 '-rawin', '-in', str(path), '-sigfile', str(sig)], capture_output=True)
        if result.returncode:
            raise ValueError('Untrusted update signature')


def inspect_feed(content, platform, rust_tag=None):
    items = ET.fromstring(content).findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected one verified current update per feed')
    item = items[0]
    enclosure = item.find('enclosure')
    if enclosure is None:
        raise ValueError('Missing update enclosure')
    url = urllib.parse.urlsplit(enclosure.get('url', ''))
    prefix = f'/{config()["repository"]}/releases/download/'
    if url.scheme != 'https' or url.netloc != 'github.com' or url.query or url.fragment or not url.path.startswith(prefix):
        raise ValueError('Update does not point to this repository release')
    parts = url.path[len(prefix):].split('/')
    if len(parts) != 2:
        raise ValueError('Invalid release download path')
    tag, name = parts
    build = item.findtext(f'{{{SPARKLE}}}version', '')
    version = item.findtext(f'{{{SPARKLE}}}shortVersionString', '')
    if not re.fullmatch(r'[1-9][0-9]*', build):
        raise ValueError('Update build is not numeric')
    if platform == 'native':
        if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag) or version != tag[1:]:
            raise ValueError('Native feed references a Rust or invalid release')
        expected = f'MijiaLAN-{version}-universal.zip'
    else:
        if platform not in PLATFORMS or tag != rust_tag or tag != f'rs-v{version}-b{build}':
            raise ValueError('Rust feed references another flavor, platform or build')
        extension = 'msi' if platform.startswith('windows') else 'zip'
        expected = f'MijiaLAN-rs-{version}-b{build}-{platform}.{extension}'
        os_type = enclosure.get(f'{{{SPARKLE}}}os')
        if os_type != ('windows-x64' if platform.startswith('windows') else 'macos'):
            raise ValueError('Update OS does not match its path')
    if name != expected:
        raise ValueError('Update archive does not match its flavor or architecture')
    length = enclosure.get('length', '')
    if not re.fullmatch(r'[1-9][0-9]*', length) or int(length) > 512 * 1024 * 1024:
        raise ValueError('Invalid update length')
    signature = enclosure.get(f'{{{SPARKLE}}}edSignature', '')
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Missing Ed25519 signature')
    return tag, name, enclosure.get('url'), int(length), signature


def verify_feed(content, platform, directory, rust_tag=None):
    tag, name, url, length, signature = inspect_feed(content, platform, rust_tag)
    release = api('releases/tags/' + tag)
    if release['draft']:
        raise ValueError('Cannot deploy an unpublished update')
    asset = next((a for a in release['assets'] if a['name'] == name), None)
    if not asset or asset['size'] != length:
        raise ValueError('Update asset does not match the public release')
    archive = directory / name
    download(url, archive, length)
    if archive.stat().st_size != length:
        raise ValueError('Truncated update archive')
    key = config()['native_public_key' if platform == 'native' else 'rust_public_key']
    verify(archive, signature, key)
    if platform == 'native' or platform.startswith('macos'):
        with zipfile.ZipFile(archive) as payload:
            info_path = 'MijiaLAN.app/Contents/Info.plist'
            if payload.getinfo(info_path).file_size > 128 * 1024:
                raise ValueError('Packaged app metadata is too large')
            info = plistlib.loads(payload.read(info_path))
        item = ET.fromstring(content).find('./channel/item')
        feed_path = '/appcast.xml' if platform == 'native' else f'/rs/{platform}/appcast.xml'
        expected = dict(CFBundleIdentifier='com.mijialan.MijiaLAN' if platform == 'native' else 'xyz.ipocket.MijiaLAN.Rust',
            CFBundleVersion=item.findtext(f'{{{SPARKLE}}}version'),
            CFBundleShortVersionString=item.findtext(f'{{{SPARKLE}}}shortVersionString'),
            SUFeedURL=config()['origin'] + feed_path, SUPublicEDKey=key)
        if any(info.get(k) != v for k, v in expected.items()):
            raise ValueError('Feed metadata does not match the signed app bundle')


def rust_feeds(directory):
    releases = api('releases?per_page=100', paginate=True)
    candidates = []
    for release in releases:
        match = re.fullmatch(r'rs-v[0-9]+\.[0-9]+\.[0-9]+-b([1-9][0-9]*)', release['tag_name'])
        assets = {a['name']: a for a in release['assets']}
        if match and not release['draft'] and {'rust-update-feeds.zip', 'rust-update-feeds.zip.sig'} <= assets.keys():
            candidates.append((int(match[1]), release, assets))
    selected = {}
    # Each platform advances independently; a newer ARM release cannot remove an existing Intel feed.
    for _, release, assets in sorted(candidates, key=lambda row: row[0], reverse=True):
        bundle, signature = directory / 'feeds.zip', directory / 'feeds.sig'
        download(assets['rust-update-feeds.zip']['browser_download_url'], bundle, 256 * 1024)
        download(assets['rust-update-feeds.zip.sig']['browser_download_url'], signature, 256)
        verify(bundle, signature.read_text(), config()['rust_public_key'])
        with zipfile.ZipFile(bundle) as archive:
            allowed = {f'rs/{p}/appcast.xml' for p in PLATFORMS}
            names = archive.namelist()
            if len(set(names)) != len(names) or not set(names) <= allowed:
                raise ValueError('Feed bundle contains a foreign path or duplicate entry')
            for platform in PLATFORMS:
                name = f'rs/{platform}/appcast.xml'
                if platform in selected or name not in names:
                    continue
                if archive.getinfo(name).file_size > 128 * 1024:
                    raise ValueError('Feed XML is too large')
                content = archive.read(name)
                verify_feed(content, platform, directory, release['tag_name'])
                selected[platform] = content
        if len(selected) == len(PLATFORMS):
            break
    return selected


def native_feed_content(directory, override=None):
    candidates = [override.read_bytes()] if override else []
    for release in api('releases?per_page=100', paginate=True):
        if release['draft'] or release.get('prerelease') or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', release['tag_name']):
            continue
        asset = next((a for a in release['assets'] if a['name'] == 'native-appcast.xml'), None)
        if asset:
            path = directory / (release['tag_name'] + '.xml')
            download(asset['browser_download_url'], path, 1024 * 1024)
            content = path.read_bytes()
            if inspect_feed(content, 'native')[0] != release['tag_name']:
                raise ValueError('Native feed snapshot references another release')
            candidates.append(content)
    # Backward compatibility for releases made before public feed snapshots existed.
    live = directory / 'native-live.xml'
    try:
        download(config()['origin'] + '/appcast.xml', live, 1024 * 1024)
        candidates.append(live.read_bytes())
    except OSError:
        if not candidates: raise
    if not candidates:
        raise ValueError('No native feed can be preserved')
    for content in candidates:
        inspect_feed(content, 'native')
    # A queued deployment may be superseded by another publisher. Both rebuild from
    # public snapshots, so every remaining deployment includes the newest native build.
    content = max(candidates, key=lambda data: int(ET.fromstring(data).findtext(f'./channel/item/{{{SPARKLE}}}version')))
    verify_feed(content, 'native', directory)
    return content


def check_live(output):
    paths = sorted([*output.rglob('appcast.xml'), *output.glob('tvos/releases.json')])
    for path in paths:
        url = config()['origin'] + '/' + path.relative_to(output).as_posix()
        expected = path.read_bytes()
        for attempt in range(12):
            request = urllib.request.Request(url, headers={'Cache-Control': 'no-cache'})
            try:
                with urllib.request.urlopen(request, timeout=20) as response:
                    if response.read(1024 * 1024) == expected:
                        break
            except OSError:
                pass
            if attempt == 11:
                raise ValueError('Live feed does not match the verified site: ' + url)
            time.sleep(10)
        print('Live feed verified: ' + url)


def assemble(output, native_feed=None):
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Site staging directory must be empty')
    with tempfile.TemporaryDirectory(prefix='shared-update-site-') as directory:
        directory = Path(directory)
        native = native_feed_content(directory, native_feed)
        feeds = rust_feeds(directory)
        tv = tvos_updates.encode(api('releases?per_page=100', paginate=True))
        # Nothing is staged until every retained flavor's public archive has been verified.
        (output / 'appcast.xml').write_bytes(native)
        (output / 'tvos').mkdir()
        (output / 'tvos/releases.json').write_bytes(tv)
        for platform, content in feeds.items():
            target = output / f'rs/{platform}/appcast.xml'
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
        links = ['<li><a href="appcast.xml">MijiaLAN for macOS</a></li>']
        links += ['<li><a href="tvos/releases.json">MijiaLAN for Apple TV · version information</a></li>']
        links += [f'<li><a href="rs/{p}/appcast.xml">MijiaLAN Rust · {p}</a></li>' for p in sorted(feeds)]
        (output / 'index.html').write_text('<!doctype html><html lang="en"><meta charset="utf-8">'
            '<title>MijiaLAN Updates</title><h1>MijiaLAN Updates</h1><ul>' + ''.join(links) + '</ul></html>\n')
        (output / '.nojekyll').touch()
        print('Verified complete site: native macOS' + ''.join(', Rust ' + p for p in sorted(feeds)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--native-feed', type=Path)
    parser.add_argument('--check-live', action='store_true')
    args = parser.parse_args()
    if args.check_live: check_live(args.output)
    else: assemble(args.output, args.native_feed)
