#!/usr/bin/env python3
"""Bootstrap the managed Homarr v2.10.1 through its real HTTP onboarding API.

Run before attaching the public proxy route. No direct database mutation, Docker
socket exposure, secret command arguments, API-key creation or response logging.
"""
import argparse
import hashlib
import http.cookiejar
import ipaddress
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

sys.dont_write_bytecode = True
PRIVATE = Path('/etc/homelab/homarr')
BOARD_NAME = 'homelab'


class Refused(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Refused(message)


def private_json(path, value=None):
    if value is not None:
        data = (json.dumps(value, separators=(',', ':')) + '\n').encode()
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o600,
            'Private bootstrap file ownership or mode differs')
    return json.loads(path.read_text())


def replace_private(path, value):
    temp = path.with_name(path.name + '.new')
    require(not temp.exists() and not temp.is_symlink(), 'Private transaction file already exists')
    private_json(temp, value)
    os.replace(temp, path)


def services_from(path):
    services = json.loads(path.read_text())
    expected = {'pve01', 'pve02', 'pihole01', 'pihole02', 'uptime', 'vault', 'grafana'}
    require(isinstance(services, list) and len(services) == 7, 'Exactly seven service links are required')
    hosts = set()
    ids = set()
    for app in services:
        require(set(app) == {'name', 'href', 'sourceId', 'iconUrl'}, 'Unexpected service fields')
        require(isinstance(app['name'], str) and 1 <= len(app['name']) <= 127, 'Invalid service name')
        require(re.fullmatch(r'homelab-[a-z0-9-]+', app['sourceId']) is not None, 'Invalid source ID')
        url = urllib.parse.urlsplit(app['href'])
        require(url.scheme == 'https' and url.hostname and url.port is None and not url.username and not url.password
                and not url.query and not url.fragment, 'Invalid service URL')
        require(url.hostname.endswith('.home.arpa'), 'Service must use the project domain')
        hosts.add(url.hostname.removesuffix('.home.arpa'))
        ids.add(app['sourceId'])
        require(app['iconUrl'] == '/favicon.ico', 'Initial board uses its bundled local icon')
    require(hosts == expected and len(ids) == 7, 'Service hostnames or IDs differ')
    return services


def inspect_address(container):
    require(re.fullmatch(r'[a-f0-9]{12,64}', container) is not None, 'Use a Docker container ID')
    result = subprocess.run(['docker', 'inspect', container], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=20, check=False)
    require(result.returncode == 0, 'Managed container inspection failed')
    try:
        record = json.loads(result.stdout)[0]
        labels = record['Config']['Labels']
        require(labels.get('com.docker.compose.project') == 'homelab-homarr'
                and labels.get('com.docker.compose.service') == 'homarr'
                and labels.get('io.homelab.managed') == 'homarr-v1', 'Container ownership differs')
        require(record['State']['Running'], 'Managed container is not running')
        require(not record['HostConfig'].get('PortBindings'), 'Homarr must have no published ports')
        mounts = record.get('Mounts', [])
        require(not any('docker.sock' in m.get('Source', '') or 'docker.sock' in m.get('Destination', '')
                        for m in mounts), 'Homarr must not mount a Docker socket')
        address = record['NetworkSettings']['Networks']['homelab-proxy_default']['IPAddress']
        require(ipaddress.ip_address(address).is_private, 'Backend address is not private')
    except (KeyError, IndexError, ValueError, TypeError) as exc:
        raise Refused('Managed container inspection format differs') from exc
    return f'http://{address}:7575'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, base):
        self.base = base
        # Only the inspected same-host Docker address is reachable by this
        # client. Auth.js may set Secure cookies from canonical BASE_URL even
        # though this private pre-proxy bootstrap uses plain HTTP.
        policy = http.cookiejar.DefaultCookiePolicy(secure_protocols=('http', 'https'))
        self.jar = http.cookiejar.CookieJar(policy)
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                                  urllib.request.HTTPCookieProcessor(self.jar), NoRedirect())

    def request(self, path, value=None, method='GET', form=False):
        require(path.startswith('/') and not path.startswith('//'), 'Invalid API path')
        headers = {'Accept': 'application/json', 'Origin': self.base,
                   'Sec-Fetch-Site': 'same-origin', 'X-TRPC-Source': 'homelab-bootstrap'}
        data = None
        if value is not None:
            data = (urllib.parse.urlencode(value) if form else json.dumps(value)).encode()
            headers['Content-Type'] = 'application/x-www-form-urlencoded' if form else 'application/json'
            if form:
                headers['X-Auth-Return-Redirect'] = '1'
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with self.opener.open(req, timeout=45) as response:
                raw = response.read(2 * 1024 * 1024 + 1)
                require(len(raw) <= 2 * 1024 * 1024, 'API response too large')
                return response.status, json.loads(raw) if raw else None
        except urllib.error.HTTPError as exc:
            # Do not expose URL, response bodies, headers, cookies or errors.
            return exc.code, None
        except (urllib.error.URLError, TimeoutError, ValueError) as exc:
            raise Refused('Homarr API transport failed') from exc

    def rpc(self, procedure, value=None, mutation=False):
        path = '/api/trpc/' + procedure
        payload = {'json': value} if value is not None else {'json': None, 'meta': {'values': ['undefined'], 'v': 1}}
        if mutation:
            status, body = self.request(path, payload, 'POST')
        else:
            status, body = self.request(path + '?' + urllib.parse.urlencode({'input': json.dumps(payload)}))
        require(status == 200 and isinstance(body, dict) and 'error' not in body, 'Homarr API operation refused')
        try:
            return body['result']['data']['json']
        except (KeyError, TypeError) as exc:
            raise Refused('Homarr API response shape differs') from exc

    def login(self, admin):
        status, body = self.request('/api/auth/csrf')
        require(status == 200 and isinstance(body, dict) and isinstance(body.get('csrfToken'), str),
                'Authentication challenge unavailable')
        status, body = self.request('/api/auth/callback/credentials', {
            'csrfToken': body['csrfToken'], 'name': admin['username'], 'password': admin['password'],
            'callbackUrl': self.base + '/', 'redirect': 'false', 'json': 'true',
        }, 'POST', form=True)
        # Auth.js can return a 302; follow no redirects and inspect the actual
        # session instead. Wrong credentials must never produce a user session.
        require(status in (200, 302, 303, 401), 'Authentication request failed')
        status, session = self.request('/api/auth/session')
        return status == 200 and isinstance(session, dict) and isinstance(session.get('user'), dict) \
            and session['user'].get('name') == admin['username'] \
            and 'admin' in session['user'].get('permissions', [])


def current_step(client):
    result = client.rpc('onboard.currentStep')
    require(isinstance(result, dict) and result.get('current') in ('start', 'user', 'setup', 'finish'),
            'Unsupported onboarding state')
    return result['current']


def bootstrap(client, services, private=PRIVATE, client_factory=Client):
    info = private.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o700,
            'Private runtime directory ownership or mode differs')
    admin_path, state_path = private / 'admin.json', private / 'bootstrap.json'
    step = current_step(client)
    digest = hashlib.sha256(json.dumps(services, sort_keys=True).encode()).hexdigest()
    if not admin_path.exists() and not state_path.exists():
        require(step == 'start', 'Existing Homarr state is not owned by this bootstrap')
        # State first: interrupted credential creation is refused, never reset.
        private_json(state_path, {'version': 1, 'phase': 'prepared', 'services_sha256': digest})
        private_json(admin_path, {'username': 'merin', 'password': secrets.token_urlsafe(36)})
    admin = private_json(admin_path)
    state = private_json(state_path)
    require(set(admin) == {'username', 'password'} and admin['username'] == 'merin'
            and isinstance(admin['password'], str) and len(admin['password']) >= 32, 'Private admin input differs')
    require(state.get('version') == 1 and state.get('services_sha256') == digest
            and state.get('phase') in ('prepared', 'finished'), 'Bootstrap provenance differs')
    if step in ('start', 'user'):
        require(state['phase'] == 'prepared', 'Finished bootstrap cannot recreate an account')
        status, body = client.request('/api/onboarding/claim', {}, 'POST')
        require(status == 200 and isinstance(body, dict) and body.get('status') in ('issued', 'active'),
                'Onboarding could not be claimed')
        if step == 'start':
            client.rpc('onboard.nextStep', mutation=True)
            require(current_step(client) == 'user', 'Initial administrator step differs')
        client.rpc('user.initUser', {'username': admin['username'], 'password': admin['password'],
                                    'confirmPassword': admin['password']}, mutation=True)
    require(client.login(admin), 'Managed administrator authentication failed')
    step = current_step(client)
    if step == 'setup':
        require(state['phase'] == 'prepared', 'Finished bootstrap cannot replace a board')
        existing = client.rpc('board.getAllBoards')
        require(isinstance(existing, list) and (not existing or (len(existing) == 1
                and existing[0].get('name') == 'dashboard' and existing[0].get('creator') is None)),
                'Unknown boards already exist; preserve and review')
        payload = {
            'server': {'defaultLocale': 'en-gb', 'defaultColorScheme': 'dark', 'analyticsEnabled': False},
            'board': {'name': BOARD_NAME, 'primaryColor': '#228be6', 'secondaryColor': '#15aabf',
                      'itemRadius': 'lg', 'layoutPreset': 'balanced', 'columnCount': 10,
                      'leftSidebar': False, 'rightSidebar': False},
            'apps': services, 'integrations': [], 'selectedAppIds': [], 'selectedIntegrationIds': [],
            'selectedDockerSourceIds': [], 'selectedWidgetKinds': [],
        }
        result = client.rpc('onboard.completeSetup', payload, mutation=True)
        require(isinstance(result, dict) and result.get('boardName') == BOARD_NAME
                and isinstance(result.get('boardId'), str), 'Created board response differs')
        state.update(phase='finished', board_id=result['boardId'])
        replace_private(state_path, state)
    require(current_step(client) == 'finish', 'Onboarding is incomplete')
    board = client.rpc('board.getBoardByName', {'name': BOARD_NAME})
    require(board.get('id') == state.get('board_id') and board.get('name') == BOARD_NAME,
            'Board ownership differs')
    board = remove_initial_seed_items(client, board, services, state)
    verify_links(client, board, services, allow_additional=state.get('board_verified') is True)
    if not board.get('isPublic'):
        client.rpc('board.changeBoardVisibility', {'id': board['id'], 'visibility': 'public'}, mutation=True)
    anonymous = client_factory(client.base)
    public_board = anonymous.rpc('board.getBoardByName', {'name': BOARD_NAME})
    require(public_board.get('id') == board['id'] and public_board.get('isPublic') is True,
            'Read-only public board unavailable')
    verify_links(anonymous, public_board, services, allow_additional=state.get('board_verified') is True)
    status, _ = anonymous.request('/api/onboarding/claim', {}, 'POST')
    require(status in (403, 409), 'Finished onboarding is claimable')
    require_denied(anonymous, 'board.changeBoardVisibility', {'id': board['id'], 'visibility': 'public'})
    wrong = client_factory(client.base)
    require(not wrong.login({'username': admin['username'], 'password': secrets.token_urlsafe(36)}),
            'Incorrect password accepted')
    if not state.get('board_verified'):
        state['board_verified'] = True
        replace_private(state_path, state)
    print('PASS Homarr administrator, completed onboarding, seven original public service links, denied writes and wrong password')


def remove_initial_seed_items(client, board, services, state):
    """Remove the exact v2.10.1 first-start example items once, through editor API.

    Homarr seeds a default board before onboarding; completeSetup retains its
    four example app cards and clock/weather/bookmarks, then adds our seven.
    Never prune a board after successful verification or public activation.
    """
    entries = board.get('items', [])
    # A verified board belongs to its user. Later apps/widgets are never seed
    # cleanup candidates; original service provenance is checked separately.
    if state.get('board_verified') is True:
        return board
    if len(entries) == 7:
        return board
    require(state.get('phase') == 'finished' and not state.get('board_verified')
            and board.get('id') == state.get('board_id') and board.get('name') == BOARD_NAME
            and board.get('isPublic') is False and len(entries) == 14,
            'Unexpected board content; refusing initial example cleanup')
    sections = board.get('sections', [])
    require(len(sections) == 1 and sections[0].get('kind') == 'empty'
            and sections[0].get('xOffset') == 0 and sections[0].get('yOffset') == 0,
            'Initial board sections differ')
    our_ids = {'onboarding_app_' + hashlib.sha256(app['sourceId'].encode()).hexdigest()[:32]
               for app in services}
    app_items = [item for item in entries if item.get('kind') == 'app']
    require(len(app_items) == 11, 'Initial example app count differs')
    all_ids = [item.get('options', {}).get('appId') for item in app_items]
    require(all(isinstance(app_id, str) for app_id in all_ids) and len(set(all_ids)) == 11
            and our_ids.issubset(all_ids), 'Initial app provenance differs')
    rows = client.rpc('app.byIds', all_ids)
    seed_pairs = {
        ('Homarr Docs', 'https://homarr.dev/docs/getting-started'),
        ('Homarr GitHub', 'https://github.com/homarr-labs/homarr'),
        ('Help Translate', 'https://homarr.dev/docs/community/translations'),
        ('Support Homarr', 'https://opencollective.com/homarr'),
    }
    seed_ids = set(all_ids) - our_ids
    require(len(rows) == 11 and len(seed_ids) == 4
            and {(row['name'], row['href']) for row in rows if row.get('id') in seed_ids} == seed_pairs
            and {(row['name'], row['href']) for row in rows if row.get('id') in our_ids}
                == {(app['name'], app['href']) for app in services}, 'Initial example service links differ')
    keep = [item for item in app_items if item['options']['appId'] in our_ids]
    extras = [item for item in entries if item not in keep]
    require(len(keep) == 7 and len(extras) == 7, 'Initial cleanup scope differs')
    widgets = [item for item in extras if item.get('kind') != 'app']
    require(len(widgets) == 3 and {item.get('kind') for item in widgets} == {'clock', 'weather', 'bookmarks'},
            'Initial example widget types differ')
    advanced = {'title': None, 'customCssClasses': [], 'borderColor': ''}
    for item in extras:
        require(item.get('integrationIds') == [] and item.get('advancedOptions') == advanced,
                'Customized example item must be preserved')
        positions = item.get('layouts', [])
        require(len(positions) == 2, 'Initial example item layouts differ')
        kind, options = item.get('kind'), item.get('options')
        expected_size = (1, 1) if kind == 'app' else (2, 2) if kind == 'bookmarks' else (2, 1)
        require(all((position.get('width'), position.get('height')) == expected_size for position in positions),
                'Resized example item must be preserved')
        if kind == 'app':
            require(options == {'appId': options.get('appId'), 'openIn': 'newTab', 'showTitle': True},
                    'Customized example app must be preserved')
        elif kind == 'clock':
            require(options == {}, 'Customized clock must be preserved')
        elif kind == 'weather':
            require(options == {'showHumidity': False, 'showCity': False, 'hasForecast': False},
                    'Customized weather must be preserved')
        elif kind == 'bookmarks':
            require(isinstance(options, dict) and set(options) == {'title', 'layout', 'openNewTab', 'items'}
                    and options['title'] == 'Useful Links' and options['layout'] == 'grid'
                    and options['openNewTab'] is True and len(options['items']) == 4
                    and set(options['items']) == seed_ids, 'Customized bookmarks must be preserved')
    # Keep all sections and each retained item's options/IDs/layouts unchanged.
    client.rpc('board.saveBoard', {'id': board['id'], 'sections': sections, 'items': keep}, mutation=True)
    cleaned = client.rpc('board.getBoardByName', {'name': BOARD_NAME})
    require(cleaned.get('id') == board['id'], 'Board identity changed during cleanup')
    verify_links(client, cleaned, services)
    return cleaned


def require_denied(client, procedure, payload):
    status, body = client.request('/api/trpc/' + procedure, {'json': payload}, 'POST')
    error_code = (body or {}).get('error', {}).get('json', {}).get('data', {}).get('code') if isinstance(body, dict) else None
    require(status in (401, 403) or error_code in ('UNAUTHORIZED', 'FORBIDDEN'),
            'Anonymous configuration write was accepted')


def verify_links(client, board, services, allow_additional=False):
    items = board.get('items', [])
    if allow_additional:
        original = {'onboarding_app_' + hashlib.sha256(app['sourceId'].encode()).hexdigest()[:32]: app
                    for app in services}
        original_cards = [item for item in items if item.get('kind') == 'app'
                          and item.get('options', {}).get('appId') in original]
        ids = [item['options']['appId'] for item in original_cards]
        require(len(original) == 7 and len(ids) == 7 and len(set(ids)) == 7,
                'Original service card provenance differs')
        rows = client.rpc('app.byIds', ids)
        require(len(rows) == 7 and len({row.get('id') for row in rows}) == 7
                and all(row.get('id') in original
                        and row.get('name') == original[row['id']]['name']
                        and row.get('href') == original[row['id']]['href'] for row in rows),
                'Original persisted service links differ')
        return
    require(len(items) == 7 and all(item.get('kind') == 'app' for item in items), 'Board content differs')
    app_ids = [item.get('options', {}).get('appId') for item in items]
    require(all(isinstance(app_id, str) for app_id in app_ids) and len(set(app_ids)) == 7, 'Board app IDs differ')
    rows = client.rpc('app.byIds', app_ids)
    actual = {(row['name'], row['href']) for row in rows}
    desired = {(row['name'], row['href']) for row in services}
    require(len(rows) == 7 and actual == desired, 'Persisted service links differ')


def main():
    import fcntl
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', required=True)
    parser.add_argument('--services', type=Path, required=True)
    args = parser.parse_args()
    require(os.geteuid() == 0, 'Run as root inside the managed app guest')
    services = services_from(args.services)
    lock_path = Path('/var/lib/homelab/homarr-bootstrap.lock')
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        bootstrap(Client(inspect_address(args.container)), services)


if __name__ == '__main__':
    try:
        main()
    except Refused as error:
        # Deliberate Refused strings contain only fixed public phase labels.
        print('ERROR Homarr bootstrap: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        # Exception detail can include secret payloads or HTTP response data.
        print('ERROR Homarr bootstrap refused; inspect ownership/state privately', file=sys.stderr)
        raise SystemExit(1)
