#!/usr/bin/env python3
"""Bootstrap an isolated Jellyfin instance; verify or add only owned library paths."""
import argparse
import json
import os
import secrets
import stat
import subprocess
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, build_opener, HTTPRedirectHandler

ROOT = Path("/etc/homelab/jellyfin")
OWNER = ROOT / "owner.json"
PROXY = "192.168.1.58"
BASE = "http://127.0.0.1:8096"
AUTH = 'MediaBrowser Client="Homelab", Device="Jellyfin setup", DeviceId="homelab-jellyfin-setup", Version="1"'
LIBRARIES = {"Movies": ("movies", "/srv/media/Movies"), "TV Shows": ("tvshows", "/srv/media/TV Shows"), "Music": ("music", "/srv/media/Music")}


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def req(path, body=None, token=None, method=None, status=200):
    headers = {"Authorization": AUTH + (f', Token="{token}"' if token else "")}
    if body is not None:
        headers["Content-Type"] = "application/json"
    request = Request(BASE+path, data=json.dumps(body).encode() if body is not None else None,
                      headers=headers, method=method)
    try:
        with build_opener(NoRedirect()).open(request, timeout=15) as reply:
            if reply.status != status:
                raise RuntimeError(f"Unexpected status {reply.status} at {path.split('?')[0]}")
            return json.load(reply) if status == 200 else None
    except HTTPError as e:
        raise RuntimeError(f"HTTP {e.code} at {path.split('?')[0]}") from None


def public_info(require_closed=False):
    for _ in range(45):
        try:
            info = req("/System/Info/Public")
            if not require_closed or info.get("StartupWizardCompleted") is True:
                return info
        except (URLError, TimeoutError, RuntimeError):
            pass
        time.sleep(2)
    raise RuntimeError("Jellyfin did not become ready")


def private(path, mode):
    info = path.lstat()
    expected = stat.S_ISDIR if mode == 0o700 else stat.S_ISREG
    if not expected(info.st_mode) or info.st_uid or stat.S_IMODE(info.st_mode) != mode:
        raise RuntimeError("Unsafe private state")


def account(create=False):
    if create:
        ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    private(ROOT, 0o700)
    if create and not OWNER.exists() and not OWNER.is_symlink():
        fd = os.open(OWNER, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump({"username":"admin", "password":secrets.token_urlsafe(32)}, stream)
            stream.write("\n")
    private(OWNER, 0o600)
    data = json.loads(OWNER.read_text())
    if data.get("username") != "admin" or len(data.get("password","")) < 24:
        raise RuntimeError("Unexpected owner account state")
    return data


def login(owner):
    auth = req("/Users/AuthenticateByName", {"Username":owner["username"],"Pw":owner["password"]})
    token = auth["AccessToken"]
    me = req("/Users/Me", token=token)
    if me["Name"] != owner["username"] or not me["Policy"]["IsAdministrator"]:
        raise RuntimeError("Owner authentication failed")
    return token


def close(token):
    req("/Sessions/Logout", token=token, method="POST", status=204)


def network(token, mutate=False):
    path = "/System/Configuration/network"
    data = req(path, token=token)
    want = {"EnableRemoteAccess":False, "KnownProxies":[PROXY], "EnableIPv6":False}
    if mutate:
        data.update(want)
        req(path, data, token=token, status=204)
        data = req(path, token=token)
    if any(data.get(k) != v for k,v in want.items()):
        raise RuntimeError("Unexpected local access / known proxy configuration")


def bootstrap():
    info = public_info()
    if info.get("StartupWizardCompleted"):
        raise RuntimeError("Setup already closed; use verify; will not reset owner")
    owner = account(create=True)
    req("/Startup/User")
    req("/Startup/User", {"Name":owner["username"],"Password":owner["password"]}, status=204)
    req("/Startup/Configuration", {"ServerName":"Homelab Jellyfin","UICulture":"en-GB",
        "MetadataCountryCode":"GB","PreferredMetadataLanguage":"en"}, status=204)
    req("/Startup/RemoteAccess", {"EnableRemoteAccess":False}, status=204)
    req("/Startup/Complete", method="POST", status=204)
    token = login(owner)
    try:
        network(token, mutate=True)
    finally:
        close(token)
    print("Private Jellyfin admin initialized, authenticated and remote access disabled")


def libraries(token, create):
    base = "/Library/VirtualFolders"
    entries = req(base, token=token)
    for name, (kind, folder) in LIBRARIES.items():
        found = [item for item in entries if item.get("Name") == name]
        if subprocess.run(["runuser", "-u", "jellyfin", "--", "test", "-d", folder], check=False).returncode:
            raise RuntimeError(f"Missing mounted library folder: {name}")
        if not found:
            if not create:
                raise RuntimeError(f"Missing library: {name}")
            args = urlencode({"name":name,"collectionType":kind,"paths":folder,"refreshLibrary":"true"})
            req(base+"?"+args, {"LibraryOptions":{"EnableRealtimeMonitor":False}},
                token=token, status=204)
        elif len(found) != 1 or found[0].get("Locations") != [folder]:
            raise RuntimeError(f"Existing library differs: {name}")
    if create:
        libraries(token, False)


def verify(create=False):
    info = public_info(require_closed=True)
    for path in ("/Users/Me", "/Startup/User"):
        try:
            req(path)
        except RuntimeError as e:
            if str(e) not in {f"HTTP 401 at {path}", f"HTTP 403 at {path}"}:
                raise
        else:
            raise RuntimeError(f"Anonymous access was unexpectedly allowed: {path}")
    token = login(account())
    try:
        network(token)
        libraries(token, create)
    finally:
        close(token)
    print("Jellyfin " + info["Version"] + ": owner login, closed wizard, local access and 3 media paths verified")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("action", choices=["bootstrap", "libraries", "verify"])
    action = p.parse_args().action
    os.umask(0o077)
    try:
        bootstrap() if action == "bootstrap" else verify(action == "libraries")
    except (RuntimeError, OSError, ValueError, KeyError) as e:
        print(str(e) if isinstance(e, RuntimeError) else f"Jellyfin setup stopped: {type(e).__name__}")
        raise SystemExit(1) from None