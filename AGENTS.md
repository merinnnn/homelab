# Homelab working instructions

Inspect Git status/diff and preserve existing changes before editing. The November 2026 run began with an uncommitted change to `scripts/provision/provision-debian-vm.sh`; later fixes build on it. Read `README.md`, `docs/setup-status.md` and `docs/networking.md` before running setup scripts.

The local continuity record is the Obsidian vault at `C:\Users\merin\Documents\ChatGPT\Homelab\Knowledge`. Read `00 Start Here.md`, `Agent Guide.md`, current state, setup continuation and the latest test reports. If this path is unavailable, use the repository status documentation and explicitly report the missing live evidence. Update the vault after material work; never write credentials, private keys or tokens to notes or Git.

Both nodes are standalone. Each node's vmbr1 is host-local, despite using the same subnet. Inspect current guests, volumes, services, routes and firewall rules before mutation. A failed ping does not establish isolation. Do not run bootstrap/storage scripts as tests. Preserve unrelated nftables rules and host management access.

One coordinator owns shared host mutations, guest allocation and cleanup. Record test ownership before creating resources; clean up only resources created by the current test. Historical guest IDs are not reservations. Do not overwrite remote `/root/homelab` working trees: they may have independent uncommitted work.

Use meaningful offline tests for failure behavior, then controlled live checks where access is authorized. Report PASS/FAIL/BLOCKED/NOT RUN with evidence; distinguish mock results, current live results, historical evidence and plans. Leave a concrete handoff and list remaining resources and material untested behavior. No commits, pushes or host reboots are implied by testing.

User preference: make one Git commit per major repository change with a simple message. Do not add co-author trailers unless requested. Commit completed, verified work; pushing remains separate.
