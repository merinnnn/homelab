#!/usr/bin/env python3
"""Offline bootstrap state-machine and transport tests; no live service mutation."""
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('homarr_bootstrap', ROOT / 'scripts/deploy/bootstrap-homarr.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
SERVICES = h.services_from(ROOT / 'configs/docker/homarr/services.json')


class FakePath:
    def __init__(self, name, files):
        self.name, self.files = name, files
    def exists(self):
        return self.name in self.files


class Private:
    def __init__(self):
        self.files = {}
    def lstat(self):
        return types.SimpleNamespace(st_mode=0o40700, st_uid=0)
    def __truediv__(self, name):
        return FakePath(name, self.files)


def storage(path, value=None):
    if value is not None:
        if path.exists():
            raise h.Refused('Exists')
        path.files[path.name] = copy.deepcopy(value)
    if not path.exists():
        raise h.Refused('Missing private file')
    return copy.deepcopy(path.files[path.name])


def replace(path, value):
    path.files[path.name] = copy.deepcopy(value)


class FakeClient:
    def __init__(self, base='http://172.18.0.4:7575', server=None):
        self.base = base
        self.server = server if server is not None else {'step': 'start', 'admin': None, 'board': None, 'calls': []}
        self.logged_in = False
        self.claimed = False
    def factory(self, base):
        return FakeClient(base, self.server)
    def request(self, path, value=None, method='GET', form=False):
        self.server['calls'].append((method, path))
        if path == '/api/onboarding/claim':
            if self.server['step'] == 'finish':
                return 409, None
            self.claimed = True
            return 200, {'status': 'issued'}
        if path.startswith('/api/trpc/') and not self.logged_in:
            return 401, None
        raise AssertionError('Unexpected request')
    def login(self, admin):
        self.server['calls'].append(('LOGIN', admin['username']))
        self.logged_in = admin == self.server['admin']
        return self.logged_in
    def rpc(self, method, value=None, mutation=False):
        self.server['calls'].append(('MUTATE' if mutation else 'QUERY', method))
        if method == 'onboard.currentStep':
            return {'current': self.server['step']}
        if method == 'onboard.nextStep':
            if not self.claimed:
                raise AssertionError('Missing claim')
            self.server['step'] = 'user'
        elif method == 'user.initUser':
            if not self.claimed or self.server['step'] != 'user':
                raise AssertionError('Invalid initial admin flow')
            self.server['admin'] = {'username': value['username'], 'password': value['password']}
            self.server['step'] = 'setup'
        elif method == 'board.getAllBoards':
            if not self.logged_in:
                raise AssertionError('Unprotected setup')
            return self.server.get('foreign_boards', [])
        elif method == 'onboard.completeSetup':
            if not self.logged_in or self.server['step'] != 'setup':
                raise AssertionError('Invalid setup flow')
            assert value['server']['analyticsEnabled'] is False
            assert value['integrations'] == [] and value['selectedDockerSourceIds'] == []
            self.server['apps'] = copy.deepcopy(value['apps'])
            self.server['board'] = {'id': 'owned-board', 'name': 'homelab', 'isPublic': False,
                'items': [{'kind': 'app', 'options': {'appId': app['sourceId']}} for app in value['apps']]}
            self.server['step'] = 'finish'
            return {'boardId': 'owned-board', 'boardName': 'homelab'}
        elif method == 'board.getBoardByName':
            board = self.server['board']
            if not self.logged_in and not board['isPublic']:
                raise h.Refused('Private board')
            return copy.deepcopy(board)
        elif method == 'board.changeBoardVisibility':
            if not self.logged_in:
                raise AssertionError('Anonymous write')
            self.server['board']['isPublic'] = True
        elif method == 'app.byIds':
            return copy.deepcopy(self.server['apps'])
        else:
            raise AssertionError('Unexpected RPC')


class BootstrapTests(unittest.TestCase):
    def run_bootstrap(self, client, private):
        with patch.object(h, 'private_json', storage), patch.object(h, 'replace_private', replace), contextlib.redirect_stdout(io.StringIO()):
            h.bootstrap(client, SERVICES, private, client.factory)
    def test_fresh_claim_admin_login_board_and_public_readonly(self):
        c, p = FakeClient(), Private()
        self.run_bootstrap(c, p)
        self.assertEqual(c.server['step'], 'finish')
        self.assertTrue(c.server['board']['isPublic'])
        self.assertGreaterEqual(len(p.files['admin.json']['password']), 32)
        self.assertEqual(p.files['bootstrap.json']['board_id'], 'owned-board')
        self.assertLess(c.server['calls'].index(('MUTATE', 'user.initUser')),
                        c.server['calls'].index(('MUTATE', 'onboard.completeSetup')))
    def test_repeat_has_no_account_board_or_visibility_mutations(self):
        c, p = FakeClient(), Private()
        self.run_bootstrap(c, p)
        before = copy.deepcopy(p.files)
        c.server['calls'].clear()
        self.run_bootstrap(c.factory(c.base), p)
        self.assertEqual(p.files, before)
        self.assertFalse(any(kind == 'MUTATE' for kind, _ in c.server['calls']))
    def test_foreign_initialized_install_is_preserved(self):
        c, p = FakeClient(), Private()
        c.server['step'] = 'finish'
        with self.assertRaises(h.Refused):
            self.run_bootstrap(c, p)
        self.assertEqual(p.files, {})
    def test_foreign_board_refused_before_creation(self):
        c, p = FakeClient(), Private()
        c.server['foreign_boards'] = [{'name': 'someone-else', 'creator': {'id': 'x'}}]
        with self.assertRaises(h.Refused):
            self.run_bootstrap(c, p)
        self.assertIsNone(c.server['board'])
    def test_link_drift_refused(self):
        c, p = FakeClient(), Private()
        self.run_bootstrap(c, p)
        c.server['apps'][0]['href'] = 'https://unknown.home.arpa/'
        with self.assertRaises(h.Refused):
            self.run_bootstrap(c.factory(c.base), p)
    def test_source_schema_exact_hosts_and_local_icons(self):
        self.assertEqual(len(SERVICES), 7)
        self.assertTrue(all(app['iconUrl'] == '/favicon.ico' for app in SERVICES))
    def test_rpc_uses_superjson_undefined_for_void(self):
        c = h.Client('http://172.18.0.4:7575')
        seen = []
        def request(path, value=None, method='GET', form=False):
            seen.append(path)
            return 200, {'result': {'data': {'json': []}}}
        c.request = request
        c.rpc('board.getAllBoards')
        from urllib.parse import parse_qs, urlsplit
        value = json.loads(parse_qs(urlsplit(seen[0]).query)['input'][0])
        self.assertEqual(value['meta']['values'], ['undefined'])
    def test_non_owned_container_id_refused_before_docker(self):
        with self.assertRaises(h.Refused):
            h.inspect_address('homarr; unsafe')
    def test_anonymous_server_error_is_not_auth_denial(self):
        c = types.SimpleNamespace(request=lambda *args: (500, {'error': {}}))
        with self.assertRaises(h.Refused):
            h.require_denied(c, 'board.changeBoardVisibility', {})
    def test_failed_rpc_does_not_expose_response(self):
        c = h.Client('http://172.18.0.4:7575')
        c.request = lambda *args: (400, {'error': {'message': 'PRIVATE_SENTINEL'}})
        with self.assertRaises(h.Refused) as caught:
            c.rpc('user.initUser', {'password': 'PRIVATE_SENTINEL'}, True)
        self.assertNotIn('PRIVATE_SENTINEL', str(caught.exception))


if __name__ == '__main__':
    unittest.main(verbosity=2)
