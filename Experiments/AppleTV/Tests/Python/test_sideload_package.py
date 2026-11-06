"""Run after packaging with MIJIALAN_SIDELOAD_TEST_IPA set; mutates only temporary copies."""
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("verify_sideload", ROOT / "verify_sideload.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


@unittest.skipUnless(os.environ.get("MIJIALAN_SIDELOAD_TEST_IPA"), "requires a built TV entitlement-template IPA")
class SideloadPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mijialan-package-test-")
        self.directory = Path(self.temporary.name)
        self.source = Path(os.environ["MIJIALAN_SIDELOAD_TEST_IPA"]).resolve()
        subprocess.run(["ditto", "-x", "-k", str(self.source), str(self.directory)], check=True, capture_output=True)
        self.app = next((self.directory / "Payload").glob("*.app"))
        self.provider = next((self.app / "PlugIns").glob("*.appex"))

    def tearDown(self):
        self.temporary.cleanup()

    def repack(self):
        ipa = self.directory / "changed.ipa"
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(self.directory / "Payload"), str(ipa)], check=True, capture_output=True)
        return ipa

    def resign(self, bundle, remove=None, group=None):
        raw = subprocess.check_output(["codesign", "-d", "--entitlements", ":-", str(bundle)], stderr=subprocess.DEVNULL)
        values = plistlib.loads(raw)
        if remove:
            values.pop(remove, None)
        if group:
            values[checker.GROUPS] = [group]
        path = self.directory / (bundle.name + ".plist")
        path.write_bytes(plistlib.dumps(values))
        subprocess.run(["codesign", "--force", "--sign", "-", "--generate-entitlement-der", "--entitlements", str(path), str(bundle)], check=True, capture_output=True)

    def test_template_is_valid_but_not_a_device_authorization(self):
        result = checker.verify(self.source, template=True)
        self.assertEqual(result["signingMode"], "entitlement-template")
        self.assertFalse(result["appleProfilesVerified"])
        with self.assertRaisesRegex(ValueError, "provisioning profile"):
            checker.verify(self.source)

    def test_removed_extension_is_rejected(self):
        shutil.rmtree(self.provider)
        with self.assertRaisesRegex(ValueError, "Packet Tunnel extension"):
            checker.verify(self.repack(), template=True)

    def test_dropped_ne_permission_is_rejected_even_when_resigned(self):
        self.resign(self.provider, remove=checker.NE)
        self.resign(self.app)
        with self.assertRaisesRegex(ValueError, "Packet Tunnel permission"):
            checker.verify(self.repack(), template=True)

    def test_unshared_group_is_rejected_even_when_both_signatures_are_valid(self):
        self.resign(self.provider, group="group.example.only-the-provider")
        self.resign(self.app)
        with self.assertRaisesRegex(ValueError, "no common signed sharing permission"):
            checker.verify(self.repack(), template=True)

    def test_lost_keychain_permission_is_rejected_even_when_resigned(self):
        self.resign(self.provider, remove=checker.KEYCHAIN)
        self.resign(self.app)
        with self.assertRaisesRegex(ValueError, "shared permissions"):
            checker.verify(self.repack(), template=True)


if __name__ == "__main__":
    unittest.main()
