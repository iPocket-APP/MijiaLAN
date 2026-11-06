import base64
import io
import plistlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import update_site as site


class SharedSiteTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.files, self.releases = {}, {}
        self.settings = dict(origin='https://mijialan-updates.ipocket.xyz', repository='iPocket-APP/MijiaLAN',
            native_public_key=base64.b64encode(bytes(32)).decode(), rust_public_key=base64.b64encode(bytes([1]) * 32).decode())
        for target, replacement in [('config', lambda: self.settings), ('api', self.api),
                                    ('download', self.download), ('verify', lambda *args: None)]:
            mock = patch.object(site, target, replacement)
            mock.start(); self.addCleanup(mock.stop)

    def api(self, path, paginate=False):
        if path.startswith('releases?'): return list(reversed(list(self.releases.values())))
        return self.releases[path.removeprefix('releases/tags/')]

    def download(self, url, path, limit):
        content = self.files[url]
        if len(content) > limit: raise ValueError('fixture exceeds limit')
        path.write_bytes(content)

    def feed(self, tag, platform, build):
        version = tag[1:] if platform == 'native' else '0.1.0'
        extension = 'msi' if platform.startswith('windows') else 'zip'
        name = f'MijiaLAN-{version}-universal.zip' if platform == 'native' else f'MijiaLAN-rs-{version}-b{build}-{platform}.{extension}'
        url = f'https://github.com/iPocket-APP/MijiaLAN/releases/download/{tag}/{name}'
        content = ('archive:' + name).encode()
        if not platform.startswith('windows'):
            buffer = io.BytesIO()
            feed_path = '/appcast.xml' if platform == 'native' else f'/rs/{platform}/appcast.xml'
            info = dict(CFBundleIdentifier='com.mijialan.MijiaLAN' if platform == 'native' else 'xyz.ipocket.MijiaLAN.Rust',
                CFBundleVersion=str(build), CFBundleShortVersionString=version,
                SUFeedURL=self.settings['origin'] + feed_path,
                SUPublicEDKey=self.settings['native_public_key' if platform == 'native' else 'rust_public_key'])
            with zipfile.ZipFile(buffer, 'w') as archive:
                archive.writestr('MijiaLAN.app/Contents/Info.plist', plistlib.dumps(info))
            content = buffer.getvalue()
        self.files[url] = content
        release = self.releases.setdefault(tag, dict(tag_name=tag, draft=False, assets=[]))
        release['assets'].append(dict(name=name, size=len(content), browser_download_url=url))
        root = ET.Element('rss')
        item = ET.SubElement(ET.SubElement(root, 'channel'), 'item')
        ET.SubElement(item, f'{{{site.SPARKLE}}}version').text = str(build)
        ET.SubElement(item, f'{{{site.SPARKLE}}}shortVersionString').text = version
        ET.SubElement(item, 'enclosure', {'url': url, 'length': str(len(content)),
            f'{{{site.SPARKLE}}}edSignature': base64.b64encode(bytes(64)).decode(),
            f'{{{site.SPARKLE}}}os': 'windows-x64' if platform.startswith('windows') else 'macos'})
        return ET.tostring(root)

    def bundle(self, build, platforms, extra=None):
        tag = f'rs-v0.1.0-b{build}'
        path = self.root / f'feed-b{build}.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            for platform in platforms:
                archive.writestr(f'rs/{platform}/appcast.xml', self.feed(tag, platform, build))
            if extra: archive.writestr(extra, b'foreign path')
        release = self.releases[tag]
        for name, content in [('rust-update-feeds.zip', path.read_bytes()), ('rust-update-feeds.zip.sig', b'fixture-signature')]:
            url = f'https://github.com/{tag}/{name}'
            self.files[url] = content
            release['assets'].append(dict(name=name, size=len(content), browser_download_url=url))

    def test_each_platform_keeps_its_newest_signed_release(self):
        self.bundle(12, site.PLATFORMS)
        self.bundle(13, ['windows-x86_64'])
        selected = site.rust_feeds(self.root)
        self.assertEqual(set(selected), set(site.PLATFORMS))
        for platform, content in selected.items():
            item = ET.fromstring(content).find('./channel/item')
            self.assertEqual(item.findtext(f'{{{site.SPARKLE}}}version'), '13' if platform.startswith('windows') else '12')

    def test_native_and_rust_refreshes_preserve_all_other_paths(self):
        native = self.feed('v0.1.6', 'native', 6)
        self.files[self.settings['origin'] + '/appcast.xml'] = native
        self.bundle(12, site.PLATFORMS)
        first = self.root / 'rust-trigger'
        site.assemble(first)
        native_input = self.root / 'native.xml'
        native_input.write_bytes(native)
        second = self.root / 'native-trigger'
        site.assemble(second, native_input)
        for relative in ['appcast.xml', *(f'rs/{p}/appcast.xml' for p in site.PLATFORMS)]:
            self.assertEqual((first / relative).read_bytes(), (second / relative).read_bytes())
        self.assertEqual((second / 'appcast.xml').read_bytes(), native)

    def test_a_superseded_native_deployment_does_not_lose_a_new_public_release(self):
        older = self.feed('v0.1.6', 'native', 6)
        self.files[self.settings['origin'] + '/appcast.xml'] = older
        newer = self.feed('v0.1.7', 'native', 7)
        url = 'https://github.com/iPocket-APP/MijiaLAN/releases/download/v0.1.7/native-appcast.xml'
        self.files[url] = newer
        self.releases['v0.1.7']['assets'].append(dict(name='native-appcast.xml', size=len(newer), browser_download_url=url))
        stale = self.root / 'older-native.xml'
        stale.write_bytes(older)
        self.bundle(12, site.PLATFORMS)
        site.assemble(self.root / 'site', stale)
        self.assertEqual((self.root / 'site/appcast.xml').read_bytes(), newer)
        self.assertTrue((self.root / 'site/rs/windows-x86_64/appcast.xml').exists())

    def test_foreign_bundle_paths_or_untrusted_signatures_stage_nothing(self):
        native = self.feed('v0.1.6', 'native', 6)
        self.files[self.settings['origin'] + '/appcast.xml'] = native
        self.bundle(12, ['macos-arm64'], extra='appcast.xml')
        output = self.root / 'rejected-site'
        with self.assertRaises(ValueError): site.assemble(output)
        self.assertEqual(list(output.iterdir()), [])
        self.bundle(13, site.PLATFORMS)
        with patch.object(site, 'verify', side_effect=ValueError('bad signature')):
            with self.assertRaises(ValueError): site.assemble(output)
        self.assertEqual(list(output.iterdir()), [])

    def test_native_cannot_be_replaced_with_a_rust_enclosure(self):
        content = self.feed('rs-v0.1.0-b12', 'macos-arm64', 12)
        with self.assertRaises(ValueError): site.inspect_feed(content, 'native')

    def test_unsigned_feed_cannot_lie_about_the_signed_native_build(self):
        content = self.feed('v0.1.6', 'native', 6)
        root = ET.fromstring(content)
        root.find(f'./channel/item/{{{site.SPARKLE}}}version').text = '9999'
        with self.assertRaisesRegex(ValueError, 'signed app bundle'):
            site.verify_feed(ET.tostring(root), 'native', self.root)

    def test_initial_site_retains_native_when_no_rust_update_release_exists(self):
        native = self.feed('v0.1.6', 'native', 6)
        self.files[self.settings['origin'] + '/appcast.xml'] = native
        site.assemble(self.root / 'site')
        self.assertEqual((self.root / 'site/appcast.xml').read_bytes(), native)


if __name__ == '__main__': unittest.main()
