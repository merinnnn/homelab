#!/usr/bin/env python3
"""Independent read-only local Home Assistant HTTP, WebSocket and backup checks.

Token refresh writes only the existing root-private auth record. No device
actions, pairing, discovery requests, failed password attempts or notifications.
"""
import hashlib
import http.client
import importlib.util
import json
from pathlib import Path
import socket
import ssl
import sys

PRIVATE = Path('/etc/homelab/home-assistant')
HOST = 'ha.home.arpa'
PROXY = '192.168.1.58'
EXPECTED_CA = 'A5B9A7BDCFAA07275A9CB13EB53C4EFEA7ACAAEFDC803E538EB25AEB5C8F0EC6'


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    sys.modules[name] = value
    spec.loader.exec_module(value)
    return value


class HTTPS(http.client.HTTPSConnection):
    def __init__(self, context):
        super().__init__(HOST, 443, timeout=30, context=context)

    def connect(self):
        sock = socket.create_connection((PROXY, 443), 30)
        self.sock = self._context.wrap_socket(sock, server_hostname=HOST)


def get(context, path, token=None, http=False):
    connection = http.client.HTTPConnection(PROXY, 80, timeout=30) if http else HTTPS(context)
    headers = {'Host': HOST}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    try:
        connection.request('GET', path, headers=headers)
        response = connection.getresponse()
        body = response.read(1024 * 1024)
        return response.status, dict((k.lower(), v) for k, v in response.getheaders()), body
    finally:
        connection.close()


def run(private=PRIVATE):
    runtime = module('home_assistant_runtime', 'home-assistant-runtime.py')
    backup = module('home_assistant_backup', 'home-assistant-backup.py')
    checks = []

    def check(name, condition):
        checks.append({'check': name, 'pass': bool(condition)})

    for name in ('owner.json', 'auth.json', 'bootstrap.json', 'backup-managed.json', 'backup-password'):
        backup.private_path(private/name)
        check('root-private ' + name, True)
    backup.private_path(private, directory=True)
    check('root-private runtime directory', True)
    address, bridge = runtime.owned_endpoint()
    check('owned VM has reserved LAN address', address == '192.168.1.211' and bridge == 'vmbr0')

    ca_path = private/'proxy-root.crt'
    der = ssl.PEM_cert_to_DER_cert(ca_path.read_text(encoding='ascii'))
    check('original Caddy root retained', hashlib.sha256(der).hexdigest().upper() == EXPECTED_CA)
    context = ssl.create_default_context(cafile=str(ca_path))
    status, headers, body = get(context, '/')
    check('HTTPS frontend and TLS hostname verification', status == 200)
    check('frontend document contains Home Assistant', b'home-assistant' in body.lower())
    status, headers, _ = get(context, '/', http=True)
    check('HTTP redirects to same HTTPS origin', status in (301, 302, 307, 308) and
          headers.get('location') in ('https://ha.home.arpa', 'https://ha.home.arpa/'))
    for path in ('/api/', '/api/config', '/api/states'):
        status, _, _ = get(context, path)
        check('anonymous denied ' + path, status == 401)

    client, token = runtime.authenticated_client(private)
    status, _, _ = get(context, '/api/', token)
    check('authenticated REST API works', status == 200)
    status, _, body = get(context, '/api/config', token)
    config = json.loads(body) if status == 200 else {}
    check('authenticated config is running', str(config.get('state')).upper() == 'RUNNING')
    check('London timezone', config.get('time_zone') == 'Europe/London')
    check('canonical local URL', config.get('internal_url') == 'https://ha.home.arpa')
    user = client.command('auth/current_user')
    check('authenticated WebSocket owner', user.get('is_owner') is True)
    check('owner is administrator', user.get('is_admin') is True)
    http_config = client.command('http/config')
    check('no pending proxy trial or revert timer', http_config.get('pending') is None and
          http_config.get('revert_at') is None)
    stable = http_config.get('stable') or {}
    check('backend native port 80', stable.get('server_port') == 80)
    check('forwarded client IP enabled', stable.get('use_x_forwarded_for') is True)
    check('only proxy is trusted', stable.get('trusted_proxies') == ['192.168.1.58/32'])
    try:
        # Before restart all onboarding routes may remain with completed states.
        steps = client.request('GET', '/api/onboarding')
        check('onboarding closed', isinstance(steps, list) and bool(steps) and
              all(step.get('done') is True for step in steps))
    except runtime.HTTPError as error:
        check('onboarding closed', error.status == 404)

    password = backup.load_password(private)
    native = backup.verify_configuration(client, password)
    check('daily encrypted complete native backup policy', backup.config_matches(native,
          backup.canonical(native, password)))
    check('next automatic backup scheduled', bool(native.get('next_automatic_backup')))
    status = client.command('backup/info')
    check('backup manager idle', status.get('state') == 'idle')
    check('backup agents healthy', not status.get('agent_errors'))
    successful = []
    for candidate in status.get('backups', []):
        try:
            backup.validate_backup_metadata(candidate)
            successful.append(candidate)
        except RuntimeError:
            pass
    check('at least one encrypted complete local backup', bool(successful))
    return {'checks': checks, 'passed': sum(c['pass'] for c in checks),
            'total': len(checks), 'all_passed': all(c['pass'] for c in checks),
            'read_only_scope': True, 'device_actions': False, 'visual_browser': False,
            'restore_tested': False, 'reboot_tested_by_this_script': False}


if __name__ == '__main__':
    try:
        result = run()
        print(json.dumps(result, sort_keys=True))
        raise SystemExit(0 if result['all_passed'] else 1)
    except Exception as error:
        print(json.dumps({'all_passed': False, 'error_type': type(error).__name__,
                          'error': 'Independent verification stopped; inspect private state locally'}))
        raise SystemExit(1)
