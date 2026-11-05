#!/usr/bin/env python3
"""Resolve trusted CI packages and publish their signed distribution without rebuilding."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import tomllib
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import updates

from build_artifact import digest, verify


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def api(path, method='GET', body=None):
    args = ['gh', 'api', '--method', method, f'repos/{os.environ["GITHUB_REPOSITORY"]}/{path}']
    if body is not None:
        args += ['--input', '-']
    result = subprocess.run(args, input=json.dumps(body) if body is not None else None,
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout) if result.stdout.strip() else None


def source_plan(ref, build):
    if ref and not re.fullmatch(r'rs-v[0-9]+\.[0-9]+\.[0-9]+-b[1-9][0-9]*', ref):
        raise ValueError('Use an rs-vVERSION-bBUILD tag or an empty source_ref')
    sha = git('rev-parse', '--verify', (ref or os.environ['GITHUB_SHA']) + '^{commit}')
    subprocess.run(['git', 'merge-base', '--is-ancestor', sha, 'origin/MijiaLAN-rs'], check=True)
    version = tomllib.loads(git('show', f'{sha}:Cargo.toml'))['workspace']['package']['version']
    if ref:
        match = re.fullmatch(r'rs-v([0-9]+\.[0-9]+\.[0-9]+)-b([1-9][0-9]*)', ref)
        if match[1] != version:
            raise ValueError('Release tag and Cargo version differ')
        if build and str(build) != match[2]:
            raise ValueError('Build input and release tag differ')
        build = match[2]
    if not re.fullmatch(r'[1-9][0-9]*', str(build)):
        raise ValueError('A positive build_number is required')
    updates.build_number(build)
    return dict(source_sha=sha, version=version, build_number=str(build), tag=f'rs-v{version}-b{build}')


def ready(run, source):
    return (run.get('head_sha') == source and run.get('head_branch') == 'MijiaLAN-rs'
            and run.get('event') in ['push', 'workflow_dispatch']
            and run.get('head_repository', {}).get('full_name') == os.environ['GITHUB_REPOSITORY'])


def resolve(args):
    result = source_plan(args.ref, args.build)
    deadline = time.monotonic() + args.wait
    missing = time.monotonic() + 90
    chosen = None
    while time.monotonic() < deadline:
        runs = api(f'actions/workflows/ci.yml/runs?head_sha={result["source_sha"]}&branch=MijiaLAN-rs&per_page=30')['workflow_runs']
        candidates = [r for r in runs if ready(r, result['source_sha']) and (not args.run or r['id'] == args.run)
                      and (args.run or r.get('display_title', '').startswith(('Build · all ·', 'Build · release ·')))]
        for run in candidates[:1]:
            jobs = api(f'actions/runs/{run["id"]}/jobs?per_page=100')['jobs']
            required = [next((j for j in jobs if j['name'] == name), None)
                        for name in ['Windows (x86_64)', 'macOS (arm64)', 'macOS (x86_64)']]
            if all(j and j['conclusion'] == 'success' for j in required):
                chosen = run['id']
                break
            if any(j and j['conclusion'] in ['failure', 'timed_out'] for j in required):
                raise ValueError(f'CI package validation failed in run {run["id"]}; fix or rerun Build first')
        if chosen:
            break
        if not candidates and time.monotonic() > missing:
            raise ValueError('No trusted Build run for this commit. Run Build on MijiaLAN-rs, then rerun this release')
        print('Waiting for verified Windows x64 and native macOS arm64 packages...', flush=True)
        time.sleep(20)
    if not chosen:
        raise TimeoutError('Timed out waiting for CI packages')
    artifacts = api(f'actions/runs/{chosen}/artifacts?per_page=100')['artifacts']
    names = {a['name'] for a in artifacts if not a['expired']}
    if not {'MijiaLAN-Rust-Windows-x86_64', 'MijiaLAN-Rust-macOS-arm64'} <= names:
        raise ValueError('Required CI artifacts are missing or expired')
    result['run_id'] = str(chosen)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as f:
        for key, value in result.items(): f.write(f'{key}={value}\n')
    print(json.dumps(result, indent=2))


def collect(args):
    repository = os.environ['GITHUB_REPOSITORY']
    info, archive = verify(args.windows, args.source, 'x86_64-pc-windows-msvc', repository)
    args.dist.mkdir(parents=True, exist_ok=True)
    name = f'MijiaLAN-rs-{args.version}-b{args.build}'
    portable = args.dist / f'{name}-windows-x86_64.zip'
    updates.repackage_windows(archive, portable, args.version, args.build)
    subprocess.run(['bash', 'scripts/package-windows-msi.sh', str(portable)], check=True)
    portable.with_suffix('.sha256').unlink()
    for arch in ['arm64', 'x86_64']:
        source = args.mac / arch
        mac_hashes = dict(line.split(maxsplit=1)[::-1] for line in (source / 'SHA256SUMS.txt').read_text().splitlines())
        for suffix in ['dmg', 'zip']:
            file = source / f'{name}-macos-{arch}.{suffix}'
            if not file.is_file() or mac_hashes.get(file.name) != digest(file):
                raise ValueError('Signed Mac package is missing or checksum mismatch')
            shutil.copyfile(file, args.dist / file.name)
    updates.prepare_feeds(args.dist, args.version, args.build)
    files = sorted(p for p in args.dist.iterdir() if p.name != 'SHA256SUMS.txt')
    (args.dist / 'SHA256SUMS.txt').write_text(''.join(f'{digest(p)}  {p.name}\n' for p in files))
    print('Prepared verified macOS and Windows distribution files')
    return info


def publish(args):
    tag = f'rs-v{args.version}-b{args.build}'
    releases = api('releases?per_page=100')
    previous = next((r for r in releases if r['tag_name'] == tag), None)
    if previous and (not previous['draft'] or previous['target_commitish'] != args.source):
        raise ValueError('Release is already public or uses another source; use a new build number')
    files = sorted(p for p in args.dist.iterdir() if p.is_file())
    expected = {p.name: 'sha256:' + digest(p) for p in files}
    name = f'MijiaLAN-rs-{args.version}-b{args.build}'
    required = {f'{name}-macos-{arch}.{extension}' for arch in ['arm64', 'x86_64'] for extension in ['zip', 'dmg']}
    required |= {f'{name}-windows-x86_64.{ext}' for ext in ['zip', 'msi']}
    required |= {'rust-update-feeds.zip', 'rust-update-feeds.zip.sig', 'SHA256SUMS.txt'}
    if set(expected) != required:
        raise ValueError('Expected both Mac architectures, Windows ZIP/MSI, signed feeds and checksum manifest')
    updates.build_number(args.build)
    # The shared publisher is main-only: retain the existing Pages environment's branch restrictions.
    site_config = api('contents/update-site.json?ref=main')
    import base64
    deployed_keys = json.loads(base64.b64decode(site_config['content']))
    if deployed_keys['rust_public_key'] != updates.configuration()['public_key']:
        raise ValueError('Merge the shared update publisher and matching Rust public key into main before publishing')
    api('contents/.github/workflows/shared-update-site.yml?ref=main')
    for item in releases:
        match = re.fullmatch(r'rs-v[0-9]+\.[0-9]+\.[0-9]+-b([1-9][0-9]*)', item['tag_name'])
        if match and not item['draft'] and int(match[1]) >= int(args.build):
            raise ValueError('Rust update builds must increase monotonically across all versions')
    body = f'''MijiaLAN Rust 体验版 {args.version}（构建 {args.build}）。\n\n源码：`{args.source}`，CI 构建：[Build run {args.run}](https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{args.run})。发布复用该次已验证的 Release 程序，无需重新编译。\n\n- macOS Apple Silicon / Intel：分别提供 DMG / ZIP，内置 Sparkle 自动更新。Developer ID 签名、Hardened Runtime，App 和 DMG 均完成 Apple 公证及票据验证。\n- Windows x64：推荐 MSI 安装包，内置 WinSparkle 自动更新；便携 ZIP 保留为手动更新方式。未做 Authenticode 签名；需要 [Microsoft Visual C++ v14 x64 运行库](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist/)。\n- 校验值见 `SHA256SUMS.txt`。现有 Rust 配置及桥身份继续沿用，Swift 版与 Rust 版数据独立。\n\n构建经过格式、Clippy、Release 测试和包内 CLI 验证；具体支持范围及实机边界见[项目说明](https://github.com/{os.environ['GITHUB_REPOSITORY']}/tree/{args.source})。\n'''
    release = previous or api('releases', 'POST', dict(tag_name=tag, target_commitish=args.source, name=f'MijiaLAN {args.version}-rs.{args.build} · Rust 体验版', body=body, draft=True, prerelease=True, make_latest='false'))
    existing = {a['name']: a['digest'] for a in release['assets']}
    for p in files:
        if p.name in existing:
            if existing[p.name] != expected[p.name]:
                raise ValueError('Draft asset bytes differ; use a new build number or inspect the retained draft')
            continue
        subprocess.run(['gh', 'release', 'upload', tag, str(p), '--repo', os.environ['GITHUB_REPOSITORY']], check=True)
    uploaded = api(f'releases/{release["id"]}')
    if {a['name']: a['digest'] for a in uploaded['assets']} != expected:
        raise ValueError('Release upload checksum mismatch; draft retained for inspection')
    result = api(f'releases/{release["id"]}', 'PATCH', dict(body=body, draft=False, prerelease=True, make_latest='false'))
    print(result['html_url'])


def refresh_site(args):
    if not re.fullmatch(r'rs-v[0-9]+\.[0-9]+\.[0-9]+-b[1-9][0-9]*', args.tag):
        raise ValueError('Expected a Rust release tag')
    workflow = 'actions/workflows/shared-update-site.yml'
    before = {run['id'] for run in api(workflow + '/runs?event=workflow_dispatch&branch=main&per_page=30')['workflow_runs']}
    api(workflow + '/dispatches', 'POST', dict(ref='main', inputs=dict(source_release=args.tag)))
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline:
        runs = api(workflow + '/runs?event=workflow_dispatch&branch=main&per_page=30')['workflow_runs']
        run = next((r for r in runs if r['id'] not in before and r['display_title'] == 'Refresh update feeds · ' + args.tag), None)
        if run and run['status'] == 'completed':
            if run['conclusion'] != 'success':
                raise ValueError('Release is public but update-site deployment needs recovery: ' + run['html_url'])
            print('Shared native/Rust feeds deployed and publicly verified: ' + run['html_url'])
            return
        time.sleep(10)
    raise ValueError('Timed out waiting for shared update-site deployment; release remains public')


if __name__ == '__main__':
    p = argparse.ArgumentParser(); sub = p.add_subparsers(dest='command', required=True)
    r = sub.add_parser('resolve'); r.add_argument('--ref', default=''); r.add_argument('--build', default=''); r.add_argument('--run', type=int, default=0); r.add_argument('--wait', type=int, default=3600)
    r = sub.add_parser('refresh-site'); r.add_argument('--tag', required=True)
    for cmd in ['collect', 'publish']:
        r = sub.add_parser(cmd)
        r.add_argument('--source', required=True); r.add_argument('--version', required=True); r.add_argument('--build', required=True); r.add_argument('--dist', type=Path, default=Path('distribution'))
        if cmd == 'collect': r.add_argument('--windows', type=Path, required=True); r.add_argument('--mac', type=Path, required=True)
        else: r.add_argument('--run', required=True)
    args = p.parse_args()
    {'resolve': resolve, 'collect': collect, 'publish': publish, 'refresh-site': refresh_site}[args.command](args)
