#!/usr/bin/env python3
"""Private runtime setup and local admin checks; never print secret values."""
import argparse
import http.cookiejar
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

PRIVATE = Path('/etc/homelab/vaultwarden')
IMAGE_RE = re.compile(r'vaultwarden/server@sha256:[0-9a-f]{64}')
HASH_RE = re.compile(r'\$argon2id\$v=19\$m=65540,t=3,p=4\$[A-Za-z0-9+/]+\$[A-Za-z0-9+/]+')
SETTINGS = {
    'DOMAIN': 'https://vault.home.arpa',
    'DATA_FOLDER': '/data', 'DATABASE_URL': 'sqlite:///data/db.sqlite3',
    'ROCKET_ADDRESS': '0.0.0.0', 'ROCKET_PORT': '80',
    'SIGNUPS_ALLOWED': 'false', 'INVITATIONS_ALLOWED': 'false', 'SIGNUPS_VERIFY': 'false',
    'SHOW_PASSWORD_HINT': 'false', 'IP_HEADER': 'X-Forwarded-For',
    'IP_HEADER_TRUSTED_PROXIES': 'local', 'UMASK': '077', 'TZ': 'Europe/London',
    'LOG_LEVEL': 'warn'
}

def private_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
        raise RuntimeError('Expected a root-owned mode-600 regular runtime file')
    return path.read_text().strip()

def write_new(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        stream.write(value + '\n')

def parse_env(text):
    result = {}
    for line in text.splitlines():
        if not line or '=' not in line:
            raise RuntimeError('Malformed private service environment')
        key, value = line.split('=', 1)
        if key in result:
            raise RuntimeError('Duplicate private environment setting')
        result[key] = value
    return result

def validate_email(value):
    if not isinstance(value, str) or len(value) > 254 or not re.fullmatch(r'[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+', value):
        raise RuntimeError('Expected one valid owner email in private runtime input')
    return value.strip().lower()

def generate_hash(image, token):
    # Vaultwarden's hash CLI reads a terminal. A private PTY supplies the token;
    # its captured output is never forwarded to stdout, stderr or log files.
    import errno
    import pty
    import select
    import time
    if not IMAGE_RE.fullmatch(image):
        raise RuntimeError('Expected the pinned official image')
    master, slave = pty.openpty()
    name = 'homelab-vaultwarden-hash-' + secrets.token_hex(8)
    process = None
    output = bytearray()
    sent = 0
    try:
        process = subprocess.Popen(
            ['docker', 'run', '--rm', '--name', name, '--network', 'none', '--read-only',
             '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true', '-it',
             image, '/vaultwarden', 'hash', '--preset', 'bitwarden'],
            stdin=slave, stdout=slave, stderr=slave, close_fds=True, start_new_session=True)
        os.close(slave)
        slave = None
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            readable, _, _ = select.select([master], [], [], 0.2)
            if readable:
                try:
                    block = os.read(master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
                if not block:
                    break
                output.extend(block)
                if len(output) > 1024 * 1024:
                    raise RuntimeError('Hash command exceeded private capture limit')
                if sent == 0 and b'Password:' in output:
                    os.write(master, token.encode() + b'\n')
                    sent = 1
                if sent == 1 and b'Confirm Password:' in output:
                    os.write(master, token.encode() + b'\n')
                    sent = 2
            if process.poll() is not None and not readable:
                break
        if process.wait(timeout=5) != 0 or sent != 2:
            raise RuntimeError('Pinned image could not generate the private admin hash')
        match = re.search(rb"ADMIN_TOKEN='([^'\r\n]+)'", output)
        if not match or not HASH_RE.fullmatch(match.group(1).decode()):
            raise RuntimeError('Pinned image returned an unexpected Argon2id hash')
        return match.group(1).decode()
    finally:
        if slave is not None:
            os.close(slave)
        os.close(master)
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15, check=False)

def prepare(image):
    if os.geteuid() != 0:
        raise RuntimeError('Run inside apps01 as root')
    if not IMAGE_RE.fullmatch(image):
        raise RuntimeError('Expected an official-repository digest')
    if not PRIVATE.exists():
        PRIVATE.mkdir(mode=0o700, parents=True)
    info = PRIVATE.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        raise RuntimeError('Expected a private root-owned runtime directory')
    marker = PRIVATE / 'managed-v1'
    if not marker.exists():
        if any(PRIVATE.iterdir()):
            raise RuntimeError('Unmanaged private runtime directory; nothing overwritten')
        write_new(marker, 'homelab-vaultwarden-v1')
    if private_file(marker) != 'homelab-vaultwarden-v1':
        raise RuntimeError('Unexpected private ownership marker')
    token_path = PRIVATE / 'admin-token'
    if not token_path.exists():
        write_new(token_path, secrets.token_urlsafe(48))
    token = private_file(token_path)
    if not re.fullmatch(r'[A-Za-z0-9_-]{64}', token):
        raise RuntimeError('Unexpected existing admin token; no rotation performed')
    hash_path = PRIVATE / 'admin-token.argon2'
    if not hash_path.exists():
        write_new(hash_path, generate_hash(image, token))
    encoded = private_file(hash_path)
    if not HASH_RE.fullmatch(encoded):
        raise RuntimeError('Expected a protected Argon2id admin hash')
    expected = {**SETTINGS, 'ADMIN_TOKEN': encoded}
    env_path = PRIVATE / 'service.env'
    if env_path.exists():
        if parse_env(private_file(env_path)) != expected:
            raise RuntimeError('Private environment drift; nothing overwritten')
    else:
        write_new(env_path, '\n'.join(key + '=' + value for key, value in expected.items()))
    print('Protected runtime configuration verified; admin token and hash were not printed.')

def container_metadata(container):
    result = subprocess.run(['docker', 'inspect', container], capture_output=True, check=True, text=True, timeout=15)
    data = json.loads(result.stdout)
    if len(data) != 1:
        raise RuntimeError('Expected exactly one managed container')
    return data[0]

def verify_container(container):
    data = container_metadata(container)
    if data['Config'].get('Labels', {}).get('io.homelab.managed') != 'vaultwarden-v1':
        raise RuntimeError('Unexpected Vaultwarden container ownership')
    if data['HostConfig'].get('PortBindings'):
        raise RuntimeError('Vaultwarden must not publish host ports')
    mounts = data.get('Mounts', [])
    if not any(m.get('Type') == 'volume' and m.get('Name') == 'homelab-vaultwarden-data' and m.get('Destination') == '/data' and m.get('RW') for m in mounts):
        raise RuntimeError('Expected the persistent managed data volume')
    if set(data['NetworkSettings']['Networks']) != {'homelab-proxy_default'}:
        raise RuntimeError('Expected only the existing reverse-proxy network')
    env = parse_env('\n'.join(data['Config']['Env']))
    expected = parse_env(private_file(PRIVATE / 'service.env'))
    if any(env.get(key) != value for key, value in expected.items()):
        raise RuntimeError('Effective container settings differ from protected runtime configuration')
    if data.get('State', {}).get('Health', {}).get('Status') != 'healthy':
        raise RuntimeError('Vaultwarden is not healthy')
    # Avoid config.json silently overriding the managed environment policy.
    subprocess.run(['docker', 'exec', container, 'sh', '-ec', 'test ! -e /data/config.json'], check=True, timeout=15, capture_output=True)
    print('Container health, closed signup policy, persistent volume and internal-only networking verified.')

def connect_admin(base, token):
    anonymous = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with anonymous.open(urllib.request.Request(base + '/admin/users', headers={'Accept': 'application/json'}), timeout=15):
            raise RuntimeError('Anonymous access to admin user data was accepted')
    except urllib.error.HTTPError as error:
        if error.code not in (401, 403):
            raise RuntimeError('Unexpected anonymous admin response') from None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    payload = urllib.parse.urlencode({'token': token}).encode()
    request = urllib.request.Request(base + '/admin/', data=payload, headers={'Content-Type': 'application/x-www-form-urlencoded'})
    with opener.open(request, timeout=15) as response:
        response.read(1024 * 1024)
    with opener.open(urllib.request.Request(base + '/admin/users', headers={'Accept': 'application/json'}), timeout=15) as response:
        if response.status != 200 or not isinstance(json.load(response), list):
            raise RuntimeError('Admin authentication check failed')
    return opener, base

def admin_session(container):
    data = container_metadata(container)
    address = data['NetworkSettings']['Networks']['homelab-proxy_default']['IPAddress']
    if not re.fullmatch(r'(?:[0-9]{1,3}\.){3}[0-9]{1,3}', address):
        raise RuntimeError('Expected an internal container IPv4 address')
    return connect_admin('http://' + address, private_file(PRIVATE / 'admin-token'))

def invite(container, owner):
    if not isinstance(owner, dict) or set(owner) != {'email'}:
        raise RuntimeError('Private owner JSON must contain only an email field')
    email = validate_email(owner['email'])
    opener, base = admin_session(container)
    lookup = base + '/admin/users/by-mail/' + urllib.parse.quote(email, safe='')
    try:
        with opener.open(urllib.request.Request(lookup, headers={'Accept': 'application/json'}), timeout=15) as response:
            existing = json.load(response)
        if str(existing.get('email', '')).lower() != email:
            raise RuntimeError('Unexpected existing owner record')
        print('Owner record already exists; no invitation or account settings changed.')
        return
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise RuntimeError('Could not safely inspect the private owner record') from None
    request = urllib.request.Request(base + '/admin/invite', data=json.dumps({'email': email}).encode(), headers={'Content-Type': 'application/json', 'Accept': 'application/json'})
    with opener.open(request, timeout=15) as response:
        created = json.load(response)
    if str(created.get('email', '')).lower() != email:
        raise RuntimeError('Unexpected owner invitation response')
    print('Owner invitation created without SMTP. Complete registration yourself at https://vault.home.arpa/#/signup with the exact invited email.')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'verify', 'auth', 'invite'])
    parser.add_argument('--image')
    parser.add_argument('--container')
    owner_group = parser.add_mutually_exclusive_group()
    owner_group.add_argument('--owner-file', type=Path)
    owner_group.add_argument('--owner-stdin', action='store_true')
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args.image or '')
        return
    if not args.container or not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]*', args.container):
        raise RuntimeError('Expected the managed container identifier')
    verify_container(args.container)
    if args.action == 'auth':
        admin_session(args.container)
        print('Admin authentication verified; no session cookie or token was printed.')
    elif args.action == 'invite':
        if args.owner_stdin:
            owner = json.loads(sys.stdin.read(16385))
        elif args.owner_file:
            owner = json.loads(private_file(args.owner_file))
        else:
            raise RuntimeError('Provide private owner JSON by file or stdin')
        invite(args.container, owner)

if __name__ == '__main__':
    try:
        main()
    except urllib.error.HTTPError as error:
        print(f'ERROR: Vaultwarden runtime HTTP status {error.code}; response and protected values were not printed.', file=sys.stderr)
        raise SystemExit(1)
    except Exception:
        # Do not print arbitrary HTTP responses, subprocess output or exceptions
        # that might contain protected configuration, cookies or private input.
        print('ERROR: Vaultwarden runtime action failed; protected values were not printed. Inspect the named phase and private files locally.', file=sys.stderr)
        raise SystemExit(1)
