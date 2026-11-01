# Homelab working instructions

Run deployments from the repository checkout at /root/homelab on the appropriate Proxmox node. Read README.md, docs/deployment.md, docs/setup-status.md and docs/networking.md first. Inspect Git status/diff and live ownership before changes; preserve existing work. Do not use personal desktop paths, embedded identities, assumed identity filenames, or generated desktop bootstrap payloads in repository scripts.

Keep authorized keys, private keys, passwords, tokens and runtime account files outside Git. Scripts use standard authentication configuration or explicit public input. Private runtime files belong in /etc/homelab with root-only access. Never copy their contents into notes, logs or command arguments. The identity-free script audit is a required check.

Both nodes are standalone. Each vmbr1 is host-local despite sharing a subnet. VM100 on pve02 is permanent apps01; CT100 on pve01 is permanent dns01. Do not remove them as old test resources. One coordinator owns shared host changes, guest allocation and cleanup. Preserve unrelated nftables rules and management access. A failed ping does not establish isolation. Do not rerun bootstrap/storage scripts as diagnostics.

Preserve independent server edits before updating checkouts. Use backups/stashes and fast-forward merges; do not discard dirty work. Guest payloads come from the installed checkout. Verify the same intended commit is installed on both nodes and record any retained server work.

Report PASS/FAIL/BLOCKED/NOT RUN with evidence, separating mocks, live observations, historical records and plans. Update repository deployment/status docs and the external knowledge vault when available. Deployment is incomplete until services, authentication, monitor/DNS behavior and persistence are verified.

Make one Git commit per major completed repository change with a simple message. Do not add co-author trailers unless requested. Pushing and host reboots remain separate actions.

Household browsing must remain independent of Pi-hole and either Proxmox node. Current router DNS is public resolvers first, Pi-hole third; network-wide filtering is best effort. Do not restore Pi-hole-only household DNS. Review docs/pihole.md and verify a bounded outage with automatic recovery before changing this policy.
