from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tvos_updates as tv


def release(build=2, version='0.1.1'):
    return dict(tag_name=f'tvos-v{version}-b{build}', draft=False, prerelease=True,
        published_at='2026-11-06T00:00:00Z', body='TV update notes',
        assets=[dict(name=f'MijiaLAN-tvOS-{version}-b{build}.ipa', size=1234)])


class TVUpdateTests(unittest.TestCase):
    def test_tv_feed_is_sorted_and_cannot_contain_native_or_rust_updates(self):
        native, rust = release(), release()
        native['tag_name'], rust['tag_name'] = 'v99.0.0', 'rs-v99.0.0-b999'
        feed = tv.release_feed([release(), native, release(3), rust])
        self.assertEqual(feed['bundleIdentifier'], tv.BUNDLE)
        self.assertEqual(feed['platform'], 'tvOS')
        self.assertEqual([r['build'] for r in feed['releases']], [3, 2])

    def test_drafts_empty_assets_and_wrong_ipa_names_are_not_announced(self):
        draft, missing, wrong = release(), release(), release()
        draft['draft'] = True
        missing['assets'] = []
        wrong['assets'][0]['name'] = 'MijiaLAN-0.1.1-universal.zip'
        self.assertEqual(tv.release_feed([draft, missing, wrong])['releases'], [])

    def test_ambiguous_build_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'not unique'):
            tv.release_feed([release(), release(version='0.1.2')])

    def test_empty_feed_means_no_tv_release_not_latest_native_version(self):
        self.assertEqual(tv.release_feed([])['releases'], [])

    def test_announcement_history_stays_within_the_client_response_limit(self):
        releases = [release(build) for build in range(1, 31)]
        for item in releases:
            item['body'] = '测' * 6000
        feed = tv.release_feed(releases)
        self.assertEqual(len(feed['releases']), 20)
        self.assertEqual(feed['releases'][0]['build'], 30)
        self.assertLess(len(tv.encode(releases)), 1024 * 1024)


if __name__ == '__main__':
    unittest.main()
