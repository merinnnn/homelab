# Homarr dashboard

Homarr 2.10.1 replaces Homepage at https://home.home.arpa/. It runs inside permanent apps01 VM100 on pve02, private Docker alias homelab-homarr:7575 on the existing Caddy network. It has no published backend port or Docker socket. The public board contains eight service cards, including n8n; administration requires its private account.

Deploy from the actual /root/homelab checkout on pve02:

```bash
bash scripts/deploy/proxmox-homarr.sh 100
# Bootstrap must succeed before switching the public route:
bash scripts/deploy/proxmox-reverse-proxy.sh 100 home.arpa /etc/homelab/proxy-trust
```

The installer resolves the reviewed official release to an immutable digest, generates a persistent root-only encryption key and retains the named homelab-homarr-data volume at /appdata. The native health endpoint is /api/health/live. API onboarding creates the first administrator and seven-card homelab board before proxy activation; there is no direct database mutation. Repeat runs verify owned configuration/accounts/links and refuse unknown state. The board is publicly readable on the LAN; anonymous writes, onboarding reclaim and wrong-password login are rejected. Cards contain links only, no service API credentials. Source services.json defines the initial cards. After the verified-board marker exists, repeats preserve added cards/widgets while requiring all seven original deterministic app IDs/names/URLs to remain intact. Missing or changed original links still cause refusal; initial onboarding/pruning stays strict. Never reset the database to pass a test.

Private files inside apps01: /etc/homelab/homarr/{encryption-key,managed-v1,admin.json,bootstrap.json}, root-only. The generated admin password is unrelated to the Vaultwarden master password. Never print/copy these files into Git/notes. A private desktop account-store entry is supplied after successful setup. Save the encryption key alongside consistent full /appdata backups; losing it prevents decryption of saved integration secrets. This initial board has no integrations. Homarr database/board/key persistence must pass a container restart. No recurring independent Homarr backup job is created here.

Docker uses both local Pi-hole resolvers and NODE_EXTRA_CA_CERTS with the existing PUBLIC Caddy root so friendly local HTTPS URLs resolve and validate. Private CA signing keys never leave Caddy. No router, household DNS policy, static IP, management service or WAN forwarding change is needed.

After Homarr is validated, retire only the owned homelab-homepage Compose project using its retained VM /opt/homelab/homepage/current files; verify project/service/network ownership before stopping/removing its container. Retain old configuration releases as rollback evidence. Active Homepage source helpers/configs/tests are removed; their history remains in Git. No shared Caddy network or unrelated volume is removed. To recover the previous dashboard, restore the previous source revision/configuration through a reviewed migration.

Checks: homarr-offline.sh, homarr-bootstrap-offline.py, reverse-proxy-offline.sh, shell syntax and identity audit; native startup/onboarding/login/read-only board links, repeat, private key/volume persistence, retained local CA and all existing service pages. Current dated results and explicit limits are in the Obsidian Homarr report. Backend-only API checks are separate from visual browser verification.

Homarr2.10.1 seeds four sample cards and three sample widgets before onboarding. The bootstrap removes those board items once only when the private board provenance, seven deterministic project apps, exact upstream defaults and unchanged item settings all match. It uses the normal board editor API and preserves accounts, source app records, sections and retained item layouts. After successful verification, a private marker disables automatic pruning of later customizations. Unknown or customized content is refused. The first live migration retained a private cold backup before this cleanup.

15November2026: `homarr-add-n8n.py --container <owned-homarr-id>` adds only the n8n bookmark through normal additive editor APIs. It retains all seven existing item IDs/options/layouts/sections, never rewrites services.json or private bootstrap provenance, and refuses ambiguous duplicates. The second run made no changes and public visibility/original-link/auth checks passed with eight cards. No new Homarr integration or dashboard administrator account was created.
