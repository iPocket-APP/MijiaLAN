import base64
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import updates
import update_site


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.seed = bytes(range(32))
        public = subprocess.run([updates.openssl(), 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'],
            input=bytes.fromhex('302e020100300506032b657004220420') + self.seed, capture_output=True, check=True).stdout[-32:]
        self.key = base64.b64encode(public).decode()
        self.settings = {'base_url': 'https://mijialan-updates.ipocket.xyz', 'public_key': self.key}
        self.site_settings = dict(origin=self.settings['base_url'], repository='iPocket-APP/MijiaLAN',
                                  native_public_key=self.key, rust_public_key=self.key)
        self.updates_config = patch.object(updates, 'configuration', return_value=self.settings)
        self.updates_config.start(); self.addCleanup(self.updates_config.stop)
        self.site_config = patch.object(update_site, 'config', return_value=self.site_settings)
        self.site_config.start(); self.addCleanup(self.site_config.stop)
        self.env = patch.dict(os.environ, RUST_UPDATE_PRIVATE_KEY=base64.b64encode(self.seed).decode())
        self.env.start(); self.addCleanup(self.env.stop)

    def test_signatures_reject_tampering_wrong_keys_and_malformed_material(self):
        archive = self.root / 'update.zip'
        archive.write_bytes(b'release bytes')
        signature = updates.sign(archive)
        updates.verify_signature(archive, signature, self.key)
        update_site.verify(archive, signature, self.key)
        archive.write_bytes(b'changed bytes')
        for verifier in [updates.verify_signature, update_site.verify]:
            with self.assertRaises(ValueError): verifier(archive, signature, self.key)
            with self.assertRaises(ValueError): verifier(archive, signature, base64.b64encode(bytes(32)).decode())
            with self.assertRaises(ValueError): verifier(archive, 'abc', self.key)

    def write_packages(self, build=12):
        for platform in updates.PLATFORMS:
            extension = 'msi' if platform.startswith('windows') else 'zip'
            path = self.root / f'MijiaLAN-rs-0.1.0-b{build}-{platform}.{extension}'
            if extension == 'msi':
                path.write_bytes(b'installer payload')
            else:
                info = dict(CFBundleIdentifier='xyz.ipocket.MijiaLAN.Rust', CFBundleVersion=str(build),
                            CFBundleShortVersionString='0.1.0', SUFeedURL=updates.feed_url(platform), SUPublicEDKey=self.key)
                with zipfile.ZipFile(path, 'w') as archive:
                    archive.writestr('MijiaLAN.app/Contents/Info.plist', plistlib.dumps(info))

    def test_signed_bundle_has_only_isolated_platform_feeds_and_matching_release_builds(self):
        self.write_packages()
        updates.prepare_feeds(self.root, '0.1.0', 12)
        bundle = self.root / 'rust-update-feeds.zip'
        update_site.verify(bundle, (self.root / 'rust-update-feeds.zip.sig').read_text(), self.key)
        with zipfile.ZipFile(bundle) as archive:
            self.assertEqual(set(archive.namelist()), {f'rs/{p}/appcast.xml' for p in updates.PLATFORMS})
            for platform in updates.PLATFORMS:
                content = archive.read(f'rs/{platform}/appcast.xml')
                tag, name, _, length, signature = update_site.inspect_feed(content, platform, 'rs-v0.1.0-b12')
                self.assertEqual(tag, 'rs-v0.1.0-b12')
                self.assertEqual(length, (self.root / name).stat().st_size)
                update_site.verify(self.root / name, signature, self.key)
                for other in ['native', *(p for p in updates.PLATFORMS if p != platform)]:
                    with self.assertRaises(ValueError): update_site.inspect_feed(content, other, 'rs-v0.1.0-b12')
                with self.assertRaises(ValueError): update_site.inspect_feed(content, platform, 'rs-v0.1.0-b13')

    def test_mac_package_identity_mismatch_blocks_feed_generation(self):
        self.write_packages()
        path = self.root / 'MijiaLAN-rs-0.1.0-b12-macos-arm64.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('MijiaLAN.app/Contents/Info.plist', plistlib.dumps(dict(CFBundleIdentifier='com.mijialan.MijiaLAN')))
        with self.assertRaises(ValueError): updates.prepare_feeds(self.root, '0.1.0', 12)

    def test_windows_release_stamp_preserves_executable_and_runtime_bytes(self):
        source, output = self.root / 'source.zip', self.root / 'release.zip'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('app/mijialan-rust.exe', b'verified executable')
            archive.writestr('app/WinSparkle.dll', b'verified runtime')
            archive.writestr('app/mijialan-update.json', json.dumps(updates.windows_metadata('0.1.0', 1)))
        updates.repackage_windows(source, output, '0.1.0', 12)
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(archive.read('app/mijialan-rust.exe'), b'verified executable')
            self.assertEqual(archive.read('app/WinSparkle.dll'), b'verified runtime')
            self.assertEqual(json.loads(archive.read('app/mijialan-update.json'))['build'], 12)

    def test_msi_increases_build_and_does_not_remove_newer_products(self):
        stage = self.root / 'app'
        stage.mkdir()
        (stage / 'mijialan-rust.exe').write_bytes(b'program')
        (stage / 'mijialan-update.json').write_text(json.dumps(updates.windows_metadata('0.1.0', 12)))
        output = self.root / 'app.wxs'
        subprocess.run([sys.executable, str(updates.ROOT / 'packaging/windows/generate_msi.py'), str(stage), '0.1.0', str(output)], check=True)
        root = ET.parse(output).getroot()
        ns = {'w': 'http://schemas.microsoft.com/wix/2006/wi'}
        self.assertEqual(root.find('w:Product', ns).get('Version'), '0.1.12')
        upgrade = root.find('.//w:UpgradeVersion[@Property="PREVIOUSVERSIONS"]', ns)
        self.assertEqual(upgrade.get('Maximum'), '0.1.12')
        self.assertEqual(root.find('.//w:RegistryValue[@Name="InstallPath"]', ns).get('Value'), '[INSTALLDIR]')
        launch = root.find('.//w:CustomAction[@Id="LaunchApplication"]', ns)
        self.assertEqual(launch.get('Return'), 'asyncNoWait')
        self.assertTrue(launch.get('FileKey').startswith('F'))
        scheduled = root.find('.//w:InstallExecuteSequence/w:Custom[@Action="LaunchApplication"]', ns)
        self.assertEqual(scheduled.get('After'), 'InstallFinalize')
        self.assertIn('NOT Installed', scheduled.text)
        self.assertIn('REMOVE="ALL"', scheduled.text)

    def test_invalid_builds_and_foreign_platforms_are_rejected(self):
        for build in [0, -1, 65536, '12.5', '１２', True]:
            with self.assertRaises(ValueError): updates.build_number(build)
        with self.assertRaises(ValueError): updates.feed_url('native')
