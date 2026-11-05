#!/usr/bin/env python3
"""Install a published release the way a person does, open it, and record what actually appears.

Steps: download the DMG and mark it as a browser download; assess it with Gatekeeper; copy the app to
/Applications; open it; then look for the menu-bar icon, click it, and open the app again while it runs.
Evidence (Gatekeeper output, windows, panel events, logs, crash reports, screenshots) goes to --evidence.
"""

import argparse
import hashlib
import json
import os
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

POPUP_LAYER = 101  # NSWindow.Level.popUpMenu: the native app's panel


def run(*args, check=False, timeout=120):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    if check and result.returncode != 0:
        raise SystemExit(f"{' '.join(map(str, args))} failed ({result.returncode}):\n{result.stdout}{result.stderr}")
    return result


def captured(result):
    return {'status': result.returncode, 'output': (result.stdout + result.stderr).strip()[-4000:]}


class Check:
    def __init__(self, evidence, probe):
        self.evidence = evidence
        self.probe = probe
        self.report = {'macos': platform.mac_ver()[0], 'build': run('sw_vers', '-buildVersion').stdout.strip(),
                       'architecture': platform.machine(), 'timeline': []}
        self.started = time.time()

    def probe_json(self, *args):
        result = run(self.probe, *args, timeout=30)
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return {'error': captured(result)}

    def pid(self, executable):
        result = run('pgrep', '-f', f'^{executable}( |$)')
        pids = [int(p) for p in result.stdout.split()]
        return pids[0] if pids else None

    def observe(self, label, executable):
        pid = self.pid(executable)
        entry = {'label': label, 'seconds': round(time.time() - self.started, 1), 'pid': pid}
        if pid:
            entry['windows'] = self.probe_json('windows', str(pid))
            entry['statusItems'] = self.probe_json('statusitems', str(pid)).get('items', [])
        self.report['timeline'].append(entry)
        print(json.dumps(entry, sort_keys=True), flush=True)
        return entry

    def screenshot(self, name):
        run('screencapture', '-x', self.evidence / name, timeout=30)


def panel_visible(entry):
    windows = (entry.get('windows') or {}).get('windows', [])
    return any(w.get('layer') == POPUP_LAYER and w.get('onscreen') for w in windows)


def any_window_visible(entry):
    windows = (entry.get('windows') or {}).get('windows', [])
    return any(w.get('onscreen') and w.get('layer', 0) in (0, 3, POPUP_LAYER) for w in windows)


def download(tag, work):
    native = not tag.startswith('rs-')
    pattern = '*-universal.dmg' if native else '*-macos-arm64.dmg'
    run('gh', 'release', 'download', tag, '--pattern', pattern, '--pattern', 'SHA256SUMS.txt', '--dir', work, check=True)
    image = next(work.glob('*.dmg'))
    sums = dict(reversed(row.split()) for row in (work / 'SHA256SUMS.txt').read_text().splitlines() if row.strip())
    assert hashlib.sha256(image.read_bytes()).hexdigest() == sums[image.name], 'DMG checksum mismatch'
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', help='Release tag to download and install')
    parser.add_argument('--app', type=Path, help='Open this app as it is instead (local dry run)')
    parser.add_argument('--probe', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--no-click', action='store_true', help='Do not post mouse events')
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    check = Check(args.evidence.resolve(), args.probe.resolve())
    report = check.report
    report['tag'] = args.tag
    report['access'] = check.probe_json('access')
    report['displays'] = check.probe_json('windows', '0').get('displays')
    work = Path(tempfile.mkdtemp(prefix='install-check-'))

    if args.app:
        app = args.app.resolve()
    else:
        image = download(args.tag, work)
        # What Safari or Chrome writes on a download: Gatekeeper then checks the first open.
        quarantine = f'0083;{int(time.time()):x};Safari;{str(uuid.uuid4()).upper()}'
        run('xattr', '-w', 'com.apple.quarantine', quarantine, image, check=True)
        report['dmgAssessment'] = captured(run('spctl', '--assess', '--type', 'open', '--context',
                                               'context:primary-signature', '-vv', image))
        mount = work / 'mount'
        mount.mkdir()
        run('hdiutil', 'attach', '-nobrowse', '-readonly', '-mountpoint', mount, image, check=True)
        source = next(mount.glob('*.app'))
        app = Path('/Applications') / source.name
        if app.exists():
            shutil.rmtree(app)
        run('ditto', source, app, check=True)
        run('hdiutil', 'detach', mount, '-force')
        # Finder carries the image's quarantine onto the copy.
        run('xattr', '-w', 'com.apple.quarantine', quarantine, app, check=True)
        report['codesign'] = captured(run('codesign', '--verify', '--deep', '--strict', '-vv', app))
        report['appAssessment'] = captured(run('spctl', '--assess', '--type', 'execute', '-vv', app))
        if shutil.which('syspolicy_check'):
            report['syspolicyCheck'] = captured(run('syspolicy_check', 'distribution', app, timeout=300))
        # The first-open confirmation needs a person; its verdict is the assessment above.
        run('xattr', '-d', 'com.apple.quarantine', app)

    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    executable = str(app / 'Contents/MacOS' / info['CFBundleExecutable'])
    native = info.get('CFBundleIdentifier') == 'com.mijialan.MijiaLAN'
    report['app'] = {key: info.get(key) for key in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion',
                                                    'LSMinimumSystemVersion', 'LSUIElement', 'CFBundleExecutable')}
    report['app']['architectures'] = run('lipo', '-archs', executable).stdout.split()
    report['app']['linked'] = run('otool', '-L', executable).stdout.splitlines()[1:]

    panel_events = check.evidence / 'panel-events.json'
    check.started = time.time()
    since = time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(check.started - 5))
    # Only diagnostics output is added; the profile, keychain and defaults are what a person gets.
    report['open'] = captured(run('open', app, '--env', f'MIJIALAN_NAV_DIAGNOSTICS_OUTPUT={panel_events}'))
    for delay in (1, 3, 6, 10):
        time.sleep(max(0, check.started + delay - time.time()))
        launched = check.observe(f'launch+{delay}s', executable)
    check.screenshot('launch.png')

    clicked = None
    item = (launched.get('statusItems') or [None])[0]
    if launched.get('pid') and item and not args.no_click:
        run(check.probe, 'click', item['x'] + item['width'] / 2, item['y'] + item['height'] / 2)
        time.sleep(2.5)
        clicked = check.observe('after icon click', executable)
        check.screenshot('click.png')
        if panel_visible(clicked):
            run(check.probe, 'click', item['x'] + item['width'] / 2, item['y'] + item['height'] / 2)
            time.sleep(1.5)
            check.observe('after second click', executable)

    reopened = None
    if launched.get('pid'):
        # Opening the app again while it runs, as from Launchpad or Finder.
        report['reopen'] = captured(run('open', app))
        time.sleep(3)
        reopened = check.observe('after reopen', executable)
        check.screenshot('reopen.png')

    pid = check.pid(executable)
    if pid:
        run('kill', '-TERM', pid)
        time.sleep(2)
        if check.pid(executable):
            run('kill', '-KILL', pid)

    name = info['CFBundleExecutable']
    logs = run('log', 'show', '--style', 'compact', '--info', '--debug', '--start', since, '--predicate',
               f'process == "{name}" OR subsystem BEGINSWITH "com.mijialan"', timeout=300)
    (check.evidence / 'app.log').write_text(logs.stdout[-2_000_000:])
    system = run('log', 'show', '--style', 'compact', '--info', '--start', since, '--predicate',
                 '(process IN {"runningboardd", "launchd", "syspolicyd", "tccd", "amfid", "kernel", "ControlCenter", "SystemUIServer"})'
                 f' AND eventMessage CONTAINS[c] "{name}"', timeout=300)
    (check.evidence / 'system.log').write_text(system.stdout[-2_000_000:])
    crashes = []
    for folder in (Path.home() / 'Library/Logs/DiagnosticReports', Path('/Library/Logs/DiagnosticReports')):
        for report_file in folder.glob(f'*{name}*') if folder.exists() else []:
            if report_file.stat().st_mtime >= check.started - 5:
                shutil.copy(report_file, check.evidence / report_file.name)
                crashes.append(report_file.name)
    report['crashReports'] = crashes

    alive = bool(launched.get('pid'))
    icon = bool(launched.get('statusItems'))
    if not alive:
        verdict = 'exited right after opening'
    elif native and not icon:
        verdict = 'running, but no menu-bar icon'
    elif native and not (clicked and panel_visible(clicked)) and not (reopened and panel_visible(reopened)):
        verdict = 'icon present, but the panel never appeared'
    elif not native and not icon and not any_window_visible(launched):
        verdict = 'running, but nothing on screen'
    else:
        verdict = 'ok'
    report['result'] = {'verdict': verdict, 'stayedRunning': alive, 'menuBarIcon': icon,
                        'panelOnClick': None if clicked is None else panel_visible(clicked),
                        'panelOnReopen': None if reopened is None else panel_visible(reopened)}
    (check.evidence / 'report.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(json.dumps(report['result'], sort_keys=True))

    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        r = report['result']
        with open(summary, 'a') as out:
            out.write(f"### {args.tag or app.name} on macOS {report['macos']} ({report['architecture']})\n\n"
                      f"**{verdict}**\n\n| Check | Result |\n|---|---|\n"
                      f"| Gatekeeper (app) | `{report.get('appAssessment', {}).get('output', '-').splitlines()[0] if report.get('appAssessment') else '-'}` |\n"
                      f"| Stayed running | {r['stayedRunning']} |\n| Menu-bar icon | {r['menuBarIcon']} |\n"
                      f"| Panel after icon click | {r['panelOnClick']} |\n| Panel after reopening | {r['panelOnReopen']} |\n"
                      f"| Crash reports | {', '.join(crashes) or 'none'} |\n"
                      f"| Input permissions | {report['access']} |\n\n")
    return 0 if verdict == 'ok' else 1


if __name__ == '__main__':
    sys.exit(main())
