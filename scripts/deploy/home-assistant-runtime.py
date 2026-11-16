#!/usr/bin/env python3
"""Private Home Assistant owner bootstrap and authenticated local API client.

Run on the owning Proxmox node. No secret values are printed. HTTP targets are
derived from the owned VM's QEMU agent, never accepted from arbitrary input.
"""
import argparse
import base64
import hashlib
import http.client
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket
import ssl
import stat
import struct
import subprocess
import sys
import time
from urllib.parse import urlencode, urlsplit

MARKER = "homelab-home-assistant-v1"
VMID = 102
MAC = "BC:24:11:32:8F:61"
ORIGIN = "https://ha.home.arpa"
PRIVATE = Path("/etc/homelab/home-assistant")
MANIFEST = Path("/var/lib/homelab/home-assistant/vm-102.json")
MAX_RESPONSE = 16 * 1024 * 1024


class SafeError(RuntimeError):
    """An error message that never contains remote responses or secrets."""


class HTTPError(SafeError):
    def __init__(self, status, path):
        self.status = status
        super().__init__(f"Home Assistant returned HTTP {status} for {path.split('?')[0]}")


def private_dir(path):
    path = Path(path)
    if os.name != "posix" or os.geteuid() != 0:
        raise SafeError("Run as root on pve01")
    # Refuse any symlink component before creating/opening private material.
    for part in [path, *path.parents]:
        if part.is_symlink():
            raise SafeError("Private directory contains a symbolic link")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    st = path.stat()
    if st.st_uid != 0 or stat.S_IMODE(st.st_mode) != 0o700:
        raise SafeError("Private directory must be root-owned mode 0700")
    return path


def read_private(path):
    path = Path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or stat.S_IMODE(st.st_mode) != 0o600:
            raise SafeError("Private JSON must be a root-owned mode 0600 regular file")
        with os.fdopen(fd, "r", encoding="utf-8") as f:
            fd = -1
            data = json.load(f)
        if not isinstance(data, dict):
            raise SafeError("Private JSON must contain an object")
        return data
    finally:
        if fd != -1:
            os.close(fd)


def write_private(path, value):
    path = Path(path)
    private_dir(path.parent)
    if path.is_symlink():
        raise SafeError("Refusing private JSON symbolic link")
    if path.exists():
        read_private(path)  # Refuse to overwrite a permissive or alien file.
    tmp = path.with_name(path.name + ".tmp-" + secrets.token_hex(8))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            json.dump(value, f, separators=(",", ":"))
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        dfd = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        tmp.unlink(missing_ok=True)


def run_json(argv):
    result = subprocess.run(argv, capture_output=True, timeout=40)
    if result.returncode:
        raise SafeError("Owned VM inspection failed")
    try:
        return json.loads(result.stdout)
    except (ValueError, UnicodeError):
        raise SafeError("Owned VM inspection returned invalid JSON") from None


def owned_endpoint():
    """Verify installer ownership and return QGA-observed address/bridge."""
    if os.name != "posix" or os.geteuid() != 0 or socket.gethostname().split(".")[0] != "pve01":
        raise SafeError("Run as root on the owning pve01 node")
    manifest = read_private(MANIFEST)
    if any(manifest.get(k) != v for k, v in {
        "marker": MARKER, "node": "pve01", "vmid": VMID, "mac": MAC,
        "phase": "complete",
    }.items()):
        raise SafeError("Home Assistant VM ownership manifest mismatch")
    config = run_json(["pvesh", "get", "/nodes/pve01/qemu/102/config", "--output-format", "json"])
    net = str(config.get("net0", ""))
    mac = re.search(r"(?:^|,)virtio=([0-9A-Fa-f:]{17})(?:,|$)", net)
    bridge = re.search(r"(?:^|,)bridge=([^,]+)(?:,|$)", net)
    if (config.get("name") != "ha01" or not mac or mac.group(1).upper() != MAC
            or not bridge or bridge.group(1) not in ("vmbr0", "vmbr1")
            or manifest.get("bridge") != bridge.group(1)
            or config.get("scsi0") != manifest.get("scsi0")
            or config.get("efidisk0") != manifest.get("efidisk0")):
        raise SafeError("Home Assistant VM configuration differs from ownership manifest")
    interfaces = run_json(["qm", "agent", str(VMID), "network-get-interfaces"])
    addresses = []
    for interface in interfaces:
        if interface.get("hardware-address", "").upper() != MAC:
            continue
        for address in interface.get("ip-addresses", []):
            if address.get("ip-address-type") != "ipv4":
                continue
            ip = ipaddress.ip_address(address["ip-address"])
            if bridge.group(1) == "vmbr1" and ip in ipaddress.ip_network("10.0.10.0/24") and str(ip) != "10.0.10.1":
                addresses.append(str(ip))
            if bridge.group(1) == "vmbr0" and str(ip) == "192.168.1.211":
                addresses.append(str(ip))
    if len(addresses) != 1:
        raise SafeError("Expected exactly one owned VM address on its assigned network")
    return addresses[0], bridge.group(1)


class FixedHTTPS(http.client.HTTPSConnection):
    def __init__(self, host, connect_ip, context):
        super().__init__(host, 443, timeout=40, context=context)
        self.connect_ip = connect_ip

    def connect(self):
        # Preserve TLS SNI/certificate-name checks while dialing the fixed proxy.
        sock = socket.create_connection((self.connect_ip, 443), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


class Client:
    def __init__(self, base_url, ca_file=None, connect_ip=None, token=None):
        parts = urlsplit(base_url)
        if parts.username or parts.password or parts.query or parts.fragment or parts.path not in ("", "/"):
            raise SafeError("Only an approved Home Assistant origin is allowed")
        if parts.scheme == "https":
            if base_url.rstrip("/") != ORIGIN or connect_ip not in (None, "192.168.1.58"):
                raise SafeError("HTTPS target must be the fixed Home Assistant proxy")
            self.context = ssl.create_default_context(cafile=str(ca_file) if ca_file else None)
            self.connect_ip = "192.168.1.58"
        elif parts.scheme == "http":
            approved_ip, _ = owned_endpoint()
            if parts.hostname != approved_ip or parts.port not in (None, 80) or connect_ip not in (None, approved_ip):
                raise SafeError("HTTP target does not match the owned VM's QGA address and port 80")
            self.context = None
            self.connect_ip = approved_ip
        else:
            raise SafeError("Unsupported Home Assistant transport")
        self.base_url = base_url.rstrip("/")
        self.host = parts.hostname
        self.port = parts.port or (443 if parts.scheme == "https" else 80)
        self.token = token

    def connection(self):
        if self.context:
            return FixedHTTPS(self.host, self.connect_ip, self.context)
        return http.client.HTTPConnection(self.connect_ip, self.port, timeout=40)

    @staticmethod
    def path(path):
        if not isinstance(path, str) or not path.startswith("/") or path.startswith("//") or "\r" in path or "\n" in path:
            raise SafeError("Only relative API paths are allowed")
        return path

    def request(self, method, path, data=None, form=False, token=None):
        path = self.path(path)
        headers = {"Accept": "application/json", "Host": self.host}
        selected_token = token if token is not None else self.token
        if selected_token:
            headers["Authorization"] = "Bearer " + selected_token
        body = None
        if data is not None:
            body = urlencode(data).encode() if form else json.dumps(data).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
        connection = self.connection()
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            if response.status < 200 or response.status >= 300:
                raise HTTPError(response.status, path)
            raw = response.read(MAX_RESPONSE + 1)
            if len(raw) > MAX_RESPONSE:
                raise SafeError("Home Assistant response exceeded the permitted size")
            if not raw:
                return None
            try:
                return json.loads(raw)
            except (ValueError, UnicodeError):
                raise SafeError("Home Assistant returned invalid JSON") from None
        finally:
            connection.close()

    def websocket(self, token=None):
        return WebSocket(self, token or self.token)

    def command(self, type, **kwargs):
        with self.websocket() as ws:
            return ws.call(type, **kwargs)

    def download(self, path, destination, token=None, max_bytes=4 * 1024**3):
        path = self.path(path)
        if not path.startswith("/api/backup/download/") or "password" in path.lower():
            raise SafeError("Only encrypted backup downloads without query passwords are allowed")
        destination = Path(destination)
        private_dir(destination.parent)
        fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        connection = self.connection()
        total, digest = 0, hashlib.sha256()
        try:
            with os.fdopen(fd, "wb") as f:
                connection.request("GET", path, headers={"Host": self.host, "Authorization": "Bearer " + (token or self.token)})
                response = connection.getresponse()
                if response.status != 200:
                    raise HTTPError(response.status, path)
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > max_bytes:
                        raise SafeError("Encrypted backup exceeded the permitted size")
                    digest.update(chunk)
                    f.write(chunk)
                f.flush()
                os.fsync(f.fileno())
            if not total:
                raise SafeError("Encrypted backup download was empty")
            return {"bytes": total, "sha256": digest.hexdigest()}
        except BaseException:
            destination.unlink(missing_ok=True)
            raise
        finally:
            connection.close()


class WebSocket:
    def __init__(self, client, token):
        if not token:
            raise SafeError("Authenticated WebSocket requires an access token")
        self.client, self.token, self.sock, self.counter = client, token, None, 0

    def __enter__(self):
        try:
            self.sock = socket.create_connection((self.client.connect_ip, self.client.port), timeout=40)
            if self.client.context:
                self.sock = self.client.context.wrap_socket(self.sock, server_hostname=self.client.host)
            key = base64.b64encode(secrets.token_bytes(16)).decode()
            request = ("GET /api/websocket HTTP/1.1\r\nHost: " + self.client.host + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Version: 13\r\n\r\n")
            self.sock.sendall(request.encode())
            headers = bytearray()
            while not headers.endswith(b"\r\n\r\n"):
                headers.extend(self._read(1))
                if len(headers) > 65536:
                    raise SafeError("WebSocket handshake headers exceeded the permitted size")
            lines = headers.decode("ascii").split("\r\n")
            expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            parsed = {k.lower(): v.strip() for line in lines[1:] if ":" in line for k, v in [line.split(":", 1)]}
            if not lines[0].startswith("HTTP/1.1 101 ") or parsed.get("sec-websocket-accept") != expected:
                raise SafeError("WebSocket handshake was not accepted")
            if self.receive().get("type") != "auth_required":
                raise SafeError("WebSocket did not request authentication")
            self.send({"type": "auth", "access_token": self.token})
            if self.receive().get("type") != "auth_ok":
                raise SafeError("WebSocket authentication was denied")
            return self
        except BaseException:
            self.close()
            raise

    def _read(self, length):
        result = bytearray()
        while len(result) < length:
            chunk = self.sock.recv(length - len(result))
            if not chunk:
                raise SafeError("WebSocket closed before the operation completed")
            result.extend(chunk)
        return bytes(result)

    def frame(self, payload, opcode=1):
        mask = secrets.token_bytes(4)
        length = len(payload)
        prefix = bytes([0x80 | opcode])
        if length < 126:
            prefix += bytes([0x80 | length])
        elif length < 65536:
            prefix += bytes([0x80 | 126]) + struct.pack("!H", length)
        else:
            prefix += bytes([0x80 | 127]) + struct.pack("!Q", length)
        self.sock.sendall(prefix + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(payload)))

    def send(self, value):
        self.frame(json.dumps(value, separators=(",", ":")).encode())

    def receive(self):
        result, message_opcode = bytearray(), None
        while True:
            first, second = self._read(2)
            if first & 0x70 or second & 0x80:
                raise SafeError("Invalid server WebSocket frame")
            opcode, final, length = first & 15, bool(first & 0x80), second & 127
            if length == 126:
                length = struct.unpack("!H", self._read(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._read(8))[0]
            if length > MAX_RESPONSE or len(result) + length > MAX_RESPONSE:
                raise SafeError("WebSocket response exceeded the permitted size")
            payload = self._read(length)
            if opcode == 8:
                raise SafeError("WebSocket closed before the operation completed")
            if opcode in (9, 10):
                if not final or length > 125:
                    raise SafeError("Invalid WebSocket control frame")
                if opcode == 9:
                    self.frame(payload, 10)
                continue
            if opcode == 1 and message_opcode is None:
                message_opcode = 1
            elif opcode != 0 or message_opcode is None:
                raise SafeError("Unsupported WebSocket data frame")
            result.extend(payload)
            if final:
                try:
                    value = json.loads(result)
                except (ValueError, UnicodeError):
                    raise SafeError("WebSocket returned invalid JSON") from None
                if not isinstance(value, dict):
                    raise SafeError("WebSocket returned an invalid message")
                return value

    def call(self, type, **kwargs):
        if "id" in kwargs or "type" in kwargs:
            raise SafeError("WebSocket command identifiers cannot be overridden")
        self.counter += 1
        self.send({"id": self.counter, "type": type, **kwargs})
        while True:
            response = self.receive()
            if response.get("id") != self.counter or response.get("type") != "result":
                continue
            if response.get("success") is not True:
                code = str(response.get("error", {}).get("code", "unknown"))
                if not re.fullmatch(r"[A-Za-z0-9_-]{1,60}", code):
                    code = "unknown"
                raise SafeError(f"Home Assistant WebSocket operation {type} failed ({code})")
            return response.get("result")

    def close(self):
        if self.sock:
            self.sock.close()
            self.sock = None

    def __exit__(self, *args):
        self.close()


def authenticated_client(private_dir=PRIVATE, base_url=None, ca_file=None, connect_ip=None):
    directory = globals()["private_dir"](private_dir)
    auth = read_private(directory / "auth.json")
    if auth.get("client_id") != ORIGIN + "/" or not isinstance(auth.get("refresh_token"), str):
        raise SafeError("Private Home Assistant authentication metadata is invalid")
    owned_endpoint()
    base = base_url or ORIGIN
    ca = ca_file or directory / "proxy-root.crt" if base.startswith("https:") else None
    client = Client(base, ca_file=ca, connect_ip=connect_ip)
    reply = client.request("POST", "/auth/token", {
        "client_id": auth["client_id"], "grant_type": "refresh_token", "refresh_token": auth["refresh_token"],
    }, form=True)
    token = reply.get("access_token")
    if not isinstance(token, str) or len(token) < 20:
        raise SafeError("Home Assistant did not return an access token")
    auth.update(access_token=token, base_url=base)
    write_private(directory / "auth.json", auth)
    client.token = token
    return client, token


def login(client, owner):
    first = client.request("POST", "/auth/login_flow", {
        "client_id": ORIGIN + "/", "redirect_uri": ORIGIN + "/", "handler": ["homeassistant", None],
    })
    flow = first.get("flow_id", "")
    if not re.fullmatch(r"[a-f0-9]{32}", flow):
        raise SafeError("Home Assistant login did not return a valid flow")
    second = client.request("POST", "/auth/login_flow/" + flow, {
        "client_id": ORIGIN + "/", "username": owner["username"], "password": owner["password"],
    })
    if second.get("type") != "create_entry" or not isinstance(second.get("result"), str):
        raise SafeError("Existing private owner credentials were not accepted")
    return second["result"]


def exchange(client, code, directory):
    auth = client.request("POST", "/auth/token", {
        "client_id": ORIGIN + "/", "grant_type": "authorization_code", "code": code,
    }, form=True)
    if not all(isinstance(auth.get(k), str) and len(auth[k]) >= 20 for k in ("access_token", "refresh_token")):
        raise SafeError("Home Assistant owner authorization failed")
    auth.update(client_id=ORIGIN + "/", base_url=client.base_url)
    write_private(directory / "auth.json", auth)
    client.token = auth["access_token"]


def prepare(directory):
    path = directory / "owner.json"
    if path.exists():
        owner = read_private(path)
        if owner.get("username") != "admin" or owner.get("name") != "Homelab Owner" or not isinstance(owner.get("password"), str) or len(owner["password"]) < 24:
            raise SafeError("Existing private owner metadata is inconsistent; no reset performed")
        return owner
    owner = {"username": "admin", "name": "Homelab Owner", "password": secrets.token_urlsafe(32)}
    write_private(path, owner)
    return owner


def bootstrap(directory):
    address, bridge = owned_endpoint()
    if bridge != "vmbr1":
        raise SafeError("Initial owner bootstrap requires the isolated vmbr1 network")
    owner = prepare(directory)
    client = Client("http://" + address)
    try:
        steps = client.request("GET", "/api/onboarding")
    except HTTPError as error:
        # Completed onboarding unregisters these endpoints on the next restart.
        # Only our own existing verified marker permits a repeat in that state.
        if error.status != 404 or not (directory / "bootstrap.json").exists():
            raise
        previous = read_private(directory / "bootstrap.json")
        if previous != {"marker": MARKER, "vmid": VMID, "mac": MAC, "owner_initialized": True}:
            raise SafeError("Existing owner bootstrap marker is inconsistent")
        steps = [{"step": s, "done": True} for s in ("user", "core_config", "analytics", "integration")]
    done = {step["step"]: step["done"] for step in steps}
    if done.get("user") is False:
        result = client.request("POST", "/api/onboarding/users", {**owner, "client_id": ORIGIN + "/", "language": "en"})
        code = result.get("auth_code")
        if not isinstance(code, str):
            raise SafeError("Owner setup did not return an authorization code")
    elif done.get("user") is True:
        code = login(client, owner)
    else:
        raise SafeError("Unexpected onboarding state; no reset performed")
    exchange(client, code, directory)
    current = client.command("auth/current_user")
    if current.get("is_owner") is not True or current.get("name") != owner["name"]:
        raise SafeError("Authenticated account is not the expected owner")
    client.command("config/core/update", location_name="Home", time_zone="Europe/London", country="GB", language="en", internal_url=ORIGIN)
    if not done.get("core_config"):
        client.request("POST", "/api/onboarding/core_config", {})
    client.command("analytics/preferences", preferences={"base": False, "diagnostics": False, "statistics": False, "usage": False, "snapshots": False})
    if not done.get("analytics"):
        client.request("POST", "/api/onboarding/analytics", {})
    if not done.get("integration"):
        client.request("POST", "/api/onboarding/integration", {"client_id": ORIGIN + "/", "redirect_uri": ORIGIN + "/"})
    # Prove a new anonymous visitor cannot claim a second owner with the same
    # valid request shape. The existing private password is never sent here.
    anonymous = Client(client.base_url)
    try:
        anonymous.request("POST", "/api/onboarding/users", {"name": "Closed setup check", "username": "setup-closed-check", "password": secrets.token_urlsafe(32), "client_id": ORIGIN + "/", "language": "en"})
    except HTTPError as error:
        if error.status not in (403, 404):
            raise
    else:
        raise SafeError("Owner setup was unexpectedly open after bootstrap")
    try:
        final_steps = client.request("GET", "/api/onboarding")
    except HTTPError as error:
        if error.status != 404 or not all(done.values()):
            raise
    else:
        if not final_steps or not all(s.get("done") is True for s in final_steps):
            raise SafeError("Home Assistant onboarding did not finish")
    # Separate password login proves the saved credentials are reusable.
    exchange(client, login(client, owner), directory)
    write_private(directory / "bootstrap.json", {"marker": MARKER, "vmid": VMID, "mac": MAC, "owner_initialized": True})
    print("Owner initialized, login verified, onboarding closed; private credentials saved")


def set_hostname(directory):
    address, _ = owned_endpoint()
    client, _ = authenticated_client(directory, base_url="http://" + address)
    current = client.command("supervisor/api", endpoint="/host/info", method="get")
    if current.get("hostname") not in ("homeassistant", "ha01"):
        raise SafeError("Existing Home Assistant hostname differs from the fresh installation")
    if current.get("hostname") != "ha01":
        client.command("supervisor/api", endpoint="/host/options", method="post", data={"hostname": "ha01"})
    if client.command("supervisor/api", endpoint="/host/info", method="get").get("hostname") != "ha01":
        raise SafeError("Home Assistant hostname update was not verified")
    print("Owned Home Assistant hostname verified as ha01")


def configure_proxy(directory):
    address, _ = owned_endpoint()
    client, _ = authenticated_client(directory, base_url="http://" + address)
    current = client.command("http/config")
    config = dict(current.get("stable") or current["default"])
    for key in ("created_at", "error", "error_message"):
        config.pop(key, None)
    config.update(server_port=80, use_x_forwarded_for=True, trusted_proxies=["192.168.1.58/32"])
    client.command("http/config/configure", config=config)
    print("HTTP proxy settings staged; verify HTTPS and promote within five minutes")


def verify(directory, promote=False):
    client, _ = authenticated_client(directory)
    current = client.command("auth/current_user")
    if current.get("is_owner") is not True:
        raise SafeError("HTTPS API did not authenticate the owner")
    config = client.command("http/config")
    active = config.get("pending") if config.get("active_config_type") == "pending" else config.get("stable")
    if not active or active.get("server_port") != 80 or active.get("use_x_forwarded_for") is not True or active.get("trusted_proxies") != ["192.168.1.58/32"]:
        raise SafeError("Expected HTTP proxy settings are not active")
    if promote:
        client.command("http/config/promote")
        config = client.command("http/config")
        if config.get("pending") is not None or config.get("revert_at") is not None:
            raise SafeError("HTTP proxy configuration was not promoted")
    print("HTTPS owner authentication and WebSocket proxy settings verified" + (" and promoted" if promote else ""))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "bootstrap", "set-hostname", "configure-proxy", "verify", "promote-proxy"))
    parser.add_argument("--private-dir", default=str(PRIVATE))
    args = parser.parse_args()
    directory = private_dir(args.private_dir)
    if args.action == "prepare":
        owned_endpoint()
        prepare(directory)
        print("Private owner credentials prepared")
    elif args.action == "bootstrap":
        bootstrap(directory)
    elif args.action == "configure-proxy":
        configure_proxy(directory)
    elif args.action == "set-hostname":
        set_hostname(directory)
    else:
        verify(directory, promote=args.action == "promote-proxy")


if __name__ == "__main__":
    try:
        main()
    except (SafeError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        # Only our sanitized errors may include a message. Do not stringify
        # socket, decoder or subprocess errors that may reference private input.
        message = str(error) if isinstance(error, SafeError) else type(error).__name__
        print("Home Assistant operation failed: " + message, file=sys.stderr)
        raise SystemExit(1)
