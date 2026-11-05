#!/usr/bin/env python3
"""Verify and launch the exact packaged ZIP on the runner's native architecture."""

import argparse
import hashlib
import json
import platform
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from release_metadata import ROOT, metadata


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("distribution", type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--notarized", action="store_true")
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    evidence = args.evidence.resolve()
    data = metadata()
    archive = args.distribution.resolve() / f"MijiaLAN-{data['version']}-universal.zip"
    checksum_rows = (args.distribution / 'SHA256SUMS.txt').read_text().splitlines()
    expected = next(row.split()[0] for row in checksum_rows if row.split()[1] == archive.name)
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == expected, 'ZIP checksum mismatch'
    with tempfile.TemporaryDirectory(prefix='mijialan-native-smoke-') as directory:
        root = Path(directory)
        run('ditto', '-x', '-k', str(archive), str(root))
        app = root / 'MijiaLAN.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleShortVersionString'] == data['version']
        assert info['CFBundleVersion'] == str(data['build_number'])
        assert info['LSMinimumSystemVersion'] == '15.0'
        run('lipo', str(app / 'Contents/MacOS/MijiaLAN'), '-verify_arch', platform.machine())
        run('codesign', '--verify', '--deep', '--strict', str(app))
        run(sys.executable, str(ROOT / 'scripts/swift_runtime.py'), 'verify', str(app),
            '--report', str(evidence / 'runtime.json'))
        if args.notarized:
            run('xcrun', 'stapler', 'validate', str(app))
            run('spctl', '--assess', '--type', 'execute', '--verbose=4', str(app))
            image = archive.with_suffix('.dmg')
            image_hash = next(row.split()[0] for row in checksum_rows if row.split()[1] == image.name)
            assert hashlib.sha256(image.read_bytes()).hexdigest() == image_hash, 'DMG checksum mismatch'
            run('hdiutil', 'verify', str(image))
            run('xcrun', 'stapler', 'validate', str(image))
            run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=4', str(image))
        # LaunchServices needs writable, pre-existing output files on local storage.
        stdout, stderr, snapshot = root / 'stdout.txt', root / 'stderr.txt', root / 'launch.png'
        stdout.touch()
        stderr.touch()
        try:
            run('open', '-n', '-g', '-j', '-W', '-a', str(app),
                '--stdout', str(stdout), '--stderr', str(stderr),
                '--env', 'MIJIALAN_EPHEMERAL=1', '--env', f'MIJIALAN_SNAPSHOT={snapshot}',
                '--env', 'MIJIALAN_SNAPSHOT_DELAY=1', '--env', 'MIJIALAN_UI_PAGE=settings', timeout=60)
            assert snapshot.is_file() and snapshot.stat().st_size > 1000, 'App failed to render its settings view'
        finally:
            for path in (stdout, stderr, snapshot):
                if path.exists():
                    (evidence / path.name).write_bytes(path.read_bytes())
        report = {'macos': platform.mac_ver()[0], 'architecture': platform.machine(),
                  'version': data['version'], 'build_number': data['build_number'],
                  'archive_sha256': expected, 'notarized': args.notarized, 'launch': 'passed'}
        (evidence / 'smoke.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report))


if __name__ == '__main__':
    main()
