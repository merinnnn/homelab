#!/usr/bin/env python3
"""Read-only backup decryption test using HAOS's installed SecureTar library.

No plaintext is extracted. The recovery password travels only over QGA stdin.
The Supervisor's existing archive must match the host export by SHA256.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tarfile


GUEST_CODE = r'''
import hashlib, json, secrets, sys, tarfile
from pathlib import Path
from securetar import SecureTarArchive

try:
    data = json.load(sys.stdin)
    matches = []
    for root in (Path('/data/backup'), Path('/backup')):
        if not root.is_dir():
            continue
        for path in root.glob('*.tar'):
            if path.is_symlink() or not path.is_file():
                continue
            with tarfile.open(path, 'r:') as archive:
                try:
                    info = archive.getmember('./backup.json')
                except KeyError:
                    info = archive.getmember('backup.json')
                if info.size > 1024*1024 or not info.isfile():
                    raise RuntimeError()
                with archive.extractfile(info) as stream:
                    metadata = json.load(stream)
                if metadata.get('slug') != data['backup_id']:
                    continue
            with path.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            if digest != data['sha256']:
                raise RuntimeError()
            if path.resolve() not in matches:
                matches.append(path.resolve())
    if len(matches) != 1:
        raise RuntimeError()
    path = matches[0]
    count = 0
    first = None
    with SecureTarArchive(path, 'r', password=data['password']) as archive:
        for member in archive.tar:
            if member.name.endswith('.tar.gz'):
                if not archive.validate(member):
                    raise RuntimeError()
                count += 1
                first = first or member.name
    if count != data['components'] or not first:
        raise RuntimeError()
    with SecureTarArchive(path, 'r', password=secrets.token_urlsafe(64)) as archive:
        member = next(member for member in archive.tar if member.name == first)
        if archive.validate_password(member):
            raise RuntimeError()
    print(json.dumps({'ok': True, 'components': count,
        'decryption_integrity_verified': True, 'wrong_password_denied': True,
        'plaintext_extracted': False, 'restore_tested': False,
        'same_export_sha256': True}))
except Exception as error:
    print(json.dumps({'ok': False, 'error_type': type(error).__name__}))
    raise SystemExit(1)
'''


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def run(archive, private):
    runtime = load('ha_runtime', 'home-assistant-runtime.py')
    backup = load('ha_backup', 'home-assistant-backup.py')
    runtime.owned_endpoint()
    backup.private_path(private, directory=True)
    backup.private_path(archive)
    structural = backup.inspect_archive(archive)
    with tarfile.open(archive, 'r:') as outer:
        try:
            member = outer.getmember('./backup.json')
        except KeyError:
            member = outer.getmember('backup.json')
        with outer.extractfile(member) as stream:
            backup_id = json.load(stream)['slug']
    request = {'backup_id': backup_id, 'sha256': structural['sha256'],
               'password': backup.load_password(private), 'components': structural['components']}
    result = subprocess.run(['qm', 'guest', 'exec', '102', '--timeout', '600', '--pass-stdin',
        '--', 'docker', 'exec', '-i', 'hassio_supervisor', 'python3', '-c', GUEST_CODE],
        input=json.dumps(request).encode(), capture_output=True, timeout=650)
    backup.require(result.returncode == 0, 'Guest decryption verification did not finish')
    response = json.loads(result.stdout)
    backup.require(bool(response.get('exited')) and response.get('exitcode') == 0,
                   'Guest decryption verification failed')
    safe = json.loads(response.get('out-data', '{}'))
    backup.require(safe.get('ok') is True and safe.get('decryption_integrity_verified') is True,
                   'Guest decryption verification did not pass')
    return safe


if __name__ == '__main__':
    try:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('--archive', required=True, type=Path)
        parser.add_argument('--private-dir', type=Path, default=Path('/etc/homelab/home-assistant'))
        args = parser.parse_args()
        print(json.dumps(run(args.archive, args.private_dir), sort_keys=True))
    except Exception as error:
        print(json.dumps({'ok': False, 'error_type': type(error).__name__,
                          'error': 'Read-only decryption verification failed; no private details printed'}))
        raise SystemExit(1)
