#!/usr/bin/env python3
"""Create one explicitly allocated HAOS guest; preserve partial/unknown resources."""
import argparse
import fcntl
import hashlib
import json
import lzma
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import urllib.request

VERSION = '18.4'
IMAGE = f'haos_ova-{VERSION}.qcow2.xz'
URL = f'https://github.com/home-assistant/operating-system/releases/download/{VERSION}/{IMAGE}'
SHA256 = '756ec485b1b153099ca53e88a5eebd63a801d56b791afe5c6d63ef94a35dc02d'
IMAGE_BYTES = 508539728
NODE, NAME, STORAGE, BRIDGE = 'pve01', 'ha01', 'local-lvm', 'vmbr0'
MARKER = 'homelab-home-assistant-v1'
DISK_BYTES = 32 * 1024**3


class Refused(RuntimeError):
    pass


def command(*args):
    result = subprocess.run(args, text=True, capture_output=True, timeout=1800)
    if result.returncode:
        # Config/guest output may contain sensitive data. Never echo it.
        raise Refused(f'{args[0]} {args[1] if len(args) > 1 else ""} failed; inspect privately on the node')
    return result.stdout


def config(vmid, run=command):
    result = {}
    for line in run('qm', 'config', str(vmid), '--current', '1').splitlines():
        if ':' in line and not line.startswith('#'):
            key, value = line.split(':', 1)
            result[key] = value.strip()
    return result


def write_state(path, value):
    fd, name = tempfile.mkstemp(prefix='.state-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(value, stream, sort_keys=True, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def inspect_config(actual, expected):
    fixed = {'name': NAME, 'description': MARKER, 'bios': 'ovmf', 'machine': 'q35',
             'cores': '2', 'memory': '4096', 'balloon': '0', 'cpu': 'host',
             'ostype': 'l26', 'scsihw': 'virtio-scsi-single', 'onboot': '1',
             'boot': 'order=scsi0', 'serial0': 'socket', 'vga': 'std',
             'startup': 'order=20,up=30,down=120'}
    for key, value in fixed.items():
        if actual.get(key) != value:
            raise Refused(f'Owned VM configuration drift: {key}')
    if actual.get('agent') not in ('1', 'enabled=1'):
        raise Refused('Owned VM guest agent configuration drift')
    network = actual.get('net0', '').split(',')
    if set(network) != {f'virtio={expected["mac"]}', f'bridge={expected["bridge"]}'}:
        raise Refused('Owned VM network/MAC drift')
    for disk in ('scsi0', 'efidisk0'):
        if actual.get(disk) != expected.get(disk):
            raise Refused(f'Owned VM disk configuration drift: {disk}')
    for key in actual:
        if re.fullmatch(r'(?:scsi|sata|ide|virtio|unused|net)\d+', key) and key not in ('scsi0', 'net0'):
            raise Refused(f'Unexpected attached or unused VM device: {key}')
    efi = actual.get('efidisk0', '')
    if 'efitype=4m' not in efi.split(',') or 'pre-enrolled-keys=0' not in efi.split(','):
        raise Refused('UEFI secure boot keys must remain disabled')
    scsi = actual.get('scsi0', '').split(',')
    if not {'discard=on', 'iothread=1', 'ssd=1', 'size=32G'}.issubset(scsi):
        raise Refused('Owned system disk properties drift')


def prepare_image(cache, run=command):
    compressed = cache / IMAGE
    if compressed.exists() and (compressed.is_symlink() or not compressed.is_file()):
        raise Refused('Unsafe image cache path')
    if not compressed.exists():
        fd, name = tempfile.mkstemp(prefix='.download-', dir=cache)
        try:
            with os.fdopen(fd, 'wb') as output, urllib.request.urlopen(URL, timeout=60) as response:
                if not response.url.startswith('https://'):
                    raise Refused('Image download left HTTPS')
                total = 0
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > IMAGE_BYTES:
                        raise Refused('Image download exceeds pinned size')
                    output.write(chunk)
            os.replace(name, compressed)
        finally:
            if os.path.exists(name):
                os.unlink(name)
    digest = hashlib.sha256()
    with compressed.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    if compressed.stat().st_size != IMAGE_BYTES or digest.hexdigest() != SHA256:
        raise Refused('Pinned HAOS image size/SHA256 verification failed')
    # Always derive a fresh import file from the verified archive. Cached unpacked data
    # is never trusted, and original disks are never reimported on a repeat.
    fd, name = tempfile.mkstemp(prefix='.verified-', suffix='.qcow2', dir=cache)
    try:
        with os.fdopen(fd, 'wb') as output, lzma.open(compressed, 'rb') as source:
            count = 0
            while chunk := source.read(1024 * 1024):
                count += len(chunk)
                if count > DISK_BYTES:
                    raise Refused('Unpacked image exceeds approved maximum')
                output.write(chunk)
        data = json.loads(run('qemu-img', 'info', '--output=json', name))
        if data.get('format') != 'qcow2' or data.get('backing-filename') or not 0 < data.get('virtual-size', 0) <= DISK_BYTES:
            raise Refused('Unexpected QCOW2 format, backing file or virtual size')
        run('qemu-img', 'check', name)
        return Path(name), data['virtual-size']
    except BaseException:
        os.unlink(name)
        raise


def deploy(vmid, mac, bridge, state_path, exists, image_factory, run=command):
    provenance = {'marker': MARKER, 'node': NODE, 'vmid': vmid, 'mac': mac,
                  'version': VERSION, 'image_sha256': SHA256}
    if state_path.exists():
        if state_path.is_symlink() or state_path.stat().st_uid != 0 or state_path.stat().st_mode & 0o077:
            raise Refused('Unsafe ownership manifest permissions')
        state = json.loads(state_path.read_text(encoding='utf-8'))
        if any(state.get(k) != v for k, v in provenance.items()) or state.get('phase') != 'complete':
            raise Refused('Unknown or partial ownership state; inspect privately, never reset/reimport')
        if state.get('bridge') != bridge:
            raise Refused('Bridge differs from ownership state; use explicit guarded promotion')
        if not exists(vmid):
            raise Refused('Owned VM missing; no automatic data replacement')
        inspect_config(config(vmid, run), state)
        print('Owned Home Assistant VM verified; no disk/configuration changes')
        return state
    if exists(vmid):
        raise Refused('Allocated guest ID is already in use; no ownership manifest')
    if bridge != 'vmbr1':
        raise Refused('Initial creation must use isolated vmbr1; claim owner before guarded LAN promotion')
    # Download/check/space validation must complete before recording intent or qm create.
    image, virtual_size = image_factory()
    try:
        state = dict(provenance, phase='creating', bridge=bridge)
        write_state(state_path, state)
        run('qm', 'create', str(vmid), '--name', NAME, '--description', MARKER,
            '--ostype', 'l26', '--cpu', 'host', '--cores', '2', '--memory', '4096',
            '--balloon', '0', '--machine', 'q35', '--bios', 'ovmf',
            '--scsihw', 'virtio-scsi-single', '--net0', f'virtio={mac},bridge={bridge}',
            '--agent', 'enabled=1', '--onboot', '1', '--startup', 'order=20,up=30,down=120',
            '--serial0', 'socket', '--vga', 'std')
        run('qm', 'set', str(vmid), '--efidisk0', f'{STORAGE}:1,efitype=4m,pre-enrolled-keys=0')
        run('qm', 'set', str(vmid), '--scsi0', f'{STORAGE}:0,import-from={image},discard=on,iothread=1,ssd=1')
        if virtual_size < DISK_BYTES:
            run('qm', 'resize', str(vmid), 'scsi0', '32G')
        run('qm', 'set', str(vmid), '--boot', 'order=scsi0')
        actual = config(vmid, run)
        state.update(scsi0=actual.get('scsi0'), efidisk0=actual.get('efidisk0'))
        inspect_config(actual, state)
        state['phase'] = 'complete'
        write_state(state_path, state)
        print('Created owned Home Assistant VM (stopped); configure networking and owner before proxy publication')
        return state
    finally:
        image.unlink(missing_ok=True)


def promote(vmid, mac, state_path, marker_path, exists, run=command):
    # Reuse the complete ownership/configuration guard before changing one NIC.
    if not state_path.is_file() or state_path.is_symlink():
        raise Refused('Promotion requires a complete owned VM')
    current_bridge = json.loads(state_path.read_text(encoding='utf-8')).get('bridge')
    if current_bridge not in ('vmbr0', 'vmbr1'):
        raise Refused('Unknown promotion bridge state')
    state = deploy(vmid, mac, current_bridge, state_path, exists,
                   lambda: (_ for _ in ()).throw(Refused('Promotion cannot create guests')), run)
    if marker_path.is_symlink() or not marker_path.is_file() or marker_path.stat().st_mode & 0o077 or marker_path.stat().st_uid != 0:
        raise Refused('Promotion requires a root-only successful owner-bootstrap marker')
    marker = json.loads(marker_path.read_text(encoding='utf-8'))
    expected = {'marker': MARKER, 'vmid': vmid, 'mac': mac, 'owner_initialized': True}
    if any(marker.get(key) != value for key, value in expected.items()):
        raise Refused('Owner-bootstrap marker mismatch')
    if current_bridge == 'vmbr0':
        print('Owned LAN promotion already verified; no changes')
        return
    # Record partial intent before mutation. A failed promotion is never silently
    # retried or mistaken for an unclaimed VM; inspect it privately on the node.
    state['phase'] = 'promoting'
    write_state(state_path, state)
    run('qm', 'set', str(vmid), '--net0', f'virtio={mac},bridge=vmbr0')
    state['bridge'] = 'vmbr0'
    inspect_config(config(vmid, run), state)
    state['phase'] = 'complete'
    write_state(state_path, state)
    print('Promoted owned, owner-initialized Home Assistant VM to vmbr0')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('install', 'promote-lan'))
    parser.add_argument('vmid', type=int)
    parser.add_argument('mac', help='Explicitly allocated unicast MAC')
    parser.add_argument('--bridge', choices=('vmbr0', 'vmbr1'), default='vmbr1')
    args = parser.parse_args()
    if os.geteuid() != 0 or socket.gethostname().split('.')[0] != NODE:
        raise Refused('Run as root from the installed pve01 checkout')
    if Path(__file__).resolve().parents[2] != Path('/root/homelab'):
        raise Refused('Run this script from the actual /root/homelab Git checkout')
    if not 100 <= args.vmid <= 999999999 or not re.fullmatch(r'[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}', args.mac):
        raise Refused('Invalid explicit VMID/MAC')
    mac = args.mac.upper()
    if int(mac[:2], 16) & 1 or mac == '00:00:00:00:00:00':
        raise Refused('Require a valid unicast MAC')
    command('pveversion')
    command('ip', 'link', 'show', args.bridge)
    state_dir = Path('/var/lib/homelab/home-assistant')
    cache = Path('/var/cache/homelab/home-assistant')
    for directory in (state_dir, cache):
        if directory.is_symlink():
            raise Refused('Unsafe state/cache directory')
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        if directory.stat().st_uid != 0 or directory.stat().st_mode & 0o077:
            raise Refused('State/cache directory must remain root-owned mode700')
    # This lock also prevents two IDs from racing through this installer's allocation.
    lock_path = state_dir / 'deploy.lock'
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        exists = lambda vmid: any(Path(f'/etc/pve/{kind}/{vmid}.conf').exists() for kind in ('qemu-server', 'lxc'))
        state_path = state_dir / f'vm-{args.vmid}.json'
        def image_factory():
            status = json.loads(command('pvesh', 'get', f'/nodes/{NODE}/storage/{STORAGE}/status', '--output-format', 'json'))
            if status.get('active') != 1 or status.get('enabled') != 1 or 'images' not in status.get('content', '').split(',') or int(status.get('avail', 0)) < DISK_BYTES + 1024**3:
                raise Refused('Need active local-lvm storage with at least33GiB available')
            available = next((int(line.split()[1]) * 1024 for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith('MemAvailable:')), 0)
            if available < 5 * 1024**3:
                raise Refused('Need at least5GiB available host RAM before allocating4GiB')
            if __import__('shutil').disk_usage(cache).free < 4 * 1024**3:
                raise Refused('Need at least4GiB cache space for the verified HAOS image')
            return prepare_image(cache)
        if args.action == 'promote-lan':
            command('ip', 'link', 'show', 'vmbr0')
            promote(args.vmid, mac, state_path, Path('/etc/homelab/home-assistant/bootstrap.json'), exists)
        else:
            deploy(args.vmid, mac, args.bridge, state_path, exists, image_factory)


if __name__ == '__main__':
    try:
        main()
    except (Refused, OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit(f'Home Assistant VM installation refused: {error}')
