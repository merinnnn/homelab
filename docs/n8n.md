# n8n

n8n is hosted on apps01 (pve02 VM100, static 192.168.1.58) behind the existing Caddy proxy at https://n8n.home.arpa/. Local DNS and trust in the existing public Caddy root are required. No new LAN address, published n8n/database/runner port or WAN forwarding is used. Internet-facing webhook callbacks require a separately designed ingress; this deployment is local.

The `homelab-n8n` Compose project has n8n2.47.7, its matching external JavaScript/Python runner image and PostgreSQL16.16. Initial official tags resolve to digests, retained for repeat deployment. Upgrades require a reviewed version/migration and backup. PostgreSQL uses a private internal network; only n8n joins the proxy network. The external runner has no database connection or Docker socket. Concurrency, memory, logs and execution retention are bounded. Execution history prunes after seven days/1000 entries; successful production execution data is not saved. Community packages and diagnostic/template requests are disabled. A Code node is not a security boundary for untrusted administrators; keep the owner account private.

## Deploy from the owning node

Read AGENTS.md and inspect the installed checkout, live ownership and resource capacity first. apps01 has 4 GiB RAM after a guarded graceful guest restart. Do not reboot physical nodes or change household DNS.

```bash
# On pve02, from /root/homelab:
bash scripts/deploy/proxmox-n8n.sh 100
```

This installs public payloads from the checkout into `/opt/homelab/n8n-payload`, creates private configuration and starts the three healthy services. It refuses unknown projects/volumes, private-state drift, missing managed data or unexpected release state. It retains prior releases and persistent data on failures. It does not expose the new owner-setup screen through Caddy.

Before adding the proxy route, run `n8n-bootstrap.py prepare` inside apps01 with a private JSON email input on stdin, then `bootstrap --base-url http://<inspected-owned-Docker-IP>:5678`. The helper accepts only the inspected managed n8n container address, generates the owner password once, claims the instance, verifies fresh login and rejects repeat owner setup. Identity comes from private operator input, never source. Do not put the password or account JSON in arguments/logs. Existing ownership markers forbid reclaiming a reset instance.

Only after bootstrap succeeds, apply the updated proxy from the pve02 checkout and local records on each owning node using the existing documented helpers. Enable `homelab-n8n-backup.timer` inside apps01. The fixed-origin HTTPS verification command is:

```bash
python3 /opt/homelab/n8n-payload/scripts/deploy/n8n-bootstrap.py verify \
  --base-url https://n8n.home.arpa \
  --ca-file /opt/homelab/reverse-proxy/root.crt --workflow
```

It checks authentication/setup closure and runs an inactive synthetic Manual Trigger -> Code workflow returning42 through the external runner. It deletes only its exact unchanged fixture. It sends no external messages. A retained `active_probe` marker requires inspection before another acceptance run.

## Private state and recovery

`/etc/homelab/n8n` is root0700: root0600 encryption-key, PostgreSQL password, runner token, three raw env files and checksum manifest, plus owner.json/bootstrap.json. Docker reads private env files on the host; no root0600 secret is directly mounted for UID1000. Container administrators/root can inspect runtime environments. Do not print them. Owner credentials are also saved in the existing private desktop service-credentials file; no SMTP password-reset delivery is configured.

Named volumes `homelab-n8n-postgres-data` and `homelab-n8n-data` must remain paired with the original encryption key. Never create replacement empty volumes or rotate the encryption key to repair a start failure. Volumes and all containers carry `io.homelab.managed=n8n-v1`. `/opt/homelab/n8n/current` points to a retained, manifest-verified private release.

The systemd backup timer runs daily at03:30 Europe/London plus up to five minutes jitter. It briefly stops n8n and runners under an independent recovery timer, leaves PostgreSQL running, validates a custom-format logical `pg_dump`, then archives all user-folder/binary data, private runtime and pinned release settings into root0600 `/var/backups/homelab-n8n`. Services must become healthy before disarming recovery. Snapshots include credentials; never place them in Git or this project's public notes. There is no automatic retention or recurring off-node transfer. Keep disk usage under review.

Restore into a separate empty database/user-folder volume with the exact image pins and original encryption key. Validate archive paths first. Restore the logical dump with `pg_restore`, numeric user-folder ownership, private settings and matching key; verify inactive workflows and decrypted test credentials through maintenance CLI before allowing triggers. Never restore over running production data to test a backup. A same-node snapshot is not protection against losing pve02.

`homarr-add-n8n.py` uses the existing Homarr administrator/API to add one bookmark, preserving existing cards/layouts. It refuses ambiguous duplicates and is idempotent. The original seven-card onboarding seed/provenance remains unchanged.

## Validation boundaries

Offline behavior tests cover deployment ownership/drift/rollback, private owner setup, additive dashboard changes and backup failure recovery. They use mocks and do not establish live operation. Live evidence, image digests, workflow execution, restart, backup/isolated restore results and current limitations belong in the dated setup-status and external Knowledge report. Physical power restoration and native visual browser rendering are separate checks.
