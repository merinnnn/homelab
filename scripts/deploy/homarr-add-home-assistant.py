#!/usr/bin/env python3
"""Add the Home Assistant bookmark through Homarr2.10.1's additive editor API only.

Does not call onboarding/saveBoard, change existing cards, or edit private
Homarr bootstrap provenance. Imports the existing protected bootstrap client.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
SOURCE = Path(__file__).resolve().with_name("bootstrap-homarr.py")
SPEC = importlib.util.spec_from_file_location("managed_homarr", SOURCE)
homarr = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(homarr)
URL = "https://ha.home.arpa/"


def add_link(client, expected_board_id):
    board = client.rpc("board.getBoardByName", {"name": "homelab"})
    homarr.require(board.get("id") == expected_board_id and board.get("name") == "homelab" and board.get("isPublic") is True,
                   "Existing public board ownership differs")
    before = {item["id"]: item for item in board.get("items", [])}
    homarr.require(len(before) == len(board.get("items", [])), "Duplicate existing board item identity")
    apps = client.rpc("app.all")
    homarr.require(isinstance(apps, list), "Application list differs")
    matches = [app for app in apps if app.get("href") == URL]
    homarr.require(len(matches) <= 1, "Multiple Home Assistant bookmarks already exist; review before adding")
    created = False
    if matches:
        app_id = matches[0]["id"]
    else:
        app = client.rpc("app.create", {"name": "Home Assistant", "description": "Smart home platform", "href": URL,
                                         "iconUrl": "/favicon.ico", "pingUrl": None}, mutation=True)
        app_id = app.get("appId")
        homarr.require(isinstance(app_id, str) and app_id, "Created Home Assistant application identity missing")
        created = True
    cards = [item for item in before.values() if item.get("kind") == "app" and item.get("options", {}).get("appId") == app_id]
    homarr.require(len(cards) <= 1, "Multiple Home Assistant board cards already exist")
    new_item = None
    if not cards:
        added = client.rpc("board.addItem", {"boardId": board["id"], "kind": "app",
                                             "options": {"appId": app_id, "openIn": "newTab", "showTitle": True},
                                             "integrationIds": [], "size": {"width": 1, "height": 1}}, mutation=True)
        new_item = added.get("itemId")
        homarr.require(isinstance(new_item, str) and new_item, "Created Home Assistant card identity missing")
    after = client.rpc("board.getBoardByName", {"name": "homelab"})
    entries = {item["id"]: item for item in after.get("items", [])}
    homarr.require(after.get("id") == board["id"] and after.get("isPublic") is True
                   and after.get("sections") == board.get("sections") and after.get("layouts") == board.get("layouts"),
                   "Existing board structure changed during additive operation")
    homarr.require(all(entries.get(key) == value for key, value in before.items()), "Existing board items changed")
    expected_ids = set(before) | ({new_item} if new_item else set())
    homarr.require(set(entries) == expected_ids, "Unexpected board item appeared during additive operation")
    final_cards = [item for item in entries.values() if item.get("kind") == "app" and item.get("options", {}).get("appId") == app_id]
    homarr.require(len(final_cards) == 1, "Home Assistant bookmark placement missing")
    # The public response must expose the same new app/card; no visibility or
    # permissions change is required and no anonymous mutation is attempted.
    return {"application_created": created, "card_added": bool(new_item), "existing_items_preserved": len(before)}


def main():
    import fcntl
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", required=True)
    args = parser.parse_args()
    homarr.require(os.geteuid() == 0, "Run as root inside the managed app guest")
    directory = homarr.PRIVATE
    info = directory.lstat()
    homarr.require(info.st_uid == 0 and (info.st_mode & 0o777) == 0o700 and not directory.is_symlink(),
                   "Private runtime directory differs")
    admin = homarr.private_json(directory / "admin.json")
    state = homarr.private_json(directory / "bootstrap.json")
    homarr.require(state.get("phase") == "finished" and state.get("board_verified") is True and state.get("board_id"),
                   "Verified existing board provenance required")
    fd = os.open("/var/lib/homelab/homarr-bootstrap.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        base = homarr.inspect_address(args.container)
        client = homarr.Client(base)
        homarr.require(client.login(admin), "Existing administrator authentication failed")
        result = add_link(client, state["board_id"])
        public = homarr.Client(base)
        board = public.rpc("board.getBoardByName", {"name": "homelab"})
        ids = [item.get("options", {}).get("appId") for item in board.get("items", []) if item.get("kind") == "app"]
        rows = public.rpc("app.byIds", ids)
        homarr.require(sum(row.get("href") == URL for row in rows) == 1, "Public Home Assistant card is unavailable")
        print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except homarr.Refused as error:
        print("Homarr Home Assistant link refused: " + str(error), file=sys.stderr)
        sys.exit(1)
    except Exception:
        print("Homarr Home Assistant link refused; existing private state preserved", file=sys.stderr)
        sys.exit(1)
