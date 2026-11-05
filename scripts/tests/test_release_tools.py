import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'ci'))
import notarize
import release_metadata
import ci_artifact
import find_ci_artifact


class ReleaseMetadataTests(unittest.TestCase):
    def test_invalid_release_versions_and_builds_are_rejected(self):
        for version, build in [('1.2', 1), ('1.2.3\ninjected=value', 1), ('1.2.3', 0), ('1.2.3', True)]:
            with self.subTest(version=version, build=build), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'release.json').write_text(json.dumps({'version': version, 'build_number': build}))
                with patch.object(release_metadata, 'ROOT', root), self.assertRaises(ValueError):
                    release_metadata.metadata()

    def test_a_different_tag_cannot_publish_the_current_version(self):
        data = release_metadata.metadata()
        argv = ['release_metadata.py', '--tag', 'rs-v' + data['version']]
        with patch.object(sys, 'argv', argv), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            release_metadata.main()
        self.assertEqual(error.exception.code, 2)


class NotarizationTests(unittest.TestCase):
    def check_submission(self, status, exit_code, accepted):
        with tempfile.TemporaryDirectory() as directory:
            prefix = Path(directory) / 'app-notary'
            identifier = '00000000-0000-0000-0000-000000000001'
            def command(args, **kwargs):
                if args[2] == 'submit':
                    kwargs['stdout'].write(json.dumps({'id': identifier, 'status': status}))
                    return notarize.subprocess.CompletedProcess(args, exit_code)
                self.assertEqual(args[2], 'log')
                self.assertEqual(args[3], identifier)
                Path(args[4]).write_text(json.dumps({'status': status, 'issues': []}))
                return notarize.subprocess.CompletedProcess(args, 0)
            argv = ['notarize.py', str(Path(directory) / 'app.zip'), '--profile', 'test-only', '--log-prefix', str(prefix)]
            with patch.object(sys, 'argv', argv), patch.object(notarize.subprocess, 'run', side_effect=command):
                if accepted:
                    notarize.main()
                else:
                    with self.assertRaises(SystemExit):
                        notarize.main()
            self.assertEqual(json.loads(Path(str(prefix) + '.json').read_text())['id'], identifier)
            self.assertTrue(Path(str(prefix) + '-details.json').is_file())

    def test_accepted_submission_succeeds(self):
        self.check_submission('Accepted', 0, True)

    def test_rejected_status_fails_even_when_the_command_exits_successfully(self):
        self.check_submission('Invalid', 0, False)

    def test_timed_out_submission_keeps_the_id_and_fails(self):
        self.check_submission('In Progress', 1, False)


class ArtifactPromotionTests(unittest.TestCase):
    def prepare(self, directory):
        data = release_metadata.metadata()
        paths = [directory / f"MijiaLAN-{data['version']}-universal.zip", directory / 'symbols.tar.gz']
        for path in paths:
            path.write_bytes(b'test-build-payload')
        record = {**data, 'source_commit': 'a' * 40, 'run_id': '42',
                  'files': {p.name: ci_artifact.sha256(p) for p in paths}}
        (directory / 'provenance.json').write_text(json.dumps(record))
        return record, paths

    def test_matching_commit_run_and_payload_are_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record, _ = self.prepare(root)
            self.assertEqual(ci_artifact.validate(root, 'a' * 40, '42'), record)

    def test_another_commit_or_run_cannot_be_promoted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.prepare(root)
            for commit, run_id in [('b' * 40, '42'), ('a' * 40, '43')]:
                with self.subTest(commit=commit, run_id=run_id), self.assertRaises(AssertionError):
                    ci_artifact.validate(root, commit, run_id)

    def test_modified_payload_cannot_be_promoted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, paths = self.prepare(root)
            paths[0].write_bytes(b'changed')
            with self.assertRaises(AssertionError):
                ci_artifact.validate(root, 'a' * 40, '42')

    def test_forks_pull_requests_and_other_refs_are_not_release_inputs(self):
        repository, commit = 'iPocket-APP/MijiaLAN', 'a' * 40
        base = {'head_sha': commit, 'head_branch': 'main', 'event': 'push', 'head_repository': {'full_name': repository}}
        self.assertTrue(find_ci_artifact.trusted(base, repository, commit))
        for change in [{'event': 'pull_request'}, {'head_branch': 'feature'}, {'head_sha': 'b' * 40},
                       {'head_repository': None}, {'head_repository': {'full_name': 'fork/MijiaLAN'}}]:
            with self.subTest(change=change):
                self.assertFalse(find_ci_artifact.trusted({**base, **change}, repository, commit))


if __name__ == '__main__':
    unittest.main()
