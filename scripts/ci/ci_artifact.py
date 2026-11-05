#!/usr/bin/env python3
"""Archive a CI build or promote an exact-commit artifact without recompiling it."""

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tarfile
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from release_metadata import ROOT, metadata


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def uuids(path):
    output = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(path)], text=True)
    return {arch: value for value, arch in re.findall(r'UUID: ([0-9A-F-]+) \(([^)]+)\)', output)}


def validate(directory, commit, run_id):
    record = json.loads((directory / 'provenance.json').read_text())
    release = metadata()
    assert record['source_commit'] == commit, 'CI artifact belongs to a different source commit'
    assert record['run_id'] == str(run_id), 'CI artifact belongs to a different workflow run'
    assert record['version'] == release['version'] and record['build_number'] == release['build_number'], 'CI release metadata mismatch'
    expected = {f"MijiaLAN-{release['version']}-universal.zip", 'symbols.tar.gz'}
    assert set(record['files']) == expected, 'Unexpected CI payload files'
    for name, digest in record['files'].items():
        assert sha256(directory / name) == digest, f'CI payload checksum mismatch: {name}'
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['archive', 'promote'])
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--symbols', required=True, type=Path)
    parser.add_argument('--run-id', default=os.environ.get('GITHUB_RUN_ID', 'local'))
    args = parser.parse_args()
    data = metadata()
    executable = args.app / 'Contents/MacOS/MijiaLAN'
    archive = args.directory / f"MijiaLAN-{data['version']}-universal.zip"
    commit = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    args.directory.mkdir(parents=True, exist_ok=True)
    if args.mode == 'archive':
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(args.app), str(archive)], check=True)
        with tarfile.open(args.directory / 'symbols.tar.gz', 'w:gz') as tar:
            tar.add(args.symbols, arcname='MijiaLAN.app.dSYM')
        record = {**data, 'source_commit': commit, 'run_id': str(args.run_id),
                  'toolchain': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
                  'uuids': uuids(executable),
                  'files': {p.name: sha256(p) for p in [archive, args.directory / 'symbols.tar.gz']}}
        (args.directory / 'provenance.json').write_text(json.dumps(record, indent=2) + '\n')
        sums = {**record['files'], 'provenance.json': sha256(args.directory / 'provenance.json')}
        (args.directory / 'SHA256SUMS.txt').write_text(''.join(f'{digest}  {name}\n' for name, digest in sums.items()))
    else:
        record = validate(args.directory, commit, args.run_id)
        assert not args.app.exists() and not args.symbols.exists(), 'Promotion destination must be empty'
        args.app.parent.mkdir(parents=True, exist_ok=True)
        args.symbols.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['ditto', '-x', '-k', str(archive), str(args.app.parent)], check=True)
        with tarfile.open(args.directory / 'symbols.tar.gz', 'r:gz') as tar:
            for member in tar.getmembers():
                name = PurePosixPath(member.name)
                assert not name.is_absolute() and '..' not in name.parts and name.parts[0] == 'MijiaLAN.app.dSYM'
                assert member.isfile() or member.isdir(), 'Unexpected symbol archive member'
            tar.extractall(args.symbols.parent, filter='data')
        print(f"Reusing CI run {args.run_id}, source {commit}; no Swift compilation")
    info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleShortVersionString'] == data['version'] and info['CFBundleVersion'] == str(data['build_number'])
    actual = uuids(executable)
    assert set(actual) == {'arm64', 'x86_64'} and actual == record['uuids'] == uuids(args.symbols), 'CI binary/dSYM UUID mismatch'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app)], check=True)


if __name__ == '__main__':
    main()
