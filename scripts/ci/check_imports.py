#!/usr/bin/env python3
"""List the system libraries and symbols an app needs that an older macOS SDK does not provide.

dyld stops an app before main() when a strongly linked library or strongly imported symbol is missing: no
window, no dialog, and no process left to see. An SDK's .tbd stubs list what that macOS version's libraries
export, so a strong import absent from the macOS 15.5 SDK is absent on macOS 15.5 and 15.6 as well.
"""

import argparse
import json
import plistlib
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

IMPORT = re.compile(r'^\s+0x[0-9A-Fa-f]+\s+(\S+)\s+(\[weak-import\]\s+)?\(from ([^)]+)\)\s*$')
HEADER = re.compile(r'\(for architecture ([^)]+)\):$')


def family(arch):
    # System libraries ship arm64e slices; an arm64 app binds to them.
    return 'arm64' if arch.startswith('arm64') else arch


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def imports(binary, arch):
    rows = []
    for line in run('xcrun', 'dyld_info', '-arch', arch, '-imports', str(binary)).splitlines():
        match = IMPORT.match(line)
        if match:
            rows.append((match.group(1), match.group(3), bool(match.group(2))))
    return rows


def dependents(binary, arch):
    """The binary's linked libraries as (load path, weak)."""
    rows, listing = [], False
    for line in run('xcrun', 'dyld_info', '-arch', arch, '-dependents', str(binary)).splitlines():
        if not line.startswith(' ') or line.strip().startswith('-'):
            listing = False  # the next binary's header, or another section such as -rpaths
        elif 'load path' in line:
            listing = True
        elif listing and line.strip():
            fields = line.split()
            rows.append((fields[-1], fields[0] == 'weak-link'))
    return rows


def exports(sdk):
    """Per architecture family: the symbols exported and the install names of the libraries present."""
    files = [str(p) for p in Path(sdk).rglob('*.tbd')]
    symbols, libraries = defaultdict(set), defaultdict(set)
    for start in range(0, len(files), 400):
        output = subprocess.run(['xcrun', 'nm', '-gj', *files[start:start + 400]], capture_output=True, text=True).stdout
        arch = None
        for line in output.splitlines():
            header = HEADER.search(line)
            if header:
                arch = family(header.group(1))
                libraries[arch].add(line[:header.start()].strip())
            elif line and arch:
                symbols[arch].add(line)
    return symbols, libraries


def sdk_version(sdk):
    return json.loads((Path(sdk) / 'SDKSettings.json').read_text())['Version']


def demangle(names):
    if not names:
        return []
    result = subprocess.run(['xcrun', 'swift-demangle', '--simplified'], input='\n'.join(names), capture_output=True, text=True)
    return result.stdout.splitlines() if result.returncode == 0 else names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--sdk', action='append', required=True, help='MacOSX*.sdk to check against; repeatable')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
    binaries = [args.app / 'Contents/MacOS' / info['CFBundleExecutable']]
    binaries += sorted((args.app / 'Contents/Frameworks').glob('*.dylib'))
    bundled = {b.stem for b in binaries[1:]}
    needed = defaultdict(lambda: defaultdict(set))  # arch -> symbol -> libraries
    linked = defaultdict(lambda: defaultdict(set))  # arch -> library load path -> binaries
    for binary in binaries:
        for arch in run('lipo', '-archs', str(binary)).split():
            for symbol, library, weak in imports(binary, arch):
                if not weak and library not in bundled and not library.startswith('<'):
                    needed[arch][symbol].add(library)
            for path, weak in dependents(binary, arch):
                if not weak and not path.startswith('@'):
                    linked[arch][path].add(binary.name)
    report = {'app': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion'),
              'minimumSystemVersion': info.get('LSMinimumSystemVersion'),
              'strongImports': {arch: len(symbols) for arch, symbols in needed.items()},
              'strongLibraries': {arch: sorted(paths) for arch, paths in linked.items()}, 'sdks': []}
    missing_any = False
    sdks = sorted({Path(sdk).resolve() for sdk in args.sdk}, key=lambda sdk: [int(n) for n in sdk_version(sdk).split('.')])
    for sdk in sdks:
        symbols_present, libraries_present = exports(sdk)
        entry = {'sdk': str(sdk), 'version': sdk_version(sdk), 'missingLibraries': {}, 'missing': {}}
        for arch, paths in linked.items():
            absent = sorted(p for p in paths if p not in libraries_present[family(arch)])
            if absent:
                missing_any = True
                entry['missingLibraries'][arch] = [{'library': p, 'linkedBy': sorted(paths[p])} for p in absent]
        for arch, symbols in needed.items():
            missing = sorted(s for s in symbols if s not in symbols_present[family(arch)])
            if missing:
                missing_any = True
                entry['missing'][arch] = [{'symbol': s, 'demangled': d, 'from': sorted(symbols[s])}
                                          for s, d in zip(missing, demangle(missing))]
        report['sdks'].append(entry)
        libraries = {arch: len(rows) for arch, rows in entry['missingLibraries'].items()}
        counts = {arch: len(rows) for arch, rows in entry['missing'].items()}
        print(f"macOS {entry['version']} SDK: missing strong libraries {libraries or 'none'}, "
              f"missing strong imports {counts or 'none'}", flush=True)
        for arch, rows in entry['missingLibraries'].items():
            for row in rows:
                print(f"  [{arch}] library {row['library']} (linked by {', '.join(row['linkedBy'])})")
        for arch, rows in entry['missing'].items():
            for row in rows[:40]:
                print(f"  [{arch}] {', '.join(row['from'])}: {row['demangled']}")
    if args.report:
        args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    return 1 if missing_any else 0


if __name__ == '__main__':
    sys.exit(main())
