#!/usr/bin/env python3
"""Offline contract/security checks; no claim of live n8n acceptance."""
import importlib.util
import json
from pathlib import Path
import tempfile
import ssl
import unittest
from unittest.mock import patch
import sys

sys.dont_write_bytecode = True
SOURCE = Path(__file__).resolve().parents[1] / "deploy" / "n8n-bootstrap.py"
SPEC = importlib.util.spec_from_file_location("bootstrap", SOURCE)
app = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(app)


class Contracts(unittest.TestCase):
    def test_target_cannot_exfiltrate_owner(self):
        for target in ["https://example.com", "http://192.168.1.3:5678", "https://n8n.home.arpa.evil/",
                       "https://n8n.home.arpa/?x=1", "https://x@n8n.home.arpa", "https://n8n.home.arpa:444"]:
            with self.subTest(target=target), self.assertRaises(app.Failure):
                app.validate_target(target, "verify", str(SOURCE))

    def test_http_requires_exact_inspected_container_address(self):
        with patch.object(app, "docker_owned_ips", return_value={"172.18.0.9"}):
            self.assertEqual(app.validate_target("http://172.18.0.9:5678", "bootstrap"), "http://172.18.0.9:5678")
            for target in ["http://172.18.0.8:5678", "http://172.18.0.9:8080", "http://localhost:5678", "http://172.18.0.9:5678/path"]:
                with self.subTest(target=target), self.assertRaises(app.Failure):
                    app.validate_target(target, "bootstrap")

    def test_redirects_denied(self):
        self.assertIsNone(app.NoRedirect().redirect_request(None, None, 302, "redirect", {}, "https://example.com"))

    def test_pinned_address_guard_requires_fixed_https_host_and_ca(self):
        self.assertEqual(app.validate_target("https://n8n.home.arpa", "verify", str(SOURCE), "192.168.1.58"), "https://n8n.home.arpa")
        for host, action, ca, address in [("https://n8n.home.arpa", "verify", str(SOURCE), "192.168.1.3"),
                                          ("https://n8n.home.arpa", "verify", None, "192.168.1.58"),
                                          ("http://172.18.0.9:5678", "bootstrap", None, "192.168.1.58"),
                                          ("https://example.com", "verify", str(SOURCE), "192.168.1.58")]:
            with self.subTest(host=host, address=address), self.assertRaises(app.Failure):
                app.validate_target(host, action, ca, address)

    def test_pinned_tls_dials_ip_but_validates_sni_hostname(self):
        context = ssl.create_default_context()
        connection = app.PinnedHTTPSConnection("n8n.home.arpa", connect_ip="192.168.1.58", context=context)
        sock = unittest.mock.MagicMock()
        with patch.object(app.socket, "create_connection", return_value=sock) as dial, patch.object(context, "wrap_socket", return_value=sock) as wrap:
            connection.connect()
        self.assertEqual(connection.host, "n8n.home.arpa")
        self.assertEqual(dial.call_args.args[0], ("192.168.1.58", 443))
        self.assertEqual(wrap.call_args.kwargs["server_hostname"], "n8n.home.arpa")
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)

    def test_pinned_transport_refuses_insecure_context_or_alternate_redirect_host(self):
        insecure = ssl._create_unverified_context()
        with self.assertRaises(app.Failure):
            app.PinnedHTTPSConnection("n8n.home.arpa", connect_ip="192.168.1.58", context=insecure)
        handler = app.PinnedHTTPSHandler(ssl.create_default_context(), "192.168.1.58")
        with self.assertRaises(app.Failure):
            handler.https_open(app.urllib.request.Request("https://example.com/"))

    def test_private_owner_repeat_and_identity_guard(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            self.assertEqual(app.prepare(path, {"email": "fixture@example.invalid"}), "prepared")
            before = (path / "owner.json").read_bytes()
            self.assertEqual(app.prepare(path, {"email": "fixture@example.invalid"}), "preserved")
            self.assertEqual(before, (path / "owner.json").read_bytes())
            owner = app.read_private(path / "owner.json")
            self.assertGreaterEqual(len(owner["password"]), 40)
            with self.assertRaises(app.Failure):
                app.prepare(path, {"email": "different@example.invalid"})

    def test_flatted_result(self):
        data = '[{"resultData":"1"},{"runData":"2"},{"Code":"3"},["4"],{"data":"5"},{"main":"6"},["7"],["8"],{"json":"9"},{"answer":42,"probe":"10"},"homelab-n8n-acceptance"]'
        result = app.unflatten(data)
        self.assertEqual(result["resultData"]["runData"]["Code"][0]["data"]["main"][0][0]["json"]["answer"], 42)

    def test_existing_owner_is_never_overwritten(self):
        class Existing:
            cookie = ""
            def request(self, method, path, payload=None, **kwargs):
                if path == "/rest/settings":
                    return {"userManagement": {"showSetupOnFirstLoad": False}}
                raise app.Failure("Existing credentials do not match")
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(app.Failure):
                app.bootstrap(Existing(), Path(folder), {"email": "fixture@example.invalid", "password": "unused"})
            self.assertFalse((Path(folder) / "bootstrap.json").exists())

    def test_owner_role_required(self):
        with self.assertRaises(app.Failure):
            app.check_identity({"id": "fixture", "email": "fixture@example.invalid", "role": "global:member"},
                               {"email": "fixture@example.invalid"})

    def test_workflow_cleanup_when_code_fails(self):
        class Fixture:
            def __init__(self):
                self.created = None
                self.cleaned = False
            def request(self, method, path, payload=None, **kwargs):
                if method == "POST" and path == "/rest/workflows":
                    self.created = dict(payload, id="fixture-only", active=False)
                    return self.created
                if path.endswith("/run"):
                    return {"executionId": "fixture-execution"}
                if path.startswith("/rest/executions/"):
                    return {"status": "error"}
                if path.endswith("/archive"):
                    return {}
                if method == "DELETE":
                    self.cleaned = True
                    return True
                if method == "GET":
                    return None if self.cleaned else self.created
                raise AssertionError("Unexpected fixture request")
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            app.write_private(path / "bootstrap.json", {"schema": "n8n-owner-v1", "owner_id": "fixture"})
            client = Fixture()
            with self.assertRaises(app.Failure):
                app.synthetic_workflow(client, path)
            self.assertTrue(client.cleaned)
            self.assertNotIn("active_probe", app.read_private(path / "bootstrap.json"))


if __name__ == "__main__":
    unittest.main()
