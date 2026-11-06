"""Public tvOS version announcements, separate from executable installers and Sparkle feeds."""
from datetime import datetime
import json
import re

REPOSITORY = 'iPocket-APP/MijiaLAN'
BUNDLE = 'com.ipocket.MijiaLAN.TVPrototype'
TAG = re.compile(r'tvos-v((?:0|[1-9][0-9]{0,5})\.(?:0|[1-9][0-9]{0,5})\.(?:0|[1-9][0-9]{0,5}))-b([1-9][0-9]*)')


def release_feed(releases):
    selected = {}
    for release in releases:
        tag = release.get('tag_name', '')
        match = TAG.fullmatch(tag)
        if not match or release.get('draft') or not release.get('published_at'):
            continue
        version, build = match[1], int(match[2])
        expected = f'MijiaLAN-tvOS-{version}-b{build}.ipa'
        if not any(asset.get('name') == expected and asset.get('size', 0) > 0 for asset in release.get('assets', [])):
            continue
        if build > 2_147_483_647:
            raise ValueError('TV build exceeds its supported range')
        datetime.fromisoformat(release['published_at'].replace('Z', '+00:00'))
        if build in selected:
            raise ValueError('TV build number is not unique')
        selected[build] = dict(version=version, build=build, tag=tag,
            notes=(release.get('body') or '')[:6000], publishedAt=release['published_at'],
            releaseURL=f'https://github.com/{REPOSITORY}/releases/tag/{tag}')
    return dict(schemaVersion=1, platform='tvOS', bundleIdentifier=BUNDLE, channel='selfSigned',
        releases=[selected[build] for build in sorted(selected, reverse=True)[:20]])


def encode(releases):
    return (json.dumps(release_feed(releases), ensure_ascii=False, indent=2) + '\n').encode()
