"""Offline transport and ownership guards; no live devices or credentials."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / "deploy/home-assistant-runtime.py"
SPEC = importlib.util.spec_from_file_location("ha_runtime", PATH)
R = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(R)


class FakeSocket:
    def __init__(self, incoming=b""):
        self.incoming, self.sent, self.closed = bytearray(incoming), bytearray(), False

    def recv(self, size):
        result = self.incoming[:size]
        del self.incoming[:size]
        return bytes(result)

    def sendall(self, data):
        self.sent.extend(data)

    def close(self):
        self.closed = True


def frame(value, opcode=1, final=True):
    raw = json.dumps(value).encode() if isinstance(value, dict) else value
    first = opcode | (0x80 if final else 0)
    if len(raw) < 126:
        return bytes([first, len(raw)]) + raw
    return bytes([first, 126]) + struct.pack("!H", len(raw)) + raw


class TransportTests(unittest.TestCase):
    def client(self):
        with patch.object(R, "owned_endpoint", return_value=("10.0.10.50", "vmbr1")):
            return R.Client("http://10.0.10.50", token="synthetic-test-token")

    def test_http_must_match_qga_address(self):
        with patch.object(R, "owned_endpoint", return_value=("10.0.10.50", "vmbr1")):
            self.assertEqual(R.Client("http://10.0.10.50:80").connect_ip, "10.0.10.50")
            for url in ("http://10.0.10.51", "http://10.0.10.50:8123", "http://192.168.1.211", "http://10.0.10.50/path", "http://bad@10.0.10.50", "http://10.0.10.50#foo"):
                with self.subTest(url=url), self.assertRaises(R.SafeError):
                    R.Client(url)

    def test_https_host_and_dial_ip_fixed(self):
        with patch.object(R.ssl, "create_default_context") as ctx:
            self.assertEqual(R.Client(R.ORIGIN).connect_ip, "192.168.1.58")
            ctx.assert_called_once()
        for url in ("https://evil.example", "https://ha.home.arpa:444", "https://ha.home.arpa/path", "https://ha.home.arpa?x=y"):
            with self.subTest(url=url), self.assertRaises(R.SafeError):
                R.Client(url)
        with self.assertRaises(R.SafeError):
            R.Client(R.ORIGIN, connect_ip="192.168.1.2")

    def test_https_preserves_sni_and_ca_checks(self):
        context = unittest.mock.Mock()
        sock = object()
        with patch.object(R.socket, "create_connection", return_value=sock) as dial:
            connection = R.FixedHTTPS("ha.home.arpa", "192.168.1.58", context)
            connection.connect()
        dial.assert_called_once_with(("192.168.1.58", 443), 40)
        context.wrap_socket.assert_called_once_with(sock, server_hostname="ha.home.arpa")

    def test_relative_api_paths(self):
        for path in ("https://evil.example", "//evil.example/a", "/api/\r\nEvil: x"):
            with self.assertRaises(R.SafeError):
                R.Client.path(path)
        self.assertEqual(R.Client.path("/api/config"), "/api/config")

    def test_http_redirect_never_followed_or_body_exposed(self):
        client = self.client()
        connection = unittest.mock.Mock()
        response = connection.getresponse.return_value
        response.status = 302
        with patch.object(client, "connection", return_value=connection):
            with self.assertRaises(R.HTTPError) as error:
                client.request("POST", "/auth/token", {"code": "private-synthetic"})
        self.assertNotIn("private-synthetic", str(error.exception))
        response.read.assert_not_called()
        self.assertEqual(connection.request.call_count, 1)
        connection.close.assert_called_once()

    def test_json_size_bounded(self):
        client = self.client()
        connection = unittest.mock.Mock()
        response = connection.getresponse.return_value
        response.status = 200
        response.read.return_value = b"x" * 33
        with patch.object(client, "connection", return_value=connection), patch.object(R, "MAX_RESPONSE", 32):
            with self.assertRaises(R.SafeError):
                client.request("GET", "/api/config")
        response.read.assert_called_once_with(33)

    def test_websocket_masked_outgoing(self):
        ws = R.WebSocket(self.client(), "test-token")
        ws.sock = FakeSocket()
        ws.send({"test": 42})
        wire = ws.sock.sent
        self.assertEqual(wire[0], 0x81)
        self.assertTrue(wire[1] & 0x80)
        size, mask = wire[1] & 0x7f, wire[2:6]
        raw = bytes(c ^ mask[i % 4] for i, c in enumerate(wire[6:]))
        self.assertEqual(len(raw), size)
        self.assertEqual(json.loads(raw), {"test": 42})

    def test_fragmentation_and_ping(self):
        ws = R.WebSocket(self.client(), "test-token")
        ws.sock = FakeSocket(frame(b'{"value":', final=False) + frame(b"ping", opcode=9) + frame(b"42}", opcode=0))
        self.assertEqual(ws.receive(), {"value": 42})
        self.assertEqual(ws.sock.sent[0], 0x8a)

    def test_server_mask_or_bad_fragments_rejected(self):
        for wire in (b"\x81\x80", frame(b"{}", opcode=0), frame(b"x", opcode=9, final=False)):
            ws = R.WebSocket(self.client(), "test-token")
            ws.sock = FakeSocket(wire)
            with self.assertRaises(R.SafeError):
                ws.receive()

    def test_websocket_auth_handshake_and_command(self):
        key_raw = b"x" * 16
        key = base64.b64encode(key_raw).decode()
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        incoming = ("HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode()
        incoming += frame({"type": "auth_required"}) + frame({"type": "auth_ok"})
        incoming += frame({"id": 1, "type": "result", "success": True, "result": {"is_owner": True}})
        sock = FakeSocket(incoming)
        with patch.object(R.socket, "create_connection", return_value=sock), patch.object(R.secrets, "token_bytes", side_effect=lambda n: key_raw if n == 16 else b"y" * n):
            with self.client().websocket() as ws:
                self.assertEqual(ws.call("auth/current_user"), {"is_owner": True})
        self.assertTrue(sock.closed)

    def test_invalid_websocket_accept_closes(self):
        sock = FakeSocket(b"HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: invalid\r\n\r\n")
        with patch.object(R.socket, "create_connection", return_value=sock):
            with self.assertRaises(R.SafeError):
                with self.client().websocket():
                    pass
        self.assertTrue(sock.closed)

    def test_remote_error_redacted(self):
        ws = R.WebSocket(self.client(), "test-token")
        ws.sock = FakeSocket(frame({"id": 1, "type": "result", "success": False, "error": {"code": "failed", "message": "private-synthetic-secret"}}))
        with self.assertRaises(R.SafeError) as error:
            ws.call("backup/config/update")
        self.assertNotIn("private-synthetic", str(error.exception))

    def test_backup_query_password_rejected_before_file_io(self):
        with self.assertRaises(R.SafeError):
            self.client().download("/api/backup/download/id?password=synthetic", Path("ignored"))


class OwnershipTests(unittest.TestCase):
    def manifest(self, bridge="vmbr1"):
        return {"marker": R.MARKER, "node": "pve01", "vmid": 102, "mac": R.MAC,
                "phase": "complete", "bridge": bridge, "scsi0": "local-lvm:vm-102-disk-1,size=32G",
                "efidisk0": "local-lvm:vm-102-disk-0,efitype=4m,pre-enrolled-keys=0,size=4M"}

    def config(self, bridge="vmbr1"):
        m = self.manifest(bridge)
        return {"name": "ha01", "net0": "virtio=" + R.MAC + ",bridge=" + bridge,
                "scsi0": m["scsi0"], "efidisk0": m["efidisk0"]}

    def interfaces(self, ip="10.0.10.50", mac=R.MAC):
        return [{"hardware-address": mac.lower(), "ip-addresses": [{"ip-address-type": "ipv4", "ip-address": ip}]}]

    def check(self, manifest=None, config=None, interfaces=None):
        with patch.object(R.os, "name", "posix"), patch.object(R.os, "geteuid", return_value=0, create=True), patch.object(R.socket, "gethostname", return_value="pve01"), patch.object(R, "read_private", return_value=manifest or self.manifest()), patch.object(R, "run_json", side_effect=[config or self.config(), interfaces or self.interfaces()]):
            return R.owned_endpoint()

    def test_owned_private_endpoint(self):
        self.assertEqual(self.check(), ("10.0.10.50", "vmbr1"))

    def test_owned_lan_endpoint(self):
        self.assertEqual(self.check(self.manifest("vmbr0"), self.config("vmbr0"), self.interfaces("192.168.1.211")), ("192.168.1.211", "vmbr0"))

    def test_manifest_identity_and_phase_guard(self):
        for field, value in (("node", "pve02"), ("vmid", 100), ("phase", "created"), ("marker", "other"), ("mac", "00:00:00:00:00:00")):
            manifest = self.manifest()
            manifest[field] = value
            with self.subTest(field=field), self.assertRaises(R.SafeError):
                self.check(manifest=manifest)

    def test_disk_and_vm_identity_drift_guard(self):
        for field, value in (("scsi0", "alien-disk"), ("efidisk0", "alien-efi"), ("name", "other"), ("net0", "virtio=00:00:00:00:00:00,bridge=vmbr1")):
            config = self.config()
            config[field] = value
            with self.subTest(field=field), self.assertRaises(R.SafeError):
                self.check(config=config)

    def test_bridge_manifest_mismatch_guard(self):
        with self.assertRaises(R.SafeError):
            self.check(config=self.config("vmbr0"), interfaces=self.interfaces("192.168.1.211"))

    def test_interface_mac_and_ip_guard(self):
        for interfaces in (self.interfaces(mac="00:00:00:00:00:00"), self.interfaces("192.168.1.211"), self.interfaces("10.0.10.1"), self.interfaces("10.0.10.50") * 2):
            with self.subTest(interfaces=interfaces), self.assertRaises(R.SafeError):
                self.check(interfaces=interfaces)


@unittest.skipUnless(os.name == "posix" and os.geteuid() == 0, "requires native Linux root permissions")
class PrivateFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.directory = R.private_dir(Path(self.tmp.name) / "private")

    def tearDown(self):
        self.tmp.cleanup()

    def test_atomic_write_read_and_modes(self):
        path = self.directory / "test.json"
        R.write_private(path, {"synthetic": 42})
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(R.read_private(path), {"synthetic": 42})
        R.write_private(path, {"synthetic": 43})
        self.assertEqual(R.read_private(path), {"synthetic": 43})
        self.assertEqual(list(self.directory.glob("*.tmp-*")), [])

    def test_permissive_file_rejected_without_overwrite(self):
        path = self.directory / "test.json"
        path.write_text('{"synthetic":42}')
        path.chmod(0o644)
        with self.assertRaises(R.SafeError):
            R.write_private(path, {"synthetic": 43})
        self.assertEqual(path.read_text(), '{"synthetic":42}')

    def test_symlink_file_and_directory_refused(self):
        target = self.directory / "target.json"
        R.write_private(target, {"synthetic": 42})
        alias = self.directory / "alias.json"
        alias.symlink_to(target)
        with self.assertRaises((R.SafeError, OSError)):
            R.read_private(alias)
        with self.assertRaises(R.SafeError):
            R.write_private(alias, {"synthetic": 43})
        alias_dir = Path(self.tmp.name) / "alias"
        alias_dir.symlink_to(self.directory, target_is_directory=True)
        with self.assertRaises(R.SafeError):
            R.private_dir(alias_dir)

    def test_prepare_preserves_password(self):
        first = R.prepare(self.directory)
        self.assertEqual(first, R.prepare(self.directory))
        self.assertGreaterEqual(len(first["password"]), 32)


class BootstrapTests(unittest.TestCase):
    def test_owner_marker_written_only_after_claim_login_and_closed_setup(self):
        state = {"steps": {key: False for key in ("user", "core_config", "analytics", "integration")}, "calls": []}
        owner = {"username": "admin", "name": "Homelab Owner", "password": "synthetic-password-32-characters-only"}
        class FakeClient:
            def __init__(self, base):
                self.base_url, self.token = base, None

            def request(self, method, path, data=None, **kwargs):
                state["calls"].append((method, path))
                if path == "/api/onboarding":
                    return [{"step": k, "done": v} for k, v in state["steps"].items()]
                if path == "/api/onboarding/users":
                    if state["steps"]["user"]:
                        raise R.HTTPError(403, path)
                    state["steps"]["user"] = True
                    self.assert_owner = data
                    return {"auth_code": "synthetic-authorization-code"}
                if path.startswith("/api/onboarding/"):
                    state["steps"][path.rsplit("/", 1)[1]] = True
                    return {}
                if path == "/auth/token":
                    return {"access_token": "synthetic-access-token-for-test", "refresh_token": "synthetic-refresh-token-for-test"}
                if path == "/auth/login_flow":
                    return {"flow_id": "a" * 32}
                if path == "/auth/login_flow/" + "a" * 32:
                    return {"type": "create_entry", "result": "synthetic-login-authorization-code"}
                raise AssertionError("unexpected request " + path)

            def command(self, type, **kwargs):
                state["calls"].append(("WS", type))
                if type == "auth/current_user":
                    return {"is_owner": True, "name": "Homelab Owner"}
                return {}

        written = []
        with patch.object(R, "owned_endpoint", return_value=("10.0.10.50", "vmbr1")), patch.object(R, "prepare", return_value=owner), patch.object(R, "Client", FakeClient), patch.object(R, "write_private", side_effect=lambda p,v: written.append((p,v))), patch("builtins.print"):
            R.bootstrap(Path("private-test"))
        self.assertTrue(all(state["steps"].values()))
        self.assertEqual(written[-1][0].name, "bootstrap.json")
        self.assertEqual(written[-1][1], {"marker": R.MARKER, "vmid": 102, "mac": R.MAC, "owner_initialized": True})
        self.assertEqual(state["calls"].count(("POST", "/api/onboarding/users")), 2)
        self.assertIn(("POST", "/auth/login_flow/" + "a" * 32), state["calls"])

    def test_bootstrap_refuses_lan_before_credentials_created(self):
        with patch.object(R, "owned_endpoint", return_value=("192.168.1.211", "vmbr0")), patch.object(R, "prepare") as prepare:
            with self.assertRaises(R.SafeError):
                R.bootstrap(Path("private-test"))
            prepare.assert_not_called()


if __name__ == "__main__":
    unittest.main()
