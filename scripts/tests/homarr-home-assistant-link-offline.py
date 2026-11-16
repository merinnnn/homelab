#!/usr/bin/env python3
"""Add-only Homarr behavior checks with a mock API; no live claim."""
import copy
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
DEPLOY = Path(__file__).resolve().parents[1] / "deploy"
CLIENT = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else DEPLOY / "bootstrap-homarr.py"
WORK = tempfile.TemporaryDirectory()
shutil.copy2(CLIENT, Path(WORK.name) / "bootstrap-homarr.py")
shutil.copy2(DEPLOY / "homarr-add-home-assistant.py", Path(WORK.name) / "homarr-add-home-assistant.py")
SPEC = importlib.util.spec_from_file_location("link", Path(WORK.name) / "homarr-add-home-assistant.py")
link = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(link)


class Mock:
    def __init__(self):
        self.board = {"id": "owned-board", "name": "homelab", "isPublic": True, "sections": [{"id": "section"}],
                      "layouts": [{"id": "layout"}], "items": [{"id": "existing-custom-widget", "kind": "clock", "options": {"custom": True}}]}
        self.apps = []
        self.mutations = []

    def rpc(self, proc, payload=None, mutation=False):
        if mutation:
            self.mutations.append(proc)
        if proc == "board.getBoardByName":
            return copy.deepcopy(self.board)
        if proc == "app.all":
            return copy.deepcopy(self.apps)
        if proc == "app.create":
            self.apps.append(dict(payload, id="new-app"))
            return dict(payload, appId="new-app")
        if proc == "board.addItem":
            self.board["items"].append({"id": "new-item", "kind": payload["kind"], "options": payload["options"]})
            return {"itemId": "new-item"}
        raise AssertionError("Unexpected API operation " + proc)


class AddOnly(unittest.TestCase):
    def test_add_and_repeat_preserve_custom_content(self):
        client = Mock()
        before = copy.deepcopy(client.board["items"])
        result = link.add_link(client, "owned-board")
        self.assertTrue(result["card_added"])
        self.assertEqual(client.board["items"][:1], before)
        self.assertEqual(client.mutations, ["app.create", "board.addItem"])
        self.assertFalse(link.add_link(client, "owned-board")["card_added"])
        self.assertEqual(client.mutations, ["app.create", "board.addItem"])

    def test_reuse_existing_exact_url(self):
        client = Mock()
        client.apps = [{"id": "existing-app", "href": link.URL, "name": "Owner customized name"}]
        self.assertFalse(link.add_link(client, "owned-board")["application_created"])
        self.assertEqual(client.mutations, ["board.addItem"])

    def test_ambiguous_apps_refuse_before_mutation(self):
        client = Mock()
        client.apps = [{"id": "a", "href": link.URL}, {"id": "b", "href": link.URL}]
        with self.assertRaises(link.homarr.Refused):
            link.add_link(client, "owned-board")
        self.assertEqual(client.mutations, [])

    def test_unknown_board_refused(self):
        client = Mock()
        with self.assertRaises(link.homarr.Refused):
            link.add_link(client, "another-board")
        self.assertEqual(client.mutations, [])


if __name__ == "__main__":
    try:
        unittest.main()
    finally:
        WORK.cleanup()
