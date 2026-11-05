#!/usr/bin/env python3
"""Find a successful native main-branch build for the exact release commit."""

import argparse
import json
import os
import subprocess
import time
import urllib.parse
import urllib.request
from pathlib import Path


def trusted(run, repository, commit):
    return (run['head_sha'] == commit and run['head_branch'] == 'main'
            and run['event'] in ('push', 'workflow_dispatch')
            and (run.get('head_repository') or {}).get('full_name') == repository)


def request(path):
    url = 'https://api.github.com/repos/' + os.environ['GITHUB_REPOSITORY'] + '/' + path
    headers = {'Authorization': 'Bearer ' + os.environ['GH_TOKEN'], 'Accept': 'application/vnd.github+json'}
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--github-output', required=True, type=Path)
    args = parser.parse_args()
    repository = os.environ['GITHUB_REPOSITORY']
    # Normalize annotated tags to the checked-out commit before looking up CI.
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    started, deadline = time.monotonic(), time.monotonic() + 1800
    while True:
        query = urllib.parse.urlencode({'head_sha': commit, 'per_page': 20})
        runs = request('actions/workflows/native-ci.yml/runs?' + query)['workflow_runs']
        runs = [run for run in runs if trusted(run, repository, commit)]
        for run in runs:
            if run['conclusion'] != 'success':
                continue
            artifacts = request(f"actions/runs/{run['id']}/artifacts?per_page=100")['artifacts']
            artifact = next((a for a in artifacts if a['name'] == 'native-ci-universal' and not a['expired']), None)
            if artifact:
                with args.github_output.open('a') as stream:
                    stream.write(f"run_id={run['id']}\nartifact_id={artifact['id']}\n")
                print('Reusing validated build:', run['html_url'], flush=True)
                return
        pending = next((run for run in runs if run['status'] != 'completed'), None)
        if pending:
            if time.monotonic() >= deadline:
                raise SystemExit('Timed out waiting for native CI: ' + pending['html_url'])
            print('Waiting for the existing native CI build:', pending['html_url'], flush=True)
            time.sleep(15)
            continue
        if runs and runs[0]['conclusion'] not in ('success', 'cancelled', 'skipped'):
            raise SystemExit('Native CI failed; fix it before release: ' + runs[0]['html_url'])
        if not runs and time.monotonic() - started < 30:
            time.sleep(5)
            continue
        print('No reusable CI artifact; build once in this release workflow.', flush=True)
        return


if __name__ == '__main__':
    main()
