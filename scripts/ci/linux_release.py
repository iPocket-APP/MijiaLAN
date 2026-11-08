#!/usr/bin/env python3
"""Publish an accepted Linux build without recompiling it."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import tomllib

from release import api, digest, git

TEMPLATE_IMAGE = 'mijialan-bridge:candidate'
IMAGE_ARCHIVE = 'mijialan-bridge-amd64.tar.gz'


def identity():
    version = tomllib.loads(Path('Cargo.toml').read_text())['workspace']['package']['version']
    build = os.environ['MIJIALAN_LINUX_BUILD']
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or not re.fullmatch(r'[1-9][0-9]*', build):
        raise ValueError('Invalid version or Linux build number')
    return version, build


def package_names(version, build):
    prefix = f'MijiaLAN-rs-{version}-b{build}-linux-x86_64'
    return [f'{prefix}.deb', f'{prefix}.tar.gz']


def image_config(name):
    info = json.loads(subprocess.check_output(['docker', 'image', 'inspect', name], text=True))[0]
    if (info['Os'], info['Architecture'], info['Config']['User']) != ('linux', 'amd64', '10001:10001'):
        raise ValueError('Unexpected Linux container platform or user')
    if info['Config']['Labels']['org.opencontainers.image.revision'] != git('rev-parse', 'HEAD'):
        raise ValueError('Image was built from another source')
    return info['Id']


def checksum_file(path, files):
    path.write_text(''.join(f'{digest(file)}  {file.name}\n' for file in sorted(files)))


def record(folder):
    version, build = identity()
    log = (folder / 'tests.log').read_text()
    passed = sum(map(int, re.findall(r'test result: ok\. (\d+) passed', log)))
    if not passed or 'test result: FAILED' in log:
        raise ValueError('Missing successful Rust Release tests')
    names = [*package_names(version, build), 'compose.yaml', IMAGE_ARCHIVE]
    files = [folder / name for name in names]
    info = dict(version=version, build=build, source=git('rev-parse', 'HEAD'),
                run=os.environ['GITHUB_RUN_ID'], tests_passed=passed,
                image_id=image_config(TEMPLATE_IMAGE), files={p.name: digest(p) for p in files})
    (folder / 'build-info.json').write_text(json.dumps(info, indent=2) + '\n')
    checksum_file(folder / 'SHA256SUMS.txt', files + [folder / 'build-info.json'])
    print(json.dumps(info, indent=2))


def resolve():
    _, build = identity()
    run_id = os.environ['CANDIDATE_RUN']
    if not run_id.isascii() or not run_id.isdigit():
        raise ValueError('Use the numeric Linux candidate run ID')
    run = api(f'actions/runs/{run_id}')
    if (run['head_sha'] != git('rev-parse', 'HEAD') or run['head_branch'] != 'MijiaLAN-rs'
            or run['head_repository']['full_name'] != os.environ['GITHUB_REPOSITORY']
            or run['path'] != '.github/workflows/linux.yml'
            or run['event'] not in ('push', 'workflow_dispatch') or run['conclusion'] != 'success'):
        raise ValueError('The candidate must be a successful Linux Build on this exact MijiaLAN-rs commit')
    artifacts = api(f'actions/runs/{run_id}/artifacts')['artifacts']
    if not any(a['name'] == f'MijiaLAN-Linux-x86_64-b{build}' and not a['expired'] for a in artifacts):
        raise ValueError('The Linux candidate is missing or expired')
    return run_id


def remote_manifest(image, config_dir):
    return subprocess.run(['docker', '--config', config_dir, 'buildx', 'imagetools', 'inspect', '--raw', image],
                          text=True, capture_output=True)


def publish_image(folder, image, info):
    subprocess.run(['docker', 'load', '-i', str(folder / IMAGE_ARCHIVE)], check=True)
    if image_config(TEMPLATE_IMAGE) != info['image_id']:
        raise ValueError('Loaded image differs from the tested image')
    with tempfile.TemporaryDirectory(prefix='mijialan-ghcr-') as auth:
        subprocess.run(['docker', '--config', auth, 'login', 'ghcr.io', '-u', os.environ['GITHUB_ACTOR'],
                        '--password-stdin'], input=os.environ['GH_TOKEN'], text=True, check=True)
        existing = remote_manifest(image, auth)
        if existing.returncode == 0:
            if json.loads(existing.stdout)['config']['digest'] != info['image_id']:
                raise ValueError('Registry tag already refers to another image')
        else:
            if not any(text in existing.stderr.lower() for text in ('not found', 'manifest unknown')):
                raise RuntimeError(existing.stderr.strip())
            subprocess.run(['docker', 'tag', TEMPLATE_IMAGE, image], check=True)
            subprocess.run(['docker', '--config', auth, 'push', image], check=True)

    with tempfile.TemporaryDirectory(prefix='mijialan-anonymous-') as anonymous:
        result = remote_manifest(image, anonymous)
        if result.returncode:
            raise RuntimeError('Make the GHCR mijialan-bridge package public in Package settings, then rerun publication')
        if json.loads(result.stdout)['config']['digest'] != info['image_id']:
            raise ValueError('Public image config differs from the candidate')
        inspected = subprocess.check_output(['docker', '--config', anonymous, 'buildx', 'imagetools', 'inspect',
                                             '--format', '{{.Manifest.Digest}}', image], text=True).strip()
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', inspected):
            raise ValueError('Could not resolve the public image digest')
        return image.rsplit(':', 1)[0] + '@' + inspected


def release_by_tag(tag):
    page = 1
    while releases := api(f'releases?per_page=100&page={page}'):
        if release := next((release for release in releases if release['tag_name'] == tag), None):
            return release
        page += 1
    return None


def stage(folder, dist, nas=None):
    run_id = resolve()
    version, build = identity()
    source = git('rev-parse', 'HEAD')
    repo = os.environ['GITHUB_REPOSITORY']
    info = json.loads((folder / 'build-info.json').read_text())
    names = package_names(version, build)
    expected = {*names, IMAGE_ARCHIVE, 'compose.yaml'}
    if (info['version'], info['build'], info['source'], info['run']) != (version, build, source, run_id):
        raise ValueError('Candidate provenance does not match the requested release')
    if not info['tests_passed'] or set(info['files']) != expected or any(
            digest(folder / name) != info['files'][name] for name in expected):
        raise ValueError('Missing or invalid Linux candidate assets')


    if nas is not None:
        prefix = f'MijiaLAN-rs-{version}-b{build}'
        spk = f'{prefix}-synology-geminilake-test.spk'
        fpk = f'{prefix}-fnos-x86_64-test.fpk'
        hashes = dict(line.split(maxsplit=1)[::-1]
                      for line in (nas / 'NAS-SHA256SUMS.txt').read_text().splitlines())
        if set(hashes) != {spk, fpk} or any(digest(nas / name) != hashes[name] for name in hashes):
            raise ValueError('Missing or invalid NAS candidate assets')
    dist.mkdir(parents=True, exist_ok=True)
    image = f'ghcr.io/{repo.split("/")[0].lower()}/mijialan-bridge:{version}-rs-linux.{build}'
    pinned = publish_image(folder, image, info)

    for name in names:
        shutil.copyfile(folder / name, dist / name)
    template = (folder / 'compose.yaml').read_text()
    if template.count(f'image: {TEMPLATE_IMAGE}') != 1:
        raise ValueError('Unexpected NAS Compose template')
    (dist / 'compose.yaml').write_text(template.replace(f'image: {TEMPLATE_IMAGE}', f'image: {pinned}'))
    if nas is not None:
        shutil.copyfile(nas / spk, dist / spk)
    return pinned


def publish(folder):
    run_id = resolve()
    version, build = identity()
    source = git('rev-parse', 'HEAD')
    tag = f'rs-linux-v{version}-b{build}'
    repo = os.environ['GITHUB_REPOSITORY']
    release = release_by_tag(tag)
    if release and (not release['draft'] or release['target_commitish'] != source):
        raise ValueError('Release is already public or belongs to another source')
    with tempfile.TemporaryDirectory(prefix='mijialan-linux-release-') as directory:
        dist = Path(directory)
        pinned = stage(folder, dist)
        checksum_file(dist / 'SHA256SUMS.txt', list(dist.iterdir()))
        files = sorted(dist.iterdir())
        hashes = {file.name: 'sha256:' + digest(file) for file in files}

        body = f'''MijiaLAN Linux {version}（构建 {build}）。

- Debian 12 / Ubuntu 24.04 x86_64 桌面版提供 DEB 和便携包。
- 群晖 DS920+ 从 Container Manager 导入 `compose.yaml`，修改 NAS IPv4 后启动。镜像为 `{pinned}`。
- 从 DSM 日志获取一次性设置码，通过浏览器导入米家设备并配对 Apple「家庭」。

[安装和升级说明](https://github.com/{repo}/blob/{source}/docs/linux.md) · [验收所用 CI 产物](https://github.com/{repo}/actions/runs/{run_id})
'''
        if not release:
            release = api('releases', 'POST', dict(tag_name=tag, target_commitish=source,
                          name=f'MijiaLAN {version} · Linux b{build}', body=body,
                          draft=True, prerelease=True, make_latest='false'))
        existing = {asset['name']: asset['digest'] for asset in release['assets']}
        if any(hashes.get(name) != value for name, value in existing.items()):
            raise ValueError('Existing draft assets differ from the candidate')
        for file in files:
            if file.name not in existing:
                subprocess.run(['gh', 'release', 'upload', tag, str(file), '--repo', repo], check=True)
        received = api(f'releases/{release["id"]}')
        if {asset['name']: asset['digest'] for asset in received['assets']} != hashes:
            raise ValueError('GitHub asset digests differ from the Linux manifest')
        result = api(f'releases/{release["id"]}', 'PATCH', dict(draft=False, prerelease=True, make_latest='false'))
        print(result['html_url'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('resolve')
    for command in ['record', 'publish']:
        commands.add_parser(command).add_argument('folder', type=Path)
    staging = commands.add_parser('stage')
    staging.add_argument('folder', type=Path)
    staging.add_argument('dist', type=Path)
    staging.add_argument('--nas', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'resolve':
        print(resolve())
    elif args.command == 'record':
        record(args.folder)
    elif args.command == 'stage':
        print(stage(args.folder, args.dist, args.nas))
    else:
        publish(args.folder)
