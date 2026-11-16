import copy
import importlib.util
import io
import json
from pathlib import Path
import struct
import tarfile
import tempfile
import unittest
from unittest.mock import patch

script = Path(__file__).with_name('home-assistant-backup.py')
if not script.is_file():
    script = Path(__file__).resolve().parent.parent/'deploy/home-assistant-backup.py'
spec = importlib.util.spec_from_file_location('ha_backup', script)
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


class Client:
    def __init__(self):
        self.config = {'automatic_backups_configured': False, 'schedule': {'recurrence': 'never'}}
        self.calls = []
        self.timezone = 'Europe/London'
        self.states = [{'state': 'idle', 'backups': []}]

    def command(self, command, **kwargs):
        self.calls.append(command)
        if command == 'get_config':
            return {'time_zone': self.timezone}
        if command == 'backup/agents/info':
            return {'agents': [{'agent_id': backup.AGENT}]}
        if command == 'backup/config/info':
            return {'config': copy.deepcopy(self.config)}
        if command == 'backup/config/update':
            self.config = copy.deepcopy(kwargs)
            self.config['next_automatic_backup'] = '2026-11-16T04:45:00Z'
            return None
        if command == 'backup/info':
            return self.states.pop(0) if len(self.states) > 1 else self.states[0]
        if command == 'backup/generate_with_automatic_settings':
            return {'backup_job_id': 'a' * 32}
        raise AssertionError(command)


def make_archive(path, *, encrypted=True, missing=False, unsafe=False, protected=True,
                 wrong_id=False, folders=None, supervisor=True):
    folders = list(backup.FOLDERS if folders is None else folders)
    metadata = {'slug': 'sample1' if not wrong_id else 'wrong', 'type': 'partial',
                'protected': protected, 'compressed': True,
                'homeassistant': {'version': '2026.11.1', 'exclude_database': False},
                'folders': folders, 'addons': []}
    with tarfile.open(path, 'w') as archive:
        parts = {'./backup.json': json.dumps(metadata).encode()}
        names = ['homeassistant'] + [folder.replace('/', '_') for folder in folders]
        if supervisor:
            names.append('supervisor')
        if missing:
            names.remove('homeassistant')
        for name in names:
            # Structural fixtures are intentionally not cryptographic restore tests.
            header = struct.pack('!9sB6sQ8x', b'SecureTar', 3, b'\x00'*6, 100)
            parts[f'./{name}.tar.gz'] = header + b'x'*200 if encrypted else b'plaintext'*30
        if unsafe:
            parts['../escape'] = b'x'
        for name, data in parts.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.private = self.root / 'private'
        self.private.mkdir()
        self.client = Client()
        # Production ownership is validated on root Linux; Windows fixtures
        # intentionally cover logic without pretending to prove root ownership.
        self.guard = patch.object(backup, 'private_path')
        self.guard.start()

    def tearDown(self):
        self.guard.stop()
        self.temp.cleanup()

    def test_configure_repeat_preserves_password(self):
        first = backup.configure(self.client, self.private)
        password = (self.private/'backup-password').read_text()
        second = backup.configure(self.client, self.private)
        self.assertTrue(first['changed'])
        self.assertFalse(second['changed'])
        self.assertEqual(password, (self.private/'backup-password').read_text())
        self.assertNotIn(password.strip(), json.dumps(first))
        self.assertEqual(self.client.config['retention'], {'copies': None, 'days': None})
        self.assertEqual(self.client.calls.count('backup/config/update'), 1)

    def test_configure_refuses_policy_drift(self):
        backup.configure(self.client, self.private)
        self.client.config['schedule']['time'] = '06:00:00'
        with self.assertRaisesRegex(RuntimeError, 'changed'):
            backup.configure(self.client, self.private)
        self.assertEqual(self.client.calls.count('backup/config/update'), 1)

    def test_configure_refuses_unknown_existing_policy(self):
        self.client.config['automatic_backups_configured'] = True
        with self.assertRaisesRegex(RuntimeError, 'not managed'):
            backup.configure(self.client, self.private)
        self.assertNotIn('backup/config/update', self.client.calls)

    def test_configure_refuses_wrong_timezone(self):
        self.client.timezone = 'UTC'
        with self.assertRaisesRegex(RuntimeError, 'timezone'):
            backup.configure(self.client, self.private)
        self.assertNotIn('backup/config/update', self.client.calls)

    def test_archive_structural_encryption_and_no_restore_claim(self):
        path = self.root/'backup.tar'
        make_archive(path)
        result = backup.inspect_archive(path, 'sample1')
        self.assertEqual(result['components'], 6)
        self.assertTrue(result['encrypted'])
        self.assertFalse(result['decryption_tested'])
        self.assertFalse(result['restore_tested'])
        self.assertEqual(len(result['sha256']), 64)

    def test_archive_rejects_plaintext_and_unprotected(self):
        for kwargs in ({'encrypted': False}, {'protected': False}):
            path = self.root/'bad.tar'
            make_archive(path, **kwargs)
            with self.assertRaises(RuntimeError):
                backup.inspect_archive(path)

    def test_archive_rejects_missing_wrong_identity_unsafe(self):
        for kwargs in ({'missing': True}, {'wrong_id': True}, {'unsafe': True}):
            path = self.root/'bad.tar'
            make_archive(path, **kwargs)
            with self.assertRaises(RuntimeError):
                backup.inspect_archive(path, 'sample1')

    def test_current_supervisor_folder_alias_and_optional_configuration(self):
        path = self.root/'current.tar'
        folders = ['share', 'ssl', 'media', 'apps/local']
        make_archive(path, folders=folders, supervisor=False)
        result = backup.inspect_archive(path, 'sample1')
        self.assertEqual(result['components'], 5)
        self.assertFalse(result['supervisor_configuration_included'])
        with self.assertRaisesRegex(RuntimeError, 'Supervisor configuration'):
            backup.inspect_archive(path, 'sample1', require_supervisor=True)
        make_archive(path, folders=folders, supervisor=True)
        self.assertTrue(backup.inspect_archive(path, require_supervisor=True)
                        ['supervisor_configuration_included'])

    def test_alias_support_does_not_accept_omitted_or_duplicate_folders(self):
        for folders in (['share', 'ssl', 'apps/local'],
                        ['share', 'ssl', 'media'],
                        ['share', 'ssl', 'media', 'addons/local', 'apps/local']):
            path = self.root/'bad-folders.tar'
            make_archive(path, folders=folders, supervisor=False)
            with self.assertRaises(RuntimeError):
                backup.inspect_archive(path)

    def test_native_metadata_accepts_only_documented_alias(self):
        metadata = {'backup_id': 'sample1', 'homeassistant_included': True,
            'database_included': True, 'folders': ['share', 'ssl', 'media', 'apps/local'],
            'agents': {backup.AGENT: {'protected': True, 'size': 12345}}}
        self.assertEqual(backup.validate_backup_metadata(metadata), 'sample1')
        metadata['folders'] = ['share', 'ssl', 'media', 'unknown/local']
        with self.assertRaises(RuntimeError):
            backup.validate_backup_metadata(metadata)

    def test_metadata_rejects_failed_parts(self):
        metadata = {'backup_id': 'sample1', 'homeassistant_included': True,
            'database_included': True, 'folders': backup.FOLDERS,
            'agents': {backup.AGENT: {'protected': True, 'size': 12345}},
            'failed_folders': ['share']}
        with self.assertRaisesRegex(RuntimeError, 'incomplete'):
            backup.validate_backup_metadata(metadata)
        metadata['failed_folders'] = []
        self.assertEqual(backup.validate_backup_metadata(metadata), 'sample1')

    def test_creation_does_not_export_failed_job(self):
        backup.configure(self.client, self.private)
        self.client.states = [{'state': 'idle', 'backups': []},
            {'state': 'idle', 'backups': [], 'last_action_event': {'state': 'failed'}}]
        with self.assertRaisesRegex(RuntimeError, 'did not complete'):
            backup.create(self.client, self.private, self.root/'backups', pause=lambda _: None)

    def test_creation_does_not_export_ambiguous_job(self):
        backup.configure(self.client, self.private)
        self.client.states = [{'state': 'idle', 'backups': []},
            {'state': 'idle', 'backups': [{'backup_id': 'a'}, {'backup_id': 'b'}],
             'last_action_event': {'state': 'completed'}}]
        with self.assertRaisesRegex(RuntimeError, 'ambiguous'):
            backup.create(self.client, self.private, self.root/'backups', pause=lambda _: None)

    def test_creation_exports_only_completed_encrypted_archive(self):
        backup.configure(self.client, self.private)
        source = self.root/'source.tar'
        make_archive(source)
        metadata = {'backup_id': 'sample1', 'homeassistant_included': True,
            'database_included': True, 'folders': backup.FOLDERS,
            'agents': {backup.AGENT: {'protected': True, 'size': source.stat().st_size}}}
        self.client.states = [{'state': 'idle', 'backups': []},
            {'state': 'create_backup', 'backups': []},
            {'state': 'idle', 'backups': [metadata],
             'last_action_event': {'state': 'completed'}}]

        def download(path, target, max_bytes):
            self.assertEqual(path, '/api/backup/download/sample1?agent_id=hassio.local')
            self.assertNotIn('password', path)
            target.write_bytes(source.read_bytes())
            return backup.inspect_archive(target)

        self.client.download = download
        result = backup.create(self.client, self.private, self.root/'backups', pause=lambda _: None)
        self.assertTrue(result['native_completion'])
        self.assertTrue((self.root/'backups/home-assistant-sample1.tar.sha256').is_file())
        self.assertFalse(result['restore_tested'])

    def test_creation_timeout_never_downloads(self):
        backup.configure(self.client, self.private)
        timer = iter([0, 2])
        with self.assertRaisesRegex(RuntimeError, 'Timed out'):
            backup.create(self.client, self.private, self.root/'backups', timeout=1,
                          pause=lambda _: None, clock=lambda: next(timer))


if __name__ == '__main__':
    unittest.main()
