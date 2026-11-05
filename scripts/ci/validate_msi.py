#!/usr/bin/env python3
"""Inspect the compiled MSI tables, including upgrade safety and client restart."""
import argparse
import csv
import io
import subprocess


def table(package, name):
    text = subprocess.check_output(['msiinfo', 'export', str(package), name], text=True)
    rows = list(csv.reader(io.StringIO(text), delimiter='\t'))
    return [dict(zip(rows[0], row)) for row in rows[3:] if row]


def validate(package, version, build):
    major, minor, _ = version.split('.')
    expected = f'{int(major)}.{int(minor)}.{int(build)}'
    properties = {row['Property']: row['Value'] for row in table(package, 'Property')}
    assert properties['ProductVersion'] == expected, 'MSI build differs from the signed feed'
    upgrades = {row['ActionProperty']: row for row in table(package, 'Upgrade')}
    assert upgrades['PREVIOUSVERSIONS']['VersionMax'] == expected, 'Upgrade removal is not bounded'
    assert upgrades['NEWERPRODUCTFOUND']['VersionMin'] == expected, 'Downgrade guard is missing'
    assert int(upgrades['NEWERPRODUCTFOUND']['Attributes']) & 2, 'Newer versions must be detection-only'
    assert any(row['Name'] == 'InstallPath' and row['Value'] == '[INSTALLDIR]' and row['Root'] == '1'
               for row in table(package, 'Registry')), 'Per-user install marker is missing'
    actions = {row['Action']: row for row in table(package, 'CustomAction')}
    assert set(actions) == {'LaunchApplication'}, 'Unexpected installer execution action'
    action = actions['LaunchApplication']
    flags = int(action['Type'])
    assert flags & 0x3F == 18 and flags & 0xC0 == 0xC0, 'Client launch must be an asynchronous installed EXE'
    assert not flags & 0xC00, 'Client launch must be immediate and use the installing user'
    files = {row['File']: row for row in table(package, 'File')}
    assert files[action['Source']]['FileName'].split('|')[-1] == 'mijialan-rust.exe', 'Wrong restart executable'
    assert not action['Target'], 'Restart must not run external commands'
    sequence = {row['Action']: row for row in table(package, 'InstallExecuteSequence')}
    launch = sequence['LaunchApplication']
    assert int(launch['Sequence']) > int(sequence['InstallFinalize']['Sequence']), 'Restart runs before commit'
    assert launch['Condition'] == 'NOT Installed AND NOT (REMOVE="ALL")', 'Restart must not run during removal or repair'
    print('Compiled MSI verified: release build, upgrade bounds, per-user install and post-commit client restart')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package')
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    args = parser.parse_args()
    validate(args.package, args.version, args.build)
