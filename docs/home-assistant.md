# Home Assistant OS

Deployed and verified on 16 November 2026. Home Assistant runs at https://ha.home.arpa/ and is linked in Homarr.

## Permanent guest and access

| Item | Configuration |
| --- | --- |
| Owning node / guest | pve01 / permanent VM102, ha01 |
| Resources |2 vCPU,4GiB RAM,32GiB system disk, local-lvm |
| NIC | VirtIO, MAC BC:24:11:32:8F:61 |
| Final network | vmbr0, static/reserved192.168.1.211/24; gateway192.168.1.1; DNS192.168.1.210/192.168.1.150/94.140.14.14 |
| Friendly address | https://ha.home.arpa/ |
| Direct recovery address | http://192.168.1.211/ |
| Software | Official HAOS18.4 KVM image; Core2026.11.1, Supervisor2026.11.0 |

This dedicated HAOS guest provides Supervisor and the Home Assistant app system. It is separate from apps01 Docker and retains its own persistent system/data disk. No device pairing, real automation, radio/USB passthrough, public ingress or Home Assistant Cloud account was configured by this setup. Pair devices and create real automations privately in the UI.

The friendly URL uses Caddy on pve02/apps01. If pve02 or apps01 is unavailable while pve01/ha01 survives, use the direct HTTP address on the trusted home network. Its HTTP traffic is not encrypted. HA itself and supported local automations can continue on pve01; individual devices and cloud integrations have their own dependencies. Local names also require a surviving configured local DNS resolver. Household internet DNS remains the accepted AdGuard-first policy and does not depend on HA or the proxy.

## Deployment and ownership

Run repository helpers from the actual `/root/homelab` Git checkout on pve01. The official HAOS18.4 KVM QCOW2 compressed asset is pinned by exact SHA256 and length before decompression/import.18.5 was a Pi-specific release. The installer checks qcow2 format, virtual size, backing-file absence and qemu-img integrity before guest mutation. Configuration is UEFI/q35,4MiB EFI disk without enrolled Secure Boot keys, VirtIO SCSI with discard/iothread/ssd, guest agent, onboot and startup order20. No cloud-init or Debian bootstrap is applied to HAOS.

For the **already installed final guest**, this command performs ownership/configuration verification and never reimports/resizes/resets existing disks:

```sh
cd /root/homelab
python3 scripts/provision/home-assistant-vm.py install 102 BC:24:11:32:8F:61 --bridge vmbr0
```

Ownership is recorded in root0600 `/var/lib/homelab/home-assistant/vm-102.json`, including exact original scsi0/EFI volume strings, image provenance, VMID/MAC and bridge. Unknown existing IDs, missing/partial state, missing owned guests, changed disks/options, extra disks/NICs and unsafe manifest permissions are refused. A failed creation/promotion leaves its partial resource and phase marker for explicit inspection. The installer does not destroy/reset/clean up guests or silently replace a missing disk/VM.

Historical first installation used `install ... --bridge vmbr1` and produced a stopped guest. Fresh creation on vmbr0 is explicitly refused. The coordinator started it privately, claimed and authenticated the owner, completed onboarding and disabled analytics, reserved the LAN address, configured guest static networking through the native ha network command and used guarded `promote-lan`. Promotion requires the matching root0600 successful bootstrap marker and changes only the owned NIC bridge. Do not move the current guest back to vmbr1 or replay first-install commands as diagnostics.

## Accounts and reverse proxy

The local owner is `admin`. A random password and API refresh/access tokens are stored privately on pve01 under root0700 `/etc/homelab/home-assistant`: root0600 `owner.json`, `auth.json` and `bootstrap.json`. The existing private desktop services.json store contains the login and separate backup recovery password in its homeAssistant entry; ACLs allow only the user, SYSTEM and Administrators. Do not put account values, tokens or full authenticated API/log output in Git, this documentation or Obsidian. Change credentials privately in the UI and keep the private service store current. No real owner's email, master password or device secrets are needed in source.

HAOS Core2026.11 uses native HTTP80; the Container installation's usual8123 must not be assumed here. The backend port, exact Core version and WebSocket settings must be observed again after upgrades. Current HTTP settings are managed through the Home Assistant UI/WebSocket API with a timed trial, rather than old YAML-only guidance. The helper stages forwarded-client-IP handling with **only192.168.1.58/32 trusted as proxy**, then promotes the trial only after authenticated HTTPS/WebSocket verification. Core canonical internal URL is https://ha.home.arpa and timezone is Europe/London.

Public Caddy root trust remains the existing homelab CA. Only its public certificate is copied to pve01 as `/etc/homelab/home-assistant/proxy-root.crt`; private CA keys stay in apps01's persistent Caddy volume. Do not bypass certificate checks or broaden trusted_proxies to the LAN. Other client devices need their own local DNS/public-root trust; Windows NRPT/CurrentUser trust does not configure them automatically.

Read-only authentication/proxy verification after final publication:

```sh
cd /root/homelab
python3 scripts/deploy/home-assistant-runtime.py verify
python3 scripts/deploy/verify-home-assistant.py
```

The first uses the private owner token and validates HTTPS hostname/CA while dialing the fixed Caddy IP. The independent verifier reports safe booleans for ownership/static address, TLS/redirects, anonymous denial, authenticated REST/WebSocket owner, stable trusted proxy and encrypted backup policy. A failure does not authorize resetting accounts, disks, HTTP settings or backup policy. Inspect privately before changing state.

## Native encrypted backups

The implemented policy configures native Home Assistant daily04:45 Europe/London encrypted backups to the local Supervisor agent `hassio.local`: HA configuration/database, all installed apps, and share/ssl/media/addons/local folders. Automatic deletion/retention is disabled. Native backups reside inside HAOS; this creates a backup on the same VM/node and cannot protect against losing that storage alone.

Private root0600 `backup-password` and `backup-managed.json` under `/etc/homelab/home-assistant` preserve encryption/recovery provenance. Keep the recovery password/emergency kit separately from the backup and outside Git/vault. A backup file without its matching recovery secret is insufficient. Guarded repeats refuse changed owned policy/password markers rather than overwrite them.

After policy is configured, the following creates a new native encrypted backup of all configured parts, waits for completion and exports it to root0700 `/var/backups/homelab-home-assistant` on pve01, writing a root0600 archive and checksum. This is an intentional backup operation, not a read-only probe:

```sh
cd /root/homelab
python3 scripts/deploy/home-assistant-backup.py create
```

The code verifies unambiguous native completion, encrypted metadata, component archive headers and exported size/SHA256. It never prints archive contents or the recovery secret and never restores or automatically deletes backups. A safe structural read-only check of an exact existing export is:

```sh
python3 scripts/deploy/home-assistant-backup.py inspect --archive /var/backups/homelab-home-assistant/EXACT_EXISTING_BACKUP.tar
```

`verify-home-assistant-backup-crypto.py --archive <exact-export>` is a separate read-only decryption/integrity test against the owned Supervisor's matching native backup, with wrong-password rejection and no plaintext extraction. Structural validation, successful decryption and an actual restore are distinct claims. Do not describe the first two as a tested restore.

Initial encrypted off-node copy, separate recovery-secret storage and SHA/ACL verification passed. The exported archive home-assistant-aa95035d.tar is 1259520 bytes; SHA256 c8a803d0070999095ef3b903e5309c92452f8831105175ac85dcb4d7cf81a104. A prior initial export is also retained. Private desktop backups are under .config/homelab/backups/home-assistant; no backup or recovery values belong in Git or Obsidian. Recurring off-node export/transfer, retention/capacity alerting and an isolated actual restore remain separate unless explicitly completed. Restore only into a separately allocated, isolated target with an explicit plan to prevent duplicate device control; never restore/reset permanent VM102 merely to make acceptance pass. Preserve original volumes/manifest/accounts and use the matching backup recovery secret. No production restore command is implemented by these helpers.

## Recovery checks

On pve01, these checks inspect state without modifying HA, devices, disks or network:

```sh
qm status 102
qm agent 102 ping
qm agent 102 network-get-interfaces
cd /root/homelab
python3 scripts/provision/home-assistant-vm.py install 102 BC:24:11:32:8F:61 --bridge vmbr0
```

If the proxy path fails, check the direct HTTP endpoint before changing HA. If a guest is stopped and its manifest/disks/configuration are verified, starting that existing VM is a separate deliberate recovery action; do not recreate it. If QGA or networking is unavailable, use the existing Proxmox console and inspect the owned guest privately. A failed health check is not permission to rerun host storage/network bootstrap, reset onboarding, replace accounts or attach a new empty disk.

Onboot/startup configuration supports automatic startup when pve01 boots. It does not prove household blackout recovery, BIOS power-return behavior, router cold boot, UPS behavior, storage failure recovery or HA availability when pve01 is off. HA has no cross-node high availability.

## Acceptance and limits

Live PASS: official image pin/import and owned repeat; private owner/password login and closed onboarding; saved router reservation; guest static networking/hostname; both Pi-holes17 records; native Caddy config and all11 Windows default-trust HTTPS pages; additive Homarr9 cards/repeat0 preserving8; all30 independent REST/WebSocket/TLS/auth/backup checks. A graceful guest reboot changed the kernel boot ID, recovered the guest agent and preserved the static IP/owner/proxy settings; the temporary host start guard was stopped. Host onboot is configured; no physical host reboot occurred.

The daily encrypted backup policy repeats without changes. A post-reboot native backup completed/exported with five protected SecureTarV3 components; every component passed decryption/integrity and a random wrong password was rejected without extracting plaintext. Its checksum matches the original Supervisor archive and the private off-node copy. Native raw metadata uses apps/local while Core's compatibility API returns addons/local; the checker recognizes only that alias. Supervisor intentionally omits supervisor.tar.gz when no network mounts/private Docker registries exist; use --require-supervisor for create/inspect if such configuration needs protection. All configured folders and HA/database remain required. Native metadata calls this partial even when it includes all configured parts.

Offline native Linux PASS:16 installer fault tests,28 owner/transport/proxy/hostname tests,15 backup tests,3 independent-verifier request regressions,4 additive Homarr tests,36 proxy assertions and6 DNS tests. These are mocks and do not count as live tests. Hosted CI was not run. The identity-free script audit passed. Existing10 apps01 containers remained healthy, both node exporters responded and both Pi-holes blocked the test ad domain.

NOT RUN: an actual restored HA backup, physical power/BIOS/router cold boot, visual browser, real device pairing/automation/radios/USB, arbitrary workload capacity and cross-node HA. No WAN/cloud ingress, recurring off-node backup transfer/retention or HA-specific alert was configured. Existing monitoring cannot notify when its own node/power/internet is lost. The native daily schedule was configured and verified; waiting for a future scheduled run was not tested. The current setup is ready for device pairing in the UI.
