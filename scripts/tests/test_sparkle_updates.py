import base64
import json
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sparkle_updates


class UpdateConfigurationTests(unittest.TestCase):
    def test_configures_updates_without_changing_app_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "MijiaLAN.app"
            path = app / "Contents/Info.plist"
            path.parent.mkdir(parents=True)
            original = {"CFBundleIdentifier": "com.mijialan.MijiaLAN", "CFBundleVersion": "7"}
            path.write_bytes(plistlib.dumps(original))
            sparkle_updates.configure_app(app)
            info = plistlib.loads(path.read_bytes())
            for key, value in original.items():
                self.assertEqual(info[key], value)
            self.assertTrue(info["SUEnableAutomaticChecks"])
            self.assertFalse(info["SUAutomaticallyUpdate"])
            self.assertFalse(info["SUEnableSystemProfiling"])
            self.assertTrue(info["SUVerifyUpdateBeforeExtraction"])

    def test_rejects_http_credentials_and_invalid_public_key(self):
        config = sparkle_updates.configuration()
        changes = [{"feed_url": "http://example.com/appcast.xml"},
                   {"feed_url": "https://secret@example.com/appcast.xml"},
                   {"public_key": base64.b64encode(b"short").decode()}]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for change in changes:
                (root / "updates.json").write_text(json.dumps({**config, **change}))
                with patch.object(sparkle_updates, "ROOT", root), self.assertRaises(ValueError):
                    sparkle_updates.configuration()


class FeedValidationTests(unittest.TestCase):
    def test_rejects_missing_signature_or_mismatched_release_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, feed = root / "MijiaLAN-0.1.6-universal.zip", root / "appcast.xml"
            archive.write_bytes(b"test-update")
            prefix = "https://github.com/iPocket-APP/MijiaLAN/releases/download/v0.1.6/"
            info = {"CFBundleVersion": "7", "CFBundleShortVersionString": "0.1.6", "LSMinimumSystemVersion": "13.0"}
            signature = base64.b64encode(bytes(64)).decode()
            template = '<rss xmlns:sparkle="' + sparkle_updates.SPARKLE + '"><channel><item>' \
                       '<sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>0.1.6</sparkle:shortVersionString>' \
                       '<sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>' \
                       '<enclosure url="{url}" length="11" sparkle:edSignature="{signature}"/></item></channel></rss>'
            good = {"build": "7", "minimum": "13.0", "url": prefix + archive.name, "signature": signature}
            feed.write_text(template.format(**good))
            sparkle_updates.validate_feed(feed, archive, info, prefix)
            for change in [{"build": "6"}, {"minimum": "15.0"}, {"url": "http://example.com/update.zip"}, {"signature": ""}]:
                feed.write_text(template.format(**{**good, **change}))
                with self.subTest(change=change), self.assertRaises(ValueError):
                    sparkle_updates.validate_feed(feed, archive, info, prefix)


if __name__ == "__main__":
    unittest.main()
