#!/usr/bin/env python3
"""Merge explicit local records without replacing unrelated Pi-hole settings."""
import datetime
import ipaddress
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import tomllib


def merge_records(current, records):
    desired = {}
    for name, address in records.items():
        if not re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+home\.arpa', name):
            raise ValueError('Expected an explicit lower-case home.arpa hostname')
        parsed = ipaddress.IPv4Address(address)
        if parsed not in ipaddress.IPv4Network('192.168.1.0/24') or parsed.packed[-1] in (0, 255):
            raise ValueError('Expected a usable home-LAN address')
        desired[name] = str(parsed)
    result = list(current)
    existing = {}
    for line in current:
        parts = line.split('#', 1)[0].split()
        for alias in parts[1:]:
            normalized = alias.lower().rstrip('.')
            if normalized in desired:
                if parts[0] != desired[normalized]:
                    raise ValueError('An existing hostname conflicts with the requested record')
                existing[normalized] = parts[0]
    result.extend(f'{address} {name}' for name, address in desired.items() if name not in existing)
    return result


def set_hosts(hosts):
    subprocess.run(['pihole-FTL', '--config', 'dns.hosts', json.dumps(hosts)],
                   check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['systemctl', 'restart', 'pihole-FTL'], check=True)
    for attempt in range(30):
        if subprocess.run(['systemctl', 'is-active', '--quiet', 'pihole-FTL']).returncode == 0:
            return
        time.sleep(1)
    raise RuntimeError('FTL did not become active')


def main():
    if len(sys.argv) != 2:
        raise ValueError('Usage: install-local-dns.py <records-json>')
    if subprocess.check_output(['systemd-detect-virt', '--container'], text=True).strip() != 'lxc':
        raise ValueError('Expected the named Pi-hole LXC')
    data = json.loads(Path(sys.argv[1]).read_text())
    if data['domain'] != 'home.arpa' or not data['records']:
        raise ValueError('Expected nonempty home.arpa records')
    config = Path('/etc/pihole/pihole.toml')
    old = tomllib.loads(config.read_text())['dns']['hosts']
    new = merge_records(old, data['records'])
    if old != new:
        backup = Path('/var/backups/homelab-local-dns') / datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
        backup.mkdir(parents=True, mode=0o700)
        backup.parent.chmod(0o700)
        shutil.copy2(config, backup / 'pihole.toml')
        (backup / 'pihole.toml').chmod(0o600)
        try:
            set_hosts(new)
            verify(data['records'])
        except Exception:
            set_hosts(old)
            raise
    else:
        verify(data['records'])
    print(f'Local DNS verified: {len(data["records"])} records; unrelated entries preserved')


def verify(records):
    for name, address in records.items():
        for attempt in range(10):
            answer = subprocess.run(['dig', '+time=1', '+tries=1', '+short', '@127.0.0.1', name, 'A'],
                                    text=True, capture_output=True)
            if answer.returncode == 0 and answer.stdout.split() == [address]:
                break
            time.sleep(1)
        else:
            raise RuntimeError(f'Local DNS verification failed for {name}')


if __name__ == '__main__':
    main()
