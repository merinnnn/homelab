#!/usr/bin/env python3
"""Configure native encrypted HA backups; export without printing private data.

Run beside home-assistant-runtime.py on the owning Proxmox node. No retention
deletion, restore, device actions, or remote message delivery is implemented.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shutil
import stat
import struct
import tarfile
import time

PRIVATE = Path('/etc/homelab/home-assistant')
BACKUPS = Path('/var/backups/homelab-home-assistant')
AGENT = 'hassio.local'
FOLDERS = ['share', 'ssl', 'media', 'addons/local']
DESIRED = {
    'automatic_backups_configured': True,
    'agents': {AGENT: {'protected': True, 'retention': None}},
    'create_backup': {
        'agent_ids': [AGENT], 'include_all_addons': True,
        'include_addons': None, 'include_database': True,
        'include_folders': FOLDERS, 'name': 'Homelab Home Assistant',
    },
    'retention': {'copies': None, 'days': None},
    'schedule': {'recurrence': 'daily', 'time': '04:45:00', 'days': []},
}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def required_folders(folders):
    """Normalize only Supervisor's documented local-app folder rename.

    Core's v1 API exposes addons/local; raw current Supervisor archives contain
    apps/local. Empty existing folders are archived, so missing parts still fail.
    """
    require(isinstance(folders, list) and all(isinstance(folder, str) for folder in folders),
            'Invalid native backup folder metadata')
    normalized = ['addons/local' if folder == 'apps/local' else folder for folder in folders]
    require(len(normalized) == len(set(normalized)), 'Duplicate native backup folder aliases')
    require(set(normalized) == set(FOLDERS), 'Native backup lacks required folders or contains unknown folders')
    return normalized


def private_path(path, directory=False):
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode),
            'Private path has an unexpected type')
    require(info.st_uid == 0 and stat.S_IMODE(info.st_mode) == (0o700 if directory else 0o600),
            'Private path must have root-only ownership and mode')


def private_write(path, value):
    with open(path, 'x', encoding='utf-8', opener=lambda p, f: os.open(p, f, 0o600)) as out:
        out.write(value)
        out.flush()
        os.fsync(out.fileno())


def canonical(config, password):
    return {**DESIRED, 'create_backup': {**DESIRED['create_backup'], 'password': password}}


def config_matches(actual, expected):
    """Ignore server computed timestamps, refuse changes in owned settings."""
    for key in ('automatic_backups_configured', 'retention', 'schedule', 'create_backup'):
        if actual.get(key) != expected[key]:
            return False
    return actual.get('agents', {}).get(AGENT) == expected['agents'][AGENT]


def marker_value(password):
    return {'version': 1, 'config': DESIRED,
            'password_sha256': hashlib.sha256(password.encode()).hexdigest()}


def load_password(private_dir):
    path = private_dir / 'backup-password'
    private_path(path)
    password = path.read_text(encoding='utf-8').strip()
    require(len(password) >= 32 and '\n' not in password, 'Invalid private recovery password')
    return password


def verify_configuration(client, password):
    current = client.command('backup/config/info')['config']
    require(config_matches(current, canonical(current, password)),
            'Native backup configuration changed; preserve it for review')
    require(current.get('next_automatic_backup'), 'Native daily backup has no next run')
    return current


def configure(client, private_dir):
    private_path(private_dir, directory=True)
    require(client.command('get_config').get('time_zone') == 'Europe/London',
            'Set Home Assistant timezone before configuring backup')
    agents = client.command('backup/agents/info')['agents']
    require(any(a.get('agent_id') == AGENT for a in agents), 'HAOS local backup agent unavailable')
    current = client.command('backup/config/info')['config']
    marker = private_dir / 'backup-managed.json'
    password_file = private_dir / 'backup-password'
    if marker.exists() or marker.is_symlink():
        private_path(marker)
        password = load_password(private_dir)
        require(json.loads(marker.read_text(encoding='utf-8')) == marker_value(password),
                'Native backup provenance changed; preserve private state')
        verify_configuration(client, password)
        return {'configured': True, 'changed': False, 'daily_local_time': '04:45',
                'timezone': 'Europe/London', 'encrypted': True, 'automatic_deletion': False}
    require(not current.get('automatic_backups_configured') and
            current.get('schedule', {}).get('recurrence', 'never') == 'never',
            'Existing native backup policy is not managed; preserve it for review')
    if not password_file.exists() and not password_file.is_symlink():
        private_write(password_file, secrets.token_urlsafe(48) + '\n')
    password = load_password(private_dir)
    client.command('backup/config/update', **canonical(current, password))
    verify_configuration(client, password)
    private_write(marker, json.dumps(marker_value(password), sort_keys=True) + '\n')
    return {'configured': True, 'changed': True, 'daily_local_time': '04:45',
            'timezone': 'Europe/London', 'encrypted': True, 'automatic_deletion': False}


def validate_backup_metadata(backup):
    backup_id = backup.get('backup_id', '')
    require(isinstance(backup_id, str) and re.fullmatch(r'[a-zA-Z0-9_-]{1,128}', backup_id),
            'Invalid native backup identifier')
    require(backup.get('homeassistant_included') is True and backup.get('database_included') is True,
            'Native backup lacks Home Assistant or database')
    required_folders(backup.get('folders', []))
    require(all(not backup.get(key) for key in ('failed_addons', 'failed_folders', 'failed_agent_ids')),
            'Native backup reported incomplete parts')
    agent = backup.get('agents', {}).get(AGENT, {})
    require(agent.get('protected') is True and isinstance(agent.get('size'), int) and agent['size'] > 0,
            'Native local backup is not encrypted or is empty')
    return backup_id


def inspect_archive(path, expected_id=None, require_supervisor=False):
    """Validate safe outer tar and encryption headers, without extracting data.

    This is structural evidence, not proof of successful decryption or restore.
    Only metadata counts and SHA256 leave this function.
    """
    members = {}
    with tarfile.open(path, 'r:') as archive:
        for member in archive:
            name = member.name.removeprefix('./')
            require(member.isfile() and name == PurePosixPath(name).name and '\\' not in name
                    and name not in ('', '.', '..') and name not in members,
                    'Archive contains an unsafe or duplicate member')
            require(name == 'backup.json' or re.fullmatch(r'[a-zA-Z0-9_-]+\.tar(?:\.gz)?', name),
                    'Archive contains an unexpected member')
            members[name] = member
            require(len(members) <= 10000, 'Archive member count exceeded limit')
        require('backup.json' in members and members['backup.json'].size <= 1024 * 1024,
                'Archive has no bounded backup metadata')
        with archive.extractfile(members['backup.json']) as stream:
            metadata = json.load(stream)
        require(metadata.get('protected') is True and metadata.get('compressed') is True,
                'Archive is not a protected compressed backup')
        require(metadata.get('type') in ('full', 'partial'), 'Unexpected native backup type')
        require(expected_id is None or metadata.get('slug') == expected_id, 'Wrong native backup archive')
        home = metadata.get('homeassistant')
        require(isinstance(home, dict) and home.get('exclude_database') is False,
                'Archive omits Home Assistant database')
        required_folders(metadata.get('folders', []))
        expected = {'backup.json', 'homeassistant.tar.gz'}
        expected.update(f"{folder.replace('/', '_')}.tar.gz" for folder in metadata['folders'])
        expected.update(f"{addon['slug']}.tar.gz" for addon in metadata.get('addons', []))
        # Stable Supervisor intentionally omits this component if neither
        # network mounts nor private Docker registries are configured.
        supervisor_included = 'supervisor.tar.gz' in members
        require(not require_supervisor or supervisor_included,
                'Archive omits required Supervisor configuration')
        if supervisor_included:
            expected.add('supervisor.tar.gz')
        require(set(members) == expected, 'Archive components disagree with metadata')
        versions = set()
        for name, member in members.items():
            if name == 'backup.json':
                continue
            with archive.extractfile(member) as stream:
                header = stream.read(32)
            require(len(header) == 32 and header[:9] == b'SecureTar' and
                    header[9] in (2, 3) and header[10:16] == b'\x00' * 6,
                    'Archive component lacks a supported encryption header')
            size = struct.unpack('!Q', header[16:24])[0]
            require(size > 0 and member.size > (136 if header[9] == 3 else 48),
                    'Truncated encrypted archive component')
            versions.add(header[9])
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {'bytes': path.stat().st_size, 'sha256': digest, 'components': len(members)-1,
            'encrypted': True, 'cipher_header_versions': sorted(versions),
            'supervisor_configuration_included': supervisor_included,
            'homeassistant_and_database': True, 'structural_validation': True,
            'decryption_tested': False, 'restore_tested': False}


def create(client, private_dir, backup_dir, timeout=1800, pause=time.sleep, clock=time.monotonic,
           require_supervisor=False):
    private_path(private_dir, directory=True)
    password = load_password(private_dir)
    private_path(private_dir / 'backup-managed.json')
    require(json.loads((private_dir / 'backup-managed.json').read_text(encoding='utf-8')) ==
            marker_value(password), 'Native backup provenance changed')
    verify_configuration(client, password)
    if not backup_dir.exists():
        backup_dir.mkdir(mode=0o700)
    private_path(backup_dir, directory=True)
    before = client.command('backup/info')
    require(before.get('state') == 'idle' and not before.get('agent_errors'),
            'Native backup manager is busy or unavailable')
    before_ids = {b['backup_id'] for b in before.get('backups', [])}
    accepted = client.command('backup/generate_with_automatic_settings')
    require(isinstance(accepted.get('backup_job_id'), str), 'Native backup was not accepted')
    deadline = clock() + timeout
    selected = None
    while clock() < deadline:
        status = client.command('backup/info')
        if status.get('state') == 'idle':
            require(status.get('last_action_event', {}).get('state') == 'completed',
                    'Native backup did not complete successfully')
            require(not status.get('agent_errors'), 'Native backup agent reported an error')
            added = [b for b in status.get('backups', []) if b.get('backup_id') not in before_ids]
            require(len(added) == 1, 'New native backup identity is ambiguous')
            selected = added[0]
            break
        pause(3)
    require(selected is not None, 'Timed out waiting for native backup completion')
    backup_id = validate_backup_metadata(selected)
    expected_size = selected['agents'][AGENT]['size']
    require(shutil.disk_usage(backup_dir).free > expected_size + 512*1024*1024,
            'Insufficient free space for private backup export')
    target = backup_dir / f'home-assistant-{backup_id}.tar'
    require(not target.exists() and not target.is_symlink(), 'Backup export already exists; preserve it')
    result = client.download(f'/api/backup/download/{backup_id}?agent_id={AGENT}', target,
                             max_bytes=max(expected_size*2, 10*1024*1024))
    private_path(target)
    evidence = inspect_archive(target, backup_id, require_supervisor=require_supervisor)
    require(evidence['bytes'] == expected_size and result['sha256'] == evidence['sha256'],
            'Backup export length or checksum differs from native metadata')
    private_write(target.with_suffix('.tar.sha256'), evidence['sha256'] + '  ' + target.name + '\n')
    return {**evidence, 'file': target.name, 'native_completion': True,
            'daily_schedule_configured': True, 'automatic_deletion': False}


def runtime_module():
    spec = importlib.util.spec_from_file_location('home_assistant_runtime',
                      Path(__file__).with_name('home-assistant-runtime.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['configure', 'create', 'inspect'])
    parser.add_argument('--private-dir', type=Path, default=PRIVATE)
    parser.add_argument('--backup-dir', type=Path, default=BACKUPS)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--require-supervisor', action='store_true',
                        help='Require Supervisor configuration when network mounts/private registries exist')
    parser.add_argument('--base-url')
    parser.add_argument('--ca-file')
    parser.add_argument('--connect-ip')
    args = parser.parse_args()
    require(os.geteuid() == 0, 'Run as root on the owning Proxmox node')
    os.umask(0o077)
    if args.action == 'inspect':
        require(args.archive is not None, 'Archive path required')
        result = inspect_archive(args.archive, require_supervisor=args.require_supervisor)
    else:
        import fcntl
        private_path(args.private_dir, directory=True)
        lock = args.private_dir / 'backup.lock'
        if not lock.exists() and not lock.is_symlink():
            private_write(lock, '')
        private_path(lock)
        with lock.open('r+') as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            client, _token = runtime_module().authenticated_client(args.private_dir,
                base_url=args.base_url, ca_file=args.ca_file, connect_ip=args.connect_ip)
            result = (configure(client, args.private_dir) if args.action == 'configure' else
                      create(client, args.private_dir, args.backup_dir,
                             require_supervisor=args.require_supervisor))
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Never serialize HTTP response bodies, payloads, tokens, or private metadata.
        print(json.dumps({'ok': False, 'error_type': type(error).__name__,
                          'error': str(error) if isinstance(error, RuntimeError) else 'Backup failed; inspect private state locally'}))
        raise SystemExit(1)
