#!/usr/bin/env python3
"""Prepare the owned Alertmanager Telegram receiver from private stdin JSON."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import stat
import subprocess
import sys
import tempfile
import urllib.request

TOKEN = re.compile(r"[0-9]{5,20}:[A-Za-z0-9_-]{20,100}\Z")
IMAGE = re.compile(r"prom/alertmanager@sha256:[a-f0-9]{64}\Z")
PUBLIC_ROUTE = {"group_by": ["alertname", "node", "instance"], "group_wait": "30s", "group_interval": "5m", "repeat_interval": "4h"}
PUBLIC_INHIBITS = [{"source_matchers": ['severity="critical"'], "target_matchers": ['severity="warning"'], "equal": ["instance", "mountpoint"]}]


class SetupError(Exception):
    """Contains only a deliberately non-sensitive error message."""


def credentials(value):
    if not isinstance(value, dict) or set(value) - {"bot_token", "chat_id"}:
        raise SetupError("Expected only bot_token and optional chat_id in private JSON")
    token = value.get("bot_token")
    if not isinstance(token, str) or not TOKEN.fullmatch(token):
        raise SetupError("Invalid bot token format")
    chat = value.get("chat_id")
    if chat is not None:
        if isinstance(chat, bool) or not re.fullmatch(r"[1-9][0-9]{0,18}", str(chat)):
            raise SetupError("Expected a positive numeric private chat ID")
        chat = int(chat)
    return token, chat


def telegram_api(token, method, parameters=None):
    # The token is necessarily in Telegram's HTTPS URL. It must never appear in
    # printed exceptions, command arguments, logs, or a configurable API origin.
    request = urllib.request.Request(
        "https://api.telegram.org/bot" + token + "/" + method,
        data=json.dumps(parameters or {}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            result = json.loads(response.read(1_000_001))
        if not isinstance(result, dict) or result.get("ok") is not True:
            raise ValueError("unaccepted result")
        return result["result"]
    except Exception:
        raise SetupError("Telegram API request failed at " + method) from None


def choose_chat(token, explicit, api=telegram_api):
    me = api(token, "getMe")
    if not isinstance(me, dict) or me.get("is_bot") is not True:
        raise SetupError("Telegram did not verify a bot account")
    if explicit is None:
        updates = api(token, "getUpdates", {"timeout": 0, "limit": 100, "allowed_updates": ["message"]})
        if not isinstance(updates, list):
            raise SetupError("Telegram update response is invalid")
        selected = set()
        for update in updates:
            if not isinstance(update, dict):
                continue
            message = update.get("message", {})
            chat = message.get("chat", {}) if isinstance(message, dict) else {}
            if not isinstance(chat, dict):
                continue
            text = message.get("text", "") if isinstance(message, dict) else ""
            command = text.split(maxsplit=1)[0] if isinstance(text, str) and text.strip() else ""
            valid_command = command == "/start" or (me.get("username") and command == "/start@" + me["username"])
            chat_id = chat.get("id") if isinstance(chat, dict) else None
            if valid_command and chat.get("type") == "private" and type(chat_id) is int and chat_id > 0:
                selected.add(chat_id)
        if len(selected) != 1:
            raise SetupError("Send /start privately to the bot; exactly one private chat is required, or provide chat_id explicitly")
        explicit = selected.pop()
    chat = api(token, "getChat", {"chat_id": explicit})
    if not isinstance(chat, dict) or chat.get("type") != "private" or chat.get("id") != explicit:
        raise SetupError("Telegram did not verify the selected private chat")
    return explicit


def receiver_config(token, chat):
    return {"route": {"receiver": "telegram", **PUBLIC_ROUTE}, "receivers": [{"name": "telegram", "telegram_configs": [{
        "bot_token": token, "chat_id": chat, "parse_mode": "HTML", "message": '{{ template "telegram.default.message" . }}', "send_resolved": True}]}], "inhibit_rules": PUBLIC_INHIBITS}


def require_private(path, directory=False):
    info = path.lstat()
    expected = 0o700 if directory else 0o600
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != expected:
        raise SetupError("Expected root-owned private monitoring files and directory")


def private_write(directory, prefix, content):
    handle, name = tempfile.mkstemp(prefix=prefix, dir=directory)
    with os.fdopen(handle, "wb") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(name, 0o600)
    return Path(name)


def known_configuration(private, current, default):
    if current == default:
        return
    try:
        marker = private / "telegram-managed.json"
        require_private(marker)
        metadata = json.loads(marker.read_bytes())
        existing = json.loads(current)
        entry = existing["receivers"][0]["telegram_configs"][0]
        token, chat = credentials({"bot_token": entry["bot_token"], "chat_id": entry["chat_id"]})
        if metadata != {"schema": 1, "sha256": hashlib.sha256(current).hexdigest()} or existing != receiver_config(token, chat):
            raise ValueError("unknown configuration")
    except Exception:
        raise SetupError("Unknown or changed Alertmanager settings; nothing overwritten") from None


def validate_candidate(candidate, image, log):
    if not IMAGE.fullmatch(image):
        raise SetupError("Expected the installed pinned Alertmanager image digest")
    try:
        with log.open("wb") as output:
            os.chmod(log, 0o600)
            result = subprocess.run(["docker", "run", "--rm", "--pull=never", "--network", "none", "--user", "0:0",
                "--entrypoint", "/bin/amtool", "-v", str(candidate) + ":/config.yml:ro", image, "check-config", "/config.yml"],
                stdout=output, stderr=subprocess.STDOUT, timeout=60, check=False)
        if result.returncode:
            raise ValueError("validation failed")
    except Exception:
        raise SetupError("Alertmanager validation failed; inspect the root-only Telegram validation log") from None


def configure(private, default, value, image, api=telegram_api, validator=validate_candidate):
    require_private(private, directory=True)
    canonical = private / "alertmanager.yml"
    require_private(canonical)
    current = canonical.read_bytes()
    known_configuration(private, current, default)
    token, explicit = credentials(value)
    chat = choose_chat(token, explicit, api)
    desired = (json.dumps(receiver_config(token, chat), indent=2) + "\n").encode()
    candidate = private_write(private, ".telegram-candidate-", desired)
    log = private_write(private, "telegram-validation-", b"")
    try:
        validator(candidate, image, log)
        if current == desired:
            return False
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        private_write(private, "alertmanager-before-telegram-" + stamp + "-", current)
        metadata = (json.dumps({"schema": 1, "sha256": hashlib.sha256(desired).hexdigest()}) + "\n").encode()
        marker = private_write(private, ".telegram-marker-", metadata)
        os.replace(candidate, canonical)
        os.replace(marker, private / "telegram-managed.json")
        return True
    finally:
        candidate.unlink(missing_ok=True)


def main():
    try:
        if sys.argv[1:] != ["--input-stdin"]:
            raise SetupError("Usage: setup-telegram.py --input-stdin (private JSON on stdin only)")
        if os.geteuid() != 0 or socket.gethostname().split(".")[0] != "apps01":
            raise SetupError("Run as root inside apps01")
        os.umask(0o077)
        private = Path("/etc/homelab/monitoring")
        root = Path("/opt/homelab/monitoring")
        require_private(private, directory=True)
        import fcntl
        with (root / ".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            raw = sys.stdin.buffer.read(16_385)
            if len(raw) > 16_384:
                raise SetupError("Private credential JSON exceeds the permitted size")
            try:
                value = json.loads(raw)
            except Exception:
                raise SetupError("Invalid private credential JSON") from None
            values = [line.split("=", 1)[1] for line in (root / "current/.env").read_text().splitlines() if line.startswith("ALERTMANAGER_IMAGE=")]
            if len(values) != 1 or not IMAGE.fullmatch(values[0]):
                raise SetupError("Expected a single installed Alertmanager image digest")
            default = (Path(__file__).resolve().parents[2] / "configs/docker/monitoring/alertmanager.default.yml").read_bytes()
            changed = configure(private, default, value, values[0])
        print("Private Telegram chat verified; receiver configuration " + ("prepared" if changed else "already matches") + ". Reapply monitoring and verify delivery.")
        return 0
    except SetupError as error:
        print("ERROR: " + str(error), file=sys.stderr)
    except Exception:
        # Never print raw urllib/subprocess/config exceptions: they can include
        # bot URLs, identifiers or receiver configuration containing secrets.
        print("ERROR: Telegram setup failed; inspect private runtime state", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
