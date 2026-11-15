#!/usr/bin/env python3
"""Consistent private n8n snapshot. Restores require a separate empty stack."""
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
import subprocess
import tarfile
import tempfile
import time

PROJECT = 'homelab-n8n'
LABEL = 'n8n-v1'
RUNTIME = Path('/etc/homelab/n8n')
STACK = Path('/opt/homelab/n8n')
BACKUPS = Path('/var/backups/homelab-n8n')


def command(*args, timeout=60):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=timeout).strip()


def private_directory(path, create=False):
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        raise RuntimeError('Expected a private root-owned directory')


def private_tree(path):
    private_directory(path)
    for item in path.rglob('*'):
        info = item.lstat()
        if info.st_uid != 0 or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
            raise RuntimeError('Unexpected private runtime entry')
        if stat.S_IMODE(info.st_mode) & 0o077:
            raise RuntimeError('Private runtime permissions require review')


def containers():
    result = {}
    for service in ('n8n', 'runners', 'postgres'):
        ids = command('docker', 'ps', '-aq', '--filter', 'label=com.docker.compose.project=' + PROJECT,
                      '--filter', 'label=com.docker.compose.service=' + service).splitlines()
        if len(ids) != 1:
            raise RuntimeError('Expected exactly one container per managed service')
        item = json.loads(command('docker', 'inspect', ids[0]))[0]
        labels = item['Config'].get('Labels', {})
        if labels.get('io.homelab.managed') != LABEL or not item['State']['Running']:
            raise RuntimeError('Expected healthy owned n8n services')
        if item['State'].get('Health', {}).get('Status') != 'healthy':
            raise RuntimeError('Expected healthy owned n8n services')
        result[service] = {'id': ids[0], 'data': item}
    return result


def managed_volume(item, name, target):
    volume = json.loads(command('docker', 'volume', 'inspect', name))[0]
    if volume.get('Labels', {}).get('io.homelab.managed') != LABEL:
        raise RuntimeError('Expected the owned n8n data volume')
    if volume['Name'] != name or not any(m.get('Name') == name and m.get('Destination') == target
               and m.get('Type') == 'volume' for m in item['Mounts']):
        raise RuntimeError('Unexpected n8n data attachment')
    source = Path(volume['Mountpoint'])
    if source.is_symlink() or source.resolve(strict=True) != Path('/var/lib/docker/volumes') / name / '_data':
        raise RuntimeError('Unexpected Docker data volume path')
    return source


def stack_release():
    private_directory(STACK)
    current = STACK / 'current'
    if not current.is_symlink():
        raise RuntimeError('Expected the managed stack release link')
    release = current.resolve(strict=True)
    root = (STACK / 'releases').resolve(strict=True)
    if release.parent != root or not release.name.startswith('release.'):
        raise RuntimeError('Unexpected managed stack release')
    private_tree(release)
    for name in ('compose.yml', '.env', 'MANIFEST'):
        if not (release / name).is_file() or (release / name).is_symlink():
            raise RuntimeError('Missing managed stack backup input')
    return release


def dump_database(cid, output):
    with output.open('xb') as stream:
        subprocess.run(['docker', 'exec', cid, 'pg_dump', '-U', 'n8n', '-d', 'n8n',
                        '--format=custom', '--no-owner', '--no-acl'], stdout=stream,
                       stderr=subprocess.DEVNULL, check=True, timeout=180)
    with output.open('rb') as stream:
        if stream.read(5) != b'PGDMP':
            raise RuntimeError('Expected a PostgreSQL custom-format dump')
        stream.seek(0)
        subprocess.run(['docker', 'exec', '-i', cid, 'pg_restore', '--list'], stdin=stream,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=60)


def recover(items, unit):
    # Keep the independently armed guard until BOTH stopped services are healthy.
    command('docker', 'start', items['n8n']['id'], items['runners']['id'])
    for attempt in range(90):
        healthy = True
        for service in ('n8n', 'runners'):
            state = json.loads(command('docker', 'inspect', items[service]['id']))[0]['State']
            healthy = healthy and state['Running'] and state.get('Health', {}).get('Status') == 'healthy'
        if healthy:
            command('systemctl', 'stop', unit + '.timer')
            return
        time.sleep(1)
    raise RuntimeError('n8n recovery timed out; independent recovery guard retained')


def snapshot(items, source, release, destination, stamp):
    output = destination / ('n8n-' + stamp + '.tar.gz')
    pending = destination / (output.name + '.partial')
    unit = 'homelab-n8n-backup-recover-' + stamp.lower()
    command('systemd-run', '--unit', unit, '--on-active=900', '/usr/bin/docker', 'start',
            items['n8n']['id'], items['runners']['id'])
    try:
        # Main service drains its executions before runners stop. Database stays up.
        command('docker', 'stop', '--time', '60', items['n8n']['id'], timeout=90)
        command('docker', 'stop', '--time', '30', items['runners']['id'])
        for service in ('n8n', 'runners'):
            if json.loads(command('docker', 'inspect', items[service]['id']))[0]['State']['Running']:
                raise RuntimeError('n8n writer did not stop for snapshot')
        with tempfile.TemporaryDirectory(prefix='.n8n-backup-', dir=destination) as stage_name:
            stage = Path(stage_name)
            dump_database(items['postgres']['id'], stage / 'database.dump')
            metadata = {'format': 'homelab-n8n-backup-v1', 'created_utc': stamp,
                        'database': {'name': 'n8n', 'user': 'n8n', 'format': 'pg_dump-custom'},
                        'images': {name: item['data']['Config']['Image'] for name, item in items.items()}}
            (stage / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
            command('tar', '--numeric-owner', '-czf', str(pending), '-C', str(stage), 'database.dump',
                    'metadata.json', '-C', str(source.parent), source.name,
                    '-C', str(RUNTIME.parent), RUNTIME.name, '-C', str(release.parent), release.name,
                    timeout=300)
        with tarfile.open(pending, 'r:gz') as archive:
            names = archive.getnames()
            required = ('database.dump', 'metadata.json', '_data', 'n8n/encryption-key', 'n8n/n8n.env',
                        release.name + '/compose.yml', release.name + '/.env')
            if not all(name in names for name in required):
                raise RuntimeError('Incomplete n8n backup archive')
        pending.chmod(0o600)
        pending.rename(output)
        digest = hashlib.sha256()
        with output.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        output.with_suffix(output.suffix + '.sha256').write_text(digest.hexdigest() + '  ' + output.name + '\n')
    finally:
        recover(items, unit)
    return output


def main():
    if os.geteuid() != 0 or command('hostname', '-s') != 'apps01':
        raise RuntimeError('Run as root inside apps01')
    os.umask(0o077)
    with Path('/var/lib/homelab/n8n.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        items = containers()
        source = managed_volume(items['n8n']['data'], 'homelab-n8n-data', '/home/node/.n8n')
        managed_volume(items['postgres']['data'], 'homelab-n8n-postgres-data', '/var/lib/postgresql/data')
        private_tree(RUNTIME)
        release = stack_release()
        private_directory(BACKUPS, create=True)
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + secrets.token_hex(4)
        output = snapshot(items, source, release, BACKUPS, stamp)
        print(json.dumps({'backup': str(output), 'bytes': output.stat().st_size, 'database_dump_verified': True,
                          'service_restored': True, 'off_node_copy': False, 'pass': True}))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Never print Docker environment, dump errors, runtime contents or traceback.
        raise SystemExit('n8n backup failed; review service health and any retained recovery guard')
