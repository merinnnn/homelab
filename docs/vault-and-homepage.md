# Vaultwarden and dashboard history

The dashboard has been replaced by Homarr at the same URL; see [Homarr](homarr.md). Homepage deployment/tests below describe the previous phase and are historical. Use proxmox-homarr.sh for the current dashboard.

Live status — 1 November 2026: both HTTPS services are healthy; five real frontend/policy/Host checks PASS; owner invitation/repeat verified, one pending owner persists after restart. A separate synthetic account/item passed real encryption/login/cold restore/fresh decryption and closed signup tests in disposable resources, all cleaned. The first production full-data backup passed SQLite integrity/service recovery and was privately copied off-node. Daily backups run automatically inside the VM; recurring off-node transfer remains unconfigured. No real owner master password was created by an agent.

Deploy from /root/homelab on pve02. Both services run inside permanent apps01 VM100 at static192.168.1.58. They publish no host ports, join the existing owned Caddy network and use HTTPS home.arpa names through the proxy.

```bash
bash scripts/deploy/proxmox-homepage.sh 100
bash scripts/deploy/proxmox-vaultwarden.sh install 100
# Prepare one root-owned mode600 JSON outside Git containing only the owner email.
bash scripts/deploy/proxmox-vaultwarden.sh invite 100 /etc/homelab/vaultwarden-owner.json
bash scripts/deploy/proxmox-reverse-proxy.sh 100 home.arpa /etc/homelab/proxy-trust
```

Apply configs/local-services.json to both Pi-holes with proxmox-local-dns.sh. Existing Windows suffix-only NRPT and public-root trust cover the new names; other clients still need their own DNS/trust setup. Router AdGuard-first DNS and existing service IPs stay unchanged.

Homepage: https://home.home.arpa/ — static service cards, no API credentials/Docker socket, explicit host allowlist, managed read-only config. Vaultwarden: https://vault.home.arpa/ — Bitwarden-compatible web vault. Both images resolve their reviewed release tags to immutable digests; repeat deployments retain the pin and protect unknown configurations/data.

Vaultwarden registrations and organization invitations are disabled. The admin can invite the one owner through private runtime input without SMTP; no email message is sent. The owner completes registration directly at https://vault.home.arpa/#/signup using the exact invited email and a self-chosen master password. Never enter the master password in chat, scripts or notes. The admin token is separate from that master password.

Private VM runtime files: /etc/homelab/vaultwarden/{admin-token,admin-token.argon2,service.env}, root-only outside Git. Data persists in homelab-vaultwarden-data, root-only. Never delete that volume or store its contents in the repo/vault. The admin hash is Argon2id and Compose reads its raw env file without interpreting dollar signs. SMTP/password-reset email is not configured. User account creation, real-client login and imported real passwords require the owner; source/health checks alone do not establish them.

The native homelab-vaultwarden-backup.timer takes a daily consistent full-data snapshot at03:15 Europe/London with up to5 minutes jitter. It briefly stops only Vaultwarden, snapshots its SQLite database/attachments/sends/signing keys, and restores service health under an independent recovery timer. Backups and SHA256 files stay root-only in /var/backups/homelab-vaultwarden. A same-VM backup does not protect against loss of the node/storage. Copy backups to an independent private location; the latest project report records any tested copy/restore. No automated retention/deletion is configured.

Restore only into a new empty volume with compatible pinned image; never merge a backup over a running vault or inherit another database's WAL files. Keep existing data until a separate restored instance has been verified. Service admin credentials can be regenerated separately; recovering a vault does not recover a forgotten master password.

Validation: run scripts/tests/homepage-offline.sh, scripts/tests/vaultwarden-offline.py, the proxy/local-DNS suites and identity audit. Live acceptance covers private networking, effective closed-signup policy/admin auth, owner invitation, HTTPS hostnames, dashboard contents/host validation, restart/repeat persistence, and isolated encrypted vault-item backup/restore. No test creates a real owner master password. Dated evidence and unrun owner steps live in the external Obsidian vault.
