#!/usr/bin/env python3
"""HTTP protocol and idempotence fixtures; no real accounts or Docker changes."""
import contextlib
import importlib.util
import io
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
import unittest
from unittest.mock import patch
import sys
import urllib.error
import urllib.parse

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('vaultwarden_runtime', ROOT / 'scripts/deploy/vaultwarden-runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)

class Handler(BaseHTTPRequestHandler):
    records = {}
    invitations = 0
    fixture_token = 'synthetic-test-admin-input'
    def log_message(self, *args):
        pass
    def reply(self, code, body, cookie=False):
        self.send_response(code)
        if cookie:
            self.send_header('Set-Cookie', 'VW_ADMIN=synthetic-session; HttpOnly; Path=/admin; SameSite=Strict')
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())
    def authorized(self):
        return self.headers.get('Cookie') == 'VW_ADMIN=synthetic-session'
    def do_POST(self):
        content = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.path == '/admin/':
            form = urllib.parse.parse_qs(content.decode())
            if form.get('token') == [self.fixture_token]:
                self.reply(200, {}, cookie=True)
            else:
                self.reply(401, {})
        elif self.path == '/admin/invite' and self.authorized():
            data = json.loads(content)
            email = data['email']
            if email in type(self).records:
                self.reply(409, {})
            else:
                type(self).invitations += 1
                type(self).records[email] = {'email': email, '_status': 1}
                self.reply(200, type(self).records[email])
        else:
            self.reply(401, {})
    def do_GET(self):
        if not self.authorized():
            self.reply(401, {})
        elif self.path == '/admin/users':
            self.reply(200, list(type(self).records.values()))
        elif self.path.startswith('/admin/users/by-mail/'):
            email = urllib.parse.unquote(self.path.rsplit('/', 1)[1])
            self.reply(200, type(self).records[email]) if email in type(self).records else self.reply(404, {})
        else:
            self.reply(404, {})

class RuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.worker = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.worker.start()
        cls.base = 'http://127.0.0.1:' + str(cls.server.server_port)
    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.worker.join(timeout=2)
    def setUp(self):
        Handler.records = {}
        Handler.invitations = 0
    def test_real_http_cookie_authentication(self):
        opener, base = runtime.connect_admin(self.base, Handler.fixture_token)
        self.assertEqual(base, self.base)
        with opener.open(base + '/admin/users', timeout=2) as response:
            self.assertEqual(json.load(response), [])
    def test_bad_admin_authentication_rejected(self):
        with self.assertRaises(urllib.error.HTTPError) as error:
            runtime.connect_admin(self.base, 'wrong-synthetic-input')
        self.assertEqual(error.exception.code, 401)
    def test_owner_invite_repeat_preserves_record_and_hides_private_input(self):
        session = runtime.connect_admin(self.base, Handler.fixture_token)
        output = io.StringIO()
        with patch.object(runtime, 'admin_session', return_value=session), contextlib.redirect_stdout(output):
            runtime.invite('fixture', {'email': 'Owner@Example.Test'})
            original = dict(Handler.records['owner@example.test'])
            runtime.invite('fixture', {'email': 'Owner@Example.Test'})
        self.assertEqual(Handler.invitations, 1)
        self.assertEqual(Handler.records['owner@example.test'], original)
        self.assertNotIn('owner@example.test', output.getvalue().lower())
        self.assertNotIn(Handler.fixture_token, output.getvalue())
    def test_existing_registered_owner_not_reinvited(self):
        Handler.records['owner@example.test'] = {'email': 'owner@example.test', '_status': 0}
        session = runtime.connect_admin(self.base, Handler.fixture_token)
        with patch.object(runtime, 'admin_session', return_value=session), contextlib.redirect_stdout(io.StringIO()):
            runtime.invite('fixture', {'email': 'owner@example.test'})
        self.assertEqual(Handler.invitations, 0)
        self.assertEqual(Handler.records['owner@example.test']['_status'], 0)
    def test_unexpected_owner_shape_refused_before_auth(self):
        with patch.object(runtime, 'admin_session') as authenticate:
            with self.assertRaises(RuntimeError):
                runtime.invite('fixture', {'email': 'owner@example.test', 'password': 'synthetic'})
            authenticate.assert_not_called()
    def test_malformed_owner_refused_before_auth(self):
        with patch.object(runtime, 'admin_session') as authenticate:
            with self.assertRaises(RuntimeError):
                runtime.invite('fixture', {'email': 'not an email'})
            authenticate.assert_not_called()
    def test_raw_phc_dollars_are_preserved(self):
        encoded = '$argon2id$v=19$m=65540,t=3,p=4$c2FsdA$aGFzaA'
        self.assertEqual(runtime.parse_env('ADMIN_TOKEN=' + encoded)['ADMIN_TOKEN'], encoded)
    def test_duplicate_environment_rejected(self):
        with self.assertRaises(RuntimeError):
            runtime.parse_env('SIGNUPS_ALLOWED=false\nSIGNUPS_ALLOWED=true')
    def test_closed_signup_and_no_smtp_policy(self):
        self.assertEqual(runtime.SETTINGS['SIGNUPS_ALLOWED'], 'false')
        self.assertEqual(runtime.SETTINGS['INVITATIONS_ALLOWED'], 'false')
        self.assertEqual(runtime.SETTINGS['SIGNUPS_VERIFY'], 'false')
        self.assertFalse(any(key.startswith('SMTP_') for key in runtime.SETTINGS))
    def test_compose_persistent_private_network_contract(self):
        compose = json.loads((ROOT / 'configs/docker/vaultwarden/compose.json').read_text())
        service = compose['services']['vaultwarden']
        self.assertNotIn('ports', service)
        self.assertEqual(service['env_file'][0]['format'], 'raw')
        self.assertEqual(set(service['networks']), {'proxy'})
        self.assertEqual(compose['networks']['proxy'], {'external': True, 'name': 'homelab-proxy_default'})
        self.assertEqual(compose['volumes']['data'], {'external': True, 'name': 'homelab-vaultwarden-data'})
        self.assertNotIn('/var/run/docker.sock', json.dumps(compose))

if __name__ == '__main__':
    unittest.main(verbosity=1)
