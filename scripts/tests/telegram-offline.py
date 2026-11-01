#!/usr/bin/env python3
"""No network, Docker, root access or actual credentials are used."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import urllib.error

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("telegram_setup", REPO / "scripts/deploy/setup-telegram.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
TOKEN = "12345:" + "TestOnly_" * 5
OTHER_TOKEN = "54321:" + "FixtureOnly_" * 4
IMAGE = "prom/alertmanager@sha256:" + "a" * 64
DEFAULT = (REPO / "configs/docker/monitoring/alertmanager.default.yml").read_bytes()


def fake_api(updates=None, private=True):
    calls = []
    def api(token, method, parameters=None):
        calls.append((method, parameters))
        if method == "getMe":
            return {"is_bot": True, "username": "FixtureBot"}
        if method == "getUpdates":
            return updates or []
        if method == "getChat":
            return {"id": parameters["chat_id"], "type": "private" if private else "group"}
        raise AssertionError("Unexpected Telegram method")
    return api, calls


def update(chat, text="/start", kind="private"):
    return {"message": {"text": text, "chat": {"id": chat, "type": kind}}}


class CredentialsAndChats(unittest.TestCase):
    def test_explicit_private_chat_is_preserved_without_updates(self):
        api, calls = fake_api()
        self.assertEqual(MODULE.choose_chat(TOKEN, 101, api), 101)
        self.assertEqual([x[0] for x in calls], ["getMe", "getChat"])

    def test_discovery_accepts_only_unique_private_start(self):
        api, _ = fake_api([update(101), update(101, "/start@FixtureBot"), update(202, "/hello"), update(303, kind="group")])
        self.assertEqual(MODULE.choose_chat(TOKEN, None, api), 101)

    def test_discovery_refuses_multiple_private_chats_without_ids_in_error(self):
        api, _ = fake_api([update(101), update(202)])
        with self.assertRaises(MODULE.SetupError) as result:
            MODULE.choose_chat(TOKEN, None, api)
        self.assertNotIn("101", str(result.exception))
        self.assertNotIn("202", str(result.exception))

    def test_discovery_refuses_non_start_messages(self):
        api, _ = fake_api([update(101, "hello /start")])
        with self.assertRaises(MODULE.SetupError):
            MODULE.choose_chat(TOKEN, None, api)

    def test_explicit_group_is_refused(self):
        api, _ = fake_api(private=False)
        with self.assertRaises(MODULE.SetupError):
            MODULE.choose_chat(TOKEN, 101, api)

    def test_discovery_ignores_malformed_updates(self):
        api, _ = fake_api([None, {"message": {"chat": "bad", "text": "/start"}}, update(101)])
        self.assertEqual(MODULE.choose_chat(TOKEN, None, api), 101)

    def test_credential_shape_and_ids_fail_closed(self):
        for value in [None, {"bot_token": TOKEN, "other": "unknown"}, {"bot_token": TOKEN, "chat_id": True}, {"bot_token": TOKEN, "chat_id": -101}, {"bot_token": "invalid " + TOKEN}]:
            with self.subTest(value_type=type(value).__name__), self.assertRaises(MODULE.SetupError):
                MODULE.credentials(value)

    def test_numeric_string_chat_id_is_converted(self):
        self.assertEqual(MODULE.credentials({"bot_token": TOKEN, "chat_id": "101"}), (TOKEN, 101))

    def test_network_exception_never_exposes_token_url(self):
        with mock.patch.object(MODULE.urllib.request, "urlopen", side_effect=urllib.error.URLError("https://api.telegram.org/bot" + TOKEN + "/getMe")):
            with self.assertRaises(MODULE.SetupError) as result:
                MODULE.telegram_api(TOKEN, "getMe")
        self.assertEqual(str(result.exception), "Telegram API request failed at getMe")
        self.assertIsNone(result.exception.__cause__)

    def test_api_rejection_never_exposes_response_body(self):
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps({"ok": False, "description": TOKEN}).encode()
        with mock.patch.object(MODULE.urllib.request, "urlopen", return_value=response):
            with self.assertRaises(MODULE.SetupError) as result:
                MODULE.telegram_api(TOKEN, "getMe")
        self.assertNotIn(TOKEN, str(result.exception))


class ConfigurationPreservation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.private = Path(self.temp.name)
        self.canonical = self.private / "alertmanager.yml"
        self.canonical.write_bytes(DEFAULT)
        # Native UID/mode enforcement is exercised only on the Linux target;
        # Windows/Python fixture files do not provide Linux root ownership.
        self.guard = mock.patch.object(MODULE, "require_private")
        self.guard.start()
        self.addCleanup(self.guard.stop)
        self.api, self.calls = fake_api()
        self.value = {"bot_token": TOKEN, "chat_id": 101}
        self.validated = []
        self.validator = lambda candidate, image, log: self.validated.append(json.loads(candidate.read_bytes()))

    def configure(self, value=None):
        return MODULE.configure(self.private, DEFAULT, value or self.value, IMAGE, self.api, self.validator)

    def test_validated_config_preserves_grouping_and_creates_exact_backup(self):
        self.assertTrue(self.configure())
        actual = json.loads(self.canonical.read_bytes())
        self.assertEqual(actual["route"], {"receiver": "telegram", **MODULE.PUBLIC_ROUTE})
        self.assertEqual(actual["inhibit_rules"], MODULE.PUBLIC_INHIBITS)
        self.assertTrue(actual["receivers"][0]["telegram_configs"][0]["send_resolved"])
        backups = list(self.private.glob("alertmanager-before-telegram-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), DEFAULT)
        self.assertEqual(len(self.validated), 1)

    def test_unknown_configuration_refused_before_api_or_overwrite(self):
        unknown = b"route:\n  receiver: user-owned\n"
        self.canonical.write_bytes(unknown)
        with self.assertRaises(MODULE.SetupError):
            self.configure()
        self.assertEqual(self.canonical.read_bytes(), unknown)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.validated, [])

    def test_repeat_is_idempotent_without_extra_backup(self):
        self.configure()
        before = self.canonical.read_bytes()
        self.assertFalse(self.configure())
        self.assertEqual(self.canonical.read_bytes(), before)
        self.assertEqual(len(list(self.private.glob("alertmanager-before-telegram-*"))), 1)

    def test_owned_token_rotation_is_allowed(self):
        self.configure()
        self.assertTrue(self.configure({"bot_token": OTHER_TOKEN, "chat_id": 101}))
        self.assertEqual(json.loads(self.canonical.read_bytes())["receivers"][0]["telegram_configs"][0]["bot_token"], OTHER_TOKEN)

    def test_tampering_is_refused_even_with_owned_marker(self):
        self.configure()
        altered = json.loads(self.canonical.read_bytes())
        altered["route"]["group_wait"] = "0s"
        self.canonical.write_text(json.dumps(altered))
        before = self.canonical.read_bytes()
        with self.assertRaises(MODULE.SetupError):
            self.configure()
        self.assertEqual(self.canonical.read_bytes(), before)

    def test_validation_failure_keeps_canonical_and_cleans_staged_secret(self):
        def rejected(candidate, image, log):
            raise MODULE.SetupError("Fixture validation failed")
        self.validator = rejected
        with self.assertRaises(MODULE.SetupError):
            self.configure()
        self.assertEqual(self.canonical.read_bytes(), DEFAULT)
        self.assertEqual(list(self.private.glob(".telegram-candidate-*")), [])
        self.assertEqual(list(self.private.glob("alertmanager-before-telegram-*")), [])

    def test_success_writes_no_identity_or_secret_to_console(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            self.configure()
        self.assertEqual(output.getvalue(), "")

    def test_native_validator_errors_are_private_and_generic(self):
        candidate = self.private / "candidate.json"
        candidate.write_text(json.dumps(MODULE.receiver_config(TOKEN, 101)))
        log = self.private / "validation.log"
        with mock.patch.object(MODULE.subprocess, "run", side_effect=RuntimeError(TOKEN)):
            with self.assertRaises(MODULE.SetupError) as result:
                MODULE.validate_candidate(candidate, IMAGE, log)
        self.assertNotIn(TOKEN, str(result.exception))


if __name__ == "__main__":
    unittest.main(verbosity=2)
