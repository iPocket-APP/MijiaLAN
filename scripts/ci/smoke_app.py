#!/usr/bin/env python3
"""Verify and launch the exact packaged ZIP on the runner's native architecture."""

import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from release_metadata import ROOT, metadata


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def assess(*args):
    result = run('spctl', '--assess', *args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(result.stdout, end='')
    assert 'source=Notarized Developer ID' in result.stdout, 'Gatekeeper did not accept the notarized Developer ID package'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("distribution", type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--notarized", action="store_true")
    parser.add_argument("--startup-only", action="store_true", help="Avoid GPU rendering on virtual Intel runners")
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    evidence = args.evidence.resolve()
    data = metadata()
    archive = args.distribution.resolve() / f"MijiaLAN-{data['version']}-universal.zip"
    checksum_rows = (args.distribution / 'SHA256SUMS.txt').read_text().splitlines()
    expected = next(row.split()[0] for row in checksum_rows if row.split()[1] == archive.name)
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == expected, 'ZIP checksum mismatch'
    with tempfile.TemporaryDirectory(prefix='mijialan-native-smoke-') as directory:
        root = Path(directory).resolve()
        run('ditto', '-x', '-k', str(archive), str(root))
        app = root / 'MijiaLAN.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleShortVersionString'] == data['version']
        assert info['CFBundleVersion'] == str(data['build_number'])
        assert info['LSMinimumSystemVersion'] == '12.0'
        helper = app / 'Contents/Library/LoginItems/MijiaLANLoginItem.app'
        login = plistlib.loads((helper / 'Contents/Info.plist').read_bytes())
        assert login['CFBundleIdentifier'] == info['CFBundleIdentifier'] + '.LoginItem'
        assert login['LSMinimumSystemVersion'] == info['LSMinimumSystemVersion']
        assert login['LSBackgroundOnly'] is True
        run('lipo', str(helper / 'Contents/MacOS' / login['CFBundleExecutable']), '-verify_arch', platform.machine())
        run('lipo', str(app / 'Contents/MacOS/MijiaLAN'), '-verify_arch', platform.machine())
        run('codesign', '--verify', '--deep', '--strict', str(app))
        run(sys.executable, str(ROOT / 'scripts/swift_runtime.py'), 'verify', str(app),
            '--report', str(evidence / 'runtime.json'))
        if args.notarized:
            # The packaging job already staples and validates these exact bytes.
            # Check the target OS's Gatekeeper policy here, avoiding a redundant
            # online CloudKit lookup in stapler validate on every smoke runner.
            assess('--type', 'execute', '--verbose=4', str(app))
            image = archive.with_suffix('.dmg')
            image_hash = next(row.split()[0] for row in checksum_rows if row.split()[1] == image.name)
            assert hashlib.sha256(image.read_bytes()).hexdigest() == image_hash, 'DMG checksum mismatch'
            run('hdiutil', 'verify', str(image))
            assess('--type', 'open', '--context', 'context:primary-signature', '--verbose=4', str(image))
        # LaunchServices needs writable, pre-existing output files on local storage.
        stdout, stderr, snapshot = root / 'stdout.txt', root / 'stderr.txt', root / 'launch.png'
        diagnostics = root / 'startup.json'
        stdout.touch()
        stderr.touch()
        try:
            command = ['open', '-n', '-g', '-j', '-W', '-a', str(app), '--stdout', str(stdout),
                       '--stderr', str(stderr), '--env', 'MIJIALAN_EPHEMERAL=1']
            if args.startup_only:
                # Existing diagnostics run on MainActor after AppModel/NSApplication
                # initialize. Intel hosted VMs cannot reliably render Metal views.
                command += ['--env', f'MIJIALAN_DIAGNOSTICS_OUTPUT={diagnostics}']
                process = subprocess.Popen(command)
                try:
                    deadline = time.monotonic() + 45
                    while not diagnostics.exists():
                        assert process.poll() is None, 'App exited before startup diagnostics'
                        assert time.monotonic() < deadline, 'App did not finish startup'
                        time.sleep(0.2)
                    state = json.loads(diagnostics.read_text())
                    assert state['devices'] == [] and state['paired'] is False, 'Smoke launch must use an empty ephemeral profile'
                finally:
                    result = subprocess.run(['pgrep', '-f', '^' + re.escape(str(app / 'Contents/MacOS/MijiaLAN')) + '( |$)'], capture_output=True, text=True)
                    for pid in result.stdout.split():
                        try: os.kill(int(pid), signal.SIGTERM)
                        except ProcessLookupError: pass
                    process.wait(timeout=10)
            else:
                command += ['--env', f'MIJIALAN_SNAPSHOT={snapshot}', '--env', 'MIJIALAN_SNAPSHOT_DELAY=1',
                            '--env', 'MIJIALAN_UI_PAGE=settings']
                run(*command, timeout=60)
                assert snapshot.is_file() and snapshot.stat().st_size > 1000, 'App failed to render its settings view'
                assert 'SNAPSHOT ' in stdout.read_text(), 'App did not finish its startup/render cycle'
        finally:
            for path in (stdout, stderr, snapshot, diagnostics):
                if path.exists():
                    (evidence / path.name).write_bytes(path.read_bytes())
        report = {'macos': platform.mac_ver()[0], 'architecture': platform.machine(),
                  'version': data['version'], 'build_number': data['build_number'],
                  'archive_sha256': expected, 'notarized': args.notarized, 'launch': 'passed',
                  'evidence': 'startup-diagnostics' if args.startup_only else 'rendered-settings'}
        (evidence / 'smoke.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report))


if __name__ == '__main__':
    main()
