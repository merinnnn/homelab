#!/usr/bin/env python3
"""Claim and verify the managed n8n instance without printing private state.

prepare reads {"email": ...} on stdin; credentials are generated locally once.
bootstrap uses only an inspected, owned Docker backend. verify uses the fixed
HTTPS hostname with normal certificate validation. No redirects are followed.
"""
import argparse
import http.cookies
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

sys.dont_write_bytecode = True


class Failure(Exception):
    pass


def require(ok, message):
    if not ok:
        raise Failure(message)


def private_dir(path):
    require(path.is_absolute(), "Private directory must be absolute")
    require(not any(p.is_symlink() for p in [path, *path.parents]), "Private path symlink refused")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.stat()
    require(stat.S_ISDIR(info.st_mode), "Private path is not a directory")
    if os.name != "nt":
        require(info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o700,
                "Private directory must be owned by root with mode 0700")


def read_private(path):
    require(not path.is_symlink() and path.is_file(), "Private file missing or unsafe")
    info = path.stat()
    if os.name != "nt":
        require(info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o600,
                "Private file must be owned by root with mode 0600")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeError):
        raise Failure("Invalid private JSON") from None
    require(isinstance(value, dict), "Private JSON must be an object")
    return value


def write_private(path, value, exclusive=False):
    require(not path.is_symlink(), "Private file symlink refused")
    if path.exists():
        read_private(path)
        require(not exclusive, "Private file already exists")
    target = path if exclusive else path.with_name("." + path.name + "." + secrets.token_hex(8) + ".tmp")
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        if not exclusive:
            os.replace(target, path)
    finally:
        if not exclusive and target.exists():
            target.unlink()


def prepare(directory, payload):
    require(isinstance(payload, dict), "Owner input must be JSON object")
    email = payload.get("email", "")
    require(isinstance(email, str) and re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", email),
            "Valid owner email required on stdin")
    path = directory / "owner.json"
    if path.exists():
        require(read_private(path).get("email") == email.lower(), "Existing owner identity differs")
        return "preserved"
    owner = {"email": email.lower(), "firstName": "Homelab", "lastName": "Owner",
             "password": "Aa1-" + secrets.token_urlsafe(30)}
    write_private(path, owner, exclusive=True)
    return "prepared"


def docker_owned_ips():
    proc = subprocess.run(["docker", "ps", "-q", "--filter", "label=com.docker.compose.project=homelab-n8n",
                           "--filter", "label=com.docker.compose.service=n8n"],
                          capture_output=True, text=True, timeout=15)
    ids = proc.stdout.split()
    require(proc.returncode == 0 and len(ids) == 1, "Expected one running managed n8n backend")
    inspected = subprocess.run(["docker", "inspect", ids[0]], capture_output=True, text=True, timeout=15)
    require(inspected.returncode == 0, "Cannot inspect managed n8n backend")
    try:
        item = json.loads(inspected.stdout)[0]
        labels = item["Config"]["Labels"]
        require(labels.get("io.homelab.managed") == "n8n-v1", "n8n ownership label differs")
        require(item["State"]["Running"], "n8n backend is stopped")
        allowed = {"homelab-n8n_database", "homelab-n8n_runners", "homelab-proxy_default"}
        return {net["IPAddress"] for name, net in item["NetworkSettings"]["Networks"].items()
                if name in allowed and net.get("IPAddress")}
    except (ValueError, KeyError, IndexError, TypeError):
        raise Failure("Invalid n8n backend inspection") from None


def validate_target(base, action, ca_file=None):
    parsed = urllib.parse.urlsplit(base)
    require(not parsed.username and not parsed.password and not parsed.query and not parsed.fragment,
            "Target URL credentials, query or fragment refused")
    require(parsed.path in ("", "/"), "Target URL path refused")
    if action == "bootstrap":
        require(parsed.scheme == "http" and parsed.port == 5678, "Bootstrap requires private Docker HTTP port 5678")
        try:
            address = ipaddress.ip_address(parsed.hostname or "")
        except ValueError:
            raise Failure("Bootstrap target must be an inspected Docker address") from None
        require(address.is_private and str(address) in docker_owned_ips(), "Unowned Docker target refused")
    else:
        require(parsed.scheme == "https" and parsed.hostname == "n8n.home.arpa" and parsed.port in (None, 443),
                "Verification requires https://n8n.home.arpa")
        require(ca_file and Path(ca_file).is_file(), "Existing public CA certificate required")
    return base.rstrip("/")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, base, ca_file=None):
        self.base = base
        self.cookie = ""
        self.browser = str(uuid.uuid4())
        context = ssl.create_default_context(cafile=ca_file) if ca_file else ssl.create_default_context()
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(),
                                                 urllib.request.HTTPSHandler(context=context))

    def request(self, method, path, payload=None, expected=(200,), authenticated=True):
        require(path.startswith("/") and not path.startswith("//"), "Unsafe API path")
        headers = {"Accept": "application/json", "Content-Type": "application/json",
                   "browser-id": self.browser, "Origin": "https://n8n.home.arpa"}
        if authenticated and self.cookie:
            headers["Cookie"] = self.cookie
        encoded = json.dumps(payload).encode() if payload is not None else None
        request = urllib.request.Request(self.base + path, data=encoded, headers=headers, method=method)
        try:
            response = self.opener.open(request, timeout=30)
        except urllib.error.HTTPError as error:
            response = error
        except (urllib.error.URLError, TimeoutError, OSError):
            raise Failure("n8n API connection failed") from None
        with response:
            status = response.code
            # Cookie is intentionally sent only to the already validated, fixed
            # backend/HTTPS origin. Never weaken the deployed Secure cookie.
            for raw in response.headers.get_all("Set-Cookie", []):
                jar = http.cookies.SimpleCookie()
                jar.load(raw)
                if "n8n-auth" in jar:
                    self.cookie = "n8n-auth=" + jar["n8n-auth"].value
            body = response.read(8 * 1024 * 1024 + 1)
            require(status in expected, "n8n API rejected " + method + " " + path.split("?")[0] + " (HTTP " + str(status) + ")")
            require(len(body) <= 8 * 1024 * 1024, "Oversized n8n response refused")
            if not body:
                return None
            try:
                result = json.loads(body)
            except ValueError:
                raise Failure("Expected n8n JSON response") from None
            return result.get("data", result) if isinstance(result, dict) else result


def check_identity(user, owner):
    require(isinstance(user, dict) and user.get("email") == owner["email"] and user.get("id"),
            "Authenticated owner identity differs")
    role = user.get("role")
    require(role == "global:owner" or (isinstance(role, dict) and role.get("slug") == "global:owner"),
            "Authenticated account is not instance owner")
    return user["id"]


def login(client, owner):
    user = client.request("POST", "/rest/login", {"emailOrLdapLoginId": owner["email"], "password": owner["password"]})
    identity = check_identity(user, owner)
    require(client.cookie, "Owner authentication cookie missing")
    return identity


def settings(client):
    value = client.request("GET", "/rest/settings", authenticated=False)
    require(isinstance(value, dict) and isinstance(value.get("userManagement"), dict), "n8n settings contract differs")
    return value


def bootstrap(client, directory, owner):
    state_file = directory / "bootstrap.json"
    state = read_private(state_file) if state_file.exists() else {}
    if settings(client)["userManagement"].get("showSetupOnFirstLoad") is True:
        require(not state, "Existing owner marker forbids reclaiming instance")
        user = client.request("POST", "/rest/owner/setup", owner)
        identity = check_identity(user, owner)
    else:
        identity = login(client, owner)
    require(not state or state.get("owner_id") == identity, "Stored owner marker differs")
    require(settings(client)["userManagement"].get("showSetupOnFirstLoad") is False, "Owner setup remains open")
    client.request("POST", "/rest/owner/setup", owner, expected=(400,), authenticated=False)
    client.cookie = ""
    require(login(client, owner) == identity, "Fresh owner login differs")
    state.update({"schema": "n8n-owner-v1", "owner_id": identity})
    write_private(state_file, state)
    return {"owner_claimed": True, "fresh_login": True, "repeat_claim_denied": True}


def unflatten(text):
    if not isinstance(text, str):
        return text
    pool = json.loads(text)
    require(isinstance(pool, list) and pool, "Invalid execution data")
    built = {}

    def entry(index):
        require(0 <= index < len(pool), "Invalid execution data reference")
        if index in built:
            return built[index]
        value = pool[index]
        if isinstance(value, dict):
            result = {}
            built[index] = result
            result.update({key: child(item) for key, item in value.items()})
        elif isinstance(value, list):
            result = []
            built[index] = result
            result.extend(child(item) for item in value)
        else:
            result = value
            built[index] = result
        return result

    def child(value):
        return entry(int(value)) if isinstance(value, str) and value.isdigit() else value

    return entry(0)


def synthetic_workflow(client, directory):
    state_file = directory / "bootstrap.json"
    state = read_private(state_file)
    require(not state.get("active_probe"), "Previous acceptance workflow needs review before a new test")
    name = "homelab-n8n-acceptance-" + uuid.uuid4().hex
    nodes = [{"id": str(uuid.uuid4()), "name": "Manual Trigger", "type": "n8n-nodes-base.manualTrigger",
              "typeVersion": 1, "position": [0, 0], "parameters": {}},
             {"id": str(uuid.uuid4()), "name": "Code", "type": "n8n-nodes-base.code", "typeVersion": 2,
              "position": [240, 0], "parameters": {"mode": "runOnceForAllItems", "language": "javaScript",
              "jsCode": "return [{json: {answer: 6 * 7, probe: 'homelab-n8n-acceptance'}}];"}}]
    workflow = {"name": name, "nodes": nodes, "connections": {"Manual Trigger": {"main": [[{"node": "Code", "type": "main", "index": 0}]]}},
                "settings": {"executionOrder": "v1", "saveManualExecutions": True}}
    created = client.request("POST", "/rest/workflows", workflow)
    require(created.get("name") == name and created.get("id"), "Created test workflow identity differs")
    workflow_id = str(created["id"])
    path = "/rest/workflows/" + urllib.parse.quote(workflow_id, safe="")
    state["active_probe"] = {"id": workflow_id, "name": name}
    write_private(state_file, state)
    try:
        run = client.request("POST", path + "/run", {"triggerToStartFrom": {"name": "Manual Trigger"}})
        execution_id = str(run.get("executionId", ""))
        require(execution_id, "Manual workflow did not return execution identity")
        deadline = time.monotonic() + 150
        complete = None
        while time.monotonic() < deadline:
            complete = client.request("GET", "/rest/executions/" + urllib.parse.quote(execution_id, safe=""))
            if complete and complete.get("status") in ("success", "error", "crashed", "canceled"):
                break
            time.sleep(2)
        require(complete and complete.get("status") == "success", "Synthetic Code workflow failed or timed out")
        result = unflatten(complete.get("data"))
        try:
            output = result["resultData"]["runData"]["Code"][0]["data"]["main"][0][0]["json"]
        except (KeyError, TypeError, IndexError):
            raise Failure("Synthetic Code output missing") from None
        require(output == {"answer": 42, "probe": "homelab-n8n-acceptance"}, "Synthetic Code result differs")
    finally:
        # Only this invocation's exact-created, still-identical inactive fixture
        # can be archived/deleted. Never select by broad name prefix.
        current = client.request("GET", path)
        require(current.get("id") == workflow_id and current.get("name") == name and current.get("nodes") == nodes
                and not current.get("activeVersionId") and current.get("active") is not True,
                "Test workflow changed; cleanup refused")
        client.request("POST", path + "/archive", {})
        client.request("DELETE", path)
        client.request("GET", path, expected=(404,))
        state.pop("active_probe", None)
        write_private(state_file, state)
    return True


def verify(client, directory, owner, workflow=False):
    state = read_private(directory / "bootstrap.json")
    client.request("GET", "/rest/workflows", expected=(401,), authenticated=False)
    client.request("POST", "/rest/login", {"emailOrLdapLoginId": owner["email"], "password": "Wrong-Aa1-" + secrets.token_hex(16)},
                   expected=(401,), authenticated=False)
    require(login(client, owner) == state.get("owner_id"), "Owner identity changed after deployment")
    client.request("GET", "/rest/workflows")
    config = settings(client)
    require(config["userManagement"].get("showSetupOnFirstLoad") is False, "Owner setup is available")
    require(config.get("authCookie", {}).get("secure") is True, "Secure authentication cookie disabled")
    client.request("POST", "/rest/owner/setup", owner, expected=(400,), authenticated=False)
    result = {"anonymous_denied": True, "wrong_password_denied": True, "owner_login": True,
              "setup_closed": True, "secure_cookie": True}
    if workflow:
        result["javascript_workflow_42_and_cleanup"] = synthetic_workflow(client, directory)
    client.request("POST", "/rest/logout")
    client.cookie = ""
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "bootstrap", "verify"))
    parser.add_argument("--private-dir", default="/etc/homelab/n8n", type=Path)
    parser.add_argument("--base-url")
    parser.add_argument("--ca-file")
    parser.add_argument("--workflow", action="store_true")
    args = parser.parse_args()
    require(os.name == "nt" or os.geteuid() == 0, "Run on the application VM as root")
    private_dir(args.private_dir)
    if args.action == "prepare":
        try:
            payload = json.load(sys.stdin)
        except ValueError:
            raise Failure("Owner input must be valid JSON on stdin") from None
        print(json.dumps({"owner_credentials": prepare(args.private_dir, payload)}))
        return
    require(args.base_url, "Base URL required")
    base = validate_target(args.base_url, args.action, args.ca_file)
    owner = read_private(args.private_dir / "owner.json")
    require(set(owner) == {"email", "firstName", "lastName", "password"} and
            all(isinstance(value, str) and value for value in owner.values()), "Owner credential format differs")
    client = Client(base, args.ca_file)
    result = bootstrap(client, args.private_dir, owner) if args.action == "bootstrap" else verify(client, args.private_dir, owner, args.workflow)
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except Failure as error:
        # Our own constant diagnostics contain no response/input values.
        print("n8n bootstrap/acceptance failed: " + str(error) + "; private state preserved", file=sys.stderr)
        sys.exit(1)
    except Exception:
        # Never dump library exceptions/HTTP bodies: they can include input.
        print("n8n bootstrap/acceptance failed; private state preserved", file=sys.stderr)
        sys.exit(1)
