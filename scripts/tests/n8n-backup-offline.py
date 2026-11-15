#!/usr/bin/env python3
"""Failure-path tests only; never contacts Docker or host services."""
import importlib.util
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import types
import unittest
import subprocess
from unittest.mock import patch

sys.dont_write_bytecode = True
if sys.platform == 'win32':
    sys.modules.setdefault('fcntl', types.SimpleNamespace())
source = Path(__file__).resolve().parents[1] / 'deploy' / 'backup-n8n.py'
spec = importlib.util.spec_from_file_location('backup_n8n', source)
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


class BackupFailureTests(unittest.TestCase):
    def setUp(self):
        self.items = {name: {'id': name + '-owned', 'data': {'Config': {'Image': 'image-' + name}}}
                      for name in ('n8n', 'runners', 'postgres')}
        self.calls = []

    def command(self, *args, **kwargs):
        self.calls.append(args)
        if args[:2] == ('docker', 'inspect'):
            return json.dumps([{'State': {'Running': False}}])
        return ''

    def snapshot(self, directory):
        return backup.snapshot(self.items, Path(directory) / '_data', Path(directory) / 'release.test',
                               Path(directory), '20261115T000000Z-test')

    def test_dump_failure_restores_both_writers_and_never_stops_postgres(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(backup, 'command', self.command), \
                    patch.object(backup, 'dump_database', side_effect=RuntimeError('synthetic dump failure')), \
                    patch.object(backup, 'recover') as recover:
                with self.assertRaisesRegex(RuntimeError, 'synthetic dump failure'):
                    self.snapshot(directory)
                recover.assert_called_once()
                self.assertEqual(recover.call_args.args[0], self.items)
        self.assertEqual(self.calls[0][:3], ('systemd-run', '--unit', 'homelab-n8n-backup-recover-20261115t000000z-test'))
        stops = [call for call in self.calls if call[:2] == ('docker', 'stop')]
        self.assertEqual([call[-1] for call in stops], ['n8n-owned', 'runners-owned'])
        self.assertTrue(all('postgres-owned' not in call for call in stops))

    def test_guard_failure_prevents_any_service_stop(self):
        def fail_guard(*args, **kwargs):
            self.calls.append(args)
            raise RuntimeError('guard unavailable')
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(backup, 'command', fail_guard), patch.object(backup, 'recover') as recover:
                with self.assertRaisesRegex(RuntimeError, 'guard unavailable'):
                    self.snapshot(directory)
                recover.assert_not_called()
        self.assertEqual(len(self.calls), 1)

    def test_stop_failure_still_attempts_recovery(self):
        def fail_stop(*args, **kwargs):
            self.calls.append(args)
            if args[:2] == ('docker', 'stop'):
                raise RuntimeError('stop failure')
            return ''
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(backup, 'command', fail_stop), patch.object(backup, 'recover') as recover:
                with self.assertRaisesRegex(RuntimeError, 'stop failure'):
                    self.snapshot(directory)
                recover.assert_called_once()

    def test_recovery_requires_both_healthy_before_guard_disarm(self):
        healthy = {'n8n-owned': 'healthy', 'runners-owned': 'unhealthy'}
        def state(*args, **kwargs):
            self.calls.append(args)
            if args[:2] == ('docker', 'inspect'):
                return json.dumps([{'State': {'Running': True, 'Health': {'Status': healthy[args[2]]}}}])
            return ''
        with patch.object(backup, 'command', state), patch.object(backup.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'recovery timed out'):
                backup.recover(self.items, 'guard-test')
        self.assertFalse(any(call[:2] == ('systemctl', 'stop') for call in self.calls))
        self.calls.clear()
        healthy['runners-owned'] = 'healthy'
        with patch.object(backup, 'command', state):
            backup.recover(self.items, 'guard-test')
        self.assertEqual(self.calls[-1], ('systemctl', 'stop', 'guard-test.timer'))

    def test_foreign_container_label_refused_without_mutation(self):
        def foreign(*args, **kwargs):
            self.calls.append(args)
            if args[:3] == ('docker', 'ps', '-aq'):
                return 'foreign-id'
            return json.dumps([{'Config': {'Labels': {'io.homelab.managed': 'other-stack'}},
                                'State': {'Running': True}}])
        with patch.object(backup, 'command', foreign):
            with self.assertRaisesRegex(RuntimeError, 'owned n8n services'):
                backup.containers()
        self.assertTrue(all(call[:2] in (('docker', 'ps'), ('docker', 'inspect')) for call in self.calls))

    def test_incomplete_archive_is_never_published_and_recovers(self):
        def archive_missing_key(*args, **kwargs):
            if args[0] == 'tar':
                with tarfile.open(args[3], 'w:gz') as archive:
                    content = b'PGDMP-fixture'
                    entry = tarfile.TarInfo('database.dump')
                    entry.size = len(content)
                    archive.addfile(entry, io.BytesIO(content))
                return ''
            return self.command(*args, **kwargs)
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(backup, 'command', archive_missing_key), \
                    patch.object(backup, 'dump_database'), patch.object(backup, 'recover') as recover:
                with self.assertRaisesRegex(RuntimeError, 'Incomplete n8n backup'):
                    self.snapshot(directory)
                recover.assert_called_once()
            self.assertEqual(list(Path(directory).glob('*.tar.gz')), [])
            self.assertEqual(list(Path(directory).glob('*.sha256')), [])

    def test_dump_validation_child_inherits_descriptor_at_header(self):
        original_run = subprocess.run
        child_seen = []
        payload = b'PGDMP' + b'x' * 16384
        def real_child(args, **kwargs):
            if 'pg_dump' in args:
                kwargs['stdout'].write(payload)
                return subprocess.CompletedProcess(args, 0)
            self.assertIn('pg_restore', args)
            # A real process reads the inherited OS descriptor; replacing this
            # with stream.read() would hide Python buffered read-ahead bugs.
            result = original_run([sys.executable, '-c',
                                   "import sys; assert sys.stdin.buffer.read(5) == b'PGDMP'"], **kwargs)
            child_seen.append(result.returncode)
            return result
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(backup.subprocess, 'run', real_child):
                backup.dump_database('isolated-fixture', Path(directory) / 'database.dump')
        self.assertEqual(child_seen, [0])


if __name__ == '__main__':
    unittest.main(verbosity=2)
