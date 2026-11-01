#!/usr/bin/env python3
"""Create a consistent, private cold backup; restore only into an empty volume."""
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import sqlite3
import stat
import subprocess
import tarfile
import time


def command(*args, timeout=60):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=timeout).strip()


def main():
    if os.geteuid() != 0 or command('hostname', '-s') != 'apps01':
        raise RuntimeError('Run as root inside apps01')
    os.umask(0o077)
    lock_path=Path('/var/lib/homelab/vaultwarden.lock')
    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        ids=command('docker','ps','-aq','--filter','label=com.docker.compose.project=homelab-vaultwarden','--filter','label=com.docker.compose.service=vaultwarden').splitlines()
        if len(ids) != 1:
            raise RuntimeError('Expected one managed Vaultwarden container')
        cid=ids[0]
        data=json.loads(command('docker','inspect',cid))[0]
        if data['Config'].get('Labels',{}).get('io.homelab.managed') != 'vaultwarden-v1' or not data['State']['Running']:
            raise RuntimeError('Expected the running managed service')
        volume=json.loads(command('docker','volume','inspect','homelab-vaultwarden-data'))[0]
        if volume.get('Labels',{}).get('io.homelab.managed') != 'vaultwarden-v1':
            raise RuntimeError('Expected the managed data volume')
        if not any(m.get('Name')==volume['Name'] and m.get('Destination')=='/data' for m in data['Mounts']):
            raise RuntimeError('Unexpected data volume attachment')
        source=Path(volume['Mountpoint']).resolve(strict=True)
        if source != Path('/var/lib/docker/volumes/homelab-vaultwarden-data/_data'):
            raise RuntimeError('Nonstandard Docker volume location needs review')
        destination=Path('/var/backups/homelab-vaultwarden')
        destination.mkdir(mode=0o700,parents=True,exist_ok=True)
        info=destination.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
            raise RuntimeError('Expected a private root-owned backup directory')
        stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+secrets.token_hex(4)
        output=destination/('vaultwarden-'+stamp+'.tar.gz')
        pending=destination/(output.name+'.partial')
        unit='homelab-vaultwarden-backup-recover-'+stamp.lower()
        command('systemd-run','--unit',unit,'--on-active=600','/usr/bin/docker','start',cid)
        restored=False
        try:
            command('docker','stop','--time','30',cid)
            if json.loads(command('docker','inspect',cid))[0]['State']['Running']:
                raise RuntimeError('Service did not stop for the consistent snapshot')
            database_path=source/'db.sqlite3'
            if database_path.is_symlink() or not database_path.is_file():
                raise RuntimeError('Expected the existing regular Vaultwarden database')
            with sqlite3.connect(source/'db.sqlite3') as database:
                if database.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
                    raise RuntimeError('Source database integrity check failed')
            # The stopped service makes the database, attachments, sends and
            # signing keys part of one consistent snapshot, including any WAL.
            command('tar','--numeric-owner','-czf',str(pending),'-C',str(source),'.',timeout=300)
            with tarfile.open(pending,'r:gz') as archive:
                if './db.sqlite3' not in archive.getnames():
                    raise RuntimeError('Database is missing from the backup')
            pending.chmod(0o600)
            pending.rename(output)
            digest=hashlib.sha256()
            with output.open('rb') as stream:
                for block in iter(lambda:stream.read(1024*1024),b''):
                    digest.update(block)
            output.with_suffix(output.suffix+'.sha256').write_text(digest.hexdigest()+'  '+output.name+'\n')
        finally:
            command('docker','start',cid)
            for attempt in range(90):
                health=json.loads(command('docker','inspect',cid))[0]['State'].get('Health',{}).get('Status')
                if health=='healthy':
                    restored=True
                    break
                time.sleep(1)
            if restored:
                command('systemctl','stop',unit+'.timer')
            else:
                raise RuntimeError('Service health did not recover; independent recovery timer retained')
        print(json.dumps({'backup':str(output),'bytes':output.stat().st_size,'sqlite_integrity':'ok','service_restored':restored,'off_node_copy':False,'pass':True}))


if __name__=='__main__':
    main()
